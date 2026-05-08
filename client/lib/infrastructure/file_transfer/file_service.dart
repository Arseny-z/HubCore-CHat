import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:sodium_libs/sodium_libs.dart';

import '../../application/events/app_event_bus.dart';
import '../../application/events/app_events.dart';
import '../../shared/utils/logger.dart';
import '../../crypto/file_encryption.dart';
import '../../crypto/identity.dart';
import '../../domain/entities/file_transfer.dart';
import '../../domain/ports/file_transfer_port.dart';
import '../../domain/entities/envelope.dart';
import '../../storage/storage_service.dart';

export '../../domain/entities/file_transfer.dart' show FileOffer, FileChunk, FileAck;

// ── Constants ─────────────────────────────────────────────────────────────────

const kChunkSize    = 8 * 1024;         // 8 KB ciphertext per chunk
const kMaxFileSize  = 200 * 1024 * 1024; // 200 MB

// ── Orphan chunk limits ──────────────────────────────────────────────────────
const kMaxOrphanTransfers    = 10;   // max different transfer IDs buffered
const kMaxOrphanChunksPerTid = 500;  // max chunks per transfer before offer
const kMaxOrphanTotalDisk    = 50 * 1024 * 1024; // 50 MB total on disk
const kOrphanCleanupInterval = Duration(minutes: 10);

// ── In-progress incoming transfer ─────────────────────────────────────────────

class _IncomingTransfer {
  final String           transferId;
  final String           senderPub58;
  final String?          senderYggPubKeyHex;
  final int              totalChunks;
  final String           name;
  final String           mime;
  final int              plaintextSize;
  final Uint8List        key;
  final Uint8List        nonce;
  final String           tmpPath;
  final String?          groupId;
  final int?             ttlSeconds;
  int?                   msgId; // set after message is created in DB
  final Set<int>         received  = {};
  final DateTime         startedAt = DateTime.now();
  RandomAccessFile?      raf; // kept open for random-write without truncation

  // Debounce timer — fires a progress ack 800 ms after the last chunk arrives.
  Timer? ackDebounce;

  _IncomingTransfer({
    required this.transferId,
    required this.senderPub58,
    required this.senderYggPubKeyHex,
    required this.totalChunks,
    required this.name,
    required this.mime,
    required this.plaintextSize,
    required this.key,
    required this.nonce,
    required this.tmpPath,
    this.groupId,
    this.ttlSeconds,
  });
}

// ── FileService ───────────────────────────────────────────────────────────────

class FileService implements FileTransferPort {
  final Sodium          _sodium;
  final Identity        _identity;
  final StorageService  _storage;
  final AppEventBus?    _eventBus;

  // Active incoming transfers, keyed by transferId.
  final _incoming     = <String, _IncomingTransfer>{};

  // Chunks that arrived before their file_offer (offer may be delayed).
  // Persisted to disk so they survive app restarts.
  final _orphanChunks = <String, List<FileChunk>>{};

  // Decrypted bytes cache: messageId → bytes (null = failed, absent = not tried).
  final _decryptCache = <int, Uint8List?>{};

  // Stream that receives file_ack messages injected by MessagingService.
  final _ackCtrl = StreamController<FileAck>.broadcast();

  // Cancelled outgoing transfer IDs — checked in _sendChunks before each chunk.
  final _cancelledOutgoing = <String>{};

  // Periodic orphan chunk cleanup timer.
  Timer? _orphanCleanupTimer;

  // Active outgoing transfers: transferId → (encryptFn, sendFn) for cancellation.
  final _outgoingSendFns = <String, ({
    Future<Envelope> Function(Uint8List) encryptFn,
    Future<void> Function(Envelope) sendFn,
    String contactMasterPub58,
    String myPub58,
  })>{};

  /// Called when a file transfer is confirmed delivered (done ack received).
  /// Arguments: local DB message id, new status.
  void Function(int msgId, MessageStatus status)? onStatusUpdate;

  FileService({
    required Sodium sodium,
    required Identity identity,
    required StorageService storage,
    AppEventBus? eventBus,
  })  : _sodium   = sodium,
        _identity = identity,
        _storage  = storage,
        _eventBus = eventBus {
    _cleanTmpFiles();
    _cleanStaleOrphanChunks();
    _orphanCleanupTimer = Timer.periodic(kOrphanCleanupInterval, (_) {
      _cleanStaleOrphanChunks();
    });
  }

