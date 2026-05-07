import 'dart:typed_data';

import 'package:sodium_libs/sodium_libs.dart';

import '../../crypto/double_ratchet.dart';
import '../../crypto/identity.dart';
import '../../domain/entities/session_record.dart';
import '../../domain/ports/session_port.dart';
import '../../domain/repositories/contact_repository.dart';
import '../../domain/repositories/session_repository.dart';

export '../../domain/ports/session_port.dart';

/// Double Ratchet implementation of [SessionPort].
///
/// Handles X3DH session bootstrap (both initiator and responder sides)
/// and session persistence via domain repositories.
class DoubleRatchetSessionService implements SessionPort {
  final Sodium _sodium;
  final Identity _identity;
  final ContactRepository _contacts;
  final SessionRepository _sessions;
  final DoubleRatchet _ratchet;

  DoubleRatchetSessionService({
    required Sodium sodium,
    required Identity identity,
    required ContactRepository contacts,
    required SessionRepository sessions,
  })  : _sodium = sodium,
        _identity = identity,
        _contacts = contacts,
        _sessions = sessions,
        _ratchet = DoubleRatchet(sodium);

  // ── SessionPort ────────────────────────────────────────────────────────────

  @override
  Future<bool> hasSession(String contactMasterPub58) async {
    final contact = await _contacts.findByMasterPub(contactMasterPub58);
    if (contact?.id == null) return false;
    return await _sessions.forContact(contact!.id!) != null;
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
      // Use identity key as ephemeral when no one-time pre-key is available.
      peerEphemeralPubkey: peerEphPub ?? peerIdentityPub,
    );

    await _saveSession(contact.id!, state);
    state.dispose();
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
      myIdentityPrivkey:    _identity.x25519PrivateKey,
      myIdentityPubkey:     _identity.x25519PublicKey,
      myEphemeralPrivkey:   myEphPrivSecure,
      myEphemeralPubkey:    myEphPub,
      senderEphemeralPubkey: senderEphPub,
    );
    myEphPrivSecure.dispose();

    await _saveSession(contact.id!, state);
    state.dispose();
  }

  @override
  Future<void> deleteSession(String contactMasterPub58) async {
    final contact = await _contacts.findByMasterPub(contactMasterPub58);
    if (contact?.id == null) return;
    await _sessions.deleteForContact(contact!.id!);
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  Future<void> _saveSession(int contactId, RatchetState state) async {
    final existing = await _sessions.forContact(contactId);
    final privBytes = state.myEphemeral.privateKey.extractBytes();

    final record = SessionRecord(
      id:           existing?.id,
      contactId:    contactId,
      rootKey:      Uint8List.fromList(state.rootKey),
      sendChainKey: Uint8List.fromList(state.sendChainKey),
      recvChainKey: Uint8List.fromList(state.recvChainKey),
      myEphPub:     Uint8List.fromList(state.myEphemeral.publicKey),
      myEphPriv:    privBytes,
      peerEphPub:   state.peerEphemeral != null
          ? Uint8List.fromList(state.peerEphemeral!)
          : null,
      sendCounter:        state.sendCounter,
      recvCounter:        state.recvCounter,
      sendSinceRatchet:   state.sendCounterSinceRatchet,
      recvCounterInChain: state.recvCounterInChain,
      recvChainIndex:     state.recvChainIndex,
      skippedKeysJson:    SkippedKeysCodec.encode(state.skippedKeys),
      updatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );

    privBytes.fillRange(0, privBytes.length, 0);

    if (existing == null) {
      await _sessions.insert(record);
    } else {
      await _sessions.update(record);
    }
  }
}
