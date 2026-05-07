import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../shared/providers/app_providers.dart';
import '../../shared/utils/l10n.dart';
import '../../shared/services/avatar_service.dart';
import '../../shared/widgets/my_qr_code.dart';
import '../../shared/widgets/hubcore_app_bar.dart';

class ContactsScreen extends ConsumerStatefulWidget {
  const ContactsScreen({super.key});

  @override
  ConsumerState<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends ConsumerState<ContactsScreen> {
  final _listKey = GlobalKey<_ContactsListState>();

  void _showMyQR(BuildContext context) {
    final identity = ref.read(identityNotifierProvider);
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('My Identity'),
        content: SizedBox(
          width: 240,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
            const MyQrCode(size: 200),
            const SizedBox(height: 12),
            Text(
              identity?.fingerprint ?? '',
              style: const TextStyle(fontFamily: 'monospace', letterSpacing: 2, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.close),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final storage = ref.watch(storageProvider);
    final identity = ref.watch(identityNotifierProvider);

    return Scaffold(
      appBar: HubCoreAppBar(
        title: const Text('Chats'),
        actions: [
          if (identity != null)
            IconButton(
              icon: const Icon(Icons.qr_code),
              tooltip: 'My QR code',
              onPressed: () => _showMyQR(context),
            ),
          IconButton(
            icon: const Icon(Icons.group),
            tooltip: 'Groups',
            onPressed: () => context.push('/groups'),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: storage.isOpen
          ? _ContactsList(key: _listKey, storage: storage)
          : Center(child: Text(context.l10n.databaseError)),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await context.push('/contacts/add');
          _listKey.currentState?._load();
        },
        child: const Icon(Icons.person_add),
      ),
    );
  }
}

class _ContactsList extends StatefulWidget {
  final dynamic storage;
  const _ContactsList({super.key, required this.storage});

  @override
  State<_ContactsList> createState() => _ContactsListState();
}

class _ContactsListState extends State<_ContactsList> {
  List<Contact> _contacts = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final contacts = await widget.storage.contacts.all();
    if (mounted) setState(() => _contacts = contacts);
  }

  @override
  Widget build(BuildContext context) {
    if (_contacts.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.people_outline, size: 64, color: Colors.white38),
            const SizedBox(height: 16),
            Text(
              'No contacts yet.\nTap + to add someone.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: Colors.white54),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        itemCount: _contacts.length,
        itemBuilder: (context, i) {
          final c = _contacts[i];
          return Dismissible(
            key: Key(c.masterPub),
            direction: DismissDirection.endToStart,
            background: Container(
              color: Colors.red,
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              child: const Icon(Icons.delete, color: Colors.white),
            ),
            confirmDismiss: (_) async {
              return await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  title: Text(context.l10n.deleteContactTitle),
                  content: Text(context.l10n.deleteContactContent(c.alias.isNotEmpty ? c.alias : c.masterPub.substring(0, 8))),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.l10n.cancel)),
                    FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(context.l10n.delete)),
                  ],
                ),
              ) ?? false;
            },
            onDismissed: (_) async {
              await AvatarService.instance.delete(c.masterPub);
              await widget.storage.contacts.delete(c.masterPub);
              setState(() => _contacts.removeAt(i));
            },
            child: ListTile(
            leading: CircleAvatar(
              child: Text(
                c.alias.isNotEmpty ? c.alias[0].toUpperCase() : '?',
              ),
            ),
            title: Text(c.alias.isNotEmpty ? c.alias : c.masterPub.substring(0, 8)),
            subtitle: Text(
              c.masterPub.substring(0, 12),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            onTap: () => context.push('/chat/${c.masterPub}'),
            ),
          );
        },
      ),
    );
  }
}
