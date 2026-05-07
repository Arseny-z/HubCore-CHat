
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/providers/app_providers.dart';
import '../../shared/utils/l10n.dart';
import '../../shared/utils/logger.dart';
import '../../shared/widgets/contact_avatar.dart';
import '../../shared/widgets/hubcore_app_bar.dart';

class CreateGroupScreen extends ConsumerStatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  ConsumerState<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends ConsumerState<CreateGroupScreen> {
  final _nameCtrl = TextEditingController();
  List<Contact> _contacts = [];
  final _selected = <String>{};
  bool _creating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadContacts() async {
    final storage = ref.read(storageProvider);
    if (!storage.isOpen) return;
    final contacts = await storage.contacts.all(relationship: 'contact');
    if (mounted) setState(() => _contacts = contacts);
  }

  Future<void> _create() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = context.l10n.enterGroupName);
      return;
    }
    if (_selected.isEmpty) {
      setState(() => _error = context.l10n.selectAtLeastOneMember);
      return;
    }

    final groupSvc = ref.read(groupMessagingProvider);
    final messaging = ref.read(messagingServiceProvider);
    if (groupSvc == null || messaging == null) {
      setState(() => _error = context.l10n.messagingNotReady);
      return;
    }

    setState(() { _creating = true; _error = null; });

    try {
      final groupId = await groupSvc.createGroup(
        name: name,
        memberPubs: _selected.toList(),
      );

      // Send invite to each member via NaCl box (stateless, no DR session needed)
      final invitePayload = await groupSvc.buildInvitePayload(groupId);
      AppLogger.d('CreateGroup', 'invitePayload: ${invitePayload?.length ?? 'null'} bytes');
      if (invitePayload != null) {
        final transport = ref.read(compositeTransportProvider);
        final storage = ref.read(storageProvider);
        for (final pub in _selected) {
          try {
            AppLogger.d('CreateGroup', 'encrypting box for ${pub.substring(0, 8)}…');
            final env = await messaging.encryptBox(pub, invitePayload);
            final contact = await storage.contacts.findByMasterPub(pub);
            AppLogger.d('CreateGroup', 'sending envelope ${env.body.length}b to ${pub.substring(0, 8)}… addrs=${contact?.transportAddresses.keys.join(",")}');
            await transport.sendEnvelope(env, transportAddresses: contact?.transportAddresses);
            AppLogger.d('CreateGroup', 'invite sent OK to ${pub.substring(0, 8)}…');
          } catch (e, st) {
            AppLogger.e('CreateGroup', 'invite send to ${pub.substring(0, 8)}… failed', error: e, stack: st);
          }
        }
      }

      if (mounted) context.go('/group/$groupId');
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: HubCoreAppBar(title: Text(context.l10n.newGroupTitle)),
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
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _nameCtrl,
              decoration: InputDecoration(
                labelText: context.l10n.groupNameHint,
                border: const OutlineInputBorder(),
              ),
              textCapitalization: TextCapitalization.words,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                context.l10n.selectMembersLabel,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
              ),
            ),
          ),
          Expanded(
            child: _contacts.isEmpty
                ? Center(child: Text(context.l10n.noContactsToAdd))
                : ListView.builder(
                    itemCount: _contacts.length,
                    itemBuilder: (_, i) {
                      final c = _contacts[i];
                      final isSelected = _selected.contains(c.masterPub);
                      return CheckboxListTile(
                        value: isSelected,
                        onChanged: (v) {
                          setState(() {
                            if (v == true) {
                              _selected.add(c.masterPub);
                            } else {
                              _selected.remove(c.masterPub);
                            }
                          });
                        },
                        title: Text(
                          c.alias.isNotEmpty ? c.alias : c.masterPub.substring(0, 8),
                        ),
                        subtitle: Text(
                          c.masterPub.substring(0, 12),
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                        ),
                        secondary: ContactAvatar(
                          name: c.alias,
                          masterPub: c.masterPub,
                          radius: 20,
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton.icon(
                onPressed: _creating ? null : _create,
                icon: _creating
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.group_add),
                label: Text(context.l10n.createGroupButton(_selected.length)),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
