import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../application/events/app_event_bus.dart';
import '../shared/utils/logger.dart';
import '../application/events/app_events.dart';
import '../domain/entities/message.dart';
import '../infrastructure/transport/composite_transport.dart';
import '../infrastructure/crypto/multi_session_manager.dart';
import '../infrastructure/crypto/multi_device_payload_codec.dart';
import '../domain/entities/envelope.dart';
import '../infrastructure/connectivity/connectivity_watcher.dart';
import '../infrastructure/crypto/messaging_service.dart';
import '../storage/dao/send_queue_dao.dart';
import '../storage/storage_service.dart';

/// Manages the outbound message queue.
///
/// Responsibilities:
/// - On send failure: save to [send_queue], set message status = queued.
/// - On connectivity restored: flush pending queue (per-contact, one at a time).
/// - On retry timer: re-attempt messages with [next_retry <= now].
/// - On manual send: try immediately, fall back to queue.
class QueueService {
  final StorageService _storage;
  final MessagingService _messaging;
  final CompositeTransport _transport;
  final ConnectivityWatcher _connectivity;
  final AppEventBus? _bus;
  /// Optional multi-device session manager. When set and contact has known
  /// devices, messages are sent as v=2 MultiDevicePayload.
  MultiSessionManager? multiSessions;

  // Tracks which contacts are currently being flushed (prevent parallel sends
  // to the same contact).
  final _flushing = <String>{};

  StreamSubscription<int>? _peerSub;
  StreamSubscription<ContactHelloReceivedEvent>? _helloSub;
  Timer? _retryTimer;
  void Function()? _removePeersCb;

  QueueService({
    required StorageService storage,
    required MessagingService messaging,
    required CompositeTransport transport,
    required ConnectivityWatcher connectivity,
    AppEventBus? bus,
  })  : _storage = storage,
        _messaging = messaging,
        _transport = transport,
        _connectivity = connectivity,
        _bus = bus;

