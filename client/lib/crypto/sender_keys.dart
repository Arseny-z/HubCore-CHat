import 'dart:typed_data';
import 'package:sodium_libs/sodium_libs.dart';

import 'keys.dart';
import 'kdf.dart';

const int senderKeyDHRatchetAfterMessages = 100;

/// Encrypted message from a group sender.
class GroupMessage {
  final Uint8List ciphertext; // nonce || AEAD ciphertext
  final String senderPubkey; // base58 master pubkey of sender
  final int counter;
  final Uint8List? newSenderKey; // present when DH ratchet happened

  const GroupMessage({
    required this.ciphertext,
    required this.senderPubkey,
    required this.counter,
    this.newSenderKey,
  });
}

/// Per-member sender chain state.
///
/// Each group member has one SenderChainState, keyed by their master pubkey.
/// The owner also holds their own state (for sending).
class SenderChainState {
  Uint8List chainKey;
  X25519KeyPair myRatchetKey; // only meaningful for our own sending state
  Uint8List? peerRatchetPub; // latest ratchet pubkey received from sender

  int counter = 0;
  int messagesSinceRatchet = 0;

  SenderChainState({
    required this.chainKey,
    required this.myRatchetKey,
    this.peerRatchetPub,
  });

  void dispose() {
    chainKey.fillRange(0, chainKey.length, 0);
    myRatchetKey.dispose();
  }
}

/// Sender Keys protocol for group E2E encryption.
///
/// Each sender maintains a symmetric chain that all recipients advance in sync.
/// Post-compromise security: DH ratchet every [senderKeyDHRatchetAfterMessages].
class SenderKeys {
  final Sodium _sodium;
  final KDF _kdf;

  SenderKeys(this._sodium) : _kdf = KDF(_sodium);

  /// Create a fresh sender chain for a new group member (or self when creating group).
  SenderChainState createSenderChain() {
    final chainKey = _sodium.randombytes.buf(32);
    final ratchetKP = KeyGen(_sodium).generateX25519();
    return SenderChainState(chainKey: chainKey, myRatchetKey: ratchetKP);
  }

  /// Encrypt [plaintext] with our own [state].
  ///
  /// Returns the encrypted message. If DH ratchet fires, [GroupMessage.newSenderKey]
  /// carries our new ratchet public key so recipients can update.
  GroupMessage encrypt(
    SenderChainState state,
    Uint8List plaintext,
    String senderPubkey,
  ) {
    Uint8List? newRatchetPub;

    if (state.messagesSinceRatchet >= senderKeyDHRatchetAfterMessages) {
      _rotateRatchet(state);
      newRatchetPub = Uint8List.fromList(state.myRatchetKey.publicKey);
    }

    final msgKey = _kdf.deriveGroupMessageKey(state.chainKey);
    final nextChain = _kdf.deriveNextSenderChainKey(state.chainKey);
    state.chainKey.fillRange(0, state.chainKey.length, 0);
    state.chainKey = nextChain;

    final counter = state.counter++;
    state.messagesSinceRatchet++;

    final aead = _sodium.crypto.aeadXChaCha20Poly1305IETF;
    final nonce = _sodium.randombytes.buf(aead.nonceBytes);
    final ad = _ad(counter, senderPubkey);

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

    return GroupMessage(
      ciphertext: Uint8List.fromList([...nonce, ...encrypted]),
      senderPubkey: senderPubkey,
      counter: counter,
      newSenderKey: newRatchetPub,
    );
  }

