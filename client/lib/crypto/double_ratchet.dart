import 'dart:typed_data';
import 'package:sodium_libs/sodium_libs.dart';

import 'keys.dart';
import 'kdf.dart';
import '../shared/utils/logger.dart';

const int dhRatchetAfterMessages = 100;

/// Maximum number of messages we will skip (and cache keys for) in one chain.
/// Protects against DoS via artificially large counters.
const int maxSkip = 1000;

/// Maximum total number of skipped message keys held in memory + DB.
/// Signal spec allows 2000; we use a slightly lower limit.
const int maxSkippedKeys = 2000;

/// Skipped keys older than this are evicted to prevent unbounded accumulation.
const int skippedKeyTtlSeconds = 3600; // 1 hour

class EncryptedMessage {
  final Uint8List ciphertext;
  final int counter;
  final int previousCounter;
  final Uint8List? newEphemeralKey;

  const EncryptedMessage({
    required this.ciphertext,
    required this.counter,
    required this.previousCounter,
    this.newEphemeralKey,
  });
}

/// A cached message key for an out-of-order message.
///
/// [chainIndex] is the DH ratchet epoch (increments on each DH ratchet step).
/// [counter]    is the symmetric-ratchet counter within that epoch.
/// [key]        is the derived 32-byte message key (XChaCha20-Poly1305 key).
class SkippedKey {
  final int chainIndex;
  final int counter;
  final Uint8List key;

  SkippedKey({
    required this.chainIndex,
    required this.counter,
    required this.key,
  });
}

class RatchetState {
  Uint8List rootKey;
  Uint8List sendChainKey;
  Uint8List recvChainKey;
  X25519KeyPair myEphemeral;
  Uint8List? peerEphemeral;

  int sendCounter = 0;
  int recvCounter = 0;

  /// Messages sent in the current send chain (since last DH ratchet).
  int sendCounterSinceRatchet = 0;

  /// Counter within the current recv chain (resets on each DH ratchet).
  int recvCounterInChain = 0;

  /// DH ratchet epoch index for the recv chain. Increments each time we
  /// perform a DH ratchet step (i.e., receive a new peer ephemeral key).
  /// Used to namespace skipped keys so we never confuse keys from different
  /// ratchet generations.
  int recvChainIndex = 0;

  /// Skipped message keys: messages we received out-of-order.
  /// Keyed by a composite: (chainIndex << 32 | counter).
  /// Values are zeroed immediately after use.
  /// Each entry has a creation timestamp for TTL eviction.
  final Map<int, Uint8List> skippedKeys = {};

  /// Creation time (unix seconds) for each skipped key, same keys as [skippedKeys].
  final Map<int, int> skippedKeysCreatedAt = {};

  RatchetState({
    required this.rootKey,
    required this.sendChainKey,
    required this.recvChainKey,
    required this.myEphemeral,
    this.peerEphemeral,
  });

  void dispose() {
    rootKey.fillRange(0, rootKey.length, 0);
    sendChainKey.fillRange(0, sendChainKey.length, 0);
    recvChainKey.fillRange(0, recvChainKey.length, 0);
    for (final k in skippedKeys.values) {
      k.fillRange(0, k.length, 0);
    }
    skippedKeys.clear();
    skippedKeysCreatedAt.clear();
    myEphemeral.dispose();
  }
}

/// Signal Protocol Double Ratchet with:
///   - Commit-after-verify: ratchet state only advances on successful decrypt.
///   - Skipped-message-key cache: out-of-order messages are tolerated up to
///     [maxSkip] positions ahead and [maxSkippedKeys] total cached keys.
///   - DH ratchet: advances send+recv chains every [dhRatchetAfterMessages]
///     messages for Post-Compromise Security.
class DoubleRatchet {
  final Sodium _sodium;
  final KDF _kdf;

  DoubleRatchet(this._sodium) : _kdf = KDF(_sodium);

  // ── Session initialisation ─────────────────────────────────────────────────

