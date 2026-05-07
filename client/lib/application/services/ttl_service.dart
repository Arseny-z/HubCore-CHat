import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../infrastructure/transport/composite_transport.dart';
import '../../shared/utils/logger.dart';
import '../../storage/storage_service.dart';
import '../../infrastructure/crypto/messaging_service.dart';

/// Periodically sweeps messages whose [expires_at] has passed.
///
/// For each expired message in a DM conversation:
///   1. Sends an encrypted `ttl_delete` system envelope to the peer so they
///      delete the same message on their side.
///   2. Deletes the message (and its file record, if any) locally.
///
/// TTL is set per-conversation via:
///   storage.settings.set('ttl_seconds:<conversationId>', '<seconds>')
///
/// A value of '0' or absence means no TTL.
class TtlService {
  final StorageService _storage;
  final MessagingService _messaging;
  final CompositeTransport _transport;

  /// Called after each sweep that deleted ≥1 message.
  /// The argument is the set of affected conversationIds.
  void Function(Set<String> conversationIds)? onMessagesDeleted;

  Timer? _timer;

  static const _sweepInterval = Duration(seconds: 30);

  TtlService({
    required StorageService storage,
    required MessagingService messaging,
    required CompositeTransport transport,
  })  : _storage = storage,
        _messaging = messaging,
        _transport = transport;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(_sweepInterval, (_) => _sweep());
    // Run once immediately so the first sweep doesn't wait 30 s.
    _sweep();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _sweep() async {
    if (!_storage.isOpen) return;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final expired = await _storage.messages.expiredBefore(now);
    if (expired.isEmpty) return;

    AppLogger.d('TTL:SWEEP', 'found ${expired.length} expired message(s) at ${DateTime.now().toIso8601String()}');

    // Group by conversation so we send one ttl_delete envelope per peer.
    final byConv = <String, List<Message>>{};
    for (final msg in expired) {
      byConv.putIfAbsent(msg.conversationId, () => []).add(msg);
    }

    for (final entry in byConv.entries) {
      final conversationId = entry.key;
      final msgs = entry.value;
      final ids = msgs.map((m) => m.id!).toList();
      final peer = conversationId.length > 8 ? conversationId.substring(0, 8) : conversationId;

      // Only DM conversations — groups don't support ttl_delete yet.
      if (msgs.first.isGroup) {
        AppLogger.d('TTL:SWEEP', 'group conv $peer — deleting ${ids.length} msg(s) locally (no ttl_delete for groups)');
        for (final id in ids) {
          await _storage.messages.deleteById(id);
        }
        continue;
      }

      AppLogger.d('TTL:SWEEP', 'DM conv $peer — ids=$ids'
          ' types=${msgs.map((m) => m.contentType.name).toList()}');

      // Send ttl_delete to peer (best-effort — no retry).
      await _sendTtlDelete(conversationId, ids);

      // Delete locally (including file records).
      int deleted = 0;
      for (final msg in msgs) {
        if (msg.contentType == ContentType.image ||
            msg.contentType == ContentType.file ||
            msg.contentType == ContentType.video ||
            msg.contentType == ContentType.audio) {
          if (msg.id != null) {
            await _storage.files.deleteForMessage(msg.id!);
            AppLogger.d('TTL:SWEEP', 'deleted file record for msg id=${msg.id}');
          }
        }
        if (msg.id != null) {
          final rows = await _storage.messages.deleteById(msg.id!);
          if (rows > 0) deleted++;
        }
      }
      AppLogger.d('TTL:SWEEP', '→ deleted $deleted/${ids.length} msg(s) locally from $peer');
    }

    if (byConv.isNotEmpty) {
      onMessagesDeleted?.call(byConv.keys.toSet());
    }
  }

  Future<void> _sendTtlDelete(String contactPub58, List<int> ids) async {
    final peer = contactPub58.length > 8 ? contactPub58.substring(0, 8) : contactPub58;
    try {
      // Use stateless NaCl box — NOT Double Ratchet.
      final payload = Uint8List.fromList(
        utf8.encode(jsonEncode({'type': 'ttl_delete', 'ids': ids})),
      );
      final envelope = await _messaging.encryptBox(contactPub58, payload);
      final contact = await _storage.contacts.findByMasterPub(contactPub58);
      await _transport.sendEnvelope(envelope, transportAddresses: contact?.transportAddresses);
      AppLogger.d('TTL:DELETE', '→ $peer ids=$ids sent via NaCl box');
    } catch (e) {
      // Best-effort — peer will delete by their own TTL timer.
      AppLogger.w('TTL:DELETE', '→ $peer SEND FAILED: $e');
    }
  }
}
