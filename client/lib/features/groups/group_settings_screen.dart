import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/entities/group.dart' show GroupMember, GroupRole;
import '../../domain/entities/group_invite.dart';
import '../../shared/providers/app_providers.dart';
import '../../shared/utils/l10n.dart';
import '../../shared/utils/pubkey_codec.dart';
import '../../shared/widgets/contact_avatar.dart';
import '../../shared/widgets/hubcore_app_bar.dart';

class GroupSettingsScreen extends ConsumerStatefulWidget {
  final String groupId;
  const GroupSettingsScreen({super.key, required this.groupId});

  @override
  ConsumerState<GroupSettingsScreen> createState() => _GroupSettingsScreenState();
}

class _GroupSettingsScreenState extends ConsumerState<GroupSettingsScreen> {
  List<String> _memberPubs = [];
  Map<String, String> _aliases = {};
  Map<String, String> _memberRoles = {}; // pub → role
  String _groupName = '';
  String? _adminPub;
  String? _ownerPub;
  String _myRole = GroupRole.write;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final storage = ref.read(storageProvider);
    if (!storage.isOpen) return;
    final g     = await storage.groups.findGroup(widget.groupId);
    final pubs  = await storage.groups.memberPubs(widget.groupId);
    final myPub = _myPub();

    final contacts = await storage.contacts.all();
    final aliases = <String, String>{};
    for (final c in contacts) {
      if (c.alias.isNotEmpty) aliases[c.masterPub] = c.alias;
    }

    // Load roles for all members
    final roles = <String, String>{};
    for (final pub in pubs) {
      roles[pub] = await storage.groups.memberRole(widget.groupId, pub) ?? GroupRole.write;
    }

