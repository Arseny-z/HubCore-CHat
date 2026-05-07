import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../application/events/app_event_bus.dart';
import '../../shared/providers/app_providers.dart';
import '../../shared/services/avatar_service.dart';
import '../../shared/utils/l10n.dart';
import '../../shared/widgets/contact_avatar.dart';
import '../../shared/widgets/my_qr_code.dart';
import '../../shared/widgets/hubcore_app_bar.dart';

class ContactsTab extends ConsumerStatefulWidget {
  const ContactsTab({super.key});

  @override
  ConsumerState<ContactsTab> createState() => ContactsTabState();
}

class ContactsTabState extends ConsumerState<ContactsTab> {
  List<Contact> _contacts = [];
  bool _loading = true;
  StreamSubscription<ContactUpdatedEvent>? _contactSub;

  @override
  void initState() {
    super.initState();
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _contactSub = ref
          .read(eventBusProvider)
          .on<ContactUpdatedEvent>()
          .listen((_) { if (mounted) _load(); });
    });
  }

  @override
  void dispose() {
    _contactSub?.cancel();
    super.dispose();
  }

  Future<void> load() => _load();

  Future<void> _load() async {
    final storage = ref.read(storageProvider);
    if (!storage.isOpen) return;
    final contacts = await storage.contacts.all(relationship: 'contact');
    if (mounted) setState(() { _contacts = contacts; _loading = false; });
  }

  void _showMyQR() {
    final identity = ref.read(identityNotifierProvider);
    if (identity == null) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.myQrCode),
        content: SizedBox(
          width: 240,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const MyQrCode(size: 200),
              const SizedBox(height: 12),
              Text(
                identity.fingerprint,
                style: const TextStyle(fontFamily: 'monospace', letterSpacing: 2, fontSize: 11),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(ctx.l10n.close)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final identity = ref.watch(identityNotifierProvider);

    return Scaffold(
      appBar: HubCoreAppBar(
        title: Text(context.l10n.tabContacts, style: const TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          if (identity != null)
            IconButton(
              icon: const Icon(Icons.qr_code),
              tooltip: context.l10n.myQrCode,
              onPressed: _showMyQR,
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push('/contacts/add').then((_) => _load()),
        tooltip: context.l10n.addContactButton,
        child: const Icon(Icons.person_add_outlined),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _contacts.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.people_outline, size: 72,
                      color: theme.colorScheme.onSurface.withAlpha(60)),
                  const SizedBox(height: 16),
                  Text(
                    context.l10n.noContactsYet,
                    style: theme.textTheme.titleMedium?.copyWith(
                        color: theme.colorScheme.onSurface.withAlpha(100)),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    context.l10n.tapPlusToAdd,
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface.withAlpha(80)),
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.separated(
                itemCount: _contacts.length,
                separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
                itemBuilder: (_, i) {
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
                    confirmDismiss: (_) => showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: Text(ctx.l10n.deleteContactTitle),
                        content: Text(c.alias.isNotEmpty ? c.alias : c.masterPub.substring(0, 8)),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: Text(ctx.l10n.cancel)),
                          FilledButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: Text(ctx.l10n.delete)),
                        ],
                      ),
                    ).then((v) => v ?? false),
                    onDismissed: (_) async {
                      await AvatarService.instance.delete(c.masterPub);
                      await ref.read(storageProvider).contacts.delete(c.masterPub);
                      setState(() => _contacts.removeAt(i));
                    },
                    child: ListTile(
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      leading: ContactAvatar(
                        name: c.alias,
                        masterPub: c.masterPub,
                        radius: 26,
                      ),
                      title: Text(
                        c.alias.isNotEmpty ? c.alias : c.masterPub.substring(0, 8),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        c.masterPub.substring(0, 16),
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.info_outline, color: Colors.white38),
                        onPressed: () => context.push('/contact/${c.masterPub}')
                            .then((_) => _load()),
                      ),
                      onTap: () => context.push('/chat/${c.masterPub}'),
                    ),
                  );
                },
              ),
            ),
    );
  }

}
