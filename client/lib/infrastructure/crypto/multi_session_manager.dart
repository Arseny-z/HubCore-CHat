import 'dart:typed_data';

import 'package:sodium_libs/sodium_libs.dart';

import '../../crypto/double_ratchet.dart';
import '../../crypto/identity.dart';
import '../../crypto/keys.dart';
import '../../shared/utils/logger.dart';
import '../../storage/dao/multi_sessions_dao.dart';
import '../../storage/storage_service.dart';

/// Manages per-device Double Ratchet sessions for multi-device messaging.
///
/// Uses symmetric-only ratchet (no DH ratchet step) so sessions stay in sync
/// even when some devices are offline.
///
/// One session per (contact, device) pair, stored in multi_sessions table.
class MultiSessionManager {
  final Sodium _sodium;
  final Identity _identity;
  final StorageService _storage;
  final DoubleRatchet _ratchet;

  /// In-memory cache: (contactId, deviceId) → RatchetState
  final _cache = <String, RatchetState>{};

  MultiSessionManager({
    required Sodium sodium,
    required Identity identity,
    required StorageService storage,
  })  : _sodium = sodium,
        _identity = identity,
        _storage = storage,
        _ratchet = DoubleRatchet(sodium);

  String _cacheKey(int contactId, String deviceId) => '$contactId:$deviceId';

  // ── Load / Save ──────────────────────────────────────────────────────────

  Future<RatchetState?> loadSession(int contactId, String deviceId) async {
    final key = _cacheKey(contactId, deviceId);
    if (_cache.containsKey(key)) return _cache[key];

    final record = await _storage.multiSessions
        .forContactDevice(contactId, deviceId);
    if (record == null) return null;

    final state = _recordToState(record);
    _cache[key] = state;
    return state;
  }

  Future<void> saveSession(
      int contactId, String deviceId, RatchetState state) async {
    final key = _cacheKey(contactId, deviceId);
    _cache[key] = state;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _storage.multiSessions.upsert(MultiSessionRecord(
      contactId: contactId,
      deviceId: deviceId,
      rootKey: state.rootKey,
      sendChainKey: state.sendChainKey,
      recvChainKey: state.recvChainKey,
      myEphPub: Uint8List.fromList(state.myEphemeral.publicKey),
      myEphPriv: state.myEphemeral.privateKey.extractBytes(),
      peerEphPub: state.peerEphemeral,
      sendCounter: state.sendCounter,
      recvCounter: state.recvCounter,
      recvCounterInChain: state.recvCounterInChain,
      recvChainIndex: state.recvChainIndex,
      skippedKeys: '[]', // simplified — full skipped keys omitted for multi-device
      updatedAt: now,
    ));
  }

  Future<void> deleteSession(int contactId, String deviceId) async {
    _cache.remove(_cacheKey(contactId, deviceId));
    await _storage.multiSessions.deleteForDevice(contactId, deviceId);
  }

  Future<void> deleteAllForContact(int contactId) async {
    final keys = _cache.keys
        .where((k) => k.startsWith('$contactId:'))
        .toList();
    for (final k in keys) _cache.remove(k);
    await _storage.multiSessions.deleteForContact(contactId);
  }

  // ── Session init ─────────────────────────────────────────────────────────

  /// Initialise outbound session for [deviceId] using their ephemeral pub key.
  /// Uses simplified X3DH: DH(myDevice.priv, peerDevice.eph).
  Future<RatchetState> initOutbound({
    required int contactId,
    required String deviceId,
    required Uint8List peerDeviceEphPub,
  }) async {
    // X3DH simplified for P2P multi-device:
    // Use peer's device pub as identity and as ephemeral (no pre-key server).
    // Security note: this reduces to a 2-DH instead of 4-DH X3DH,
    // but provides session key separation from the master identity key.
    final state = _ratchet.initSender(
      peerIdentityPubkey:  peerDeviceEphPub,
      peerEphemeralPubkey: peerDeviceEphPub,
    );
    await saveSession(contactId, deviceId, state);
    AppLogger.d('MultiSession',
        'init outbound for contact=$contactId device=${deviceId.substring(0, 8)}…');
    return state;
  }

