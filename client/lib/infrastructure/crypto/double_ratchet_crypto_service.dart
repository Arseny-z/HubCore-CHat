import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium_libs/sodium_libs.dart';

import '../../crypto/identity.dart';
import '../../crypto/keys.dart';
import '../../domain/entities/group_post_envelope.dart';
import '../../domain/ports/crypto_port.dart';
import '../../domain/repositories/contact_repository.dart';
import '../../shared/utils/logger.dart';
import '../../shared/utils/pubkey_codec.dart';
import 'group_post_codec.dart';
import 'session_manager.dart';

export '../../domain/ports/crypto_port.dart';

/// Double Ratchet + NaCl box implementation of [CryptoPort].
///
/// Delegates all session operations to [SessionManager].
class DoubleRatchetCryptoService implements CryptoPort {
  final Sodium _sodium;
  final ContactRepository _contacts;
  final SessionManager _sessionManager;

  final Identity _identity;

  /// Rate limiter: track consecutive decrypt failures per contact.
  /// If a contact sends >_maxFailures messages that fail decrypt within
  /// _failureWindowMs, subsequent messages are dropped to prevent DoS
  /// via flooding with invalid ephemeral keys.
  static const _maxFailures = 20;
  static const _failureWindowMs = 60 * 1000; // 1 minute
  final _failureCounts = <String, int>{};
  final _failureFirstAt = <String, int>{};

  DoubleRatchetCryptoService({
    required Sodium sodium,
    required Identity identity,
    required ContactRepository contacts,
    required SessionManager sessionManager,
  })  : _sodium = sodium,
        _identity = identity,
        _contacts = contacts,
        _sessionManager = sessionManager;

  // ── CryptoPort: DM ─────────────────────────────────────────────────────────

  @override
  Future<EncryptedDm> encryptDm(
    String recipientMasterPub58,
    String plaintext,
  ) async {
    final contact = await _contacts.findByMasterPub(recipientMasterPub58);
    if (contact == null) throw StateError('Unknown contact: $recipientMasterPub58');

    final state = await _sessionManager.loadSession(contact.id!);
    if (state == null) {
      throw StateError('No session for $recipientMasterPub58. '
          'Call SessionPort.initOutbound first.');
    }

    final enc = _sessionManager.ratchet.encrypt(
      state,
      Uint8List.fromList(utf8.encode(plaintext)),
    );
    await _sessionManager.saveSession(contact.id!, state);

    final senderEphPub = enc.counter == 0
        ? Uint8List.fromList(state.myEphemeral.publicKey)
        : null;

    return EncryptedDm(
      ciphertext: enc.ciphertext,
      counter: enc.counter,
      senderEphPub: senderEphPub,
      newEphPub: enc.newEphemeralKey,
    );
  }

