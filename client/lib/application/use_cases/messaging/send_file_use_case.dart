import 'dart:io';

import '../../../infrastructure/crypto/messaging_service.dart';
import '../../../infrastructure/file_transfer/file_service.dart';
import '../../../infrastructure/transport/composite_transport.dart';
import '../../../domain/repositories/contact_repository.dart';
import 'ensure_session_use_case.dart';

/// Null-safe file sending use case.
///
/// Validates all dependencies are available before attempting send.
/// Uses [EnsureSessionUseCase] to guarantee DR session exists.
class SendFileUseCase {
  final FileService? _fileService;
  final MessagingService? _messaging;
  final CompositeTransport? _transport;
  final EnsureSessionUseCase? _ensureSession;
  final ContactRepository? _contacts;

  SendFileUseCase({
    required FileService? fileService,
    required MessagingService? messaging,
    required CompositeTransport? transport,
    required EnsureSessionUseCase? ensureSession,
    required ContactRepository? contacts,
  })  : _fileService = fileService,
        _messaging = messaging,
        _transport = transport,
        _ensureSession = ensureSession,
        _contacts = contacts;

  /// True if all dependencies are available.
  bool get isReady =>
      _fileService != null &&
      _messaging != null &&
      _transport != null &&
      _ensureSession != null;

  /// Send a file to [contactMasterPub58].
  ///
  /// Throws [StateError] if dependencies are not ready.
  Future<void> execute({
    required File sourceFile,
    required String myPub58,
    required String contactMasterPub58,
    void Function(double progress)? onProgress,
    String? mimeType,
    int? ttlSeconds,
  }) async {
    if (!isReady) {
      throw StateError(
          'File service not ready (DB locked or service not initialized)');
    }

    final fileService = _fileService!;
    final messaging = _messaging!;
    final transport = _transport!;
    final ensureSession = _ensureSession!;

    // Ensure DR session exists
    await ensureSession.execute(contactMasterPub58);

    // Resolve transport addresses
    final contact = await _contacts?.findByMasterPub(contactMasterPub58);
    final addrs = contact?.transportAddresses;

    await fileService.sendFile(
      sourceFile: sourceFile,
      myPub58: myPub58,
      contactMasterPub58: contactMasterPub58,
      destYggPubKeyHex: contact?.yggPubKeyHex,
      encryptFn: (p) => messaging.encryptBox(contactMasterPub58, p),
      sendFn: (env) => transport.sendEnvelope(env, transportAddresses: addrs),
      onProgress: onProgress,
      mimeType: mimeType,
      ttlSeconds: ttlSeconds,
    );
  }
}
