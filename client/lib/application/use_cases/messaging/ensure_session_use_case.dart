import 'dart:async';
import 'dart:typed_data';

import '../../../infrastructure/crypto/session_manager.dart';
import '../../../shared/utils/pubkey_codec.dart';
import '../../../domain/repositories/contact_repository.dart';

/// Ensures a DR session exists for a contact before sending messages.
///
/// Uses a per-contact async lock to prevent race conditions where
/// two concurrent sends both see no session and both call initOutbound,
/// corrupting the ratchet state.
class EnsureSessionUseCase {
  final SessionManager _sessionManager;
  final ContactRepository _contacts;

  /// Per-contact lock: contactPub → in-progress init future.
  final _locks = <String, Future<void>>{};

  EnsureSessionUseCase({
    required SessionManager sessionManager,
    required ContactRepository contacts,
  })  : _sessionManager = sessionManager,
        _contacts = contacts;

  /// Ensure a DR session exists for [contactPub58].
  ///
  /// If a session already exists, returns immediately.
  /// If another call is already initializing for this contact, waits for it.
  /// Otherwise, creates a new outbound session using [peerIdentityPub].
  Future<void> execute(String contactPub58) async {
    // Fast path: session already exists
    if (await _sessionManager.hasSession(contactPub58)) return;

    // If init is already in progress for this contact, wait for it
    if (_locks.containsKey(contactPub58)) {
      await _locks[contactPub58];
      return;
    }

    // Double-check after acquiring "lock intention"
    if (await _sessionManager.hasSession(contactPub58)) return;

    // Load contact to get x25519Pub
    final contact = await _contacts.findByMasterPub(contactPub58);
    if (contact == null) {
      throw StateError('Contact not found: $contactPub58');
    }
    if (contact.x25519Pub == null) {
      throw StateError('No X25519 key for contact $contactPub58 — '
          'wait for contact_hello exchange');
    }

    final peerIdPub = PubkeyCodec.decode(contact.x25519Pub!);
    final future = _doInit(contactPub58, peerIdPub);
    _locks[contactPub58] = future;

    try {
      await future;
    } finally {
      _locks.remove(contactPub58);
    }
  }

  Future<void> _doInit(String contactPub58, Uint8List peerIdPub) async {
    await _sessionManager.initOutbound(
      contactMasterPub58: contactPub58,
      peerIdentityPub: peerIdPub,
    );
  }
}
