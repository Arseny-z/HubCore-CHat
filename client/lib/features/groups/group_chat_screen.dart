import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';

import '../../application/events/app_event_bus.dart';
import '../../application/events/app_events.dart' show FileTransferProgressEvent, MessageRetryUpdatedEvent, GroupAdminChangedEvent, GroupAdminTransferDeclinedEvent, GroupDeletedEvent, GroupJoinedEvent;
import '../../domain/entities/group.dart' show GroupRole, GroupPermissions;
import '../../crypto/file_encryption.dart';
import '../../domain/entities/envelope.dart';
import '../../domain/entities/file_record.dart';
import '../../domain/entities/file_transfer.dart';
import '../../infrastructure/file_transfer/file_service.dart' show kChunkSize;
import '../../shared/providers/app_providers.dart';
import '../../shared/providers/crypto_providers.dart' show sodiumProvider;
import '../../shared/utils/l10n.dart';
import '../../shared/utils/logger.dart';
import '../../shared/utils/pubkey_codec.dart';
import '../../shared/widgets/hubcore_app_bar.dart';
import '../chat/chat_widgets.dart';

class GroupChatScreen extends ConsumerStatefulWidget {
  final String groupId;
  const GroupChatScreen({super.key, required this.groupId});

  @override
  ConsumerState<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends ConsumerState<GroupChatScreen> {
  final _ctrl       = TextEditingController();
  final _scrollCtrl = ScrollController();
  List<Message> _messages = [];
  Group? _group;
  Map<String, String> _aliases = {}; // pubkey → alias
  int _memberCount = 0;
  bool _sending = false;
  bool _isMember = true;
  String _myRole = GroupRole.write; // my role in this group
  String? _error;
  bool _hasMore = false;
  bool _loadingMore = false;

  static const _kPageSize = 50;
  final Map<int, double> _fileProgress = {}; // messageId → progress
  final Set<String> _readReceiptSent = {}; // messageId → already sent
  Map<String, (int, int)> _deliveryCounts = {}; // messageId → (delivered, total)
  int? _ttlSeconds; // null = no TTL for this group

  StreamSubscription<MessageReceivedEvent>? _msgSub;
  StreamSubscription<MessagesDeletedEvent>? _deletedSub;
  StreamSubscription<FileTransferProgressEvent>? _progressSub;
  StreamSubscription<MessageRetryUpdatedEvent>? _retrySub;
  StreamSubscription<GroupDeletedEvent>? _deletedGroupSub;
  StreamSubscription<GroupAdminChangedEvent>? _adminChangedSub;
  final Map<String, (int, int)> _queueAttempts = {};

  @override
  void initState() {
    super.initState();
    _load();
    _loadTtl();
    _scrollCtrl.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _subscribeToEvents());
  }