  void start() {
    _removePeersCb = _connectivity.addOnPeersAppeared(_flushAll);
    _peerSub = _connectivity.peerCount.listen((_) {});

    // Flush pending messages to a contact immediately when they come online
    _helloSub = _bus?.on<ContactHelloReceivedEvent>().listen((event) {
      AppLogger.d('Queue', 'contact_hello from ${event.senderMasterPub.substring(0, 8)}… → flush pending');
      _flushContact(event.senderMasterPub, []);
    });

    // Attempt flush on start in case peers are already up.
    _flushAll();

    // Periodic retry timer — flush due entries every minute.
    _retryTimer = Timer.periodic(const Duration(minutes: 1), (_) => _flushAll());

    // Evict expired cross_device_inbox entries hourly.
    Timer.periodic(const Duration(hours: 1), (_) async {
      try { await _storage.crossDeviceInbox.evictExpired(); } catch (_) {}
    });
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Send [plaintext] to [contactPub]. If transport fails, queues the message.
  ///
  /// Encrypts exactly once — the resulting [Envelope.body] blob is stored in
  /// [send_queue] and reused on every retry without touching DR state again.
  ///
  /// Returns the [MessageStatus] after the attempt:
  /// - [MessageStatus.sent] if delivered to transport
  /// - [MessageStatus.queued] if queued for later delivery
  Future<MessageStatus> sendOrQueue({
    required String contactPub,
    required String plaintext,
    required String contentType,
    required List<QueueRecipient> recipients,
    String? replyToId,
  }) async {
    // Try v=2 multi-device if contact has known devices and multiSessions available.
    // v=2 branch returns early — v=1 fallback only runs when no devices known.
    final ms = multiSessions;
    if (ms != null) {
      final contact = await _storage.contacts.findByMasterPub(contactPub);
      if (contact?.id != null) {
        final devices = await _storage.contactDevices.forContact(contact!.id!);
        if (devices.isNotEmpty) {
          final ttlStr = await _storage.settings.get('ttl_seconds:$contactPub');
          final ttlSec = ttlStr != null ? int.tryParse(ttlStr) : null;
          final mdPayload = await _messaging.encryptDmMultiDevice(
            contactPub, plaintext, ms,
            replyToId: replyToId,
            ttlSeconds: ttlSec,
          );
          if (mdPayload != null) {
            final mid  = mdPayload.messageId;
            final now  = DateTime.now().millisecondsSinceEpoch ~/ 1000;
            final expiresAt = ttlSec != null ? now + ttlSec : null;

            // Save message to DB BEFORE sending (at-least-once delivery)
            final dbId = await _storage.messages.insert(Message(
              conversationId: contactPub,
              isGroup: false,
              senderPub: _messaging.myMasterPub58,
              body: plaintext,
              sentAt: now,
              status: MessageStatus.sent,
              expiresAt: expiresAt,
              messageId: mid,
              replyToId: replyToId,
            ));
            _bus?.emit(MessageSentEvent(messageDbId: dbId, conversationId: contactPub));

            final encBody = mdPayload.encode();
            final envelope = Envelope(
              from: _messaging.myMasterPub58,
              to:   contactPub,
              body: encBody,
            );
            AppLogger.d('Queue', 'sendOrQueue: v=2 for ${contactPub.substring(0, 8)}… (${devices.length} devices)');

            final addrs = contact.transportAddresses.isNotEmpty
                ? contact.transportAddresses
                : recipients.first.transportAddresses;
            final result = await _transport.sendEnvelope(envelope, transportAddresses: addrs);
            if (result.success) {
              await _markSent(contactPub, mid, result.protocol!);
              for (final r in recipients) {
                await _storage.messageReceipts.markSent(mid, r.pub, result.protocol!, now);
              }
              final retryIntervalSec = await _getRetryIntervalSec();
              final queueId = await _enqueue(messageId: mid, recipients: recipients, encryptedBody: encBody, contentType: contentType);
              await _storage.sendQueue.setPendingAck(queueId, now + retryIntervalSec);
              return MessageStatus.sent;
            } else {
              await _enqueue(messageId: mid, recipients: recipients, encryptedBody: encBody, contentType: contentType);
              await _updateMessageStatus(contactPub, mid, MessageStatus.queued);
              return MessageStatus.queued;
            }
          }
        }
      }
    }

    // v=1 single-device fallback (no known devices for contact)
    final Envelope envelope;
    final String mid;
    try {
      final result = await _messaging.sendMessage(contactPub, plaintext, replyToId: replyToId);
      envelope = result.envelope;
      mid = result.messageId;
    } catch (e) {
      rethrow;
    }

    // Store the already-encrypted body — never re-encrypt on retry.
    final encryptedBody = envelope.body;

    // Try to send immediately.
    final contact = await _storage.contacts.findByMasterPub(contactPub);
    final addrs = contact?.transportAddresses.isNotEmpty == true
        ? contact!.transportAddresses
        : recipients.first.transportAddresses;
    final result = await _transport.sendEnvelope(
      envelope,
      transportAddresses: addrs,
    );

    if (result.success) {
      await _markSent(contactPub, mid, result.protocol!);
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      for (final r in recipients) {
        await _storage.messageReceipts.markSent(mid, r.pub, result.protocol!, now);
      }
      // Keep in queue as ack_pending — deleted only when msg_delivered receipt arrives.
      final retryIntervalSec = await _getRetryIntervalSec();
      final queueId = await _enqueue(
        messageId: mid,
        recipients: recipients,
        encryptedBody: encryptedBody,
        contentType: contentType,
      );
      await _storage.sendQueue.setPendingAck(queueId, now + retryIntervalSec);
      AppLogger.d('Queue', 'sendOrQueue: sent via ${result.protocol} → ack_pending msgId=${mid.substring(0, 8)}…');
      return MessageStatus.sent;
    } else {
      // Queue for later delivery.
      await _enqueue(
        messageId: mid,
        recipients: recipients,
        encryptedBody: encryptedBody,
        contentType: contentType,
      );
      await _updateMessageStatus(contactPub, mid, MessageStatus.queued);
      return MessageStatus.queued;
    }
  }

  /// Enqueue an already-encrypted envelope body that failed during router send.
  /// Called by [MessageRouter._sendRawEnvelope] on failure.
  Future<void> enqueueRaw({
    required String messageId,
    required List<QueueRecipient> recipients,
    required Uint8List encryptedBody,
    required String contentType,
  }) async {
    await _enqueue(
      messageId: messageId,
      recipients: recipients,
      encryptedBody: encryptedBody,
      contentType: contentType,
    );
  }

  /// Manually trigger a flush (e.g. when user pulls to refresh).
  void flushNow() => _flushAll();

  // ── Queue persistence ──────────────────────────────────────────────────────

  Future<int> _enqueue({
    required String messageId,
    required List<QueueRecipient> recipients,
    required Uint8List encryptedBody,
    required String contentType,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final maxAttempts = await _getMaxAttempts();
    return await _storage.sendQueue.insert(SendQueueEntry(
      messageId: messageId,
      recipients: recipients,
      encryptedBody: encryptedBody,
      contentType: contentType,
      createdAt: now,
      maxAttempts: maxAttempts,
    ));
  }

  // ── Flush logic ────────────────────────────────────────────────────────────

  Future<void> _flushAll() async {
    if (!_storage.isOpen) return;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final entries = await _storage.sendQueue.dueForRetry(now);
    AppLogger.d('Queue', 'flushAll: ${entries.length} entries due');
    if (entries.isEmpty) return;

    // Group by first recipient (primary contact for DMs).
    final byContact = <String, List<SendQueueEntry>>{};
    for (final e in entries) {
      final key = e.recipients.first.pub;
      (byContact[key] ??= []).add(e);
    }

    // Per-contact flush in parallel across contacts.
    await Future.wait(byContact.entries.map((kv) => _flushContact(kv.key, kv.value)));
  }

  Future<void> _flushContact(String contactPub, List<SendQueueEntry> entries) async {
    if (_flushing.contains(contactPub)) return;
    // Skip flush and purge queue for blocked contacts immediately.
    final contact = await _storage.contacts.findByMasterPub(contactPub);
    if (contact?.isBlocked == true) {
      await _storage.sendQueue.deleteForRecipient(contactPub);
      return;
    }
    _flushing.add(contactPub);
    try {
      // Always load fresh from DB to avoid stale entries from parallel flushes.
      final toSend = await _pendingForContact(contactPub);
      for (final entry in toSend) {
        await _trySend(entry);
      }
    } finally {
      _flushing.remove(contactPub);
    }
  }

  Future<void> _trySend(SendQueueEntry entry) async {
    if (entry.id == null) return;
    final contactPub = entry.recipients.first.pub;
    final contact = await _storage.contacts.findByMasterPub(contactPub);

    // Don't deliver to blocked contacts — remove from queue silently.
    if (contact?.isBlocked == true) {
      AppLogger.d('Queue', 'dropping queued msg to blocked contact ${contactPub.substring(0, 8)}…');
      await _storage.sendQueue.delete(entry.id!);
      return;
    }

    // For v=2 multi-device: check per_device_status and skip acked devices.
    // per_device_status is JSON: {"device_id": "sent|acked|failed"}
    // If all are acked, entry should already be deleted — but guard here too.
    final perDeviceStatus = entry.perDeviceStatus != null
        ? (jsonDecode(entry.perDeviceStatus!) as Map<String, dynamic>)
            .cast<String, String>()
        : <String, String>{};

    // Reuse the already-encrypted body — no re-encryption, DR state unchanged.
    final envelope = Envelope(
      from: _messaging.myMasterPub58,
      to: contactPub,
      body: entry.encryptedBody,
    );

    // Use current contact addresses (may be fresher than when message was queued).
    final addrs = contact?.transportAddresses.isNotEmpty == true
        ? contact!.transportAddresses
        : entry.recipients.first.transportAddresses;
    final result = await _transport.sendEnvelope(
      envelope,
      transportAddresses: addrs,
    );

    if (result.success) {
      final newAttempts = entry.attempts + 1;
      final maxAttempts = entry.maxAttempts;
      AppLogger.d('Queue', 'sent msgId=${entry.messageId.substring(0, 8)}… via ${result.protocol} attempt=$newAttempts → ack_pending');
      // Keep in queue as ack_pending — delete only when msg_delivered arrives.
      final retryIntervalSec = await _getRetryIntervalSec();
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await _storage.sendQueue.updateAttempt(entry.id!, newAttempts, now + retryIntervalSec);
      await _storage.sendQueue.setPendingAck(entry.id!, now + retryIntervalSec);
      await _markSent(contactPub, entry.messageId, result.protocol!);
      for (final r in entry.recipients) {
        await _storage.messageReceipts.markSent(
            entry.messageId, r.pub, result.protocol!, now);
      }
      _bus?.emit(MessageRetryUpdatedEvent(
        messageId: entry.messageId,
        attempts: newAttempts,
        maxAttempts: maxAttempts,
      ));
    } else {
      AppLogger.w('Queue', 'send failed msgId=${entry.messageId.substring(0, 8)}… → reschedule');
      await _reschedule(entry);
    }
  }

  Future<void> _reschedule(SendQueueEntry entry) async {
    if (entry.id == null) return;
    final newAttempts = entry.attempts + 1;
    final maxAttempts = await _getMaxAttempts();

    // Check if max attempts reached — delete message
    if (maxAttempts > 0 && newAttempts >= maxAttempts) {
      AppLogger.w('Queue', 'max attempts ($maxAttempts) reached for msgId=${entry.messageId.substring(0, 8)}… → deleting');
      await _storage.sendQueue.delete(entry.id!);
      // Find and delete the message from DB
      final contactPub = entry.recipients.first.pub;
      await _expireMessage(contactPub, entry.messageId);
      return;
    }

    final retryIntervalSec = await _getRetryIntervalSec();
    if (retryIntervalSec == 0) return; // disabled
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // Jitter ±20% to prevent thundering herd after connectivity restore.
    final jitter = Random.secure().nextInt(retryIntervalSec ~/ 5 + 1) - retryIntervalSec ~/ 10;
    final nextRetry = now + retryIntervalSec + jitter;
    await _storage.sendQueue.updateAttempt(entry.id!, newAttempts, nextRetry);
    _bus?.emit(MessageRetryUpdatedEvent(
      messageId: entry.messageId,
      attempts: newAttempts,
      maxAttempts: entry.maxAttempts,
    ));
  }

  Future<void> _expireMessage(String contactPub, String messageId) async {
    final m = await _storage.messages.findByMessageId(messageId);
    if (m?.id != null) {
      await _storage.messages.deleteById(m!.id!);
      AppLogger.d('Queue', 'expired message deleted from DB: id=${m.id}');
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  Future<List<SendQueueEntry>> _pendingForContact(String contactPub) async {
    if (!_storage.isOpen) return [];
    // All pending entries regardless of next_retry — contact just came online
    final all = await _storage.sendQueue.allPending();
    final forContact = all.where((e) =>
        e.recipients.any((r) => r.pub == contactPub)).toList();
    AppLogger.d('Queue', 'pendingForContact ${contactPub.substring(0, 8)}…: '
        '${forContact.length} entries (total queue: ${all.length})');
    return forContact;
  }

  Future<int> _getRetryIntervalSec() async {
    final val = await _storage.settings.get('queue_retry_minutes');
    final minutes = val != null ? int.tryParse(val) ?? 5 : 5;
    return minutes * 60;
  }

  Future<int> _getMaxAttempts() async {
    final val = await _storage.settings.get('queue_max_attempts');
    return val != null ? int.tryParse(val) ?? 30 : 30;
  }


  Future<void> _markSent(
      String contactPub, String messageId, String transport) async {
    final m = await _storage.messages.findByMessageId(messageId);
    if (m?.id != null) {
      await _storage.messages.updateStatusAndTransport(
          m!.id!, MessageStatus.sent, transport);
    }
  }

  Future<void> _updateMessageStatus(
      String contactPub, String messageId, MessageStatus status) async {
    final m = await _storage.messages.findByMessageId(messageId);
    if (m?.id != null) {
      await _storage.messages.updateStatus(m!.id!, status);
    }
  }

  // ── Delete ─────────────────────────────────────────────────────────────────

  /// Delete a queued message: removes from DB, queue, and receipts.
  Future<void> deleteQueued(String messageId, int messageDbId) async {
    await _storage.sendQueue.deleteByMessageId(messageId);
    await _storage.messageReceipts.deleteForMessage(messageId);
    await _storage.messages.deleteById(messageDbId);
  }

  void dispose() {
    _peerSub?.cancel();
    _helloSub?.cancel();
    _retryTimer?.cancel();
    _removePeersCb?.call();
  }
}