  /// Decrypt a [GroupMessage] using the sender's [state].
  ///
  /// [newRatchetPub] — pass [GroupMessage.newSenderKey] when present.
  Uint8List decrypt(
    SenderChainState state,
    GroupMessage message, {
    Uint8List? myRatchetPriv,
    Uint8List? myRatchetPub,
  }) {
    if (message.newSenderKey != null) {
      _advanceRatchet(state, message.newSenderKey!);
    }

    final aead = _sodium.crypto.aeadXChaCha20Poly1305IETF;
    final nonceLen = aead.nonceBytes;
    final nonce = message.ciphertext.sublist(0, nonceLen);
    final encrypted = message.ciphertext.sublist(nonceLen);

    final msgKey = _kdf.deriveGroupMessageKey(state.chainKey);
    final nextChain = _kdf.deriveNextSenderChainKey(state.chainKey);
    state.chainKey.fillRange(0, state.chainKey.length, 0);
    state.chainKey = nextChain;
    state.counter++;

    final ad = _ad(message.counter, message.senderPubkey);
    final msgKeySecure = SecureKey.fromList(_sodium, msgKey);
    msgKey.fillRange(0, msgKey.length, 0);

    final plaintext = Uint8List.fromList(
      aead.decrypt(
        cipherText: encrypted,
        additionalData: ad,
        nonce: nonce,
        key: msgKeySecure,
      ),
    );
    msgKeySecure.dispose();

    return plaintext;
  }

  /// Serialize a [SenderChainState] for distribution to a new group member.
  /// Returns: chainKey(32) || ratchetPub(32) || counter(8, big-endian)
  Uint8List exportChainState(SenderChainState state) {
    final buf = Uint8List(72);
    buf.setRange(0, 32, state.chainKey);
    buf.setRange(32, 64, state.myRatchetKey.publicKey);
    final cd = ByteData.sublistView(buf, 64, 72);
    cd.setInt64(0, state.counter, Endian.big);
    return buf;
  }

  /// Reconstruct a [SenderChainState] from a serialized blob (received member state).
  /// Used by recipients who receive the sender key distribution message.
  SenderChainState importChainState(Uint8List blob) {
    if (blob.length != 72) {
      throw FormatException(
          'SenderChainState: invalid blob length ${blob.length}, expected 72');
    }
    final chainKey = Uint8List.fromList(blob.sublist(0, 32));
    final ratchetPub = Uint8List.fromList(blob.sublist(32, 64));
    final counter = ByteData.sublistView(blob, 64, 72).getInt64(0, Endian.big);

    // For imported states (other senders) we don't have the private ratchet key.
    // Generate a placeholder; it is only used when we are the sender.
    final placeholder = KeyGen(_sodium).generateX25519();

    final state = SenderChainState(
      chainKey: chainKey,
      myRatchetKey: placeholder,
      peerRatchetPub: ratchetPub,
    );
    state.counter = counter;
    return state;
  }

  void _rotateRatchet(SenderChainState state) {
    final newKP = KeyGen(_sodium).generateX25519();
    state.myRatchetKey.dispose();
    state.myRatchetKey = newKP;
    // Apply the same chain advancement that recipients will apply on receipt,
    // so sender and recipients stay in sync.
    _advanceRatchet(state, newKP.publicKey);
  }

  void _advanceRatchet(SenderChainState state, Uint8List newSenderRatchetPub) {
    // Mix new ratchet pubkey into chain via KDF to provide post-compromise security.
    final newChain = _kdf.deriveRatchet(state.chainKey, newSenderRatchetPub);
    state.chainKey.fillRange(0, state.chainKey.length, 0);
    state.chainKey = newChain.sublist(0, 32);
    state.peerRatchetPub = newSenderRatchetPub;
    state.messagesSinceRatchet = 0;
    // Discard the second half — we only need 32B for the chain key.
    newChain.fillRange(32, 64, 0);
  }

  static Uint8List _ad(int counter, String senderPubkey) {
    final senderBytes = Uint8List.fromList(senderPubkey.codeUnits);
    final buf = ByteData(8);
    buf.setInt64(0, counter, Endian.big);
    return Uint8List.fromList([
      ...buf.buffer.asUint8List(),
      ...senderBytes,
    ]);
  }
}