  Future<void> _loadTtl() async {
    final storage = ref.read(storageProvider);
    if (!storage.isOpen) return;
    final v = await storage.settings.get('ttl_seconds:${widget.groupId}');
    if (mounted) setState(() => _ttlSeconds = v != null ? int.tryParse(v) : null);
  }

  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    if (_scrollCtrl.position.pixels <= 80.0 && _hasMore && !_loadingMore) {
      _loadMore();
    }
  }

  @override
  void dispose() {
    _msgSub?.cancel();
    _deletedSub?.cancel();
    _progressSub?.cancel();
    _retrySub?.cancel();
    _deletedGroupSub?.cancel();
    _adminChangedSub?.cancel();
    _ctrl.dispose();
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _subscribeToEvents() {
    final bus = ref.read(eventBusProvider);

    _msgSub = bus.on<MessageReceivedEvent>().listen((event) {
      if (event.isGroup && event.conversationId == widget.groupId && mounted) {
        _load();
      }
    });

    _deletedSub = bus.on<MessagesDeletedEvent>().listen((event) {
      if (event.conversationIds.contains(widget.groupId) && mounted) {
        _load();
      }
    });

    _progressSub = bus.on<FileTransferProgressEvent>().listen((event) {
      if (!mounted) return;
      setState(() {
        if (event.done) {
          _fileProgress.remove(event.messageId);
          _load();
        } else {
          _fileProgress[event.messageId] = event.progress;
        }
      });
    });

    _retrySub = bus.on<MessageRetryUpdatedEvent>().listen((event) {
      if (!mounted) return;
      setState(() {
        if (event.attempts < 0) {
          _queueAttempts.remove(event.messageId);
        } else {
          _queueAttempts[event.messageId] = (event.attempts, event.maxAttempts);
        }
      });
    });

    _deletedGroupSub = bus.on<GroupDeletedEvent>().listen((event) {
      if (event.groupId == widget.groupId && mounted) {
        context.go('/main');
      }
    });

    // Reload when admin changes so _myRole and input bar update immediately
    _adminChangedSub = bus.on<GroupAdminChangedEvent>().listen((event) {
      if (event.groupId == widget.groupId && mounted) _load();
    });
  }

  Future<void> _load() async {
    final storage = ref.read(storageProvider);
    if (!storage.isOpen) return;

    final g    = await storage.groups.findGroup(widget.groupId);
    final msgs = await storage.messages.forConversation(
        widget.groupId, limit: _kPageSize);

    // Build alias map from contacts table.
    final contacts = await storage.contacts.all();
    final aliases  = <String, String>{};
    for (final c in contacts) {
      if (c.alias.isNotEmpty) aliases[c.masterPub] = c.alias;
    }

    // Count real members (with non-zero chain keys = actually joined)
    final members = await storage.groups.membersOf(widget.groupId);
    final activeCount = members.where((m) =>
        !m.chainKey.every((b) => b == 0)).length;

    // Load delivery counts for outbound messages
    final identity = ref.read(identityNotifierProvider);
    final myPub58 = identity != null ? PubkeyCodec.encode(identity.masterPublicKey) : '';
    final counts = <String, (int, int)>{};
    for (final m in msgs) {
      if (m.senderPub == myPub58 && m.messageId != null) {
        final c = await storage.messageReceipts.deliveryCount(m.messageId!);
        if (c.$2 > 0) counts[m.messageId!] = c;
      }
    }

    // Check if we're still a member (non-zero chain key = active member)
    final isMember = members.any((m) =>
        m.masterPub == myPub58 && !m.chainKey.every((b) => b == 0));

    // Load my role
    final myRole = await storage.groups.memberRole(widget.groupId, myPub58)
        ?? GroupRole.write;

    if (mounted) {
      setState(() {
        _group    = g;
        _messages = msgs.reversed.toList();
        _aliases  = aliases;
        _memberCount = activeCount;
        _deliveryCounts = counts;
        _hasMore = msgs.length >= _kPageSize;
        _isMember = isMember;
        _myRole   = myRole;
      });
    }
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _sending) return;

    if (!_isMember) {
      setState(() => _error = context.l10n.notGroupMember);
      return;
    }
    if (!GroupPermissions.canWrite(_myRole)) {
      setState(() => _error = _myRole == GroupRole.banned
          ? 'Вы заблокированы в этой группе'
          : 'У вас нет прав на отправку сообщений');
      return;
    }

    final groupSvc = ref.read(groupMessagingProvider);
    if (groupSvc == null) {
      setState(() => _error = context.l10n.messagingNotReady);
      return;
    }

    setState(() { _sending = true; _error = null; });
    _ctrl.clear();

    try {
      final envelopes = await groupSvc.sendGroupMessage(
          widget.groupId, text, ttlSeconds: _ttlSeconds);
      final storage = ref.read(storageProvider);
      for (final env in envelopes) {
        final contact = storage.isOpen
            ? await storage.contacts.findByMasterPub(env.to)
            : null;
        final transport = ref.read(compositeTransportProvider);
        await transport.sendEnvelope(env, transportAddresses: contact?.transportAddresses);
      }
    } on StateError catch (e) {
      final msg = e.toString();
      if (msg.contains('No sender chain')) {
        setState(() { _error = context.l10n.notGroupMember; _isMember = false; });
      } else {
        setState(() => _error = context.l10n.sendError);
      }
    } catch (_) {
      setState(() => _error = context.l10n.sendError);
    } finally {
      if (mounted) setState(() => _sending = false);
    }

    await _load();
    _scrollToBottom();
  }

  static const _kGroupMaxFileSize = 200 * 1024 * 1024; // 200 MB (same as DM)

  // ── Unified group media send (file, voice, video) ──────────────────────────
  //
  // FileOffer is encrypted via Sender Keys (same channel as text messages),
  // so NO X25519 keys are required. Chunks are sent raw to all members.

  Future<void> _sendGroupMedia(File sourceFile, String mimeType, ContentType contentType) async {
    if (!_isMember) {
      setState(() => _error = context.l10n.notGroupMember);
      return;
    }
    if (!GroupPermissions.canWrite(_myRole)) {
      setState(() => _error = _myRole == GroupRole.banned
          ? 'Вы заблокированы в этой группе'
          : 'У вас нет прав на отправку сообщений');
      return;
    }
    final groupSvc = ref.read(groupMessagingProvider);
    if (groupSvc == null) { setState(() => _error = context.l10n.messagingNotReady); return; }

    setState(() { _sending = true; _error = null; });
    try {
      final bus     = ref.read(eventBusProvider);
      final sodium  = ref.read(sodiumProvider).valueOrNull;
      if (sodium == null) throw StateError('Sodium not ready');
      final identity  = ref.read(identityNotifierProvider);
      final myPub58   = identity != null ? PubkeyCodec.encode(identity.masterPublicKey) : '';
      final storage   = ref.read(storageProvider);
      final transport = ref.read(compositeTransportProvider);

      final plainSize = await sourceFile.length();
      if (plainSize > _kGroupMaxFileSize) {
        setState(() => _error = context.l10n.fileTooLarge(_kGroupMaxFileSize ~/ 1024 ~/ 1024));
        return;
      }

      // Load members + their contacts for transport addresses
      final members  = await storage.groups.memberPubs(widget.groupId);
      final recipients = members.where((p) => p != myPub58).toList();
      final contacts = <String, Contact?>{};
      for (final m in recipients) {
        contacts[m] = await storage.contacts.findByMasterPub(m);
      }

      // Encrypt file (streaming, bounded memory)
      final filesDir = await _groupFilesDir();
      final fileName = _sanitize(sourceFile.path.split('/').last);
      final encPath  = '${filesDir.path}/${DateTime.now().millisecondsSinceEpoch}_$fileName.enc';
      final enc = await FileEncryption(sodium).encryptFileStream(sourceFile, File(encPath));
      final encFile    = File(encPath);
      final encFileSize = await encFile.length();
      final totalChunks = (encFileSize / kChunkSize).ceil();
      final transferId  = _randomHex(16);
      final fileMid     = _randomHex(16);
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      // Persist to DB
      final fileId = await storage.files.insert(FileRecord(
        fileKey: enc.key, fileNonce: enc.nonce,
        localPath: encPath, mimeType: mimeType,
        sizeBytes: plainSize, createdAt: now,
      ));
      final placeholderId = await storage.messages.insert(Message(
        conversationId: widget.groupId, isGroup: true,
        senderPub: myPub58, body: fileName,
        contentType: contentType, sentAt: now,
        status: MessageStatus.sent, messageId: fileMid,
      ));
      await storage.files.updateMessageId(fileId, placeholderId);
      bus.emit(FileTransferProgressEvent(messageId: placeholderId, progress: 0.0));
      if (mounted) { _load(); _scrollToBottom(); }

      // Build FileOffer
      final offer = FileOffer(
        tid: transferId, name: fileName, mime: mimeType,
        size: plainSize, chunks: totalChunks,
        key: enc.key, nonce: enc.nonce,
        groupId: widget.groupId, ttlSeconds: 0, mid: fileMid,
        encSize: encFileSize,
      );

      // Encrypt offer via Sender Keys → fan-out envelopes (no X25519 needed)
      final offerEnvelopes = await groupSvc.encryptGroupOffer(widget.groupId, offer.encode());
      enc.key.fillRange(0, enc.key.length, 0);

      // Send offer × 3 (route warmup)
      for (int r = 0; r < 3; r++) {
        for (final env in offerEnvelopes) {
          await transport.sendEnvelope(env, transportAddresses: contacts[env.to]?.transportAddresses);
        }
        if (r < 2) await Future.delayed(const Duration(milliseconds: 400));
      }

      await Future.delayed(const Duration(milliseconds: 500));

      // Send chunks raw to all members
      final raf = await encFile.open(mode: FileMode.read);
      try {
        for (int idx = 0; idx < totalChunks; idx++) {
          final start = idx * kChunkSize;
          final end   = min(start + kChunkSize, encFileSize);
          await raf.setPosition(start);
          final data  = await raf.read(end - start);
          final chunkBody = FileChunk(
            tid: transferId, idx: idx, tot: totalChunks, data: data,
          ).encode();
          for (final m in recipients) {
            await transport.sendEnvelope(
              Envelope(from: myPub58, to: m, body: chunkBody),
              transportAddresses: contacts[m]?.transportAddresses,
            );
          }
          final p = (idx + 1) / totalChunks;
          bus.emit(FileTransferProgressEvent(
            messageId: placeholderId,
            progress: p,
            done: idx == totalChunks - 1,
          ));
          if (idx < totalChunks - 1) await Future.delayed(const Duration(milliseconds: 50));
        }
      } finally {
        await raf.close();
      }

      await storage.messages.updateStatus(placeholderId, MessageStatus.delivered);
    } catch (e, st) {
      AppLogger.e('GroupFile', 'media send error', error: e, stack: st);
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
    await _load();
    _scrollToBottom();
  }

  Future<Directory> _groupFilesDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir  = Directory('${base.path}/hubcore_files');
    await dir.create(recursive: true);
    return dir;
  }

  static String _sanitize(String raw) {
    var s = raw.replaceAll(RegExp(r'[/\\]'), '_').replaceAll('..', '_')
               .replaceAll(RegExp(r'[\x00-\x1f]'), '').trim();
    if (s.isEmpty) s = 'file';
    return s.length > 200 ? s.substring(0, 200) : s;
  }

  static String _randomHex(int bytes) {
    final r = Random.secure();
    return List.generate(bytes, (_) => r.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  Future<void> _sendFile() async {
    final type = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF182533),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.photo, color: Colors.white70),
              title: Text(context.l10n.photoVideo, style: const TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(ctx, 'media'),
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file, color: Colors.white70),
              title: Text(context.l10n.document, style: const TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(ctx, 'file'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (type == null) return;

    FilePickerResult? result;
    if (type == 'media') {
      result = await FilePicker.platform.pickFiles(type: FileType.media);
    } else {
      result = await FilePicker.platform.pickFiles(type: FileType.any);
    }
    if (result == null || result.files.isEmpty) return;
    final picked = result.files.first;
    if (picked.path == null) return;

    final mime = picked.extension != null
        ? _mimeFromExt(picked.extension!) ?? 'application/octet-stream'
        : 'application/octet-stream';
    final contentType = mime.startsWith('image/')
        ? ContentType.image
        : mime.startsWith('video/')
            ? ContentType.video
            : ContentType.file;

    await _sendGroupMedia(File(picked.path!), mime, contentType);
  }

  Future<void> _sendVoice(File audioFile) async {
    final mime = audioFile.path.endsWith('.ogg') ? 'audio/ogg' : 'audio/m4a';
    await _sendGroupMedia(audioFile, mime, ContentType.audio);
    try { await audioFile.delete(); } catch (_) {}
  }

  Future<void> _sendVideoCircle(File videoFile) async {
    await _sendGroupMedia(videoFile, 'video/mp4', ContentType.video);
    try { await videoFile.delete(); } catch (_) {}
  }

  static String? _mimeFromExt(String ext) {
    return switch (ext.toLowerCase()) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'mp4' => 'video/mp4',
      'mov' => 'video/quicktime',
      'mp3' => 'audio/mpeg',
      'pdf' => 'application/pdf',
      'doc' => 'application/msword',
      'zip' => 'application/zip',
      'apk' => 'application/vnd.android.package-archive',
      _ => null,
    };
  }

  Future<void> _showDeliveryDetails(Message msg) async {
    if (msg.messageId == null) return;
    final storage = ref.read(storageProvider);
    final receipts = await storage.messageReceipts.forMessage(msg.messageId!);
    final aliases = <String, String>{};
    for (final r in receipts) {
      final contact = await storage.contacts.findByMasterPub(r.recipientPub);
      aliases[r.recipientPub] = contact?.alias.isNotEmpty == true
          ? contact!.alias
          : '${r.recipientPub.substring(0, 12)}…';
    }
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF182533),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(
            width: 36, height: 4,
            decoration: BoxDecoration(
              color: Colors.white24, borderRadius: BorderRadius.circular(2)),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(context.l10n.deliveryStatus,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
          ),
          if (receipts.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: Text(context.l10n.noData, style: const TextStyle(color: Colors.white54)),
            )
          else
            ...receipts.map((r) {
              final name = aliases[r.recipientPub] ?? '${r.recipientPub.substring(0, 12)}…';
              final icon = r.readAt != null ? Icons.done_all : r.deliveredAt != null ? Icons.done_all : Icons.done;
              final color = r.readAt != null ? const Color(0xFF52B8EA) : Colors.white54;
              return ListTile(
                leading: Icon(icon, color: color, size: 20),
                title: Text(name, style: const TextStyle(color: Colors.white)),
                subtitle: Text(
                  r.readAt != null ? context.l10n.deliveryStatusRead : r.deliveredAt != null ? context.l10n.deliveryStatusDelivered : context.l10n.deliveryStatusSent,
                  style: TextStyle(color: color, fontSize: 12),
                ),
              );
            }),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Future<void> _onMessageVisible(Message msg) async {
    final mid = msg.messageId;
    if (mid == null || _readReceiptSent.contains(mid)) return;
    if (msg.status == MessageStatus.read) return;
    _readReceiptSent.add(mid);

    final messaging = ref.read(messagingServiceProvider);
    final storage = ref.read(storageProvider);
    if (messaging == null || !storage.isOpen) return;

    if (msg.id != null) {
      await storage.messages.updateStatus(msg.id!, MessageStatus.read);
    }
    messaging.sendReadReceipt(msg.senderPub, mid);
    AppLogger.d('Group', 'msg_read sent for mid=${mid.substring(0, 8)}…');
    if (mounted) await _load();
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    final storage = ref.read(storageProvider);
    if (!storage.isOpen) return;
    final oldestId = _messages.isNotEmpty ? _messages.first.id : null;
    if (oldestId == null) return;
    setState(() => _loadingMore = true);
    try {
      final older = await storage.messages.forConversation(
        widget.groupId, limit: _kPageSize, beforeId: oldestId);
      if (!mounted) return;
      setState(() {
        _messages = [...older.reversed.toList(), ..._messages];
        _hasMore = older.length >= _kPageSize;
        _loadingMore = false;
      });
    } finally {
      if (mounted && _loadingMore) setState(() => _loadingMore = false);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _leaveGroup() async {
    final identity = ref.read(identityNotifierProvider);
    if (identity == null) return;
    final myPub = PubkeyCodec.encode(identity.masterPublicKey);
    final storage = ref.read(storageProvider);

    final myRole  = await storage.groups.memberRole(widget.groupId, myPub) ?? GroupRole.write;
    final isAdmin = myRole == GroupRole.admin;

    if (isAdmin) {
      // Check if I'm the last admin
      final adminCount = await storage.groups.adminCount(widget.groupId);
      if (adminCount <= 1) {
        // Last admin — must transfer or auto-assign
        await _leaveAsLastAdmin(myPub);
      } else {
        // Other admins exist — can leave freely
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text(context.l10n.leaveGroupTitle),
            content: Text(context.l10n.leaveGroupContent),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.l10n.cancel)),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                child: Text(context.l10n.leaveGroup),
              ),
            ],
          ),
        );
        if (confirmed == true) await _doLeave(myPub);
      }
      return;
    }

    // Non-admin: standard leave
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(context.l10n.leaveGroupTitle),
        content: Text(context.l10n.leaveGroupContent),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.l10n.cancel)),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: Text(context.l10n.leaveGroup),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _doLeave(myPub);
  }

  Future<void> _leaveAsLastAdmin(String myPub) async {
    final storage = ref.read(storageProvider);
    final messaging = ref.read(messagingServiceProvider);
    final transport = ref.read(compositeTransportProvider);
    if (messaging == null) return;

    final memberPubs = (await storage.groups.memberPubs(widget.groupId))
        .where((p) => p != myPub)
        .toList();

    if (memberPubs.isEmpty) {
      // No other members — just delete the group
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Покинуть группу'),
          content: const Text('В группе больше нет участников. Группа будет удалена.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.l10n.cancel)),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('Удалить группу'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      await storage.groups.deleteGroup(widget.groupId);
      if (mounted) context.pop();
      return;
    }

    // Show member picker to choose new admin
    final contacts = await storage.contacts.all();
    final aliases  = {for (final c in contacts) c.masterPub: c.alias};

    if (!mounted) return;
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Передать права администратора'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Вы администратор. Перед выходом нужно передать права другому участнику.',
                style: TextStyle(fontSize: 13, color: Colors.white70),
              ),
              const SizedBox(height: 12),
              ...memberPubs.map((pub) {
                final name = aliases[pub]?.isNotEmpty == true
                    ? aliases[pub]!
                    : pub.substring(0, 8);
                return ListTile(
                  dense: true,
                  title: Text(name),
                  onTap: () => Navigator.pop(ctx, pub),
                );
              }),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(context.l10n.cancel),
          ),
        ],
      ),
    );
    if (chosen == null || !mounted) return;

    // Send transfer proposal to chosen member
    final payload = Uint8List.fromList(utf8.encode(jsonEncode({
      'type': 'group_admin_transfer',
      'group_id': widget.groupId,
      'new_admin': chosen,
    })));
    try {
      final env = await messaging.encryptBox(chosen, payload);
      final contact = await storage.contacts.findByMasterPub(chosen);
      await transport.sendEnvelope(env,
          transportAddresses: contact?.transportAddresses);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка отправки: $e')));
      }
      return;
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Запрос отправлен. Ожидаем подтверждения...')),
    );

    // Wait for accept/decline event (max 60 seconds)
    final bus = ref.read(eventBusProvider);
    bool responded = false;
    StreamSubscription? sub;
    sub = bus.on<GroupAdminChangedEvent>().listen((e) {
      if (e.groupId == widget.groupId) {
        responded = true;
        sub?.cancel();
        _doLeave(myPub);
      }
    });
    final declineSub = bus.on<GroupAdminTransferDeclinedEvent>().listen((e) {
      if (e.groupId == widget.groupId) {
        responded = true;
        sub?.cancel();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Участник отказался стать администратором. Выберите другого.')),
          );
        }
      }
    });
    // Timeout: if no response in 60s, auto-assign first available member as admin
    Future.delayed(const Duration(seconds: 60), () async {
      if (!responded) {
        sub?.cancel();
        declineSub.cancel();
        // Auto-assign first member as admin and leave
        if (memberPubs.isNotEmpty) {
          final newAdmin = memberPubs.first;
          await storage.groups.setMemberRole(widget.groupId, newAdmin, GroupRole.admin);
          await storage.groups.setAdmin(widget.groupId, newAdmin);
          // Broadcast role change
          final payload = Uint8List.fromList(utf8.encode(jsonEncode({
            'type': 'group_role_change',
            'group_id': widget.groupId,
            'target_pub': newAdmin,
            'new_role': GroupRole.admin,
            'changed_by': myPub,
          })));
          for (final pub in memberPubs) {
            try {
              final env = await messaging.encryptBox(pub, payload);
              final contact = await storage.contacts.findByMasterPub(pub);
              await transport.sendEnvelope(env,
                  transportAddresses: contact?.transportAddresses);
            } catch (_) {}
          }
          await _doLeave(myPub);
        }
      }
    });
  }

  Future<void> _doLeave(String myPub) async {
    final storage   = ref.read(storageProvider);
    final messaging = ref.read(messagingServiceProvider);
    final transport = ref.read(compositeTransportProvider);

    if (messaging != null) {
      final memberPubs = await storage.groups.memberPubs(widget.groupId);
      final payload = Uint8List.fromList(utf8.encode(jsonEncode({
        'type': 'group_left',
        'group_id': widget.groupId,
      })));
      for (final pub in memberPubs) {
        if (pub == myPub) continue;
        try {
          final env = await messaging.encryptBox(pub, payload);
          final contact = await storage.contacts.findByMasterPub(pub);
          await transport.sendEnvelope(env,
              transportAddresses: contact?.transportAddresses);
        } catch (_) {}
      }
    }

    await storage.groups.removeMember(widget.groupId, myPub);
    final remaining = await storage.groups.memberPubs(widget.groupId);
    if (remaining.isEmpty) {
      await storage.groups.deleteGroup(widget.groupId);
      ref.read(eventBusProvider).emit(GroupDeletedEvent(groupId: widget.groupId));
    } else {
      ref.read(eventBusProvider).emit(GroupJoinedEvent(
          groupId: widget.groupId, groupName: ''));
    }
    if (mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final identity = ref.watch(identityNotifierProvider);
    final myPub58  = identity != null
        ? PubkeyCodec.encode(identity.masterPublicKey)
        : '';

    final groupName = _group?.name.isNotEmpty == true
        ? _group!.name
        : widget.groupId.substring(0, 8);

    final memberCount = _memberCount;

    final fileSvc = ref.watch(fileServiceProvider);
    final storage = ref.watch(storageProvider);

    final items = buildMessageList(
      messages: _messages,
      myPub58: myPub58,
      isGroup: true,
      aliases: _aliases,
      fileSvc: fileSvc,
      storage: storage,
      fileProgress: _fileProgress.isNotEmpty ? _fileProgress : null,
      queueAttempts: _queueAttempts.isNotEmpty ? _queueAttempts : null,
      deliveryCounts: _deliveryCounts.isNotEmpty ? _deliveryCounts : null,
      onDeliveryTap: _showDeliveryDetails,
      onMessageVisible: _onMessageVisible,
    );

    return Scaffold(
      backgroundColor: const Color(0xFF0E1621),
      appBar: HubCoreAppBar(
        titleSpacing: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.canPop() ? context.pop() : context.go('/main'),
        ),
        title: GestureDetector(
          onTap: () => _showMembers(context),
          child: Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: const Color(0xFF2AABEE),
                child: Text(
                  groupName.isNotEmpty ? groupName[0].toUpperCase() : '#',
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    groupName,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 16),
                  ),
                  if (_myRole == GroupRole.read || _myRole == GroupRole.banned)
                    Text(
                      _myRole == GroupRole.banned ? '🚫 Вы заблокированы' : '👁 Только чтение',
                      style: TextStyle(
                        fontSize: 11,
                        color: _myRole == GroupRole.banned
                            ? Colors.redAccent
                            : Colors.orange,
                      ),
                    )
                  else if (memberCount > 0)
                    Text(
                      context.l10n.membersCount(memberCount),
                      style: const TextStyle(
                          fontSize: 12, color: Colors.white54),
                    ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (v) {
              if (v == 'members') _showMembers(context);
              if (v == 'settings') context.push('/group/${widget.groupId}/settings').then((_) => _load());
              if (v == 'leave') _leaveGroup();
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'members',
                child: Row(children: [
                  const Icon(Icons.people_outline, size: 20),
                  const SizedBox(width: 12),
                  Text(context.l10n.membersCount(_memberCount)),
                ]),
              ),
              PopupMenuItem(
                value: 'settings',
                child: Row(children: [
                  const Icon(Icons.manage_accounts, size: 20),
                  const SizedBox(width: 12),
                  Text(context.l10n.groupManagement),
                ]),
              ),
              PopupMenuItem(
                value: 'leave',
                child: Row(children: [
                  const Icon(Icons.exit_to_app, size: 20, color: Colors.red),
                  const SizedBox(width: 12),
                  Text(context.l10n.leaveGroup, style: const TextStyle(color: Colors.red)),
                ]),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (_error != null)
            MaterialBanner(
              content: Text(_error!),
              actions: [
                TextButton(
                  onPressed: () => setState(() => _error = null),
                  child: Text(context.l10n.dismiss),
                ),
              ],
            ),
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Text(
                      context.l10n.noMessages,
                      style: const TextStyle(color: Colors.white38, fontSize: 15),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: items.length + (_loadingMore ? 1 : 0),
                    itemBuilder: (_, i) {
                      if (i == 0 && _loadingMore) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Center(child: SizedBox(
                            width: 20, height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )),
                        );
                      }
                      return items[_loadingMore ? i - 1 : i];
                    },
                  ),
          ),
          if (!_isMember)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
              color: const Color(0xFF1C2733),
              child: Text(
                context.l10n.notGroupMember,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
            )
          else if (!GroupPermissions.canWrite(_myRole))
            Container(
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
              color: const Color(0xFF1C2733),
              child: Text(
                _myRole == GroupRole.banned
                    ? 'Вы заблокированы в этой группе'
                    : 'У вас режим "только чтение"',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
            )
          else
            ChatInputBar(
              controller: _ctrl,
              sending: _sending,
              onSend: _send,
              onAttach: _sendFile,
              onVoiceSend: _sendVoice,
              onVideoCircleSend: _sendVideoCircle,
            ),
        ],
      ),
    );
  }

  Future<void> _showMembers(BuildContext context) async {
    final storage = ref.read(storageProvider);
    if (!storage.isOpen) return;
    final pubs = await storage.groups.memberPubs(widget.groupId);
    final identity = ref.read(identityNotifierProvider);
    final myPub = identity != null ? PubkeyCodec.encode(identity.masterPublicKey) : '';
    if (!context.mounted) return;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1C2733),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(
            width: 36, height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              context.l10n.membersCount(pubs.length),
              style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: Colors.white),
            ),
          ),
          ...pubs.map((pub) {
            final alias = _aliases[pub];
            final isMe = pub == myPub;
            final label = isMe ? context.l10n.youInGroup : (alias ?? pub.substring(0, 16));
            return ListTile(
              leading: CircleAvatar(
                backgroundColor: senderColor(pub),
                child: Text(
                  label[0].toUpperCase(),
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
              title: Text(label, style: const TextStyle(color: Colors.white)),
              subtitle: alias != null && !isMe
                  ? Text(
                      pub.substring(0, 16),
                      style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          color: Colors.white54),
                    )
                  : null,
              trailing: isMe
                  ? Text(context.l10n.youInGroup, style: const TextStyle(color: Colors.white38, fontSize: 12))
                  : const Icon(Icons.chevron_right, color: Colors.white38),
              onTap: isMe
                  ? null
                  : () {
                      Navigator.pop(ctx);
                      context.push('/chat/$pub');
                    },
            );
          }),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
