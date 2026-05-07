import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/providers/app_providers.dart';
import '../../shared/widgets/hubcore_app_bar.dart';

class GroupsScreen extends ConsumerStatefulWidget {
  const GroupsScreen({super.key});

  @override
  ConsumerState<GroupsScreen> createState() => _GroupsScreenState();
}

class _GroupsScreenState extends ConsumerState<GroupsScreen> {
  List<Group> _groups = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final storage = ref.read(storageProvider);
    if (!storage.isOpen) return;
    final groups = await storage.groups.allGroups();
    if (mounted) setState(() => _groups = groups);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: HubCoreAppBar(title: const Text('Groups')),
      body: _groups.isEmpty
          ? Center(
              child: Text(
                'No groups yet.\nTap + to create one.',
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodyLarge
                    ?.copyWith(color: Colors.white54),
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.builder(
                itemCount: _groups.length,
                itemBuilder: (_, i) {
                  final g = _groups[i];
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      child: Text(
                        g.name.isNotEmpty ? g.name[0].toUpperCase() : '#',
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                    title: Text(g.name),
                    subtitle: Text(
                      g.groupId.substring(0, 12),
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                    ),
                    onTap: () => context.push('/group/${g.groupId}'),
                  );
                },
              ),
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await context.push('/group/new');
          _load();
        },
        child: const Icon(Icons.group_add),
      ),
    );
  }
}
