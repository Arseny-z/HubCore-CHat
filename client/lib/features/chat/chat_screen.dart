import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:file_picker/file_picker.dart';

import '../../application/events/app_events.dart' show FileTransferProgressEvent, MessageRetryUpdatedEvent, ContactUpdatedEvent;

import '../../application/events/app_event_bus.dart';
import '../../shared/providers/app_providers.dart';
import '../../shared/utils/l10n.dart';
import '../../shared/utils/logger.dart';
import '../../shared/utils/pubkey_codec.dart';
import '../../shared/widgets/contact_avatar.dart';
import '../../shared/widgets/hubcore_app_bar.dart';
import 'chat_widgets.dart';

class ChatScreen extends ConsumerStatefulWidget {
  final String contactMasterPub;
  const ChatScreen({super.key, required this.contactMasterPub});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _ctrl        = TextEditingController();
  final _scrollCtrl  = ScrollController();
  List<Message> _messages = [];
  Contact? _contact;
  bool _sending = false;
  String? _sendError;
  int? _ttlSeconds;        // null = no TTL for this conversation
  bool _showScrollBadge = false;
  int  _unreadCount     = 0;
  /// messageId → (delivered, total) — loaded alongside messages.
  Map<String, (int, int)> _deliveryCounts = {};
  /// messageId → (attempts, maxAttempts) for pending/ack_pending messages.
  Map<String, (int, int)> _queueAttempts = {};

  final Map<int, double> _fileProgress = {}; // messageId → progress
  final Map<int, String> _fileTransferIds = {}; // msgId → transferId (for cancellation)
  final Set<String> _readReceiptSent = {}; // messageId → already sent read receipt
  Message? _replyTo; // message being replied to
  bool _hasMore = false; // more messages available above
  bool _loadingMore = false; // currently loading older messages

  // EventBus subscriptions — cancelled in dispose().
  StreamSubscription<MessageReceivedEvent>? _msgSub;
  StreamSubscription<MessagesDeletedEvent>? _deletedSub;
  StreamSubscription<MessageStatusUpdatedEvent>? _statusSub;
  StreamSubscription<FileTransferProgressEvent>? _progressSub;
  StreamSubscription<MessageRetryUpdatedEvent>? _retrySub;
  StreamSubscription<ContactUpdatedEvent>? _contactSub;