  void dispose() {
    _orphanCleanupTimer?.cancel();
    for (final t in _incoming.values) {
      t.ackDebounce?.cancel();
      t.raf?.close();
    }
    if (!_ackCtrl.isClosed) _ackCtrl.close();
  }

  // ── Ack injection (called by MessagingService) ─────────────────────────────

  /// MessagingService calls this whenever it receives a raw file_ack envelope.
  void injectAck(FileAck ack) {
    if (!_ackCtrl.isClosed) _ackCtrl.add(ack);
  }

  // ── Cancel outgoing transfer ───────────────────────────────────────────────

  /// Cancel an in-progress outgoing transfer.
  /// Stops chunk sending and notifies the receiver with file_cancel.
  Future<void> cancelOutgoing(String transferId) async {
    AppLogger.d('File', 'cancelOutgoing tid=$transferId hasSendFn=${_outgoingSendFns.containsKey(transferId)}');
    _cancelledOutgoing.add(transferId);
    final rec = _outgoingSendFns[transferId];
    if (rec != null) {
      try {
        final body = Uint8List.fromList(
            utf8.encode(jsonEncode({'type': 'file_cancel', 'tid': transferId})));
        final envelope = await rec.encryptFn(body);
        await rec.sendFn(envelope);
        AppLogger.d('File', 'sent file_cancel for tid=$transferId');
      } catch (e) {
        AppLogger.w('File', 'file_cancel send failed (best-effort)', error: e);
      }
      _outgoingSendFns.remove(transferId);
    }
  }

  // ── Incoming cancel (called by MessagingService) ───────────────────────────

  /// Called when a file_cancel is received from the sender.
  void injectCancel(String transferId) {
    final t = _incoming[transferId];
    if (t != null) {
      t.ackDebounce?.cancel();
      t.raf?.close();
      _incoming.remove(transferId);
      // Emit done event so UI removes the progress indicator
      if (t.msgId != null) {
        _eventBus?.emit(FileTransferProgressEvent(
            messageId: t.msgId!, progress: 0.0, done: true));
        // Delete placeholder if it was created
        _storage.messages.deleteById(t.msgId!).catchError((_) => 0);
      }
      AppLogger.d('File', 'cancelled incoming transfer tid=$transferId');
    }
    _orphanChunks.remove(transferId);
    _cleanOrphanChunks(transferId);
  }

  // ── Send ───────────────────────────────────────────────────────────────────