  /// Initiator session setup (Alice sends first message).
  RatchetState initSender({
    required Uint8List peerIdentityPubkey,
    required Uint8List peerEphemeralPubkey,
  }) {
    final myEphemeral = KeyGen(_sodium).generateX25519();

    final dh1 = _dh(myEphemeral.privateKey, myEphemeral.publicKey, peerIdentityPubkey);
    final dh2 = _dh(myEphemeral.privateKey, myEphemeral.publicKey, peerEphemeralPubkey);

    final masterSecret = Uint8List(64)
      ..setRange(0, 32, dh1)
      ..setRange(32, 64, dh2);

    final derived = _kdf.deriveInitial(masterSecret);
    masterSecret.fillRange(0, 64, 0);
    dh1.fillRange(0, dh1.length, 0);
    dh2.fillRange(0, dh2.length, 0);

    return RatchetState(
      rootKey: derived.sublist(0, 32),
      sendChainKey: derived.sublist(32, 64),
      recvChainKey: Uint8List(32),
      myEphemeral: myEphemeral,
      peerEphemeral: peerEphemeralPubkey,
    );
  }

  /// Responder session setup (Bob receives first message).
  RatchetState initReceiver({
    required SecureKey myIdentityPrivkey,
    required Uint8List myIdentityPubkey,
    required SecureKey myEphemeralPrivkey,
    required Uint8List myEphemeralPubkey,
    required Uint8List senderEphemeralPubkey,
  }) {
    final dh1 = _dh(myIdentityPrivkey, myIdentityPubkey, senderEphemeralPubkey);
    final dh2 = _dh(myEphemeralPrivkey, myEphemeralPubkey, senderEphemeralPubkey);

    final masterSecret = Uint8List(64)
      ..setRange(0, 32, dh1)
      ..setRange(32, 64, dh2);

    final derived = _kdf.deriveInitial(masterSecret);
    masterSecret.fillRange(0, 64, 0);
    dh1.fillRange(0, dh1.length, 0);
    dh2.fillRange(0, dh2.length, 0);

    return RatchetState(
      rootKey: derived.sublist(0, 32),
      sendChainKey: Uint8List(32),
      recvChainKey: derived.sublist(32, 64),
      myEphemeral: X25519KeyPair(
        publicKey: myEphemeralPubkey,
        privateKey: myEphemeralPrivkey,
      ),
      peerEphemeral: senderEphemeralPubkey,
    );
  }

  // ── Encrypt ────────────────────────────────────────────────────────────────

  EncryptedMessage encrypt(RatchetState state, Uint8List plaintext) {
    final doDH = state.sendCounterSinceRatchet >= dhRatchetAfterMessages &&
        state.peerEphemeral != null;
    Uint8List? newEphPubkey;

    if (doDH) {
      _dhRatchetSend(state);
      newEphPubkey = Uint8List.fromList(state.myEphemeral.publicKey);
    }

    final msgKey = _kdf.deriveMessageKey(state.sendChainKey);
    final nextChain = _kdf.deriveNextChainKey(state.sendChainKey);
    state.sendChainKey.fillRange(0, state.sendChainKey.length, 0);
    state.sendChainKey = nextChain;

    final counter = state.sendCounter++;
    state.sendCounterSinceRatchet++;

    final aead = _sodium.crypto.aeadXChaCha20Poly1305IETF;
    final nonce = _sodium.randombytes.buf(aead.nonceBytes);
    final ad = _ad(counter);

    final msgKeySecure = SecureKey.fromList(_sodium, msgKey);
    msgKey.fillRange(0, msgKey.length, 0);

    final encrypted = Uint8List.fromList(
      aead.encrypt(
        message: plaintext,
        additionalData: ad,
        nonce: nonce,
        key: msgKeySecure,
      ),
    );
    msgKeySecure.dispose();

    return EncryptedMessage(
      ciphertext: Uint8List.fromList([...nonce, ...encrypted]),
      counter: counter,
      previousCounter: doDH ? 0 : counter,
      newEphemeralKey: newEphPubkey,
    );
  }

