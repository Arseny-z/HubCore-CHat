import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium_libs/sodium_libs.dart';

import '../../../crypto/identity.dart';
import '../../../domain/ports/transport_port.dart';
import '../../../domain/repositories/contact_repository.dart';
import '../../../infrastructure/keystore/keystore_service.dart';
import '../../events/app_event_bus.dart';

/// Rotates the signing key and broadcasts the new cert to all contacts.
///
/// Business rules enforced here:
///   1. Generate a new signing key-pair.
///   2. Build and sign a `cert_update` payload.
///   3. Broadcast to all contacts via [TransportPort] (protocol-agnostic).
///   4. Persist the updated identity via [KeystoreService].
///   5. Emit [SigningKeyRotatedEvent] so UI / other services can react.
///
/// This use case replaces [CertBroadcastService] and fixes the violation
/// where [CertBroadcastService] used [RelayClient] directly instead of
/// going through [TransportPort].
///
/// Wire format of cert_update payload:
///   {
///     "type":        "cert_update",
///     "signing_pub": "<base64 Ed25519 signing pubkey>",
///     "valid_from":  <unix seconds>,
///     "valid_until": <unix seconds>,
///     "sig":         "<base64 signature over signingPub||validFrom||validUntil>"
///   }
class RotateSigningKeyUseCase {
  final Sodium _sodium;
  final KeystoreService _keystore;
  final ContactRepository _contacts;
  final TransportPort _transport;
  final AppEventBus _bus;

  RotateSigningKeyUseCase({
    required Sodium sodium,
    required KeystoreService keystore,
    required ContactRepository contacts,
    required TransportPort transport,
    required AppEventBus bus,
  })  : _sodium = sodium,
        _keystore = keystore,
        _contacts = contacts,
        _transport = transport,
        _bus = bus;

  /// Rotate the signing key on [identity] and broadcast the new cert.
  ///
  /// Returns the updated [Identity] that was persisted.
  Future<Identity> execute(Identity identity) async {
    // ── Rotate ────────────────────────────────────────────────────────────────
    final rotated = identity.rotateSigningKey();
    await _keystore.saveIdentity(rotated);

    // ── Build cert_update payload ─────────────────────────────────────────────
    final cert = rotated.signingCert;
    final payload = Uint8List.fromList(utf8.encode(jsonEncode({
      'type': 'cert_update',
      'signing_pub': base64.encode(cert.signingPubkey),
      'valid_from': cert.validFrom,
      'valid_until': cert.validUntil,
      'sig': base64.encode(cert.signature),
    })));

    // ── Broadcast via TransportPort ───────────────────────────────────────────
    final contacts = await _contacts.all();
    for (final contact in contacts) {
      final destYgg = contact.transportAddresses['yggdrasil']
          ?? contact.yggPubKeyHex
          ?? '';
      try {
        await _transport.send(
          payload,
          TransportAddress(protocol: TransportProtocol.yggdrasil, value: destYgg),
        );
      } catch (_) {
        // Non-fatal — contact will re-verify on next real message.
      }
    }

    // ── Event ─────────────────────────────────────────────────────────────────
    _bus.emit(SigningKeyRotatedEvent());

    return rotated;
  }
}
