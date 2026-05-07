import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../../domain/entities/message.dart';
import '../../../domain/ports/crypto_port.dart';
import '../../../domain/ports/transport_port.dart';
import '../../../domain/repositories/contact_repository.dart';
import '../../../domain/repositories/file_repository.dart';
import '../../../domain/repositories/message_repository.dart';
import '../../../storage/dao/ephemeral_keys_dao.dart';
import '../../events/app_event_bus.dart';
import '../../../domain/entities/envelope.dart';

/// Sweeps messages whose [expires_at] has passed and deletes them.
///
/// For each expired DM conversation:
///   1. Sends an encrypted `ttl_delete` envelope to the peer (NaCl box,
///      best-effort — no retry on failure).
///   2. Deletes associated file records from disk.
///   3. Deletes the message rows from the DB.
///   4. Emits a [MessagesDeletedEvent] so UI can refresh.
///
/// Groups: local deletion only (no ttl_delete envelope).
///
/// This use case replaces [TtlService] and fixes the bug where
/// [TtlService.onMessagesDeleted] was never wired to [MessageRouter].
class SweepExpiredUseCase {
  final MessageRepository _messages;
  final FileRepository _files;
  final ContactRepository _contacts;
  final CryptoPort _crypto;
  final TransportPort _transport;
  final AppEventBus _bus;
  final EphemeralKeysDao? _ephemeralKeys;

  Timer? _timer;
  static const _sweepInterval = Duration(seconds: 30);
  static const _ephemeralKeyTtlSecs = 30 * 24 * 3600; // 30 days

  SweepExpiredUseCase({
    required MessageRepository messages,
    required FileRepository files,
    required ContactRepository contacts,
    required CryptoPort crypto,
    required TransportPort transport,
    required AppEventBus bus,
    EphemeralKeysDao? ephemeralKeys,
  })  : _messages = messages,
        _files = files,
        _contacts = contacts,
        _crypto = crypto,
        _transport = transport,
        _bus = bus,
        _ephemeralKeys = ephemeralKeys;

  /// Start periodic sweep timer.
  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(_sweepInterval, (_) => execute());
    execute(); // run immediately
  }

  /// Stop the timer.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() => stop();

  /// Run one sweep pass. Safe to call repeatedly (idempotent per message).
  Future<void> execute() async {
    try {
      await _doSweep();
    } catch (e) {
      // DB might be closed (app locked) — silently skip this cycle
    }
  }

  Future<void> _doSweep() async {
    await _ephemeralKeys?.deleteOlderThan(_ephemeralKeyTtlSecs);

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final expired = await _messages.expiredBefore(now);
    if (expired.isEmpty) return;

    // Group by conversation to send one ttl_delete per peer.
    final byConv = <String, List<Message>>{};
    for (final msg in expired) {
      byConv.putIfAbsent(msg.conversationId, () => []).add(msg);
    }

    final deletedConvIds = <String>{};

    for (final entry in byConv.entries) {
      final convId = entry.key;
      final msgs   = entry.value;
      final ids    = msgs.map((m) => m.id!).toList();

      if (msgs.first.isGroup) {
        // Groups: local deletion only.
        for (final id in ids) {
          await _messages.deleteById(id);
        }
        deletedConvIds.add(convId);
        continue;
      }

      // DM: notify peer first (best-effort).
      await _sendTtlDelete(convId, ids);

      // Delete file records for media messages.
      for (final msg in msgs) {
        if (_isMedia(msg.contentType)) {
          await _files.deleteForMessage(msg.id!);
        }
        await _messages.deleteById(msg.id!);
      }
      deletedConvIds.add(convId);
    }

    if (deletedConvIds.isNotEmpty) {
      _bus.emit(MessagesDeletedEvent(conversationIds: deletedConvIds));
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Future<void> _sendTtlDelete(String contactPub58, List<int> ids) async {
    try {
      final plain = Uint8List.fromList(
        utf8.encode(jsonEncode({'type': 'ttl_delete', 'ids': ids})),
      );
      // Stateless NaCl box — does not require a DR session.
      final boxed   = await _crypto.encryptBox(contactPub58, plain);
      final contact = await _contacts.findByMasterPub(contactPub58);
      final destYgg = contact?.transportAddresses['yggdrasil']
          ?? contact?.yggPubKeyHex
          ?? '';
      await _transport.send(
        Envelope(from: '', to: contactPub58, body: boxed).body,
        TransportAddress(protocol: TransportProtocol.yggdrasil, value: destYgg),
      );
    } catch (_) {
      // Best-effort — peer will delete by their own TTL timer.
    }
  }

  static bool _isMedia(ContentType ct) =>
      ct == ContentType.image ||
      ct == ContentType.video ||
      ct == ContentType.audio ||
      ct == ContentType.file;
}
