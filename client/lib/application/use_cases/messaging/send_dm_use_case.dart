import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../../domain/entities/message.dart';
import '../../../domain/ports/crypto_port.dart';
import '../../../domain/ports/session_port.dart';
import '../../../domain/ports/transport_port.dart';
import '../../../domain/repositories/contact_repository.dart';
import '../../../domain/repositories/message_repository.dart';
import '../../events/app_event_bus.dart';
import '../../../domain/entities/envelope.dart';
import '../../../shared/utils/logger.dart';
import '../../../shared/utils/pubkey_codec.dart';

/// Sends an encrypted DM to a contact.
///
/// Business rules enforced here:
///   1. Session must exist; if not — attempt auto-init from contact's x25519 key.
///   2. Message is persisted before sending (at-least-once delivery).
///   3. TTL is read from settings and applied to the stored message.
///   4. A [MessageSentEvent] is emitted after successful dispatch.
///
/// This use case is intentionally thin — crypto details stay in [CryptoPort],
/// transport details stay in [TransportPort].
class SendDmUseCase {
  final CryptoPort _crypto;
  final SessionPort _sessions;
  final ContactRepository _contacts;
  final MessageRepository _messages;
  final TransportPort _transport;
  final AppEventBus _bus;

  /// Reads TTL setting for a conversation.
  /// Signature: `Future<int?> call(String conversationId)`.
  final Future<int?> Function(String conversationId) _readTtl;

  /// Returns our own master public key (base58) for the sender field.
  final String Function() _myMasterPub;

  SendDmUseCase({
    required CryptoPort crypto,
    required SessionPort sessions,
    required ContactRepository contacts,
    required MessageRepository messages,
    required TransportPort transport,
    required AppEventBus bus,
    required Future<int?> Function(String) readTtl,
    required String Function() myMasterPub,
  })  : _crypto = crypto,
        _sessions = sessions,
        _contacts = contacts,
        _messages = messages,
        _transport = transport,
        _bus = bus,
        _readTtl = readTtl,
        _myMasterPub = myMasterPub;

  /// Encrypt [plaintext] and send it to [recipientMasterPub58].
  ///
  /// Returns the DB id of the saved [Message], or null if the contact
  /// is unknown or has no X25519 key for session init.
  Future<int?> execute({
    required String recipientMasterPub58,
    required String plaintext,
  }) async {
    final contact = await _contacts.findByMasterPub(recipientMasterPub58);
    if (contact == null) return null;

    // ── Business rule: ensure session exists ──────────────────────────────
    if (!await _sessions.hasSession(recipientMasterPub58)) {
      if (contact.x25519Pub == null) return null; // no key to init with
      await _sessions.initOutbound(
        contactMasterPub58: recipientMasterPub58,
        peerIdentityPub: PubkeyCodec.decode(contact.x25519Pub!),
      );
    }

    // ── Encrypt ───────────────────────────────────────────────────────────
    final enc = await _crypto.encryptDm(recipientMasterPub58, plaintext);

    // ── TTL ───────────────────────────────────────────────────────────────
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final ttlSec = await _readTtl(recipientMasterPub58);
    final expiresAt = ttlSec != null ? now + ttlSec : null;
    final mid = _randomMid();

    // ── Persist before send (at-least-once) ──────────────────────────────
    final dbId = await _messages.insert(Message(
      conversationId: recipientMasterPub58,
      isGroup: false,
      senderPub: _myMasterPub(),
      body: plaintext,
      sentAt: now,
      status: MessageStatus.sent,
      expiresAt: expiresAt,
      messageId: mid,
    ));

    // ── Build wire envelope ───────────────────────────────────────────────
    final payload = _buildDmPayload(enc, ttlSec: ttlSec, mid: mid);
    final envelope = Envelope(
      from: _myMasterPub(),
      to: recipientMasterPub58,
      body: payload,
    );

    // ── Send — try transports in priority order ───────────────────────────
    // Build address map: merge transportAddresses + legacy yggPubKeyHex.
    final addrs = <String, String>{
      ...contact.transportAddresses,
      if ((contact.yggPubKeyHex ?? '').isNotEmpty &&
          !contact.transportAddresses.containsKey(TransportProtocol.yggdrasil))
        TransportProtocol.yggdrasil: contact.yggPubKeyHex!,
    };

    // Priority: Yggdrasil (direct, low-latency) → Reticulum (mesh/relay)
    const priority = [TransportProtocol.yggdrasil, TransportProtocol.reticulum];
    var transported = false;
    for (final protocol in priority) {
      final addr = addrs[protocol];
      if (addr == null || addr.isEmpty) continue;
      try {
        await _transport.send(payload, TransportAddress(protocol: protocol, value: addr));
        transported = true;
        break;
      } catch (e) {
        AppLogger.w('SendDm', '$protocol failed: $e');
      }
    }
    if (!transported) {
      AppLogger.w('SendDm', 'all transports failed for ${recipientMasterPub58.substring(0, 8)}…');
    }
    final _ = envelope; // reserved for future sendEnvelope migration

    // ── Event ─────────────────────────────────────────────────────────────
    _bus.emit(MessageSentEvent(
      messageDbId: dbId,
      conversationId: recipientMasterPub58,
    ));

    return dbId;
  }

  // ── Wire format ───────────────────────────────────────────────────────────

  /// Encode [EncryptedDm] into the DM payload wire format (JSON bytes).
  ///
  /// Layout: {"c":"<b64>","n":<int>,"e":"<b64>|null","s":"<b64>|null","t":<int>,"id":"<hex8>"}
  static Uint8List _buildDmPayload(
    EncryptedDm enc, {
    int? ttlSec,
    String? mid,
  }) {
    final m = <String, dynamic>{
      'c': base64.encode(enc.ciphertext),
      'n': enc.counter,
      if (enc.newEphPub != null) 'e': base64.encode(enc.newEphPub!),
      if (enc.senderEphPub != null) 's': base64.encode(enc.senderEphPub!),
      't': ttlSec ?? 0,
      if (mid != null) 'id': mid,
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(m)));
  }

  static String _randomMid() {
    final rng = Random.secure();
    return List.generate(4, (_) => rng.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}
