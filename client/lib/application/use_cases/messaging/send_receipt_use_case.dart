import 'dart:convert';
import 'dart:typed_data';

import '../../../infrastructure/crypto/messaging_service.dart';
import '../../../domain/entities/envelope.dart';
import '../../../shared/utils/logger.dart';

/// Sends delivery/read receipts with explicit error handling.
///
/// Receipts are idempotent — resending the same receipt is safe.
/// Does NOT queue receipts (they're best-effort by design).
class SendReceiptUseCase {
  final MessagingService _messaging;
  final void Function(Envelope)? _onSendRaw;

  SendReceiptUseCase({
    required MessagingService messaging,
    required void Function(Envelope)? onSendRaw,
  })  : _messaging = messaging,
        _onSendRaw = onSendRaw;

  /// Send a delivery receipt for [messageId] to [recipientPub58].
  Future<bool> sendDeliveryReceipt(
    String recipientPub58,
    String messageId,
  ) =>
      _send(recipientPub58, {'type': 'msg_delivered', 'mid': messageId});

  /// Send a read receipt for [messageId] to [recipientPub58].
  Future<bool> sendReadReceipt(
    String recipientPub58,
    String messageId,
  ) =>
      _send(recipientPub58, {'type': 'msg_read', 'mid': messageId});

  Future<bool> _send(
    String recipientPub58,
    Map<String, dynamic> payload,
  ) async {
    try {
      final plain = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
      final env = await _messaging.encryptBox(recipientPub58, plain);
      _onSendRaw?.call(env);
      return true;
    } catch (e) {
      AppLogger.w('SendReceipt', 'failed to send ${payload['type']} '
          'for ${payload['mid']}: $e');
      return false;
    }
  }
}
