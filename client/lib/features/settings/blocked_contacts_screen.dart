import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/contact.dart';
import '../../shared/providers/app_providers.dart';
import '../../shared/widgets/contact_avatar.dart';
import '../../shared/widgets/hubcore_app_bar.dart';

class BlockedContactsScreen extends ConsumerStatefulWidget {
  const BlockedContactsScreen({super.key});

  @override
  ConsumerState<BlockedContactsScreen> createState() => _BlockedContactsScreenState();
}

class _BlockedContactsScreenState extends ConsumerState<BlockedContactsScreen> {
  List<Contact> _blocked = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final storage = ref.read(storageProvider);
    if (!storage.isOpen) return;
    final list = await storage.contacts.blocked();
    if (mounted) setState(() { _blocked = list; _loading = false; });
  }

  Future<void> _unblock(Contact c) async {
    final storage = ref.read(storageProvider);
    await storage.contacts.setRelationship(c.masterPub, 'contact');
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: HubCoreAppBar(title: const Text('Заблокированные')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _blocked.isEmpty
              ? const Center(
                  child: Text('Нет заблокированных контактов',
                      style: TextStyle(color: Colors.white38)),
                )
              : ListView.separated(
                  itemCount: _blocked.length,
                  separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
                  itemBuilder: (_, i) {
                    final c = _blocked[i];
                    final name = c.alias.isNotEmpty
                        ? c.alias
                        : c.masterPub.substring(0, 8);
                    return ListTile(
                      leading: ContactAvatar(name: name, masterPub: c.masterPub, radius: 22),
                      title: Text(name),
                      trailing: TextButton(
                        onPressed: () => _unblock(c),
                        child: const Text('Разблокировать',
                            style: TextStyle(color: Colors.orange)),
                      ),
                    );
                  },
                ),
    );
  }
}