    if (mounted) {
      setState(() {
        _groupName  = g?.name ?? '';
        _adminPub   = g?.adminPub;
        _ownerPub   = g?.ownerPub;
        _memberPubs = pubs;
        _aliases    = aliases;
        _memberRoles = roles;
        _myRole     = roles[myPub] ?? GroupRole.write;
      });
    }
  }

  String _name(String pub, BuildContext context) {
    final identity = ref.read(identityNotifierProvider);
    final myPub = identity != null ? PubkeyCodec.encode(identity.masterPublicKey) : '';
    if (pub == myPub) return context.l10n.youInGroup;
    return _aliases[pub] ?? pub.substring(0, 12);
  }

  String _myPub() {
    final identity = ref.read(identityNotifierProvider);
    return identity != null ? PubkeyCodec.encode(identity.masterPublicKey) : '';
  }

  // ── Rename ────────────────────────────────────────────────────────────────

  Future<void> _rename() async {
    final ctrl = TextEditingController(text: _groupName);
    final result = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(context.l10n.renameGroup),
        content: TextField(
          controller: ctrl,
          decoration: InputDecoration(
            hintText: context.l10n.groupNameHint,
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctrl.text.trim()),
              child: Text(context.l10n.save)),
        ],
      ),
    );
    if (result == null || result.isEmpty) return;

    setState(() => _loading = true);
    try {
      final storage = ref.read(storageProvider);
      await storage.groups.renameGroup(widget.groupId, result);

      // Send group_rename to all members
      final messaging = ref.read(messagingServiceProvider);
      final transport = ref.read(compositeTransportProvider);
      if (messaging != null) {
        final payload = Uint8List.fromList(utf8.encode(jsonEncode({
          'type': 'group_rename',
          'group_id': widget.groupId,
          'name': result,
        })));
        final myPub = _myPub();
        for (final pub in _memberPubs) {
          if (pub == myPub) continue;
          try {
            final env = await messaging.encryptBox(pub, payload);
            final contact = await storage.contacts.findByMasterPub(pub);
            await transport.sendEnvelope(env,
                transportAddresses: contact?.transportAddresses);
          } catch (_) {}
        }
      }
      setState(() { _groupName = result; _loading = false; });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.l10n.groupRenamed)));
      }
    } catch (e) {
      setState(() => _loading = false);
    }
  }

  // ── Add member ────────────────────────────────────────────────────────────

  Future<void> _addMember() async {
    final storage = ref.read(storageProvider);
    final allContacts = await storage.contacts.all(relationship: 'contact');
    // Only show contacts not already in the group and not blocked
    final available = allContacts
        .where((c) => !_memberPubs.contains(c.masterPub))
        .toList();

    if (available.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.l10n.noAvailableContacts)));
      }
      return;
    }

    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF182533),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(context.l10n.addMember,
                style: const TextStyle(color: Colors.white,
                    fontWeight: FontWeight.bold, fontSize: 16)),
          ),
          ...available.map((c) {
            final name = c.alias.isNotEmpty
                ? c.alias
                : c.masterPub.substring(0, 12);
            return ListTile(
              leading: ContactAvatar(name: name, masterPub: c.masterPub, radius: 20),
              title: Text(name, style: const TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(ctx, c.masterPub),
            );
          }),
          const SizedBox(height: 16),
        ],
      ),
    );
    if (chosen == null) return;

    setState(() => _loading = true);
    try {
      final messaging = ref.read(messagingServiceProvider);
      final transport = ref.read(compositeTransportProvider);

      if (messaging == null) return;

      // P7 per-post-wrap: add member, bump epoch, send invite (no chain).
      await storage.groups.upsertMember(GroupMember(
        groupId:   widget.groupId,
        masterPub: chosen,
        chainKey:  Uint8List(0), // placeholder until Phase 5 drops the column
        counter:   0,
        role:      GroupRole.write,
      ));
      final newEpoch = await storage.groups.bumpEpoch(widget.groupId);

      final group   = await storage.groups.findGroup(widget.groupId);
      final members = await storage.groups.memberPubs(widget.groupId);
      if (group != null) {
        final invite = GroupInvite(
          groupId:      widget.groupId,
          name:         group.name,
          members:      members,
          chainKeyBlob: Uint8List(0), // legacy field — phased out in P5
          adminPub58:   group.adminPub ?? group.ownerPub ?? '',
          epoch:        newEpoch,
        );
        final env = await messaging.encryptBox(chosen, invite.encode());
        final contact = await storage.contacts.findByMasterPub(chosen);
        await transport.sendEnvelope(env,
            transportAddresses: contact?.transportAddresses);
      }

      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.l10n.invitationSent)));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Remove member ──────────────────────────────────────────────────────────

  Future<void> _removeMember(String pub) async {
    if (pub == _myPub()) return; // cannot remove yourself — use "leave group"
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(context.l10n.removeMemberTitle),
        content: Text(context.l10n.removeMemberContent(_name(pub, context))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.l10n.cancel)),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: Text(context.l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _loading = true);
    try {
      final storage   = ref.read(storageProvider);
      final messaging = ref.read(messagingServiceProvider);
      final transport = ref.read(compositeTransportProvider);

      // P7 per-post-wrap: no chain to evict — just remove the row.
      await storage.groups.removeMember(widget.groupId, pub);

      // Bump roster epoch so all future posts include the new epoch in
      // their signature transcript — receivers detect roster change.
      await storage.groups.bumpEpoch(widget.groupId);

      if (messaging != null) {
        final kickPayload = Uint8List.fromList(utf8.encode(jsonEncode({
          'type':     'group_kick',
          'group_id': widget.groupId,
          'kicked':   pub,
        })));

        // Notify ALL members including the kicked one (so they stop sending).
        final allRecipients = _memberPubs.where((p) => p != _myPub()).toList();
        for (final memberPub in allRecipients) {
          try {
            final contact = await storage.contacts.findByMasterPub(memberPub);
            final addrs = contact?.transportAddresses;
            final kickEnv = await messaging.encryptBox(memberPub, kickPayload);
            await transport.sendEnvelope(kickEnv, transportAddresses: addrs);
          } catch (_) {}
        }
      }

      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.l10n.memberRemovedMessage(_name(pub, context)))));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Delete group ──────────────────────────────────────────────────────────

  Future<void> _deleteGroup() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(context.l10n.deleteGroupTitle),
        content: Text(context.l10n.deleteGroupContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: Text(context.l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _loading = true);
    try {
      final storage  = ref.read(storageProvider);
      final messaging = ref.read(messagingServiceProvider);
      final transport = ref.read(compositeTransportProvider);

      final payload = Uint8List.fromList(utf8.encode(jsonEncode({
        'type': 'group_delete',
        'group_id': widget.groupId,
      })));

      // Notify all members except ourselves
      if (messaging != null) {
        final myPub = _myPub();
        for (final pub in _memberPubs) {
          if (pub == myPub) continue;
          try {
            final env = await messaging.encryptBox(pub, payload);
            final contact = await storage.contacts.findByMasterPub(pub);
            await transport.sendEnvelope(env,
                transportAddresses: contact?.transportAddresses);
          } catch (_) {}
        }
      }

      // Delete locally
      await storage.groups.deleteGroup(widget.groupId);

      if (mounted) context.go('/main');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool get _isAdmin => _myRole == GroupRole.admin;

  // ── Change role ────────────────────────────────────────────────────────────

  Future<void> _changeRole(String targetPub, String newRole) async {
    final storage   = ref.read(storageProvider);
    final messaging = ref.read(messagingServiceProvider);
    final transport = ref.read(compositeTransportProvider);
    if (messaging == null) return;

    // Admin cannot change their own role — use "leave group" flow instead
    if (targetPub == _myPub()) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Нельзя изменить свою роль. Используйте "Покинуть группу".')));
      return;
    }

    // Enforce max 3 admins
    if (newRole == GroupRole.admin) {
      final count = await storage.groups.adminCount(widget.groupId);
      if (count >= GroupRole.maxAdmins) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Максимум 3 администратора')));
        return;
      }
    }
    // Owner cannot be demoted
    if (targetPub == _ownerPub && newRole != GroupRole.admin) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Нельзя понизить создателя группы')));
      return;
    }

    setState(() => _loading = true);
    try {
      final myPub = _myPub();
      await storage.groups.setMemberRole(widget.groupId, targetPub, newRole);

      // Broadcast role change to all members
      final payload = Uint8List.fromList(utf8.encode(jsonEncode({
        'type': 'group_role_change',
        'group_id': widget.groupId,
        'target_pub': targetPub,
        'new_role': newRole,
        'changed_by': myPub,
      })));
      for (final pub in _memberPubs) {
        if (pub == myPub) continue;
        try {
          final env = await messaging.encryptBox(pub, payload);
          final contact = await storage.contacts.findByMasterPub(pub);
          await transport.sendEnvelope(env, transportAddresses: contact?.transportAddresses);
        } catch (_) {}
      }
      await _load();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final myPub = _myPub();

    return Scaffold(
      appBar: HubCoreAppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.canPop() ? context.pop() : context.go('/main'),
        ),
        title: Text(context.l10n.groupManagement),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                // Group name
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor: const Color(0xFF2AABEE),
                    child: Text(
                      _groupName.isNotEmpty ? _groupName[0].toUpperCase() : '#',
                      style: const TextStyle(color: Colors.white,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                  title: Text(_groupName.isNotEmpty ? _groupName : context.l10n.unnamedGroup,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 16)),
                  subtitle: Text(
                      _isAdmin ? context.l10n.tapToRename : context.l10n.adminLabel(_name(_adminPub ?? '', context)),
                      style: const TextStyle(fontSize: 12, color: Colors.white38)),
                  trailing: _isAdmin
                      ? const Icon(Icons.edit, size: 18, color: Colors.white38)
                      : null,
                  onTap: _isAdmin ? _rename : null,
                ),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    context.l10n.membersCount(_memberPubs.length),
                    style: const TextStyle(color: Colors.white54, fontSize: 13,
                        fontWeight: FontWeight.w600),
                  ),
                ),
                // Members list
                ..._memberPubs.map((pub) {
                  final name   = _name(pub, context);
                  final isMe   = pub == myPub;
                  final role   = _memberRoles[pub] ?? GroupRole.write;
                  final isOwner = pub == _ownerPub;
                  return ListTile(
                    leading: ContactAvatar(name: name, masterPub: pub, radius: 20),
                    title: Row(
                      children: [
                        Expanded(
                          child: Text(name,
                              style: const TextStyle(color: Colors.white),
                              overflow: TextOverflow.ellipsis),
                        ),
                        const SizedBox(width: 6),
                        _RoleBadge(role: role, isOwner: isOwner),
                      ],
                    ),
                    subtitle: isMe
                        ? null
                        : Text(pub.substring(0, 16),
                            style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11,
                                color: Colors.white38)),
                    trailing: isMe
                        ? null
                        : _isAdmin
                            ? PopupMenuButton<String>(
                                icon: const Icon(Icons.more_vert,
                                    color: Colors.white38, size: 20),
                                onSelected: (v) {
                                  if (v == 'remove') {
                                    _removeMember(pub);
                                  } else {
                                    _changeRole(pub, v);
                                  }
                                },
                                itemBuilder: (_) => [
                                  if (role != GroupRole.admin)
                                    const PopupMenuItem(
                                        value: GroupRole.admin,
                                        child: Text('Сделать администратором')),
                                  if (role != GroupRole.write)
                                    const PopupMenuItem(
                                        value: GroupRole.write,
                                        child: Text('Участник (может писать)')),
                                  if (role != GroupRole.read)
                                    const PopupMenuItem(
                                        value: GroupRole.read,
                                        child: Text('Только чтение')),
                                  if (role != GroupRole.banned)
                                    const PopupMenuItem(
                                        value: GroupRole.banned,
                                        child: Text('Заблокировать в группе')),
                                  const PopupMenuDivider(),
                                  PopupMenuItem(
                                    value: 'remove',
                                    child: Text(context.l10n.removeMemberTitle,
                                        style: const TextStyle(color: Colors.red)),
                                  ),
                                ],
                              )
                            : null,
                    onTap: isMe ? null : () => context.push('/chat/$pub'),
                  );
                }),
                const Divider(),
                // Add member button (admin only)
                if (_isAdmin)
                  ListTile(
                    leading: const Icon(Icons.person_add, color: Color(0xFF2AABEE)),
                    title: Text(context.l10n.addMember,
                        style: const TextStyle(color: Color(0xFF2AABEE))),
                    onTap: _addMember,
                  ),
                // Delete group button (admin only)
                if (_isAdmin) ...[
                  const Divider(),
                  ListTile(
                    leading: const Icon(Icons.delete_forever, color: Colors.red),
                    title: Text(context.l10n.deleteGroupTitle,
                        style: const TextStyle(color: Colors.red)),
                    onTap: _deleteGroup,
                  ),
                ],
              ],
            ),
    );
  }
}

class _RoleBadge extends StatelessWidget {
  final String role;
  final bool isOwner;
  const _RoleBadge({required this.role, this.isOwner = false});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (role) {
      GroupRole.admin  => (isOwner ? 'Создатель' : 'Админ', const Color(0xFFFFB300)),
      GroupRole.read   => ('Чтение',   Colors.blueGrey),
      GroupRole.banned => ('Бан',      Colors.red),
      _                => ('',         Colors.transparent),
    };
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(40),
        border: Border.all(color: color.withAlpha(120)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label,
          style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
    );
  }
}
