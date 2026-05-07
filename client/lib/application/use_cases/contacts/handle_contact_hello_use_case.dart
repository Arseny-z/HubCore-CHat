import '../../../domain/repositories/contact_repository.dart';
import '../../events/app_event_bus.dart';

/// Handles an incoming `contact_hello` system message.
///
/// Business rules enforced here:
///   1. If the contact has no x25519 pub, store the one from the hello.
///   2. If the hello includes a Yggdrasil address, update transport_addresses.
///   3. Emit [ContactUpdatedEvent] so UI can refresh the contact row.
///
/// Wire format of a contact_hello payload:
///   {
///     "type": "contact_hello",
///     "xk":   "<base64 X25519 pub>",    // optional
///     "yk":   "<hex Yggdrasil pub>",     // optional
///   }
class HandleContactHelloUseCase {
  final ContactRepository _contacts;
  final AppEventBus _bus;

  HandleContactHelloUseCase({
    required ContactRepository contacts,
    required AppEventBus bus,
  })  : _contacts = contacts,
        _bus = bus;

  /// Process a decoded `contact_hello` JSON payload from [senderPub].
  Future<void> execute(String senderPub, Map<String, dynamic> json) async {
    final contact = await _contacts.findByMasterPub(senderPub);
    if (contact == null) return;

    bool updated = false;

    // ── X25519 key ────────────────────────────────────────────────────────────
    final x25519Pub = json['xk'] as String?;
    if (x25519Pub != null && contact.x25519Pub == null) {
      await _contacts.updateX25519Pub(senderPub, x25519Pub);
      updated = true;
    }

    // ── Yggdrasil address ─────────────────────────────────────────────────────
    final yggAddr = json['yk'] as String?;
    if (yggAddr != null && yggAddr.isNotEmpty) {
      await _contacts.updateTransportAddress(senderPub, 'yggdrasil', yggAddr);
      updated = true;
    }

    if (updated) {
      _bus.emit(ContactUpdatedEvent(masterPub: senderPub));
    }
  }
}