  /// Check if a contact is rate-limited due to repeated decrypt failures.
  bool _isRateLimited(String pub) {
    final count = _failureCounts[pub] ?? 0;
    if (count < _maxFailures) return false;
    final firstAt = _failureFirstAt[pub] ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - firstAt > _failureWindowMs) {
      // Window expired — reset
      _failureCounts.remove(pub);
      _failureFirstAt.remove(pub);
      return false;
    }
    return true;
  }

  void _recordFailure(String pub) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _failureCounts[pub] = (_failureCounts[pub] ?? 0) + 1;
    _failureFirstAt.putIfAbsent(pub, () => now);
  }

  void _resetFailures(String pub) {
    _failureCounts.remove(pub);
    _failureFirstAt.remove(pub);
  }

  @override
  Future<String?> decryptDm(
    String senderMasterPub58,
    Uint8List ciphertext,
    IncomingDmMeta meta,
  ) async {
    if (_isRateLimited(senderMasterPub58)) {
      AppLogger.w('DR', 'rate-limited: dropping message from ${senderMasterPub58.substring(0, 8)}…');
      return null;
    }

    final contact = await _contacts.findByMasterPub(senderMasterPub58);
    if (contact == null) return null;

    var state = await _sessionManager.loadSession(contact.id!);

    if (state == null) {
      if (meta.senderEphPub == null) return null;
      if (meta.senderEphPub!.length != 32) {
        AppLogger.w('DR', 'REJECTED: senderEphPub length ${meta.senderEphPub!.length} != 32');
        return null;
      }

      // Verify senderEphPub signature if present
      if (meta.senderEphSig != null) {
        try {
          final signingPub = PubkeyCodec.decode(contact.signingPub);
          final valid = _sodium.crypto.sign.verifyDetached(
            signature: meta.senderEphSig!,
            message: meta.senderEphPub!,
            publicKey: signingPub,
          );
          if (!valid) {
            AppLogger.w('DR', 'REJECTED: invalid senderEphPub signature from ${contact.id}');
            return null;
          }
          AppLogger.d('DR', 'senderEphPub signature VERIFIED for contact ${contact.id}');
        } catch (e) {
          AppLogger.e('DR', 'senderEphSig verify error', error: e);
          return null;
        }
      }

      state = _sessionManager.initReceiverFromIdentity(meta.senderEphPub!);
      _sessionManager.cacheSession(contact.id!, state);
      await _sessionManager.saveSession(contact.id!, state);
    }

    final plainBytes = _sessionManager.ratchet.tryDecrypt(
      state,
      ciphertext,
      meta.counter,
      newPeerEphemeral: meta.newEphPub,
    );

    if (plainBytes == null) {
      // DO NOT delete the session — preserve against garbage packet attacks.
      _recordFailure(senderMasterPub58);
      AppLogger.w('DR', 'decryptDm failed for contact ${contact.id} — session preserved '
          '(failures: ${_failureCounts[senderMasterPub58] ?? 0})');
      return null;
    }

    _resetFailures(senderMasterPub58);
    await _sessionManager.saveSession(contact.id!, state);
    return utf8.decode(plainBytes);
  }

  // ── CryptoPort: box ────────────────────────────────────────────────────────

  @override
  Future<Uint8List> encryptBox(
    String recipientMasterPub58,
    Uint8List plaintext,
  ) async {
    final contact = await _contacts.findByMasterPub(recipientMasterPub58);
    if (contact == null) throw StateError('Unknown contact: $recipientMasterPub58');
    if (contact.x25519Pub == null) throw StateError('No X25519 key for contact');

    final peerPub = PubkeyCodec.decode(contact.x25519Pub!);
    final ephKP   = KeyGen(_sodium).generateX25519();
    final nonce   = _sodium.randombytes.buf(_sodium.crypto.box.nonceBytes);

    final ct = Uint8List.fromList(_sodium.crypto.box.easy(
      message:   plaintext,
      nonce:     nonce,
      publicKey: peerPub,
      secretKey: ephKP.privateKey,
    ));
    final ephPubBytes = Uint8List.fromList(ephKP.publicKey);
    ephKP.dispose();

    return Uint8List.fromList(utf8.encode(jsonEncode({
      'box': base64.encode(Uint8List.fromList([...nonce, ...ct])),
      'epk': base64.encode(ephPubBytes),
    })));
  }

  @override
  Uint8List? decryptBox(Uint8List ciphertext) {
    try {
      final m = jsonDecode(utf8.decode(ciphertext)) as Map<String, dynamic>;
      if (!m.containsKey('box') || !m.containsKey('epk')) return null;
      final raw      = base64.decode(m['box'] as String);
      final epk      = base64.decode(m['epk'] as String);
      final nonceLen = _sodium.crypto.box.nonceBytes;
      return Uint8List.fromList(_sodium.crypto.box.openEasy(
        cipherText: raw.sublist(nonceLen),
        nonce:      raw.sublist(0, nonceLen),
        publicKey:  epk,
        secretKey:  _identity.x25519PrivateKey,
      ));
    } catch (e) {
      AppLogger.w('DR', 'decryptBox failed: $e');
      return null;
    }
  }

  // ── CryptoPort: decryptDmDetailed ──────────────────────────────────────────

  @override
  Future<DecryptResult> decryptDmDetailed(
    String senderMasterPub58,
    Uint8List ciphertext,
    IncomingDmMeta meta,
  ) async {
    final contact = await _contacts.findByMasterPub(senderMasterPub58);
    if (contact == null) return const DecryptResult.failure(DecryptError.noSession);

    var state = await _sessionManager.loadSession(contact.id!);

    if (state == null) {
      if (meta.senderEphPub == null) {
        return const DecryptResult.failure(DecryptError.noSession);
      }
      if (meta.senderEphPub!.length != 32) {
        AppLogger.w('DR', 'REJECTED: senderEphPub length ${meta.senderEphPub!.length} != 32');
        return const DecryptResult.failure(DecryptError.badSignature);
      }
      if (meta.senderEphSig != null) {
        try {
          final signingPub = PubkeyCodec.decode(contact.signingPub);
          final valid = _sodium.crypto.sign.verifyDetached(
            signature: meta.senderEphSig!,
            message: meta.senderEphPub!,
            publicKey: signingPub,
          );
          if (!valid) return const DecryptResult.failure(DecryptError.badSignature);
        } catch (e) {
          AppLogger.w('DR', 'ephSig verify error in decryptDmDetailed: $e');
          return const DecryptResult.failure(DecryptError.badSignature);
        }
      }
      state = _sessionManager.initReceiverFromIdentity(meta.senderEphPub!);
      _sessionManager.cacheSession(contact.id!, state);
      await _sessionManager.saveSession(contact.id!, state);
    }

    final plainBytes = _sessionManager.ratchet.tryDecrypt(
      state, ciphertext, meta.counter,
      newPeerEphemeral: meta.newEphPub,
    );

    if (plainBytes == null) {
      return const DecryptResult.failure(DecryptError.aeadFailed);
    }

    await _sessionManager.saveSession(contact.id!, state);
    return DecryptResult.success(utf8.decode(plainBytes));
  }

  // ── CryptoPort: signing ──────────────────────────────────────────────────

  @override
  Uint8List sign(Uint8List data) => _identity.sign(data);

  @override
  Future<bool> verifyContact(
    String contactMasterPub58,
    Uint8List data,
    Uint8List signature,
  ) async {
    final contact = await _contacts.findByMasterPub(contactMasterPub58);
    if (contact == null) return false;
    try {
      final signingPub = PubkeyCodec.decode(contact.signingPub);
      return _sodium.crypto.sign.verifyDetached(
        signature: signature,
        message: data,
        publicKey: signingPub,
      );
    } catch (e) {
      AppLogger.w('DR', 'verifyContact failed: $e');
      return false;
    }
  }

  @override
  bool verifySigningCert(Uint8List certBytes, Uint8List masterPub) {
    try {
      final cert = SigningCert.decode(certBytes);
      return cert.verify(_sodium, masterPub);
    } catch (e) {
      AppLogger.w('DR', 'verifySigningCert failed: $e');
      return false;
    }
  }

  // ── CryptoPort: group ──────────────────────────────────────────────────────

  @override
  Future<Uint8List> encryptGroup(String groupId, String plaintext) {
    throw UnimplementedError(
        'Group encryption is handled by GroupMessagingService until A4 phase 5.');
  }

  @override
  Future<String?> decryptGroup(
    String senderMasterPub58,
    IncomingGroupMeta meta,
    Uint8List ciphertext,
  ) {
    throw UnimplementedError(
        'Group decryption is handled by GroupMessagingService until A4 phase 5.');
  }

  // ── Per-Post Wrap (P7) ─────────────────────────────────────────────────────

  late final GroupPostCodec _groupPostCodec = GroupPostCodec(_sodium);

  @override
  Future<GroupPostBuild> encryptGroupPost({
    required String groupId,
    required int epoch,
    required String messageId,
    required Uint8List plaintext,
    required List<GroupPostRecipient> recipients,
    int? ttlSeconds,
  }) async {
    final myMasterPub58 = PubkeyCodec.encode(_identity.masterPublicKey);
    return _groupPostCodec.encryptForRecipients(
      groupId:     groupId,
      epoch:       epoch,
      messageId:   messageId,
      plaintext:   plaintext,
      senderPub58: myMasterPub58,
      recipients:  recipients,
      ttlSeconds:  ttlSeconds,
      signFn:      _identity.sign,
    );
  }

  @override
  Future<GroupPostDecryptResult> decryptGroupPost({
    required GroupPostEnvelope envelope,
    required String senderMasterPub58,
  }) async {
    // Sender must be a known contact so we can resolve their signing pub.
    final contact = await _contacts.findByMasterPub(senderMasterPub58);
    if (contact == null) {
      AppLogger.w('GroupPost', 'unknown sender $senderMasterPub58 — drop');
      return const GroupPostDecryptFailure(GroupPostDecryptError.badSignature);
    }
    final Uint8List senderSigningPub;
    try {
      senderSigningPub = PubkeyCodec.decode(contact.signingPub);
    } catch (e) {
      AppLogger.w('GroupPost', 'bad signing pub for $senderMasterPub58: $e');
      return const GroupPostDecryptFailure(GroupPostDecryptError.badSignature);
    }
    return _groupPostCodec.decrypt(
      envelope:         envelope,
      senderSigningPub: senderSigningPub,
      myX25519Priv:     _identity.x25519PrivateKey,
    );
  }
}