  /// Full send flow with ack/retry:
  ///
  /// 1. Encrypt file, save to disk, insert placeholder message in DB.
  /// 2. Send `file_offer` via DR ([encryptFn]).
  /// 3. Wait 500 ms for Yggdrasil route warmup.
  /// 4. Send all chunks (raw, 150 ms gap).
  /// 5. Retry up to 3 rounds: wait for ack, resend missing chunks.
  Future<void> sendFile({
    required File   sourceFile,
    required String myPub58,
    required String contactMasterPub58,
    required String? destYggPubKeyHex,
    required Future<Envelope> Function(Uint8List plaintext) encryptFn,
    required Future<void> Function(Envelope envelope)   sendFn,
    void Function(double progress)? onProgress,
    void Function(int msgId, String transferId)? onPlaceholderCreated,
    String? mimeType,
    int? ttlSeconds,
    /// For group files: conversationId = groupId, isGroup = true.
    /// For DM files: defaults to contactMasterPub58, isGroup = false.
    String? conversationId,
    bool isGroup = false,
    /// If provided, skip creating a placeholder message (already created by caller).
    int? existingMsgId,
  }) async {
    final plainSize = await sourceFile.length();
    if (plainSize > kMaxFileSize) {
      throw ArgumentError('File exceeds 200 MB limit');
    }

    final mime     = mimeType ?? _guessMime(sourceFile.path);
    final fileName = sourceFile.path.split('/').last;

    // Encrypt file using streaming v2 format (bounded memory).
    final filesDir = await _filesDir();
    final encPath  =
        '${filesDir.path}/${DateTime.now().millisecondsSinceEpoch}_$fileName.enc';
    final enc = await FileEncryption(_sodium).encryptFileStream(
      sourceFile,
      File(encPath),
    );

    final encFile     = File(encPath);
    final encFileSize = await encFile.length();
    final now         = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final totalChunks = (encFileSize / kChunkSize).ceil();
    final transferId  = _randomHex(16);

    // DB: FileRecord
    final fileId = await _storage.files.insert(FileRecord(
      fileKey:   enc.key,
      fileNonce: enc.nonce,
      localPath: encPath,
      mimeType:  mime,
      sizeBytes: plainSize,
      createdAt: now,
    ));

    // DB: placeholder message visible in sender's chat immediately
    final contentType =
        mime.startsWith('image/') ? ContentType.image : mime.startsWith('audio/') ? ContentType.audio : mime.startsWith('video/') ? ContentType.video : ContentType.file;
    final fileExpiresAt = (ttlSeconds != null && ttlSeconds > 0) ? now + ttlSeconds : null;
    final effectiveConvId = conversationId ?? contactMasterPub58;
    // Shared message ID — same on sender and receiver for read receipt correlation
    final fileMid = _randomHex(16);
    int msgId;
    if (existingMsgId != null) {
      msgId = existingMsgId;
    } else {
      msgId = await _storage.messages.insert(Message(
        conversationId: effectiveConvId,
        isGroup:        isGroup,
        senderPub:      myPub58,
        body:           fileName,
        contentType:    contentType,
        sentAt:         now,
        status:         MessageStatus.sent,
        expiresAt:      fileExpiresAt,
        messageId:      fileMid,
      ));
    }
    AppLogger.d('FILE:SEND', 'placeholder msgId=$msgId "$fileName" tid=$transferId'
        ' conv=$effectiveConvId group=$isGroup'
        ' ttl=${ttlSeconds != null ? "${ttlSeconds}s" : "off"}');
    await _storage.files.updateMessageId(fileId, msgId);

    // Emit progress=0 immediately so UI shows sending indicator before first chunk
    _eventBus?.emit(FileTransferProgressEvent(messageId: msgId, progress: 0.0));
    // Register fns for potential cancellation, then notify caller
    _outgoingSendFns[transferId] = (
      encryptFn: encryptFn,
      sendFn: sendFn,
      myPub58: myPub58,
      contactMasterPub58: contactMasterPub58,
    );
    onPlaceholderCreated?.call(msgId, transferId);

    // Build offer (key is encoded here, zeroed after offer is sent)
    final offer = FileOffer(
      tid:        transferId,
      name:       fileName,
      mime:       mime,
      size:       plainSize,
      chunks:     totalChunks,
      key:        enc.key,
      nonce:      enc.nonce,
      groupId:    isGroup ? (conversationId ?? contactMasterPub58) : null,
      ttlSeconds: ttlSeconds,
      mid:        fileMid,
      encSize:    encFileSize,
    );

    AppLogger.d('File', 'sending $fileName ($totalChunks chunks, enc=${encFileSize}b, tid=$transferId)');

    // 1. Send offer via DR — repeated 3× to survive Yggdrasil route warmup losses.
    //    DR ratchet advances once; receiver deduplicates by transferId.
    final offerEnvelope = await encryptFn(offer.encode());
    for (int r = 0; r < 3; r++) {
      await sendFn(offerEnvelope);
      AppLogger.d('File', 'offer sent (attempt ${r + 1}/3)');
      if (r < 2) await Future.delayed(const Duration(milliseconds: 400));
    }

    // Zero key in memory now that offer is sent
    enc.key.fillRange(0, enc.key.length, 0);

    // 2. Route warmup delay before chunks
    await Future.delayed(const Duration(milliseconds: 500));

    // 3. Send all chunks (read from encrypted file on disk, not in-memory)
    await _sendChunksFromFile(
      encFile:              encFile,
      encFileSize:          encFileSize,
      totalChunks:          totalChunks,
      transferId:           transferId,
      myPub58:              myPub58,
      contactMasterPub58:   contactMasterPub58,
      sendFn:               sendFn,
      onProgress:           onProgress,
      startIdx:             0,
      msgId:                msgId,
    );

    // 4. Ack / retry loop
    for (int round = 0; round < 3; round++) {
      if (_cancelledOutgoing.contains(transferId)) {
        _cancelledOutgoing.remove(transferId);
        break;
      }
      final ack = await _waitForAck(transferId, const Duration(seconds: 5));
      if (_cancelledOutgoing.contains(transferId)) {
        _cancelledOutgoing.remove(transferId);
        break;
      }
      if (ack == null) {
        AppLogger.d('File', 'no ack received (round $round), assuming delivered');
        break;
      }
      if (ack.done) {
        AppLogger.d('File', 'transfer $transferId complete (ack received)');
        await _storage.messages.updateStatus(msgId, MessageStatus.delivered);
        onStatusUpdate?.call(msgId, MessageStatus.delivered);
        break;
      }
      if (ack.missing.isEmpty) break;

      AppLogger.d('File', 'retrying ${ack.missing.length} missing chunks (round ${round + 1})');
      for (final idx in ack.missing) {
        if (_cancelledOutgoing.contains(transferId)) break;
        final chunkData = await _readChunkFromFile(encFile, idx, encFileSize);
        final chunk = FileChunk(
          tid:  transferId,
          idx:  idx,
          tot:  totalChunks,
          data: chunkData,
        );
        await sendFn(Envelope(
          from: myPub58,
          to:   contactMasterPub58,
          body: chunk.encode(),
        ));
        if (idx != ack.missing.last) {
          await Future.delayed(const Duration(milliseconds: 150));
        }
      }
    }
    _cancelledOutgoing.remove(transferId);
  }

