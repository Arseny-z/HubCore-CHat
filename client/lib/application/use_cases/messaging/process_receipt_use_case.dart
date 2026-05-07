import '../../events/app_event_bus.dart';
import '../../events/app_events.dart';
import '../../../shared/utils/logger.dart';
import '../../../domain/repositories/message_repository.dart';
import '../../../storage/dao/message_receipts_dao.dart';
import '../../../storage/dao/messages_dao.dart' show MessageStatus;
import '../../../storage/dao/send_queue_dao.dart';

/// Atomically processes an incoming delivery or read receipt.
///
/// Updates both `messages.status` and `message_receipts` in one place.
/// Uses a database transaction for delivery receipts to prevent inconsistent
/// state (message marked delivered but still sitting in send_queue).
class ProcessReceiptUseCase {
  final MessageRepository _messages;
  final MessageReceiptsDao _receipts;
  final SendQueueDao _queue;
  final AppEventBus _bus;

  ProcessReceiptUseCase({
    required MessageRepository messages,
    required MessageReceiptsDao receipts,
    required SendQueueDao queue,
    required AppEventBus bus,
  })  : _messages = messages,
        _receipts = receipts,
        _queue = queue,
        _bus = bus;

  /// Process a msg_received receipt (packet buffered on recipient's device).
  Future<void> processReceivedReceipt({
    required String messageId,
    required String senderPub,
  }) async {
    final msg = await _messages.findByMessageId(messageId);
    if (msg == null || msg.id == null) return;
    // Verify receipt sender is the intended recipient of the message.
    // For DM: conversationId == recipient's masterPub.
    // For group: any member can ack, so skip strict check (isGroup).
    if (!msg.isGroup && msg.conversationId != senderPub) {
      AppLogger.w('Receipt', 'msg_received REJECTED: sender $senderPub is not '
          'recipient ${msg.conversationId} for mid=${messageId.substring(0, 8)}…');
      return;
    }
    if (msg.status == MessageStatus.sent) {
      await _messages.updateStatus(msg.id!, MessageStatus.received);
      _bus.emit(MessageStatusUpdatedEvent(
        messageDbId: msg.id!,
        status: MessageStatus.received,
      ));
    }
    AppLogger.d('Receipt', 'msg_received processed: mid=${messageId.substring(0, 8)}… from $senderPub');
  }

  /// Process a msg_delivered receipt.
  ///
  /// Wraps status update, receipt record, and queue deletion in a single
  /// database transaction to prevent inconsistent state on crash.
  Future<void> processDeliveryReceipt({
    required String messageId,
    required String senderPub,
    required int deliveredAt,
  }) async {
    final msg = await _messages.findByMessageId(messageId);
    if (msg != null && !msg.isGroup && msg.conversationId != senderPub) {
      AppLogger.w('Receipt', 'msg_delivered REJECTED: sender $senderPub is not '
          'recipient ${msg.conversationId} for mid=${messageId.substring(0, 8)}…');
      return;
    }
    AppLogger.d('Receipt', 'findByMessageId mid=${messageId.substring(0, 8)}… → '
        'found=${msg != null} id=${msg?.id} status=${msg?.status}');

    final db = _queue.db;
    await db.transaction((txn) async {
      // 1. Update message status
      if (msg?.id != null && (msg!.status == MessageStatus.sent ||
          msg.status == MessageStatus.received ||
          msg.status == MessageStatus.queued)) {
        await txn.update(
          'messages',
          {'status': MessageStatus.delivered.name},
          where: 'id = ?',
          whereArgs: [msg.id],
        );
      }
      // 2. Update receipt record
      await txn.rawUpdate(
        '''UPDATE message_receipts
           SET status = ?, delivered_at = ?
           WHERE message_id = ? AND recipient_pub = ?''',
        ['delivered', deliveredAt, messageId, senderPub],
      );
      // 3. Remove from send queue
      await txn.delete('send_queue',
          where: 'message_id = ?', whereArgs: [messageId]);
    });

    // Emit events outside transaction
    if (msg?.id != null && (msg!.status == MessageStatus.sent ||
        msg.status == MessageStatus.received ||
        msg.status == MessageStatus.queued)) {
      _bus.emit(MessageStatusUpdatedEvent(
        messageDbId: msg.id!,
        status: MessageStatus.delivered,
      ));
    }
    AppLogger.d('Receipt', 'msg_delivered processed: mid=${messageId.substring(0, 8)}… from $senderPub');
    _bus.emit(MessageRetryUpdatedEvent(
      messageId: messageId,
      attempts: -1,
      maxAttempts: 0,
    ));
  }

  /// Process a msg_read receipt.
  Future<void> processReadReceipt({
    required String messageId,
    required String senderPub,
    required int readAt,
  }) async {
    final msg = await _messages.findByMessageId(messageId);
    AppLogger.d('Receipt', 'msg_read: found msg=${msg?.id} mid=${messageId.substring(0, 8)}…');
    if (msg != null && !msg.isGroup && msg.conversationId != senderPub) {
      AppLogger.w('Receipt', 'msg_read REJECTED: sender $senderPub is not '
          'recipient ${msg.conversationId} for mid=${messageId.substring(0, 8)}…');
      return;
    }
    if (msg != null && msg.id != null) {
      await _messages.updateStatus(msg.id!, MessageStatus.read);
      _bus.emit(MessageStatusUpdatedEvent(
        messageDbId: msg.id!,
        status: MessageStatus.read,
      ));
    }

    await _receipts.markRead(messageId, senderPub, readAt);
    AppLogger.d('Receipt', 'msg_read processed: mid=${messageId.substring(0, 8)}… from $senderPub');
  }
}
