import 'dart:io';
import 'dart:typed_data';

import '../entities/file_transfer.dart';
import '../entities/envelope.dart';
import '../../storage/dao/messages_dao.dart' show MessageStatus;

/// Port (interface) for file transfer operations.
///
/// Defined in Domain; implemented in Infrastructure (FileService).
/// Use cases depend on this abstraction, not on the concrete FileService.
abstract class FileTransferPort {
  /// Called when a status update should be propagated (e.g. file delivered).
  set onStatusUpdate(void Function(int msgId, MessageStatus status)? callback);

  /// Send a file to [contactMasterPub58].
  Future<void> sendFile({
    required File   sourceFile,
    required String myPub58,
    required String contactMasterPub58,
    required String? destYggPubKeyHex,
    required Future<Envelope> Function(Uint8List plaintext) encryptFn,
    required Future<void> Function(Envelope envelope) sendFn,
    void Function(double progress)? onProgress,
    String? mimeType,
    int? ttlSeconds,
    String? conversationId,
    bool isGroup = false,
    int? existingMsgId,
  });

  /// Handle an incoming file offer (sender announces a file is coming).
  Future<void> handleFileOffer(
    String  senderPub58,
    String? senderYggPubKeyHex,
    FileOffer offer,
  );

  /// Handle an incoming file chunk. Returns the local file name when the
  /// transfer completes, null otherwise.
  Future<String?> handleIncomingChunk(
    String    senderPub58,
    FileChunk chunk,
    String    myPub58,
    Future<void> Function(Envelope) sendFn,
  );

  /// Inject a file acknowledgement received from the remote peer.
  void injectAck(FileAck ack);

  void dispose();
}