  /// Read a single 8KB network chunk from the encrypted file on disk.
  Future<Uint8List> _readChunkFromFile(File encFile, int idx, int encFileSize) async {
    final start = idx * kChunkSize;
    final end   = min(start + kChunkSize, encFileSize);
    final raf = await encFile.open(mode: FileMode.read);
    try {
      await raf.setPosition(start);
      return await raf.read(end - start);
    } finally {
      await raf.close();
    }
  }

  /// Send all network chunks by reading from the encrypted file on disk.
  /// Peak memory: one 8KB chunk at a time.
  Future<void> _sendChunksFromFile({
    required File      encFile,
    required int       encFileSize,
    required int       totalChunks,
    required String    transferId,
    required String    myPub58,
    required String    contactMasterPub58,
    required Future<void> Function(Envelope) sendFn,
    void Function(double progress)? onProgress,
    required int startIdx,
    int? msgId,
  }) async {
    final raf = await encFile.open(mode: FileMode.read);
    try {
      for (int idx = startIdx; idx < totalChunks; idx++) {
        if (_cancelledOutgoing.contains(transferId)) {
          AppLogger.d('File', 'send cancelled at chunk $idx for tid=$transferId');
          _cancelledOutgoing.remove(transferId);
          return;
        }
        final start = idx * kChunkSize;
        final end   = min(start + kChunkSize, encFileSize);
        await raf.setPosition(start);
        final data = await raf.read(end - start);
        final chunk = FileChunk(
          tid:  transferId,
          idx:  idx,
          tot:  totalChunks,
          data: data,
        );
        await sendFn(Envelope(
          from: myPub58,
          to:   contactMasterPub58,
          body: chunk.encode(),
        ));
        AppLogger.d('File', 'chunk $idx/$totalChunks sent');
        final p = (idx + 1) / totalChunks;
        onProgress?.call(p);
        if (msgId != null) {
          _eventBus?.emit(FileTransferProgressEvent(
            messageId: msgId, progress: p, done: idx == totalChunks - 1));
        }
        if (idx < totalChunks - 1) {
          await Future.delayed(const Duration(milliseconds: 150));
        }
      }
    } finally {
      await raf.close();
    }
    _outgoingSendFns.remove(transferId); // cleanup after successful send
  }

  Future<FileAck?> _waitForAck(String tid, Duration timeout) {
    final completer = Completer<FileAck?>();
    late StreamSubscription<FileAck> sub;
    sub = _ackCtrl.stream.where((a) => a.tid == tid).listen((ack) {
      if (!completer.isCompleted) {
        completer.complete(ack);
        sub.cancel();
      }
    });
    Future.delayed(timeout, () {
      if (!completer.isCompleted) {
        completer.complete(null);
        sub.cancel();
      }
    });
    return completer.future;
  }

  // ── Receive ────────────────────────────────────────────────────────────────

