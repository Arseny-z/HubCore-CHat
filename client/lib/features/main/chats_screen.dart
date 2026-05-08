import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../application/events/app_event_bus.dart';
import '../../shared/providers/app_providers.dart';
import '../../shared/utils/l10n.dart';
import '../../shared/utils/pubkey_codec.dart';
import '../../shared/widgets/contact_avatar.dart';
import '../../shared/widgets/hubcore_app_bar.dart';

/// A unified chat list item — either a DM or a group.
class _ChatItem {
  final String id;          // masterPub for DM, groupId for group
  final bool isGroup;
  final bool isStranger;
  final String name;
  final String lastBody;
  final ContentType? lastContentType;
  final int lastAt;         // unix seconds
  final int unreadCount;
  final bool muted;

  const _ChatItem({
    required this.id,
    required this.isGroup,
    this.isStranger = false,
    required this.name,
    required this.lastBody,
    this.lastContentType,
    required this.lastAt,
    this.unreadCount = 0,
    this.muted = false,
  });

  /// Human-readable preview text (no raw filenames for media).
  String previewText(BuildContext context) {
    switch (lastContentType) {
      case ContentType.audio:  return context.l10n.mediaAudio;
      case ContentType.video:  return context.l10n.mediaVideoCircle;
      case ContentType.image:  return context.l10n.mediaPhoto;
      case ContentType.file:   return '📎 $lastBody';
      default:                 return lastBody;
    }
  }
}

class ChatsScreen extends ConsumerStatefulWidget {
  const ChatsScreen({super.key});

  @override
  ConsumerState<ChatsScreen> createState() => ChatsScreenState();
}

class ChatsScreenState extends ConsumerState<ChatsScreen> {
  List<_ChatItem> _items = [];
  List<_ChatItem> _strangers = [];
  bool _strangersExpanded = true;
  String _query = '';
  bool _searching = false;
  bool _loading = true;
  final _searchCtrl = TextEditingController();

  StreamSubscription<MessageReceivedEvent>? _msgSub;
  StreamSubscription<MessagesDeletedEvent>? _deletedSub;
  StreamSubscription<ContactUpdatedEvent>? _contactSub;

