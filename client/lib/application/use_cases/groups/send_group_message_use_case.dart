import '../../../domain/entities/message.dart';
import '../../../domain/ports/crypto_port.dart';
import '../../../domain/ports/transport_port.dart';
import '../../../domain/repositories/contact_repository.dart';
import '../../../domain/repositories/message_repository.dart';
import '../../events/app_event_bus.dart';

/// Encrypts a group message with Sender Keys and fan-outs to all members.
///
/// Business rules enforced here:
///   1. Encrypt once; identical payload goes to every member.
///   2. Message is persisted locally before sending (at-least-once).
///   3. [MessageSentEvent] is emitted after successful encrypt+persist.
///
/// [CryptoPort.encryptGroup] returns the ready-to-send wire payload bytes.
class SendGroupMessageUseCase {
  final CryptoPort _crypto;
  final ContactRepository _contacts;
  final MessageRepository _messages;
  final TransportPort _transport;
  final AppEventBus _bus;

  /// Returns our own master public key (base58) for the sender field.
  final String Function() _myMasterPub;

  SendGroupMessageUseCase({
    required CryptoPort crypto,
    required ContactRepository contacts,
    required MessageRepository messages,
    required TransportPort transport,
    required AppEventBus bus,
    required String Function() myMasterPub,
  })  : _crypto = crypto,
        _contacts = contacts,
        _messages = messages,
        _transport = transport,
        _bus = bus,
        _myMasterPub = myMasterPub;

  /// Encrypt [plaintext] for [groupId] and send to all [memberPubs].
  ///
  /// Returns the DB id of the saved [Message], or null on encryption failure.
  Future<int?> execute({
    required String groupId,
    required String plaintext,
    required List<String> memberPubs,
  }) async {
    final myPub = _myMasterPub();

    // ── Encrypt ───────────────────────────────────────────────────────────────
    // CryptoPort.encryptGroup returns the wire payload bytes directly.
    final payload = await _crypto.encryptGroup(groupId, plaintext);

    // ── Persist before send ───────────────────────────────────────────────────
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final dbId = await _messages.insert(Message(
      conversationId: groupId,
      isGroup: true,
      senderPub: myPub,
      body: plaintext,
      sentAt: now,
      status: MessageStatus.sent,
    ));

    // ── Fan-out ───────────────────────────────────────────────────────────────
    for (final memberPub in memberPubs) {
      if (memberPub == myPub) continue;
      final contact = await _contacts.findByMasterPub(memberPub);
      final destYgg = contact?.transportAddresses['yggdrasil']
          ?? contact?.yggPubKeyHex
          ?? '';
      try {
        await _transport.send(
          payload,
          TransportAddress(protocol: TransportProtocol.yggdrasil, value: destYgg),
        );
      } catch (_) {
        // Best-effort per member — continue with others.
      }
    }

    // ── Event ─────────────────────────────────────────────────────────────────
    _bus.emit(MessageSentEvent(
      messageDbId: dbId,
      conversationId: groupId,
    ));

    return dbId;
  }
}