  /// Called by MessagingService after DR-decrypting a `file_offer` message.
  Future<void> handleFileOffer(
    String  senderPub58,
    String? senderYggPubKeyHex,
    FileOffer offer,
  ) async {
    // Deduplicate — offer may be sent multiple times
    if (_incoming.containsKey(offer.tid)) return;

    final safeName = _sanitizeFileName(offer.name);
    AppLogger.d('File', 'offer received: $safeName (${offer.chunks} chunks, tid=${offer.tid})');

    final dir     = await _filesDir();
    final tmpPath = '${dir.path}/tmp_${offer.tid}.enc';

    // Pre-allocate file for random-access writes.
    // v2 (encSize present): use exact encrypted size from offer.
    // v1 (legacy): single AEAD blob = plaintext + 16-byte tag.
    final ciphertextSize = offer.encSize ?? (offer.size + 16);
    final raf = await File(tmpPath).open(mode: FileMode.write);
    await raf.truncate(ciphertextSize);
    // Keep raf open — _writeChunk uses setPosition without re-opening.

    final transfer = _IncomingTransfer(
      transferId:         offer.tid,
      senderPub58:        senderPub58,
      senderYggPubKeyHex: senderYggPubKeyHex,
      totalChunks:        offer.chunks,
      name:               safeName,
      mime:               offer.mime,
      plaintextSize:      offer.size,
      key:                offer.key,
      nonce:              offer.nonce,
      tmpPath:            tmpPath,
      groupId:            offer.groupId,
      ttlSeconds:         offer.ttlSeconds,
    )..raf = raf;
    _incoming[offer.tid] = transfer;

    // Create placeholder message immediately so receiver sees progress in chat
    final contentType = offer.mime.startsWith('image/')
        ? ContentType.image
        : offer.mime.startsWith('audio/')
            ? ContentType.audio
            : offer.mime.startsWith('video/')
                ? ContentType.video
                : ContentType.file;
    final isGroup = offer.groupId != null;
    final convId  = offer.groupId ?? senderPub58;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final placeholderId = await _storage.messages.insert(Message(
      conversationId: convId,
      isGroup:        isGroup,
      senderPub:      senderPub58,
      body:           offer.name,
      contentType:    contentType,
      sentAt:         now,
      status:         MessageStatus.sent, // "receiving" state
      messageId:      offer.mid ?? _randomHex(16),
    ));
    transfer.msgId = placeholderId;
    _eventBus?.emit(MessageReceivedEvent(
      conversationId: convId, isGroup: isGroup, senderPub: senderPub58));
    _eventBus?.emit(FileTransferProgressEvent(messageId: placeholderId, progress: 0.0));

    // Drain orphan chunks: in-memory first, then disk (survives restarts).
    final memOrphans = _orphanChunks.remove(offer.tid) ?? [];
    final diskOrphans = await _loadOrphanChunks(offer.tid);
    // Merge, dedup by idx
    final seen = <int>{};
    final allOrphans = <FileChunk>[];
    for (final c in [...memOrphans, ...diskOrphans]) {
      if (seen.add(c.idx)) allOrphans.add(c);
    }
    if (allOrphans.isNotEmpty) {
      AppLogger.d('File', 'draining ${allOrphans.length} orphan chunks for ${offer.tid}');
      for (final chunk in allOrphans) {
        await _writeChunk(transfer, chunk);
      }
      await _cleanOrphanChunks(offer.tid);
    }
  }

  /// Called by MessagingService when a raw `file_chunk` envelope arrives.
  ///
  /// [sendFn] is used to send progress acks back to the sender.
  Future<String?> handleIncomingChunk(
    String    senderPub58,
    FileChunk chunk,
    String    myPub58,
    Future<void> Function(Envelope) sendFn,
  ) async {
    var transfer = _incoming[chunk.tid];

    if (transfer == null) {
      // Offer not yet received — buffer in memory and persist to disk.
      // Enforce limits to prevent DoS via unbounded orphan accumulation.
      if (_orphanChunks.length >= kMaxOrphanTransfers &&
          !_orphanChunks.containsKey(chunk.tid)) {
        AppLogger.w('File', 'orphan transfer limit reached ($kMaxOrphanTransfers), dropping chunk for ${chunk.tid}');
        return null;
      }
      final list = _orphanChunks.putIfAbsent(chunk.tid, () => []);
      if (list.length >= kMaxOrphanChunksPerTid) {
        AppLogger.w('File', 'orphan chunk limit reached ($kMaxOrphanChunksPerTid) for ${chunk.tid}, dropping');
        return null;
      }
      list.add(chunk);
      await _persistOrphanChunk(chunk);
      AppLogger.d('File', 'orphan chunk ${chunk.idx}/${chunk.tot} buffered for ${chunk.tid}');
      return null;
    }

    await _writeChunk(transfer, chunk);

    // Debounced progress ack (800 ms after last chunk, if not yet complete)
    transfer.ackDebounce?.cancel();
    if (transfer.received.length < transfer.totalChunks) {
      transfer.ackDebounce = Timer(const Duration(milliseconds: 800), () {
        _sendProgressAck(transfer, myPub58, sendFn);
      });
    }

    if (transfer.received.length < transfer.totalChunks) return null;

    // All chunks received
    transfer.ackDebounce?.cancel();
    await _sendDoneAck(transfer, myPub58, sendFn);
    return _finalizeTransfer(transfer);
  }