  @override
  void initState() {
    super.initState();
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) => _subscribeToEvents());
  }

  @override
  void dispose() {
    _msgSub?.cancel();
    _deletedSub?.cancel();
    _contactSub?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _subscribeToEvents() {
    final bus = ref.read(eventBusProvider);
    _msgSub     = bus.on<MessageReceivedEvent>().listen((_) { if (mounted) _load(); });
    _deletedSub = bus.on<MessagesDeletedEvent>().listen((_) { if (mounted) _load(); });
    _contactSub = bus.on<ContactUpdatedEvent>().listen((_) { if (mounted) _load(); });
    bus.on<GroupJoinedEvent>().listen((_) { if (mounted) _load(); });
    bus.on<GroupInviteReceivedEvent>().listen((_) { if (mounted) _load(); });
  }

  Future<void> load() => _load();

  Future<void> _load() async {
    final storage = ref.read(storageProvider);
    if (!storage.isOpen) return;

    final identity = ref.read(identityNotifierProvider);
    final myPub = identity != null ? PubkeyCodec.encode(identity.masterPublicKey) : '';

    final contacts  = await storage.contacts.all(relationship: 'contact');
    // Limit stranger list to avoid UI lag with many incoming contacts
    const _kMaxStrangers = 50;
    final strangers = (await storage.contacts.strangers()).take(_kMaxStrangers).toList();
    final groups    = await storage.groups.allGroups();

    Future<_ChatItem> toItem(contact, {bool isStranger = false}) async {
      final msg    = await storage.messages.lastMessage(contact.masterPub);
      final unread = myPub.isNotEmpty
          ? await storage.messages.unreadCount(contact.masterPub, myPub)
          : 0;
      return _ChatItem(
        id: contact.masterPub,
        isGroup: false,
        isStranger: isStranger,
        name: contact.alias.isNotEmpty
            ? contact.alias
            : (contact.masterPub.length >= 8
                ? contact.masterPub.substring(0, 8)
                : contact.masterPub),
        lastBody: msg?.body ?? '',
        lastContentType: msg?.contentType,
        lastAt: msg?.sentAt ?? 0,
        unreadCount: contact.muted ? 0 : unread,
        muted: contact.muted,
      );
    }

    final items = <_ChatItem>[];
    for (final c in contacts) items.add(await toItem(c));
    for (final g in groups) {
      final msg    = await storage.messages.lastMessage(g.groupId);
      final unread = myPub.isNotEmpty
          ? await storage.messages.unreadCount(g.groupId, myPub)
          : 0;
      items.add(_ChatItem(
        id: g.groupId,
        isGroup: true,
        name: g.name.isNotEmpty ? g.name : 'Group',
        lastBody: msg?.body ?? '',
        lastContentType: msg?.contentType,
        lastAt: msg?.sentAt ?? g.createdAt,
        unreadCount: unread,
      ));
    }
    items.sort((a, b) => b.lastAt.compareTo(a.lastAt));

    final strangerItems = <_ChatItem>[];
    for (final c in strangers) strangerItems.add(await toItem(c, isStranger: true));
    strangerItems.sort((a, b) => b.lastAt.compareTo(a.lastAt));

    if (mounted) setState(() {
      _items    = items;
      _strangers = strangerItems;
      _loading  = false;
    });
  }

  Widget _buildDismissible(_ChatItem item) {
    return Dismissible(
      key: Key(item.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Colors.red,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (_) => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(ctx.l10n.deleteChatTitle),
          content: Text(ctx.l10n.deleteChatContent(item.name)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(ctx.l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              child: Text(ctx.l10n.delete),
            ),
          ],
        ),
      ).then((v) => v ?? false),
      onDismissed: (_) async {
        final storage = ref.read(storageProvider);
        await storage.messages.deleteConversation(item.id);
        if (item.isStranger) {
          await storage.contacts.delete(item.id);
          setState(() => _strangers.removeWhere((e) => e.id == item.id));
        } else {
          setState(() => _items.removeWhere((e) => e.id == item.id));
        }
      },
      child: _ChatTile(
        item: item,
        onTap: () {
          if (item.isGroup) {
            context.push('/group/${item.id}').then((_) => _load());
          } else {
            context.push('/chat/${item.id}').then((_) => _load());
          }
        },
      ),
    );
  }

  void _stopSearch() {
    setState(() {
      _searching = false;
      _query = '';
      _searchCtrl.clear();
    });
  }

  List<_ChatItem> get _filtered {
    if (_query.isEmpty) return _items;
    final q = _query.toLowerCase();
    return _items.where((i) => i.name.toLowerCase().contains(q)).toList();
  }

  List<_ChatItem> get _filteredStrangers {
    if (_query.isEmpty) return _strangers;
    final q = _query.toLowerCase();
    return _strangers.where((i) => i.name.toLowerCase().contains(q)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = _filtered;

    return Scaffold(
      appBar: _searching
          ? HubCoreAppBar(
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _stopSearch,
              ),
              title: TextField(
                controller: _searchCtrl,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: context.l10n.searchChats,
                  hintStyle: const TextStyle(color: Colors.white38),
                  border: InputBorder.none,
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            )
          : HubCoreAppBar(
              title: const Text('HubCore Chat', style: TextStyle(fontWeight: FontWeight.bold)),
              actions: [
                _NotificationBell(),
                IconButton(
                  icon: const Icon(Icons.search),
                  tooltip: context.l10n.searchMessages,
                  onPressed: () => context.push('/search'),
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert),
                  onSelected: (v) {
                    if (v == 'new_group') context.push('/group/new').then((_) => _load());
                  },
                  itemBuilder: (ctx) => [
                    PopupMenuItem(value: 'new_group', child: Text(ctx.l10n.newGroup)),
                  ],
                ),
              ],
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (filtered.isEmpty && _filteredStrangers.isEmpty)
          ? _query.isNotEmpty
              ? Center(
                  child: Text(
                    context.l10n.noChatMatchingQuery(_query),
                    style: TextStyle(color: theme.colorScheme.onSurface.withAlpha(100)),
                  ),
                )
              : _EmptyChats(theme: theme)
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                children: [
                  // ── Main chats (contacts + groups) ──────────────────────
                  ...filtered.asMap().entries.map((e) {
                    final item = e.value;
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildDismissible(item),
                        if (e.key < filtered.length - 1)
                          const Divider(height: 1, indent: 72),
                      ],
                    );
                  }),

                  // ── New conversations (strangers) ────────────────────────
                  if (_filteredStrangers.isNotEmpty) ...[
                    if (filtered.isNotEmpty)
                      const Divider(height: 1),
                    InkWell(
                      onTap: () => setState(
                          () => _strangersExpanded = !_strangersExpanded),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        child: Row(
                          children: [
                            Icon(Icons.mark_chat_unread_outlined,
                                size: 18,
                                color: theme.colorScheme.onSurface.withAlpha(160)),
                            const SizedBox(width: 8),
                            Text(
                              'Новые разговоры (${_filteredStrangers.length})',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color:
                                    theme.colorScheme.onSurface.withAlpha(160),
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.3,
                              ),
                            ),
                            const Spacer(),
                            Icon(
                              _strangersExpanded
                                  ? Icons.expand_less
                                  : Icons.expand_more,
                              size: 18,
                              color: theme.colorScheme.onSurface.withAlpha(120),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_strangersExpanded)
                      ..._filteredStrangers.asMap().entries.map((e) {
                        final item = e.value;
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildDismissible(item),
                            if (e.key < _filteredStrangers.length - 1)
                              const Divider(height: 1, indent: 72),
                          ],
                        );
                      }),
                  ],
                ],
              ),
            ),
    );
  }
}

