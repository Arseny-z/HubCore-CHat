import 'dart:typed_data';

import 'package:sodium_libs/sodium_libs.dart';
import '../../shared/utils/logger.dart';

import '../../crypto/double_ratchet.dart';
import '../../crypto/identity.dart';
import '../../crypto/keys.dart';
import '../../domain/entities/session_record.dart';
import '../../domain/ports/session_port.dart';
import '../../domain/repositories/contact_repository.dart';
import '../../domain/repositories/session_repository.dart';
import '../../shared/utils/pubkey_codec.dart';

export '../../domain/ports/session_port.dart';

/// Unified session manager — single source of truth for DR session state.
///
/// Owns the in-memory cache and persistence. Both [MessagingService] and
/// [DoubleRatchetCryptoService] delegate session operations here.
class SessionManager implements SessionPort {
  final Sodium _sodium;
  final Identity _identity;
  final ContactRepository _contacts;
  final SessionRepository _sessions;
  final DoubleRatchet _ratchet;

  /// Optional 32-byte BLAKE2b MAC key for session integrity checks.
  /// Loaded from Keystore-backed secure storage after unlock.
  /// Null = HMAC disabled (sessions are still used, just not MAC'd).
  final Uint8List? _macKey;

  /// In-memory cache: contactId → live RatchetState.
  final _cache = <int, RatchetState>{};

  SessionManager({
    required Sodium sodium,
    required Identity identity,
    required ContactRepository contacts,
    required SessionRepository sessions,
    Uint8List? macKey,
  })  : _sodium = sodium,
        _identity = identity,
        _contacts = contacts,
        _sessions = sessions,
        _macKey = macKey,
        _ratchet = DoubleRatchet(sodium);

  DoubleRatchet get ratchet => _ratchet;

  // ── SessionPort ────────────────────────────────────────────────────────────

  @override
  Future<bool> hasSession(String contactMasterPub58) async {
    final contact = await _contacts.findByMasterPub(contactMasterPub58);
    if (contact?.id == null) return false;
    return await loadSession(contact!.id!) != null;
  }

  @override
  Future<void> initOutbound({
    required String contactMasterPub58,
    required Uint8List peerIdentityPub,
    Uint8List? peerEphPub,
  }) async {
    final contact = await _contacts.findByMasterPub(contactMasterPub58);
    if (contact == null) throw StateError('Unknown contact: $contactMasterPub58');

    final state = _ratchet.initSender(
      peerIdentityPubkey: peerIdentityPub,
      peerEphemeralPubkey: peerEphPub ?? peerIdentityPub,
    );

    _cache[contact.id!] = state;
    await saveSession(contact.id!, state);
  }

  @override
  Future<void> initInbound({
    required String contactMasterPub58,
    required Uint8List senderEphPub,
    required Uint8List myEphPub,
    required Uint8List myEphPriv,
  }) async {
    final contact = await _contacts.findByMasterPub(contactMasterPub58);
    if (contact == null) throw StateError('Unknown contact: $contactMasterPub58');

    final myEphPrivSecure = SecureKey.fromList(_sodium, myEphPriv);
    final state = _ratchet.initReceiver(
      myIdentityPrivkey: _identity.x25519PrivateKey,
      myIdentityPubkey: _identity.x25519PublicKey,
      myEphemeralPrivkey: myEphPrivSecure,
      myEphemeralPubkey: myEphPub,
      senderEphemeralPubkey: senderEphPub,
    );

    _cache[contact.id!] = state;
    await saveSession(contact.id!, state);
  }

  /// Auto-init inbound session from senderEphPub (no myEph override).
  RatchetState initReceiverFromIdentity(Uint8List senderEphPub) {
    return _ratchet.initReceiver(
      myIdentityPrivkey: _identity.x25519PrivateKey,
      myIdentityPubkey: _identity.x25519PublicKey,
      myEphemeralPrivkey: _identity.x25519PrivateKey,
      myEphemeralPubkey: _identity.x25519PublicKey,
      senderEphemeralPubkey: senderEphPub,
    );
  }

  @override
  Future<void> deleteSession(String contactMasterPub58) async {
    final contact = await _contacts.findByMasterPub(contactMasterPub58);
    if (contact?.id == null) return;
    _cache.remove(contact!.id!);
    await _sessions.deleteForContact(contact.id!);
  }

  /// Delete session by contactId (internal use).
  Future<void> deleteSessionById(int contactId) async {
    _cache.remove(contactId);
    await _sessions.deleteForContact(contactId);
  }

  // ── Cache + Persistence ──────────────────────────────────────────────────

  Future<RatchetState?> loadSession(int contactId) async {
    if (_cache.containsKey(contactId)) return _cache[contactId];

    final record = await _sessions.forContact(contactId);
    if (record == null) return null;

    // Verify integrity if MAC key is available and record has a stored HMAC
    if (_macKey != null && record.hmac != null) {
      final expected = _computeHmac(record);
      if (!_hmacEqual(expected, record.hmac!)) {
        AppLogger.e('SessionMgr',
            'Session HMAC mismatch for contact $contactId — possible tampering');
        // Don't load a potentially tampered session; force re-negotiation
        await _sessions.deleteForContact(contactId);
        return null;
      }
    }

    final state = _recordToState(record);
    _cache[contactId] = state;
    return state;
  }