  /// Encrypt [plaintext] using symmetric-only ratchet — no DH ratchet step.
  ///
  /// Used for multi-device sessions where multiple devices share the same
  /// logical recipient. DH ratchet is disabled because offline devices cannot
  /// track ephemeral key changes; symmetric-only still provides per-message
  /// forward secrecy via chain key derivation.
  EncryptedMessage encryptSymmetricOnly(RatchetState state, Uint8List plaintext) {
    final msgKey   = _kdf.deriveMessageKey(state.sendChainKey);
    final nextChain = _kdf.deriveNextChainKey(state.sendChainKey);
    state.sendChainKey.fillRange(0, state.sendChainKey.length, 0);
    state.sendChainKey = nextChain;

    final counter = state.sendCounter++;
    state.sendCounterSinceRatchet++;  // tracked but never triggers DH ratchet

    final aead  = _sodium.crypto.aeadXChaCha20Poly1305IETF;
    final nonce = _sodium.randombytes.buf(aead.nonceBytes);
    final ad    = _ad(counter);

    final msgKeySecure = SecureKey.fromList(_sodium, msgKey);
    msgKey.fillRange(0, msgKey.length, 0);

    final encrypted = Uint8List.fromList(
      aead.encrypt(
        message: plaintext,
        additionalData: ad,
        nonce: nonce,
        key: msgKeySecure,
      ),
    );
    msgKeySecure.dispose();

    return EncryptedMessage(
      ciphertext: Uint8List.fromList([...nonce, ...encrypted]),
      counter: counter,
      previousCounter: counter,
      newEphemeralKey: null,  // never rotated in symmetric-only mode
    );
  }

  // ── Decrypt ────────────────────────────────────────────────────────────────

  /// Decrypt an incoming message.
  ///
  /// Returns decrypted plaintext, or null if:
  ///   - The counter is too far ahead ([maxSkip] exceeded) — DoS guard.
  ///   - AEAD authentication fails — wrong key, tampered ciphertext.
  ///   - The message key is not in the skipped-key cache (too old / replay).
  ///
  /// **Commit-after-verify**: ratchet state (recvChainKey, recvCounter) is
  /// only advanced after AEAD succeeds. A failed decrypt leaves state intact,
  /// so the next legitimate message can still be decrypted correctly.
  ///
  /// **Out-of-order tolerance**: if [counter] > current [recvCounterInChain],
  /// we derive and cache all intermediate message keys before decrypting.
  /// Cached keys are bounded by [maxSkip] and [maxSkippedKeys].
  Uint8List? tryDecrypt(
    RatchetState state,
    Uint8List ciphertext,
    int counter, {
    Uint8List? newPeerEphemeral,
  }) {
    // ── 0. Validate input ────────────────────────────────────────────────
    if (newPeerEphemeral != null && newPeerEphemeral.length != 32) {
      AppLogger.w('DR', 'rejecting newPeerEphemeral: length ${newPeerEphemeral.length} != 32');
      return null;
    }

    // ── 1. Handle DH ratchet step ──────────────────────────────────────────
    if (newPeerEphemeral != null &&
        !_bytesEqual(newPeerEphemeral, state.peerEphemeral ?? Uint8List(0))) {
      // New peer ephemeral — perform DH ratchet and try to decrypt with the
      // new recv chain. If this fails we do NOT revert the ratchet (the DH
      // step is authenticated by the new ephemeral key being included in the
      // envelope — an attacker cannot forge a valid newEphemeralKey that also
      // passes AEAD in the subsequent decrypt).
      final result = _tryDecryptAfterDHRatchet(
        state, ciphertext, counter, newPeerEphemeral,
      );
      return result;
    }

    // ── 2. Check skipped-key cache (out-of-order / delayed message) ────────
    final skippedResult = _tryDecryptFromCache(state, ciphertext, counter);
    if (skippedResult != null) return skippedResult;

    // ── 3. In-order or slightly ahead — advance chain ──────────────────────
    return _tryDecryptFromChain(state, ciphertext, counter);
  }