class _ChatTile extends StatelessWidget {
  final _ChatItem item;
  final VoidCallback onTap;
  const _ChatTile({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: item.isGroup
          ? CircleAvatar(
              radius: 26,
              backgroundColor: avatarColor(item.name),
              child: const Icon(Icons.group, color: Colors.white, size: 22),
            )
          : ContactAvatar(name: item.name, masterPub: item.id, radius: 26),
      title: Row(
        children: [
          if (item.muted) ...[
            const Icon(Icons.volume_off, size: 14, color: Colors.white38),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text(
              item.name,
              style: TextStyle(
                fontWeight: item.unreadCount > 0 ? FontWeight.w700 : FontWeight.w600,
                fontSize: 16,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      subtitle: item.lastBody.isEmpty
          ? Text(
              item.isGroup ? 'Группа создана' : 'Нет сообщений',
              style: TextStyle(color: theme.colorScheme.onSurface.withAlpha(100)),
              maxLines: 1,
            )
          : Text(
              item.previewText(context),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: item.unreadCount > 0
                    ? Colors.white.withAlpha(220)
                    : theme.colorScheme.onSurface.withAlpha(160),
                fontWeight: item.unreadCount > 0 ? FontWeight.w500 : FontWeight.normal,
              ),
            ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (item.lastAt > 0)
            Text(
              _formatTime(item.lastAt, context),
              style: theme.textTheme.bodySmall?.copyWith(
                color: item.unreadCount > 0
                    ? const Color(0xFF2AABEE)
                    : theme.colorScheme.onSurface.withAlpha(130),
                fontSize: 12,
              ),
            ),
          if (item.unreadCount > 0) ...[
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF2AABEE),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                item.unreadCount > 99 ? '99+' : '${item.unreadCount}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
      onTap: onTap,
    );
  }

  static String _formatTime(int unixSeconds, BuildContext context) {
    final dt = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final msgDay = DateTime(dt.year, dt.month, dt.day);

    if (msgDay == today) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    final yesterday = today.subtract(const Duration(days: 1));
    if (msgDay == yesterday) return context.l10n.yesterday;
    return '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}';
  }
}

class _EmptyChats extends StatelessWidget {
  final ThemeData theme;
  const _EmptyChats({required this.theme});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline,
                size: 80,
                color: theme.colorScheme.onSurface.withAlpha(50)),
            const SizedBox(height: 20),
            Text(
              context.l10n.emptyChatsTitle,
              style: theme.textTheme.titleLarge?.copyWith(
                color: theme.colorScheme.onSurface.withAlpha(120),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              context.l10n.emptyChatsSubtitle,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withAlpha(80),
                height: 1.5,
              ),
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: () => context.push('/contacts/add'),
              icon: const Icon(Icons.person_add_outlined),
              label: Text(context.l10n.addContactButton),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Notification bell with badge ─────────────────────────────────────────────

class _NotificationBell extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final countAsync = ref.watch(pendingNotificationCountProvider);
    final count = countAsync.valueOrNull ?? 0;

    return IconButton(
      icon: count > 0
          ? Badge(
              label: Text('$count', style: const TextStyle(fontSize: 10)),
              child: const Icon(Icons.notifications_outlined),
            )
          : const Icon(Icons.notifications_none),
      onPressed: () => context.push('/notifications'),
    );
  }
}