  Future<void> saveSession(int contactId, RatchetState state) async {
    _cache[contactId] = state;
    final existing = await _sessions.forContact(contactId);
    var record = _stateToRecord(contactId, state, existingId: existing?.id);

    // Attach HMAC if MAC key is available
    if (_macKey != null) {
      final mac = _computeHmac(record);
      record = SessionRecord(
        id: record.id,
        contactId: record.contactId,
        rootKey: record.rootKey,
        sendChainKey: record.sendChainKey,
        recvChainKey: record.recvChainKey,
        myEphPub: record.myEphPub,
        myEphPriv: record.myEphPriv,
        peerEphPub: record.peerEphPub,
        sendCounter: record.sendCounter,
        recvCounter: record.recvCounter,
        sendSinceRatchet: record.sendSinceRatchet,
        recvCounterInChain: record.recvCounterInChain,
        recvChainIndex: record.recvChainIndex,
        skippedKeysJson: record.skippedKeysJson,
        updatedAt: record.updatedAt,
        hmac: mac,
      );
    }

    if (existing == null) {
      await _sessions.insert(record);
    } else {
      await _sessions.update(record);
    }
  }

  void cacheSession(int contactId, RatchetState state) {
    _cache[contactId] = state;
  }

  // ── Serialization ────────────────────────────────────────────────────────

  RatchetState _recordToState(SessionRecord r) {
    final myEphPriv = SecureKey.fromList(_sodium, r.myEphPriv);
    final state = RatchetState(
      rootKey: Uint8List.fromList(r.rootKey),
      sendChainKey: Uint8List.fromList(r.sendChainKey),
      recvChainKey: Uint8List.fromList(r.recvChainKey),
      myEphemeral: X25519KeyPair(
        publicKey: Uint8List.fromList(r.myEphPub),
        privateKey: myEphPriv,
      ),
      peerEphemeral: r.peerEphPub != null ? Uint8List.fromList(r.peerEphPub!) : null,
    )
      ..sendCounter = r.sendCounter
      ..recvCounter = r.recvCounter
      ..sendCounterSinceRatchet = r.sendSinceRatchet
      ..recvCounterInChain = r.recvCounterInChain
      ..recvChainIndex = r.recvChainIndex;

    final decoded = SkippedKeysCodec.decodeWithTimestamps(r.skippedKeysJson);
    state.skippedKeys.addAll(decoded.keys);
    state.skippedKeysCreatedAt.addAll(decoded.timestamps);

    return state;
  }

  SessionRecord _stateToRecord(
    int contactId,
    RatchetState state, {
    int? existingId,
  }) {
    final privBytes = state.myEphemeral.privateKey.extractBytes();
    final record = SessionRecord(
      id: existingId,
      contactId: contactId,
      rootKey: Uint8List.fromList(state.rootKey),
      sendChainKey: Uint8List.fromList(state.sendChainKey),
      recvChainKey: Uint8List.fromList(state.recvChainKey),
      myEphPub: Uint8List.fromList(state.myEphemeral.publicKey),
      myEphPriv: privBytes,
      peerEphPub: state.peerEphemeral != null
          ? Uint8List.fromList(state.peerEphemeral!)
          : null,
      sendCounter: state.sendCounter,
      recvCounter: state.recvCounter,
      sendSinceRatchet: state.sendCounterSinceRatchet,
      recvCounterInChain: state.recvCounterInChain,
      recvChainIndex: state.recvChainIndex,
      skippedKeysJson: SkippedKeysCodec.encode(state.skippedKeys, createdAt: state.skippedKeysCreatedAt),
      updatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    privBytes.fillRange(0, privBytes.length, 0);
    return record;
  }

  // ── HMAC helpers ─────────────────────────────────────────────────────────────

  /// Compute BLAKE2b-32 MAC over critical session fields.
  /// Input = contactId(8) + rootKey + sendChainKey + recvChainKey +
  ///         myEphPub + myEphPriv + counters(5×8) = 208 bytes
  Uint8List _computeHmac(SessionRecord r) {
    final buf = ByteData(8 + 5 * 32 + 5 * 8);
    buf.setInt64(0, r.contactId, Endian.big);
    for (var i = 0; i < 32; i++) buf.setUint8(8 + i,   r.rootKey[i]);
    for (var i = 0; i < 32; i++) buf.setUint8(40 + i,  r.sendChainKey[i]);
    for (var i = 0; i < 32; i++) buf.setUint8(72 + i,  r.recvChainKey[i]);
    for (var i = 0; i < 32; i++) buf.setUint8(104 + i, r.myEphPub[i]);
    for (var i = 0; i < 32; i++) buf.setUint8(136 + i, r.myEphPriv[i]);
    buf.setInt64(168, r.sendCounter,        Endian.big);
    buf.setInt64(176, r.recvCounter,        Endian.big);
    buf.setInt64(184, r.sendSinceRatchet,   Endian.big);
    buf.setInt64(192, r.recvCounterInChain, Endian.big);
    buf.setInt64(200, r.recvChainIndex,     Endian.big);

    final key = SecureKey.fromList(_sodium, _macKey!);
    try {
      return Uint8List.fromList(
        _sodium.crypto.genericHash.call(
          outLen: 32,
          message: buf.buffer.asUint8List(),
          key: key,
        ),
      );
    } finally {
      key.dispose();
    }
  }

  /// Constant-time equality for HMAC comparison.
  static bool _hmacEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (var i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
    return diff == 0;
  }
}