  // ── Private decrypt helpers ────────────────────────────────────────────────

  /// Try to decrypt using the skipped-key cache.
  /// Evicts expired keys before lookup.
  Uint8List? _tryDecryptFromCache(
    RatchetState state,
    Uint8List ciphertext,
    int counter,
  ) {
    // Evict expired skipped keys.
    _evictExpiredSkippedKeys(state);

    final cacheKey = _skippedCacheKey(state.recvChainIndex, counter);
    final msgKeyBytes = state.skippedKeys[cacheKey];
    if (msgKeyBytes == null) return null;

    final result = _aeadDecrypt(ciphertext, counter, msgKeyBytes);
    if (result != null) {
      // Zero and remove the used key immediately.
      msgKeyBytes.fillRange(0, msgKeyBytes.length, 0);
      state.skippedKeys.remove(cacheKey);
      state.skippedKeysCreatedAt.remove(cacheKey);
    }
    return result;
  }

  /// Remove skipped keys older than [skippedKeyTtlSeconds].
  void _evictExpiredSkippedKeys(RatchetState state) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final expired = <int>[];
    for (final entry in state.skippedKeysCreatedAt.entries) {
      if (now - entry.value > skippedKeyTtlSeconds) {
        expired.add(entry.key);
      }
    }
    for (final key in expired) {
      state.skippedKeys[key]?.fillRange(0, state.skippedKeys[key]!.length, 0);
      state.skippedKeys.remove(key);
      state.skippedKeysCreatedAt.remove(key);
    }
    if (expired.isNotEmpty) {
      AppLogger.d('DR', 'evicted ${expired.length} expired skipped keys');
    }
  }

  /// Advance the current recv chain, caching skipped keys, then decrypt.
  Uint8List? _tryDecryptFromChain(
    RatchetState state,
    Uint8List ciphertext,
    int counter,
  ) {
    if (counter < state.recvCounterInChain) {
      // Counter is behind current position and not in cache → replay or already
      // delivered. Drop silently.
      return null;
    }

    final skip = counter - state.recvCounterInChain;
    if (skip > maxSkip) {
      // Too far ahead — DoS guard.
      AppLogger.w('DR', 'counter skip $skip > maxSkip $maxSkip — rejecting');
      return null;
    }
    if (state.skippedKeys.length + skip > maxSkippedKeys) {
      // Would overflow the cache — reject.
      AppLogger.w('DR', 'skipped key cache would overflow — rejecting');
      return null;
    }

    // Derive and cache keys for all skipped positions.
    // We work on a COPY of the chain key so state is only committed on success.
    var chainKeyCopy = Uint8List.fromList(state.recvChainKey);
    int counterCopy = state.recvCounterInChain;
    final toCache = <int, Uint8List>{};

    for (int i = 0; i < skip; i++) {
      final skippedMsgKey = _kdf.deriveMessageKey(chainKeyCopy);
      final nextChain = _kdf.deriveNextChainKey(chainKeyCopy);
      chainKeyCopy.fillRange(0, chainKeyCopy.length, 0);
      chainKeyCopy = nextChain;
      final ck = _skippedCacheKey(state.recvChainIndex, counterCopy);
      toCache[ck] = skippedMsgKey;
      counterCopy++;
    }

    // Derive the target message key (do NOT commit yet).
    final msgKeyBytes = _kdf.deriveMessageKey(chainKeyCopy);
    final nextChain = _kdf.deriveNextChainKey(chainKeyCopy);

    // Attempt AEAD decrypt — state only changes if this succeeds.
    final plaintext = _aeadDecrypt(ciphertext, counter, msgKeyBytes);
    msgKeyBytes.fillRange(0, msgKeyBytes.length, 0);

    if (plaintext == null) {
      // AEAD failed — discard everything, state unchanged.
      chainKeyCopy.fillRange(0, chainKeyCopy.length, 0);
      nextChain.fillRange(0, nextChain.length, 0);
      for (final k in toCache.values) {
        k.fillRange(0, k.length, 0);
      }
      return null;
    }

    // SUCCESS — commit state.
    state.recvChainKey.fillRange(0, state.recvChainKey.length, 0);
    state.recvChainKey = nextChain;
    state.recvCounterInChain = counterCopy + 1;
    state.recvCounter++;
    state.skippedKeys.addAll(toCache);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    for (final key in toCache.keys) {
      state.skippedKeysCreatedAt[key] = now;
    }
    chainKeyCopy.fillRange(0, chainKeyCopy.length, 0);

    return plaintext;
  }

  /// Perform a DH ratchet step, then attempt decrypt on the new recv chain.
  Uint8List? _tryDecryptAfterDHRatchet(
    RatchetState state,
    Uint8List ciphertext,
    int counter,
    Uint8List newPeerEphemeral,
  ) {
    // Save current state for rollback.
    final savedRootKey = Uint8List.fromList(state.rootKey);
    final savedRecvChainKey = Uint8List.fromList(state.recvChainKey);
    final savedPeerEphemeral = state.peerEphemeral != null
        ? Uint8List.fromList(state.peerEphemeral!)
        : null;
    final savedRecvChainIndex = state.recvChainIndex;
    final savedRecvCounterInChain = state.recvCounterInChain;
    // Save skipped keys so they can be rolled back if DH ratchet fails.
    final savedSkippedKeys = Map<int, Uint8List>.fromEntries(
        state.skippedKeys.entries.map(
            (e) => MapEntry(e.key, Uint8List.fromList(e.value))));
    final savedSkippedKeysCreatedAt = Map<int, int>.from(state.skippedKeysCreatedAt);

    // Perform DH ratchet (updates rootKey, recvChainKey, peerEphemeral).
    _dhRatchetRecv(state, newPeerEphemeral);

    // Try to decrypt with the freshly derived recv chain.
    final result = _tryDecryptFromChain(state, ciphertext, counter);

    if (result == null) {
      // Ratchet step failed — roll back to pre-ratchet state.
      state.rootKey.fillRange(0, state.rootKey.length, 0);
      state.rootKey = savedRootKey;
      state.recvChainKey.fillRange(0, state.recvChainKey.length, 0);
      state.recvChainKey = savedRecvChainKey;
      state.peerEphemeral = savedPeerEphemeral;
      state.recvChainIndex = savedRecvChainIndex;
      state.recvCounterInChain = savedRecvCounterInChain;
      // Rollback skipped keys — discard any keys added during failed attempt.
      for (final k in state.skippedKeys.values) {
        k.fillRange(0, k.length, 0);
      }
      state.skippedKeys
        ..clear()
        ..addAll(savedSkippedKeys);
      state.skippedKeysCreatedAt
        ..clear()
        ..addAll(savedSkippedKeysCreatedAt);
    } else {
      // Ratchet succeeded — discard saved copies.
      savedRootKey.fillRange(0, savedRootKey.length, 0);
      savedRecvChainKey.fillRange(0, savedRecvChainKey.length, 0);
      for (final k in savedSkippedKeys.values) {
        k.fillRange(0, k.length, 0);
      }
    }

    return result;
  }

  // ── AEAD ──────────────────────────────────────────────────────────────────

  Uint8List? _aeadDecrypt(Uint8List ciphertext, int counter, Uint8List msgKey) {
    try {
      final aead = _sodium.crypto.aeadXChaCha20Poly1305IETF;
      final nonceLen = aead.nonceBytes;
      if (ciphertext.length < nonceLen) return null;
      final nonce = ciphertext.sublist(0, nonceLen);
      final encrypted = ciphertext.sublist(nonceLen);

      final msgKeySecure = SecureKey.fromList(_sodium, msgKey);
      final plaintext = Uint8List.fromList(
        aead.decrypt(
          cipherText: encrypted,
          additionalData: _ad(counter),
          nonce: nonce,
          key: msgKeySecure,
        ),
      );
      msgKeySecure.dispose();
      return plaintext;
    } catch (e) {
      AppLogger.w('DR', 'AEAD decrypt failed (counter=$counter, ct=${ciphertext.length}b): $e');
      return null;
    }
  }

  // ── DH ratchet ─────────────────────────────────────────────────────────────

  void _dhRatchetSend(RatchetState state) {
    final newKP = KeyGen(_sodium).generateX25519();
    final dh = _dh(newKP.privateKey, newKP.publicKey, state.peerEphemeral!);
    final derived = _kdf.deriveRatchet(state.rootKey, dh);
    dh.fillRange(0, dh.length, 0);

    state.rootKey.fillRange(0, state.rootKey.length, 0);
    state.rootKey = derived.sublist(0, 32);
    state.sendChainKey.fillRange(0, state.sendChainKey.length, 0);
    state.sendChainKey = derived.sublist(32, 64);
    state.myEphemeral.dispose();
    state.myEphemeral = newKP;
    state.sendCounterSinceRatchet = 0;
  }

  void _dhRatchetRecv(RatchetState state, Uint8List newPeerEphemeral) {
    final dh = _dh(
      state.myEphemeral.privateKey,
      state.myEphemeral.publicKey,
      newPeerEphemeral,
    );
    final derived = _kdf.deriveRatchet(state.rootKey, dh);
    dh.fillRange(0, dh.length, 0);

    state.rootKey.fillRange(0, state.rootKey.length, 0);
    state.rootKey = derived.sublist(0, 32);
    state.recvChainKey.fillRange(0, state.recvChainKey.length, 0);
    state.recvChainKey = derived.sublist(32, 64);
    state.peerEphemeral = newPeerEphemeral;

    // New DH epoch — reset in-chain counter and bump chain index.
    state.recvChainIndex++;
    state.recvCounterInChain = 0;
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Composite cache key: upper 32 bits = chainIndex, lower 32 bits = counter.
  static int _skippedCacheKey(int chainIndex, int counter) =>
      (chainIndex << 32) | (counter & 0xFFFFFFFF);

  /// X25519 ECDH via kx clientSessionKeys / serverSessionKeys.
  /// Role is determined by comparing public keys so both sides independently
  /// arrive at the same role. Both sides use rx (client.rx == server.tx).
  Uint8List _dh(
    SecureKey myPrivateKey,
    Uint8List myPublicKey,
    Uint8List peerPublicKey,
  ) {
    final cmp = _compareBytes(myPublicKey, peerPublicKey);
    final SessionKeys session;
    final Uint8List shared;

    if (cmp <= 0) {
      session = _sodium.crypto.kx.clientSessionKeys(
        clientPublicKey: myPublicKey,
        clientSecretKey: myPrivateKey,
        serverPublicKey: peerPublicKey,
      );
      shared = Uint8List.fromList(session.rx.extractBytes());
    } else {
      session = _sodium.crypto.kx.serverSessionKeys(
        serverPublicKey: myPublicKey,
        serverSecretKey: myPrivateKey,
        clientPublicKey: peerPublicKey,
      );
      shared = Uint8List.fromList(session.tx.extractBytes());
    }
    session.rx.dispose();
    session.tx.dispose();
    return shared;
  }

  static int _compareBytes(Uint8List a, Uint8List b) {
    for (var i = 0; i < a.length && i < b.length; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return a.length - b.length;
  }

  /// Constant-time byte comparison — prevents timing side-channels.
  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static Uint8List _ad(int counter) {
    final buf = ByteData(8);
    buf.setInt64(0, counter, Endian.big);
    return buf.buffer.asUint8List();
  }
}