  @override
  void initState() {
    super.initState();
    _loadContact();
    _loadMessages().then((_) => _sendReadReceipts());
    _loadTtl();
    _scrollCtrl.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _subscribeToMessages();
    });
  }

  void _subscribeToMessages() {
    final bus = ref.read(eventBusProvider);

    _msgSub = bus.on<MessageReceivedEvent>().listen((event) {
      if (event.conversationId == widget.contactMasterPub && mounted) {
        _loadMessages().then((_) {
          if (_isAtBottom) _sendReadReceipts();
        });
        if (!_isAtBottom) {
          setState(() => _unreadCount++);
        }
      }
    });

    _deletedSub = bus.on<MessagesDeletedEvent>().listen((event) {
      if (event.conversationIds.contains(widget.contactMasterPub) && mounted) {
        _loadMessages();
      }
    });

    _statusSub = bus.on<MessageStatusUpdatedEvent>().listen((event) {
      if (!mounted) return;
      setState(() {
        final idx = _messages.indexWhere((m) => m.id == event.messageDbId);
        if (idx >= 0) {
          final old = _messages[idx];
          _messages[idx] = Message(
            id: old.id,
            conversationId: old.conversationId,
            isGroup: old.isGroup,
            senderPub: old.senderPub,
            body: old.body,
            contentType: old.contentType,
            sentAt: old.sentAt,
            receivedAt: old.receivedAt,
            status: event.status,
            expiresAt: old.expiresAt,
            messageId: old.messageId,
          );
        }
      });
      // Reload to update queueAttempts (counter disappears when delivered)
      _loadMessages();
    });

    _progressSub = bus.on<FileTransferProgressEvent>().listen((event) {
      if (!mounted) return;
      setState(() {
        if (event.done) {
          _fileProgress.remove(event.messageId);
          _loadMessages();
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

    // Reload contact when last_seen or keys change (e.g. contact_hello received)
    _contactSub = bus.on<ContactUpdatedEvent>().listen((event) {
      if (event.masterPub == widget.contactMasterPub && mounted) {
        _loadContact();
      }
    });
  }

  @override
  void dispose() {
    _msgSub?.cancel();
    _deletedSub?.cancel();
    _statusSub?.cancel();
    _progressSub?.cancel();
    _retrySub?.cancel();
    _contactSub?.cancel();
    _ctrl.dispose();
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    super.dispose();
  }

  bool get _isAtBottom =>
      _scrollCtrl.hasClients &&
      _scrollCtrl.position.pixels >=
          _scrollCtrl.position.maxScrollExtent - 80.0;

  bool get _isAtTop =>
      _scrollCtrl.hasClients &&
      _scrollCtrl.position.pixels <= 80.0;

  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    // Load older messages when scrolled to top
    if (_isAtTop && _hasMore && !_loadingMore) {
      _loadMore();
    }
    final atBottom = _isAtBottom;
    if (atBottom && _showScrollBadge) {
      setState(() {
        _showScrollBadge = false;
        _unreadCount = 0;
      });
      _sendReadReceipts();
    } else if (!atBottom && !_showScrollBadge) {
      setState(() => _showScrollBadge = true);
    }
  }

  Future<void> _forwardMessage(Message msg) async {
    final storage = ref.read(storageProvider);
    if (!storage.isOpen) return;

    final contacts = await storage.contacts.all(relationship: 'contact');
    final groups   = await storage.groups.allGroups();

    if (!mounted) return;

    // Show picker: contacts + groups
    final chosen = await showModalBottomSheet<({String id, bool isGroup})>(
      context: context,
      backgroundColor: const Color(0xFF182533),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        minChildSize: 0.3,
        expand: false,
        builder: (_, sc) => Column(
          children: [
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(context.l10n.forwardTo,
                  style: const TextStyle(color: Colors.white,
                      fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            Expanded(
              child: ListView(
                controller: sc,
                children: [
                  ...contacts.map((c) {
                    final name = c.alias.isNotEmpty
                        ? c.alias : c.masterPub.substring(0, 12);
                    return ListTile(
                      leading: ContactAvatar(name: name, masterPub: c.masterPub, radius: 20),
                      title: Text(name,
                          style: const TextStyle(color: Colors.white)),
                      onTap: () => Navigator.pop(ctx,
                          (id: c.masterPub, isGroup: false)),
                    );
                  }),
                  ...groups.map((g) {
                    final name = g.name.isNotEmpty ? g.name : 'Group';
                    return ListTile(
                      leading: const CircleAvatar(
                        backgroundColor: Color(0xFF5C6BC0),
                        child: Icon(Icons.group, color: Colors.white, size: 18),
                      ),
                      title: Text(name,
                          style: const TextStyle(color: Colors.white)),
                      subtitle: Text(context.l10n.groupLabel,
                          style: const TextStyle(color: Colors.white38, fontSize: 11)),
                      onTap: () => Navigator.pop(ctx,
                          (id: g.groupId, isGroup: true)),
                    );
                  }),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;

    // Send forwarded message
    if (chosen.isGroup) {
      final groupSvc = ref.read(groupMessagingProvider);
      if (groupSvc == null) return;
      final transport = ref.read(compositeTransportProvider);
      final envelopes = await groupSvc.sendGroupMessage(chosen.id, msg.body);
      for (final env in envelopes) {
        final c = await storage.contacts.findByMasterPub(env.to);
        await transport.sendEnvelope(env, transportAddresses: c?.transportAddresses);
      }
    } else {
      final queue = ref.read(queueServiceProvider);
      if (queue == null) return;
      final ensureSession = ref.read(ensureSessionProvider);
      await ensureSession?.execute(chosen.id);
      await queue.sendOrQueue(
        contactPub: chosen.id,
        plaintext: msg.body,
        contentType: 'text/plain',
        recipients: [QueueRecipient(pub: chosen.id,
            transportAddresses: (await storage.contacts.findByMasterPub(chosen.id))
                ?.transportAddresses)],
      );
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.messageForwarded),
              duration: const Duration(seconds: 1)));
    }
  }

  Future<void> _toggleMute() async {
    final storage = ref.read(storageProvider);
    if (!storage.isOpen || _contact == null) return;
    final newMuted = !(_contact!.muted);
    await storage.contacts.setMuted(widget.contactMasterPub, newMuted);
    await _loadContact();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(newMuted ? context.l10n.muteNotifications : context.l10n.unmuteNotifications),
        duration: const Duration(seconds: 1),
      ));
    }
  }

  Future<void> _addStrangerToContacts() async {
    final storage = ref.read(storageProvider);
    if (!storage.isOpen || _contact == null) return;
    await storage.contacts.setRelationship(widget.contactMasterPub, 'contact');
    await _loadContact();
    ref.read(eventBusProvider).emit(ContactUpdatedEvent(masterPub: widget.contactMasterPub));
  }

  Future<void> _blockStranger() async {
    final storage = ref.read(storageProvider);
    if (!storage.isOpen || _contact == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Заблокировать?'),
        content: const Text('Этот контакт не сможет отправлять вам сообщения.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Заблокировать'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await storage.contacts.setRelationship(widget.contactMasterPub, 'blocked');
    final contact = _contact!;
    if (contact.id != null) await storage.sessions.deleteForContact(contact.id!);
    await storage.sendQueue.deleteForRecipient(widget.contactMasterPub);
    ref.read(eventBusProvider).emit(ContactUpdatedEvent(masterPub: widget.contactMasterPub));
    if (mounted) context.pop();
  }

  Future<void> _loadContact() async {
    final storage = ref.read(storageProvider);
    if (!storage.isOpen) return;
    final c = await storage.contacts.findByMasterPub(widget.contactMasterPub);
    if (mounted) setState(() => _contact = c);
  }

  static const _kPageSize = 50;

  Future<void> _loadMessages() async {
    final storage = ref.read(storageProvider);
    if (!storage.isOpen) return;
    final msgs = await storage.messages.forConversation(
        widget.contactMasterPub, limit: _kPageSize);
    if (!mounted) return;
    final identity = ref.read(identityNotifierProvider);
    final myPub58 = identity != null
        ? PubkeyCodec.encode(identity.masterPublicKey)
        : '';
    final unread = msgs.where((m) =>
        m.senderPub != myPub58 &&
        m.status != MessageStatus.read).length;

    // Load delivery counts for outbound messages that have receipts.
    final counts = <String, (int, int)>{};
    for (final m in msgs) {
      if (m.senderPub == myPub58 && m.messageId != null) {
        final c = await storage.messageReceipts.deliveryCount(m.messageId!);
        if (c.$2 > 0) counts[m.messageId!] = c;
      }
    }

    // Load queue attempts for pending messages.
    final queueEntries = await storage.sendQueue.allPending();
    final queueMap = <String, (int, int)>{};
    for (final e in queueEntries) {
      if (e.ackPending == 1 || e.attempts > 0) {
        queueMap[e.messageId] = (e.attempts, e.maxAttempts);
      }
    }

    setState(() {
      _messages = msgs.reversed.toList();
      _deliveryCounts = counts;
      _queueAttempts = queueMap;
      _hasMore = msgs.length >= _kPageSize;
      if (_isAtBottom) _unreadCount = 0;
      else _unreadCount = unread;
    });
  }

  /// Load older messages (page up).
  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    final storage = ref.read(storageProvider);
    if (!storage.isOpen) return;
    // Oldest message currently shown
    final oldestId = _messages.isNotEmpty ? _messages.first.id : null;
    if (oldestId == null) return;

    setState(() => _loadingMore = true);
    try {
      final older = await storage.messages.forConversation(
        widget.contactMasterPub,
        limit: _kPageSize,
        beforeId: oldestId,
      );
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

  /// Called when an incoming message bubble becomes visible on screen.
  /// Sends msg_read receipt and updates local status.
  Future<void> _onMessageVisible(Message msg) async {
    final mid = msg.messageId;
    AppLogger.d('Chat', '_onMessageVisible: mid=$mid status=${msg.status} contentType=${msg.contentType}');
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
    AppLogger.d('Chat', 'msg_read sent for mid=${mid.substring(0, 8)}… from ${msg.senderPub.substring(0, 8)}…');
    if (mounted) await _loadMessages();
  }

  Future<void> _sendReadReceipts() async {
    // Kept for backward compat — visibility-based receipts now handle this.
  }

  // ── TTL ─────────────────────────────────────────────────────────────────────

  Future<void> _loadTtl() async {
    final storage = ref.read(storageProvider);
    if (!storage.isOpen) return;
    final v = await storage.settings.get('ttl_seconds:${widget.contactMasterPub}');
    if (mounted) setState(() => _ttlSeconds = v != null ? int.tryParse(v) : null);
  }

  Future<void> _pickTtl() async {
    final l10n = context.l10n;
    final options = <String, int?>{
      l10n.autoDeleteDisabled: null,
      l10n.autoDelete1Min: 60,
      l10n.autoDelete1Hour: 3600,
      l10n.autoDelete1Day: 86400,
      l10n.autoDelete1Week: 604800,
    };
    final chosen = await showModalBottomSheet<int?>(
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
              l10n.autoDeleteOff,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ),
          ...options.entries.map((e) {
            final isCurrent = e.value == _ttlSeconds;
            return ListTile(
              leading: Icon(
                e.value == null ? Icons.timer_off_outlined : Icons.timer_outlined,
                color: isCurrent ? const Color(0xFF2AABEE) : Colors.white54,
              ),
              title: Text(
                e.key,
                style: TextStyle(
                  color: isCurrent ? const Color(0xFF2AABEE) : Colors.white,
                  fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
              trailing: isCurrent
                  ? const Icon(Icons.check, color: Color(0xFF2AABEE), size: 20)
                  : null,
              onTap: () => Navigator.pop(ctx, e.value ?? -1),
            );
          }),
          const SizedBox(height: 16),
        ],
      ),
    );
    if (chosen == null || !mounted) return;
    final newTtl = chosen == -1 ? null : chosen;
    final storage = ref.read(storageProvider);
    if (newTtl == null) {
      await storage.settings.set('ttl_seconds:${widget.contactMasterPub}', '');
    } else {
      await storage.settings.set('ttl_seconds:${widget.contactMasterPub}', '$newTtl');
    }
    setState(() => _ttlSeconds = newTtl);
  }

  // ── Send ────────────────────────────────────────────────────────────────────

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _sending) return;

    if (_contact?.isBlocked == true) {
      setState(() => _sendError = 'Контакт заблокирован');
      return;
    }

    final ensureSession = ref.read(ensureSessionProvider);
    final queue         = ref.read(queueServiceProvider);
    if (ensureSession == null || queue == null) {
      setState(() => _sendError = context.l10n.chatInitializing);
      return;
    }

    final replyTo = _replyTo;
    setState(() { _sending = true; _sendError = null; _replyTo = null; });
    _ctrl.clear();

    try {
      await ensureSession.execute(widget.contactMasterPub);
      await queue.sendOrQueue(
        contactPub:  widget.contactMasterPub,
        plaintext:   text,
        contentType: 'text/plain',
        recipients:  [QueueRecipient(pub: widget.contactMasterPub, transportAddresses: _contact?.transportAddresses)],
        replyToId:   replyTo?.messageId,
      );
    } on StateError catch (e) {
      setState(() => _sendError = _friendlyError(e));
    } catch (e) {
      setState(() => _sendError = _friendlyError(e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }

    await _loadMessages();
    _scrollToBottom();
  }

  Future<void> _sendFile() async {
    if (_contact?.isBlocked == true) {
      setState(() => _sendError = 'Контакт заблокирован');
      return;
    }
    // Показываем выбор: Фото/Видео или Документ
    final type = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF182533),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
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

    final pickedFile = result.files.first;
    if (pickedFile.path == null) return;

    final fileSvc   = ref.read(fileServiceProvider);
    final messaging = ref.read(messagingServiceProvider);
    if (fileSvc == null || messaging == null) {
      setState(() => _sendError = context.l10n.chatInitializing);
      return;
    }

    setState(() { _sending = true; _sendError = null; });
    try {
      if (!await messaging.hasSession(widget.contactMasterPub)) {
        await _initSession(messaging);
      }
      final transport = ref.read(compositeTransportProvider);
      final identity = ref.read(identityNotifierProvider);
      final myPub58 = identity != null
          ? PubkeyCodec.encode(identity.masterPublicKey)
          : '';
      await fileSvc.sendFile(
        sourceFile: File(pickedFile.path!),
        myPub58: myPub58,
        contactMasterPub58: widget.contactMasterPub,
        destYggPubKeyHex: _contact?.yggPubKeyHex,
        encryptFn: (p) => messaging.encryptBox(widget.contactMasterPub, p),
        sendFn: (env) => transport.sendEnvelope(env, transportAddresses: _contact?.transportAddresses),
        mimeType: pickedFile.extension != null ? _mimeFromExt(pickedFile.extension!) : null,
        ttlSeconds: _ttlSeconds,
      );
    } on StateError catch (e) {
      setState(() => _sendError = _friendlyError(e));
    } catch (e, st) {
      AppLogger.e('File', 'send error', error: e, stack: st);
      setState(() => _sendError = _friendlyError(e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }

    await _loadMessages();
    _scrollToBottom();
  }

  Future<void> _sendVoice(File audioFile) async {
    if (_contact?.isBlocked == true) { setState(() => _sendError = 'Контакт заблокирован'); return; }
    final fileSvc = ref.read(fileServiceProvider);
    final messaging = ref.read(messagingServiceProvider);
    if (fileSvc == null || messaging == null) {
      setState(() => _sendError = context.l10n.chatInitializing);
      return;
    }
    setState(() { _sending = true; _sendError = null; });
    try {
      // encryptBox использует stateless NaCl box — DR-сессия не нужна
      final transport = ref.read(compositeTransportProvider);
      final identity = ref.read(identityNotifierProvider);
      final myPub58 = identity != null
          ? PubkeyCodec.encode(identity.masterPublicKey)
          : '';
      await fileSvc.sendFile(
        sourceFile: audioFile,
        myPub58: myPub58,
        contactMasterPub58: widget.contactMasterPub,
        destYggPubKeyHex: _contact?.yggPubKeyHex,
        encryptFn: (p) => messaging.encryptBox(widget.contactMasterPub, p),
        sendFn: (env) => transport.sendEnvelope(env,
            transportAddresses: _contact?.transportAddresses),
        mimeType: audioFile.path.endsWith('.ogg') ? 'audio/ogg' : 'audio/m4a',
        ttlSeconds: _ttlSeconds,
        onPlaceholderCreated: (msgId, tid) {
          _fileTransferIds[msgId] = tid;
          if (mounted) { _loadMessages(); _scrollToBottom(); }
        },
      );
    } catch (e) {
      setState(() => _sendError = _friendlyError(e));
    } finally {
      if (mounted) setState(() => _sending = false);
      try { await audioFile.delete(); } catch (_) {}
    }
    await _loadMessages();
    _scrollToBottom();
  }

  Future<void> _sendVideoCircle(File videoFile) async {
    if (_contact?.isBlocked == true) { setState(() => _sendError = 'Контакт заблокирован'); return; }
    final fileSvc = ref.read(fileServiceProvider);
    final messaging = ref.read(messagingServiceProvider);
    if (fileSvc == null || messaging == null) {
      setState(() => _sendError = context.l10n.chatInitializing);
      return;
    }
    setState(() { _sending = true; _sendError = null; });
    try {
      // encryptBox использует stateless NaCl box — DR-сессия не нужна
      final transport = ref.read(compositeTransportProvider);
      final identity = ref.read(identityNotifierProvider);
      final myPub58 = identity != null
          ? PubkeyCodec.encode(identity.masterPublicKey)
          : '';
      await fileSvc.sendFile(
        sourceFile: videoFile,
        myPub58: myPub58,
        contactMasterPub58: widget.contactMasterPub,
        destYggPubKeyHex: _contact?.yggPubKeyHex,
        encryptFn: (p) => messaging.encryptBox(widget.contactMasterPub, p),
        sendFn: (env) => transport.sendEnvelope(env,
            transportAddresses: _contact?.transportAddresses),
        mimeType: 'video/mp4',
        ttlSeconds: _ttlSeconds,
        onPlaceholderCreated: (msgId, tid) {
          _fileTransferIds[msgId] = tid;
          if (mounted) { _loadMessages(); _scrollToBottom(); }
        },
      );
    } catch (e) {
      setState(() => _sendError = _friendlyError(e));
    } finally {
      if (mounted) setState(() => _sending = false);
      try { await videoFile.delete(); } catch (_) {}
    }
    await _loadMessages();
    _scrollToBottom();
  }

  /// Converts technical exceptions to short user-friendly strings.
  String _friendlyError(Object e) {
    final l10n = context.l10n;
    final s = e.toString();
    if (s.contains('No X25519 key') || s.contains('Contact not found') ||
        s.contains('Unknown contact')) {
      return l10n.contactNotFoundError;
    }
    if (s.contains('No session') || s.contains('session')) {
      return l10n.noSessionError;
    }
    if (s.contains('DB') || s.contains('database') || s.contains('locked')) {
      return l10n.databaseError;
    }
    if (s.contains('network') || s.contains('socket') || s.contains('transport')) {
      return l10n.networkErrorQueued;
    }
    return l10n.sendError;
  }

  String? _formatLastSeen(int? ts) {
    if (ts == null) return null;
    final l10n = context.l10n;
    final now = DateTime.now();
    final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    final diff = now.difference(dt);
    if (diff.inSeconds < 60) return l10n.lastSeenRecently;
    if (diff.inMinutes < 60) return l10n.lastSeenMinutesAgo(diff.inMinutes);
    if (diff.inHours < 24) return l10n.lastSeenHoursAgo(diff.inHours);
    if (diff.inDays == 1) return l10n.lastSeenYesterday;
    if (diff.inDays < 7) return l10n.lastSeenDaysAgo(diff.inDays);
    return '${dt.day}.${dt.month.toString().padLeft(2, '0')}.${dt.year}';
  }

  static String? _mimeFromExt(String ext) {
    return switch (ext.toLowerCase()) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'mp4' => 'video/mp4',
      'mov' => 'video/quicktime',
      'avi' => 'video/x-msvideo',
      'mp3' => 'audio/mpeg',
      'ogg' => 'audio/ogg',
      'wav' => 'audio/wav',
      'pdf' => 'application/pdf',
      'doc' => 'application/msword',
      'docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls' => 'application/vnd.ms-excel',
      'xlsx' => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'zip' => 'application/zip',
      'apk' => 'application/vnd.android.package-archive',
      _ => null,
    };
  }

  Future<void> _initSession(dynamic messaging) async {
    final storage = ref.read(storageProvider);
    final contact = await storage.contacts.findByMasterPub(widget.contactMasterPub);
    if (contact == null) throw StateError('Contact not found');

    if (contact.x25519Pub == null) {
      throw StateError(
        'No X25519 key for this contact.\n'
        'Ask them to share their QR code again.',
      );
    }

    final peerIdentityPub = PubkeyCodec.decode(contact.x25519Pub!);
    await messaging.initOutboundSession(
      contactMasterPub58: widget.contactMasterPub,
      peerIdentityPub: peerIdentityPub,
      // No one-time prekey — receiver will auto-init from senderEphPub in first message.
    );
  }

  Future<void> _deleteQueued(Message msg) async {
    if (msg.id == null || msg.messageId == null) return;
    final queue = ref.read(queueServiceProvider);
    if (queue == null) return;
    await queue.deleteQueued(msg.messageId!, msg.id!);
    await _loadMessages();
  }

  Future<void> _deleteMe(Message msg) async {
    if (msg.id == null) return;
    final storage = ref.read(storageProvider);
    await storage.messages.deleteById(msg.id!);
    if (msg.messageId != null) {
      await storage.messageReceipts.deleteForMessage(msg.messageId!);
    }
    final bus = ref.read(eventBusProvider);
    bus.emit(MessagesDeletedEvent(conversationIds: {widget.contactMasterPub}));
    await _loadMessages();
  }

  Future<void> _cancelFileSend(Message msg) async {
    AppLogger.d('Chat', '_cancelFileSend msgId=${msg.id} tid=${_fileTransferIds[msg.id]}');
    if (msg.id == null) return;
    final tid = _fileTransferIds.remove(msg.id);
    if (tid != null) {
      final fileSvc = ref.read(fileServiceProvider);
      await fileSvc?.cancelOutgoing(tid);
    } else {
      AppLogger.d('Chat', '_cancelFileSend: no tid found for msgId=${msg.id}, just deleting');
    }
    await _deleteMe(msg);
  }

  Future<void> _deleteForAll(Message msg) async {
    if (msg.id == null) return;
    final messaging = ref.read(messagingServiceProvider);
    final storage   = ref.read(storageProvider);
    final transport = ref.read(compositeTransportProvider);
    if (messaging == null) return;

    // Send ttl_delete to peer (best-effort, stateless NaCl box).
    if (msg.messageId != null) {
      try {
        final plain = Uint8List.fromList(
          utf8.encode(jsonEncode({'type': 'ttl_delete', 'ids': [msg.id!]})),
        );
        final envelope = await messaging.encryptBox(widget.contactMasterPub, plain);
        await transport.sendEnvelope(envelope, transportAddresses: _contact?.transportAddresses);
      } catch (_) {}
    }

    // Delete locally.
    await storage.messages.deleteById(msg.id!);
    if (msg.messageId != null) {
      await storage.messageReceipts.deleteForMessage(msg.messageId!);
    }
    final bus = ref.read(eventBusProvider);
    bus.emit(MessagesDeletedEvent(conversationIds: {widget.contactMasterPub}));
    await _loadMessages();
  }

  Future<void> _showDeliveryDetails(Message msg) async {
    if (msg.messageId == null) return;
    final storage = ref.read(storageProvider);
    final receipts = await storage.messageReceipts.forMessage(msg.messageId!);
    // Resolve contact aliases for display.
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
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              context.l10n.deliveryStatus,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
            ),
          ),
          if (receipts.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: Text(context.l10n.noDeliveryInfo, style: const TextStyle(color: Colors.white54)),
            )
          else
            ...receipts.map((r) {
              final name = aliases[r.recipientPub] ?? '${r.recipientPub.substring(0, 12)}…';
              final statusIcon = r.readAt != null
                  ? Icons.done_all
                  : r.deliveredAt != null
                      ? Icons.done_all
                      : Icons.done;
              final statusColor = r.readAt != null
                  ? const Color(0xFF52B8EA)
                  : const Color(0xFF8EADC1);
              final timeStr = r.readAt != null
                  ? _fmtTs(r.readAt!)
                  : r.deliveredAt != null
                      ? _fmtTs(r.deliveredAt!)
                      : r.sentAt != null
                          ? _fmtTs(r.sentAt!)
                          : '—';
              final transportLabel = (r.transport != null && r.transport!.isNotEmpty)
                  ? ' ${_shortTransport(r.transport!)}'
                  : '';
              return ListTile(
                leading: Icon(statusIcon, color: statusColor, size: 20),
                title: Text(name, style: const TextStyle(color: Colors.white)),
                trailing: Text(
                  '$timeStr$transportLabel',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              );
            }),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  static String _fmtTs(int ts) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  static String _shortTransport(String t) {
    switch (t) {
      case 'yggdrasil': return 'ygg';
      case 'reticulum': return 'ret';
      case 'meshcore':  return 'mesh';
      default: return t.length > 4 ? t.substring(0, 4) : t;
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

  void _scrollToBottomAndRead() {
    _scrollToBottom();
    setState(() { _showScrollBadge = false; _unreadCount = 0; });
    _sendReadReceipts();
  }

  static String _formatTtl(int seconds) {
    if (seconds < 3600) return '${seconds ~/ 60}m';
    if (seconds < 86400) return '${seconds ~/ 3600}h';
    if (seconds < 604800) return '${seconds ~/ 86400}d';
    return '${seconds ~/ 604800}w';
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final identity = ref.watch(identityNotifierProvider);
    final myPub58  = identity != null
        ? PubkeyCodec.encode(identity.masterPublicKey)
        : '';

    final displayName = _contact?.alias.isNotEmpty == true
        ? _contact!.alias
        : (widget.contactMasterPub.length > 12
            ? '${widget.contactMasterPub.substring(0, 12)}…'
            : widget.contactMasterPub);

    final lastSeenText = _formatLastSeen(_contact?.lastSeen);

    final items = buildMessageList(
      messages: _messages,
      myPub58: myPub58,
      isGroup: false,
      fileSvc: ref.read(fileServiceProvider),
      storage: ref.read(storageProvider),
      fileProgress: _fileProgress.isNotEmpty ? _fileProgress : null,
      queueAttempts: _queueAttempts.isNotEmpty ? _queueAttempts : null,
      deliveryCounts: _deliveryCounts,
      onDeliveryTap: _showDeliveryDetails,
      onDeleteQueued: _deleteQueued,
      onDeleteMe: (msg) => msg.id != null && _fileTransferIds.containsKey(msg.id)
          ? _cancelFileSend(msg)
          : _deleteMe(msg),
      onDeleteForAll: _deleteForAll,
      onMessageVisible: _onMessageVisible,
      onReply: (msg) => setState(() => _replyTo = msg),
      onForward: _forwardMessage,
    );

    return Scaffold(
      backgroundColor: const Color(0xFF0E1621),
      appBar: HubCoreAppBar(
        titleSpacing: 0,
        title: GestureDetector(
          onTap: () => context.push('/contact/${widget.contactMasterPub}')
              .then((_) => _loadContact()),
          child: Row(
            children: [
              ContactAvatar(name: displayName, masterPub: widget.contactMasterPub, radius: 18),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      displayName,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 16),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (lastSeenText != null)
                      Text(
                        lastSeenText,
                        style: const TextStyle(
                            fontSize: 12, color: Colors.white54),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(
              _contact?.muted == true ? Icons.volume_off : Icons.volume_up_outlined,
              color: _contact?.muted == true ? Colors.white38 : null,
            ),
            tooltip: _contact?.muted == true ? context.l10n.unmuteNotifications : context.l10n.muteNotifications,
            onPressed: _toggleMute,
          ),
          IconButton(
            icon: Icon(
              _ttlSeconds != null ? Icons.timer : Icons.timer_outlined,
              color: _ttlSeconds != null ? const Color(0xFF2AABEE) : null,
            ),
            tooltip: _ttlSeconds != null
                ? context.l10n.autoDeleteLabel(_formatTtl(_ttlSeconds!))
                : context.l10n.autoDeleteOff,
            onPressed: _pickTtl,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_sendError != null)
            MaterialBanner(
              content: Text(_sendError!),
              actions: [
                TextButton(
                  onPressed: () => setState(() => _sendError = null),
                  child: Text(context.l10n.dismiss),
                ),
              ],
            ),
          if (_contact?.isStranger == true)
            _StrangerBanner(
              onAdd: _addStrangerToContacts,
              onBlock: _blockStranger,
            ),
          Expanded(
            child: Stack(
              children: [
                RefreshIndicator(
                  onRefresh: () async {
                    await _loadMessages();
                  },
                  child: items.isEmpty
                      ? ListView(children: [
                          SizedBox(
                            height: 300,
                            child: Center(
                              child: Text(
                                context.l10n.noMessagesHint,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    color: Colors.white38, fontSize: 15),
                              ),
                            ),
                          ),
                        ])
                      : ListView(
                          controller: _scrollCtrl,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 0, vertical: 8),
                          children: [
                            if (_loadingMore)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 8),
                                child: Center(
                                  child: SizedBox(
                                    width: 20, height: 20,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  ),
                                ),
                              ),
                            ...items,
                          ],
                        ),
                ),
                if (_showScrollBadge)
                  Positioned(
                    bottom: 8,
                    right: 12,
                    child: GestureDetector(
                      onTap: _scrollToBottomAndRead,
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF2AABEE),
                          shape: BoxShape.circle,
                          boxShadow: const [
                            BoxShadow(color: Colors.black45, blurRadius: 4)
                          ],
                        ),
                        padding: const EdgeInsets.all(6),
                        child: Stack(
                          alignment: Alignment.topRight,
                          clipBehavior: Clip.none,
                          children: [
                            const Icon(Icons.keyboard_arrow_down,
                                color: Colors.white, size: 24),
                            if (_unreadCount > 0)
                              Positioned(
                                top: -6,
                                right: -6,
                                child: Container(
                                  padding: const EdgeInsets.all(2),
                                  decoration: const BoxDecoration(
                                    color: Color(0xFFEF5350),
                                    shape: BoxShape.circle,
                                  ),
                                  constraints: const BoxConstraints(
                                      minWidth: 16, minHeight: 16),
                                  child: Text(
                                    _unreadCount > 99
                                        ? '99+'
                                        : '$_unreadCount',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (_contact?.isBlocked == true)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
              color: const Color(0xFF1C2733),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.block, color: Colors.red, size: 16),
                  const SizedBox(width: 8),
                  const Text('Контакт заблокирован',
                      style: TextStyle(color: Colors.red, fontSize: 13)),
                  const Spacer(),
                  TextButton(
                    onPressed: () async {
                      final storage = ref.read(storageProvider);
                      await storage.contacts.setRelationship(
                          widget.contactMasterPub, 'contact');
                      ref.read(eventBusProvider).emit(
                          ContactUpdatedEvent(masterPub: widget.contactMasterPub));
                      await _loadContact();
                    },
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.orange,
                      minimumSize: Size.zero,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Разблокировать',
                        style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            )
          else ...[
            if (_replyTo != null)
              ReplyInputBar(
                replyBody: _replyTo!.body,
                onCancel: () => setState(() => _replyTo = null),
              ),
            ChatInputBar(
              controller: _ctrl,
              sending: _sending,
              onSend: _send,
              onAttach: _sendFile,
              onVoiceSend: _sendVoice,
              onVideoCircleSend: _sendVideoCircle,
            ),
          ],
        ],
      ),
    );
  }
}

class _StrangerBanner extends StatelessWidget {
  final VoidCallback onAdd;
  final VoidCallback onBlock;
  const _StrangerBanner({required this.onAdd, required this.onBlock});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1C2B3A),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.person_outline, color: Colors.white54, size: 20),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Незнакомый контакт',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
          TextButton(
            onPressed: onAdd,
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF2AABEE),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('+ Добавить', style: TextStyle(fontSize: 13)),
          ),
          const SizedBox(width: 4),
          TextButton(
            onPressed: onBlock,
            style: TextButton.styleFrom(
              foregroundColor: Colors.redAccent,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Заблокировать', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }
}