  Future<void> _writeChunk(_IncomingTransfer transfer, FileChunk chunk) async {
    if (transfer.received.contains(chunk.idx)) return; // duplicate

    final raf = transfer.raf;
    if (raf == null) return; // transfer already finalized
    await raf.setPosition(chunk.idx * kChunkSize);
    await raf.writeFrom(chunk.data);
    transfer.received.add(chunk.idx);
    AppLogger.d('File', 'chunk ${chunk.idx}/${chunk.tot} received (${transfer.received.length}/${transfer.totalChunks})');
    final mid = transfer.msgId;
    if (mid != null) {
      final p = transfer.received.length / transfer.totalChunks;
      _eventBus?.emit(FileTransferProgressEvent(messageId: mid, progress: p));
    }
  }

  Future<void> _sendProgressAck(
    _IncomingTransfer         transfer,
    String                    myPub58,
    Future<void> Function(Envelope) sendFn,
  ) async {
    final all     = Set<int>.from(List.generate(transfer.totalChunks, (i) => i));
    final missing = (all.difference(transfer.received)).toList()..sort();
    final ack = FileAck(
      tid:      transfer.transferId,
      received: transfer.received.toList(),
      missing:  missing,
      done:     false,
    );
    AppLogger.d('File', 'sending progress ack: ${transfer.received.length}/${transfer.totalChunks}, missing=${missing.length}');
    await sendFn(Envelope(
      from: myPub58,
      to:   transfer.senderPub58,
      body: ack.encode(),
    ));
  }

  Future<void> _sendDoneAck(
    _IncomingTransfer         transfer,
    String                    myPub58,
    Future<void> Function(Envelope) sendFn,
  ) async {
    final ack = FileAck(
      tid:      transfer.transferId,
      received: transfer.received.toList(),
      missing:  [],
      done:     true,
    );
    AppLogger.d('File', 'sending done ack for ${transfer.transferId}');
    await sendFn(Envelope(
      from: myPub58,
      to:   transfer.senderPub58,
      body: ack.encode(),
    ));
  }

  Future<String> _finalizeTransfer(_IncomingTransfer transfer) async {
    _incoming.remove(transfer.transferId);

    final dir       = await _filesDir();
    final safeName  = _sanitizeFileName(transfer.name);
    final finalPath =
        '${dir.path}/${DateTime.now().millisecondsSinceEpoch}_$safeName.enc';

    // Close raf before rename
    await transfer.raf?.close();
    transfer.raf = null;

    // Rename, with copy+delete fallback for cross-mount Android paths
    try {
      await File(transfer.tmpPath).rename(finalPath);
    } catch (_) {
      await File(transfer.tmpPath).copy(finalPath);
      await File(transfer.tmpPath).delete();
    }

    final now         = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final fileId      = await _storage.files.insert(FileRecord(
      fileKey:   transfer.key,
      fileNonce: transfer.nonce,
      localPath: finalPath,
      mimeType:  transfer.mime,
      sizeBytes: transfer.plaintextSize,
      createdAt: now,
    ));
    final contentType = transfer.mime.startsWith('image/')
        ? ContentType.image
        : transfer.mime.startsWith('audio/')
            ? ContentType.audio
            : transfer.mime.startsWith('video/')
                ? ContentType.video
                : ContentType.file;
    // Determine effective TTL
    int? effectiveTtl;
    if (transfer.ttlSeconds == null) {
      final ttlStr = await _storage.settings.get('ttl_seconds:${transfer.senderPub58}');
      effectiveTtl = ttlStr != null ? int.tryParse(ttlStr) : null;
    } else if (transfer.ttlSeconds! > 0) {
      effectiveTtl = transfer.ttlSeconds;
    }
    final recvExpiresAt = effectiveTtl != null ? now + effectiveTtl : null;
    final isGroup = transfer.groupId != null;
    final convId  = transfer.groupId ?? transfer.senderPub58;
    int msgId;
    if (transfer.msgId != null) {
      // Update existing placeholder (created in handleFileOffer)
      msgId = transfer.msgId!;
      await _storage.messages.updateStatus(msgId, MessageStatus.delivered);
    } else {
      msgId = await _storage.messages.insert(Message(
        conversationId: convId,
        isGroup:        isGroup,
        senderPub:      transfer.senderPub58,
        body:           transfer.name,
        contentType:    contentType,
        sentAt:         now,
        receivedAt:     now,
        status:         MessageStatus.delivered,
        expiresAt:      recvExpiresAt,
      ));
    }
    await _storage.files.updateMessageId(fileId, msgId);

    // Notify UI: transfer done
    _eventBus?.emit(FileTransferProgressEvent(
        messageId: msgId, progress: 1.0, done: true));
    _eventBus?.emit(MessageReceivedEvent(
      conversationId: convId,
      isGroup: isGroup,
      senderPub: transfer.senderPub58,
    ));

    final ttlSource = transfer.ttlSeconds == null ? 'local' : 'sender';
    AppLogger.d('FILE:RECV', 'assembled "${transfer.name}" msgId=$msgId'
        ' chunks=${transfer.totalChunks}'
        ' ttl=${effectiveTtl != null ? "${effectiveTtl}s (expires ~${DateTime.fromMillisecondsSinceEpoch(recvExpiresAt! * 1000).toIso8601String()})" : "off"}'
        ' source=$ttlSource');
    return transfer.name;
  }

