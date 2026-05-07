import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/providers/app_providers.dart';
import '../../shared/utils/l10n.dart';
import '../../shared/utils/pubkey_codec.dart';
import '../../shared/widgets/contact_avatar.dart';
import '../../shared/widgets/hubcore_app_bar.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _ctrl = TextEditingController();
  List<_SearchResult> _results = [];
  bool _searching = false;
  String _lastQuery = '';

  // conversation name cache: id → name
  final Map<String, String> _names = {};

  @override
  void initState() {
    super.initState();
    _loadNames();
    _ctrl.addListener(_onChanged);
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onChanged);
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _loadNames() async {
    final storage = ref.read(storageProvider);
    if (!storage.isOpen) return;
    final contacts = await storage.contacts.all();
    final groups   = await storage.groups.allGroups();
    final names = <String, String>{};
    for (final c in contacts) {
      names[c.masterPub] = c.alias.isNotEmpty ? c.alias : c.masterPub.substring(0, 12);
    }
    for (final g in groups) {
      names[g.groupId] = g.name.isNotEmpty ? g.name : 'Group';
    }
    if (mounted) setState(() => _names.addAll(names));
  }

  void _onChanged() {
    final q = _ctrl.text.trim();
    if (q == _lastQuery) return;
    _lastQuery = q;
    if (q.length < 2) {
      setState(() => _results = []);
      return;
    }
    _search(q);
  }

  Future<void> _search(String query) async {
    setState(() => _searching = true);
    final storage = ref.read(storageProvider);
    if (!storage.isOpen) { setState(() => _searching = false); return; }

    final msgs = await storage.messages.search(query);
    if (!mounted) return;

    setState(() {
      _results = msgs.map((m) => _SearchResult(
        message: m,
        conversationName: _names[m.conversationId] ??
            m.conversationId.substring(0, 12),
      )).toList();
      _searching = false;
    });
  }

  void _openResult(_SearchResult r) {
    final msg = r.message;
    if (msg.isGroup) {
      context.push('/group/${msg.conversationId}');
    } else {
      context.push('/chat/${msg.conversationId}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final identity = ref.watch(identityNotifierProvider);
    final myPub = identity != null ? PubkeyCodec.encode(identity.masterPublicKey) : '';

    return Scaffold(
      backgroundColor: const Color(0xFF0E1621),
      appBar: HubCoreAppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.canPop() ? context.pop() : context.go('/main'),
        ),
        title: TextField(
          controller: _ctrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white, fontSize: 16),
          decoration: InputDecoration(
            hintText: context.l10n.searchMessagesTitle,
            hintStyle: const TextStyle(color: Colors.white38),
            border: InputBorder.none,
          ),
        ),
      ),
      body: _searching
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : _results.isEmpty && _lastQuery.length >= 2
              ? Center(
                  child: Text(
                    context.l10n.nothingFound,
                    style: const TextStyle(color: Colors.white38, fontSize: 15),
                  ),
                )
              : ListView.builder(
                  itemCount: _results.length,
                  itemBuilder: (_, i) {
                    final r = _results[i];
                    final msg = r.message;
                    final isMe = msg.senderPub == myPub;
                    final dt = DateTime.fromMillisecondsSinceEpoch(msg.sentAt * 1000);
                    final dateStr = _formatDate(dt, context);

                    return ListTile(
                      leading: msg.isGroup
                          ? CircleAvatar(
                              backgroundColor: const Color(0xFF5C6BC0),
                              child: const Icon(Icons.group, color: Colors.white, size: 18),
                            )
                          : ContactAvatar(
                              name: r.conversationName,
                              masterPub: msg.conversationId,
                              radius: 20,
                            ),
                      title: Row(
                        children: [
                          Expanded(
                            child: Text(
                              r.conversationName,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            dateStr,
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 11),
                          ),
                        ],
                      ),
                      subtitle: RichText(
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        text: TextSpan(
                          children: [
                            if (isMe)
                              TextSpan(
                                text: context.l10n.youPrefix,
                                style: const TextStyle(
                                    color: Colors.white54, fontSize: 13),
                              ),
                            ..._highlightQuery(msg.body, _lastQuery),
                          ],
                        ),
                      ),
                      onTap: () => _openResult(r),
                    );
                  },
                ),
    );
  }

  List<TextSpan> _highlightQuery(String text, String query) {
    if (query.isEmpty) {
      return [TextSpan(
          text: text,
          style: const TextStyle(color: Colors.white70, fontSize: 13))];
    }
    final lower = text.toLowerCase();
    final lowerQ = query.toLowerCase();
    final spans = <TextSpan>[];
    int start = 0;
    while (true) {
      final idx = lower.indexOf(lowerQ, start);
      if (idx < 0) {
        spans.add(TextSpan(
            text: text.substring(start),
            style: const TextStyle(color: Colors.white70, fontSize: 13)));
        break;
      }
      if (idx > start) {
        spans.add(TextSpan(
            text: text.substring(start, idx),
            style: const TextStyle(color: Colors.white70, fontSize: 13)));
      }
      spans.add(TextSpan(
          text: text.substring(idx, idx + query.length),
          style: const TextStyle(
              color: Color(0xFF2AABEE),
              fontWeight: FontWeight.w600,
              fontSize: 13)));
      start = idx + query.length;
    }
    return spans;
  }

  static String _formatDate(DateTime dt, BuildContext context) {
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

class _SearchResult {
  final Message message;
  final String conversationName;
  const _SearchResult({required this.message, required this.conversationName});
}