  /// Initialise inbound session from [senderEphPub] in the first message.
  Future<RatchetState> initInbound({
    required int contactId,
    required String senderDeviceId,
    required Uint8List senderEphPub,
  }) async {
    // Generate a fresh X25519 ephemeral keypair for this session.
    // This is different from the persistent devicePrivateKey —
    // ensures we don't reuse long-lived keys in the DH handshake.
    final myEph = KeyGen(_sodium).generateX25519();

    final state = _ratchet.initReceiver(
      myIdentityPrivkey:   _identity.devicePrivateKey,
      myIdentityPubkey:    _identity.devicePublicKey,
      myEphemeralPrivkey:  myEph.privateKey,
      myEphemeralPubkey:   myEph.publicKey,
      senderEphemeralPubkey: senderEphPub,
    );
    await saveSession(contactId, senderDeviceId, state);
    AppLogger.d('MultiSession',
        'init inbound for contact=$contactId device=${senderDeviceId.substring(0, 8)}…');
    return state;
  }

  // ── Encrypt / Decrypt ────────────────────────────────────────────────────

  /// Encrypt [plaintext] for a specific [deviceId] of [contactId].
  /// Uses symmetric-only ratchet — no DH step.
  Future<EncryptedMessage?> encrypt({
    required int contactId,
    required String deviceId,
    required Uint8List plaintext,
    Uint8List? peerDeviceEphPub,
  }) async {
    var state = await loadSession(contactId, deviceId);
    if (state == null) {
      if (peerDeviceEphPub == null) {
        AppLogger.w('MultiSession',
            'no session and no eph pub for device ${deviceId.substring(0, 8)}…');
        return null;
      }
      state = await initOutbound(
        contactId: contactId,
        deviceId: deviceId,
        peerDeviceEphPub: peerDeviceEphPub,
      );
    }
    final msg = _ratchet.encryptSymmetricOnly(state, plaintext);
    await saveSession(contactId, deviceId, state);
    return msg;
  }

  /// Decrypt [message] from [senderDeviceId].
  Future<Uint8List?> decrypt({
    required int contactId,
    required String senderDeviceId,
    required EncryptedMessage message,
    Uint8List? senderEphPub,
  }) async {
    var state = await loadSession(contactId, senderDeviceId);
    if (state == null) {
      if (senderEphPub == null) {
        AppLogger.w('MultiSession',
            'no session and no eph pub from ${senderDeviceId.substring(0, 8)}…');
        return null;
      }
      state = await initInbound(
        contactId: contactId,
        senderDeviceId: senderDeviceId,
        senderEphPub: senderEphPub,
      );
    }
    final plain = _ratchet.tryDecrypt(
      state,
      message.ciphertext,
      message.counter,
      newPeerEphemeral: message.newEphemeralKey,
    );
    await saveSession(contactId, senderDeviceId, state);
    return plain;
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  /// Returns active device IDs for [contactId] that have sessions.
  Future<List<String>> activeDeviceIds(int contactId) async {
    final devices = await _storage.contactDevices.forContact(contactId);
    return devices.map((d) => d.deviceId).toList();
  }

  RatchetState _recordToState(MultiSessionRecord r) {
    final myEphPriv = SecureKey.fromList(_sodium, r.myEphPriv);
    final state = RatchetState(
      rootKey: r.rootKey,
      sendChainKey: r.sendChainKey,
      recvChainKey: r.recvChainKey,
      myEphemeral: X25519KeyPair(
        publicKey: r.myEphPub,
        privateKey: myEphPriv,
      ),
      peerEphemeral: r.peerEphPub,
    );
    state.sendCounter           = r.sendCounter;
    state.recvCounter           = r.recvCounter;
    state.recvCounterInChain    = r.recvCounterInChain;
    state.recvChainIndex        = r.recvChainIndex;
    return state;
  }
}