  // ── Decrypt for display ────────────────────────────────────────────────────

  Future<Uint8List> decryptFile(FileRecord record) async {
    final cacheKey = record.messageId;
    if (cacheKey != null && _decryptCache.containsKey(cacheKey)) {
      final cached = _decryptCache[cacheKey];
      if (cached == null) throw StateError('decryptFile: previously failed for messageId=$cacheKey');
      return cached;
    }
    try {
      // Auto-detects v1 (single AEAD) vs v2 (streaming chunks)
      final bytes = await FileEncryption(_sodium).decryptFileAuto(
        File(record.localPath),
        Uint8List.fromList(record.fileKey),
        record.fileNonce,
      );
      if (cacheKey != null) _decryptCache[cacheKey] = bytes;
      return bytes;
    } catch (e) {
      if (cacheKey != null) _decryptCache[cacheKey] = null; // mark as failed
      rethrow;
    }
  }

  // ── Legacy receive (kept for old-format decode compatibility) ─────────────

  Future<({String localPath, String mimeType, int fileId})?> receiveFileEnvelope(
    Envelope  envelope,
    Uint8List plaintext,
  ) async {
    try {
      final m = jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;
      if (m['type'] != 'file') return null;
      final mimeType = m['mime']  as String;
      final fileName = m['name']  as String;
      final plainSize = m['size'] as int;
      final key      = base64.decode(m['key']   as String);
      final nonce    = base64.decode(m['nonce'] as String);
      final cipher   = base64.decode(m['data']  as String);

      final dir     = await _filesDir();
      final encPath =
          '${dir.path}/${DateTime.now().millisecondsSinceEpoch}_$fileName.enc';
      await File(encPath).writeAsBytes(cipher);

      final now    = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final fileId = await _storage.files.insert(FileRecord(
        fileKey:   key,
        fileNonce: nonce,
        localPath: encPath,
        mimeType:  mimeType,
        sizeBytes: plainSize,
        createdAt: now,
      ));
      return (localPath: encPath, mimeType: mimeType, fileId: fileId);
    } catch (_) {
      return null;
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  Future<Directory> _filesDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir  = Directory('${base.path}/hubcore_files');
    await dir.create(recursive: true);
    return dir;
  }

  /// Persist an orphan chunk to disk so it survives app restarts.
  Future<void> _persistOrphanChunk(FileChunk chunk) async {
    try {
      final dir = await _orphanDir();
      final file = File('${dir.path}/${chunk.tid}_${chunk.idx}.chunk');
      // Simple format: 4 bytes idx (big-endian) + 4 bytes tot + data
      final header = ByteData(8);
      header.setInt32(0, chunk.idx);
      header.setInt32(4, chunk.tot);
      final bytes = Uint8List(8 + chunk.tid.length + 1 + chunk.data.length);
      bytes.setAll(0, header.buffer.asUint8List());
      bytes[8] = chunk.tid.length;
      bytes.setAll(9, utf8.encode(chunk.tid));
      bytes.setAll(9 + chunk.tid.length, chunk.data);
      await file.writeAsBytes(bytes);
    } catch (e) {
      AppLogger.w('File', 'failed to persist orphan chunk: $e');
    }
  }

  /// Load orphan chunks for a specific transfer from disk.
  Future<List<FileChunk>> _loadOrphanChunks(String tid) async {
    final chunks = <FileChunk>[];
    try {
      final dir = await _orphanDir();
      await for (final f in dir.list()) {
        if (f is File && f.path.contains('/${tid}_') && f.path.endsWith('.chunk')) {
          final bytes = await f.readAsBytes();
          if (bytes.length < 10) continue;
          final header = ByteData.sublistView(bytes, 0, 8);
          final idx = header.getInt32(0);
          final tot = header.getInt32(4);
          final tidLen = bytes[8];
          final data = bytes.sublist(9 + tidLen);
          chunks.add(FileChunk(tid: tid, idx: idx, tot: tot, data: data));
        }
      }
    } catch (_) {}
    return chunks;
  }

  /// Delete persisted orphan chunks for a transfer.
  Future<void> _cleanOrphanChunks(String tid) async {
    try {
      final dir = await _orphanDir();
      await for (final f in dir.list()) {
        if (f is File && f.path.contains('/${tid}_') && f.path.endsWith('.chunk')) {
          await f.delete();
        }
      }
    } catch (_) {}
  }

  Future<Directory> _orphanDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/hubcore_orphan_chunks');
    await dir.create(recursive: true);
    return dir;
  }

  /// Delete orphan chunks older than 1 hour and enforce total disk size limit.
  Future<void> _cleanStaleOrphanChunks() async {
    try {
      final dir = await _orphanDir();
      final cutoff = DateTime.now().subtract(const Duration(hours: 1));
      int totalSize = 0;
      final files = <File>[];
      await for (final f in dir.list()) {
        if (f is File && f.path.endsWith('.chunk')) {
          final stat = await f.stat();
          if (stat.modified.isBefore(cutoff)) {
            await f.delete();
          } else {
            totalSize += stat.size;
            files.add(f);
          }
        }
      }
      // Enforce disk size limit — delete oldest first
      if (totalSize > kMaxOrphanTotalDisk) {
        files.sort((a, b) =>
            a.statSync().modified.compareTo(b.statSync().modified));
        for (final f in files) {
          if (totalSize <= kMaxOrphanTotalDisk) break;
          final size = f.statSync().size;
          await f.delete();
          totalSize -= size;
        }
        AppLogger.d('File', 'orphan disk cleanup: trimmed to $totalSize bytes');
      }
      // Clean stale in-memory entries (transfers that never got an offer)
      _orphanChunks.removeWhere((tid, _) => true); // orphan memory is transient
    } catch (_) {}
  }

  Future<void> _cleanTmpFiles() async {
    try {
      final dir = await _filesDir();
      await for (final f in dir.list()) {
        if (f is File && f.path.contains('/tmp_') && f.path.endsWith('.enc')) {
          await f.delete();
        }
      }
    } catch (_) {}
  }

  static String _randomHex(int bytes) {
    final r = Random.secure();
    return List.generate(bytes, (_) => r.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// Sanitize a filename from an untrusted source (FileOffer).
  /// Removes path traversal, null bytes, and other dangerous characters.
  static String _sanitizeFileName(String raw) {
    // Strip path separators and traversal
    var name = raw.replaceAll(RegExp(r'[/\\]'), '_');
    name = name.replaceAll('..', '_');
    // Remove null bytes and control characters
    name = name.replaceAll(RegExp(r'[\x00-\x1f]'), '');
    // Collapse whitespace
    name = name.replaceAll(RegExp(r'\s+'), ' ').trim();
    // Fallback if nothing left
    if (name.isEmpty) name = 'unnamed';
    // Limit length
    if (name.length > 200) name = name.substring(0, 200);
    return name;
  }

  static String _guessMime(String path) {
    final ext = path.split('.').last.toLowerCase();
    return switch (ext) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png'           => 'image/png',
      'gif'           => 'image/gif',
      'webp'          => 'image/webp',
      'mp4'           => 'video/mp4',
      'mp3'           => 'audio/mpeg',
      'ogg'           => 'audio/ogg',
      'pdf'           => 'application/pdf',
      _               => 'application/octet-stream',
    };
  }
}
