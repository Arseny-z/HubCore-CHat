import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../application/events/app_events.dart'
    show GroupInviteReceivedEvent, GroupAdminTransferReceivedEvent;
import '../../application/use_cases/groups/accept_group_invite_use_case.dart';
import '../../domain/entities/group_invite.dart';
import '../../domain/entities/message.dart';
import '../../shared/providers/app_providers.dart';
import '../../shared/providers/crypto_providers.dart';
import '../../shared/utils/pubkey_codec.dart';
import '../../shared/widgets/hubcore_app_bar.dart';
import '../../storage/dao/notifications_dao.dart';

class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() =>
      _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  List<AppNotification> _items = [];
  bool _loading = true;
  StreamSubscription? _inviteSub;
  StreamSubscription? _transferSub;

  @override
  void initState() {
    super.initState();
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) => _subscribe());
  }

  void _subscribe() {
    final bus = ref.read(eventBusProvider);
    _inviteSub   = bus.on<GroupInviteReceivedEvent>().listen((_) { if (mounted) _load(); });
    _transferSub = bus.on<GroupAdminTransferReceivedEvent>().listen((_) { if (mounted) _load(); });
  }

  @override
  void dispose() {
    _inviteSub?.cancel();
    _transferSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final storage = ref.read(storageProvider);
    if (!storage.isOpen) return;
    final items = await storage.notifications.pending();
    if (mounted) setState(() { _items = items; _loading = false; });
  }

  Future<void> _accept(AppNotification n) async {
    final storage = ref.read(storageProvider);
    final groupMessaging = ref.read(groupMessagingProvider);
    final messaging = ref.read(messagingServiceProvider);
    final bus = ref.read(eventBusProvider);
    if (groupMessaging == null || messaging == null || !storage.isOpen) return;

    final invite = GroupInvite.tryDecode(
        Uint8List.fromList(utf8.encode(n.payload)));
    if (invite == null) return;

    // Use AcceptGroupInviteUseCase for chain sync + event emission
    final useCase = AcceptGroupInviteUseCase(
      groupMessaging: groupMessaging,
      messaging: messaging,
      bus: bus,
      onSendRaw: (env) {
        final transport = ref.read(compositeTransportProvider);
        // Find contact ygg address for routing
        storage.contacts.findByMasterPub(env.to).then((c) {
          transport.sendEnvelope(env, transportAddresses: c?.transportAddresses);
        });
      },
    );
    final groupId = await useCase.execute(invite);
    await storage.notifications.updateStatus(n.id!, 'accepted');

    // Save system message "Вы вступили в группу"
    if (groupId != null) {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await storage.messages.insert(Message(
        conversationId: groupId,
        isGroup: true,
        senderPub: 'system',
        body: 'Вы вступили в группу',
        contentType: ContentType.system,
        sentAt: now,
        receivedAt: now,
        status: MessageStatus.delivered,
      ));
    }

    await _load();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Вы вступили в группу «${invite.name}»')),
      );
      // Navigate to group chat
      if (groupId != null) context.go('/group/$groupId');
    }
  }

  Future<void> _decline(AppNotification n) async {
    final storage = ref.read(storageProvider);
    if (!storage.isOpen) return;
    await storage.notifications.updateStatus(n.id!, 'declined');
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: HubCoreAppBar(
        title: const Text('Уведомления'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? const Center(
                  child: Text(
                    'Нет уведомлений',
                    style: TextStyle(color: Colors.white38, fontSize: 15),
                  ),
                )
              : ListView.builder(
                  itemCount: _items.length,
                  itemBuilder: (_, i) => _buildItem(_items[i]),
                ),
    );
  }

  Future<void> _acceptAdminTransfer(AppNotification n) async {
    final storage   = ref.read(storageProvider);
    final messaging = ref.read(messagingServiceProvider);
    final transport = ref.read(compositeTransportProvider);
    final identity  = ref.read(identityNotifierProvider);
    if (messaging == null || identity == null || !storage.isOpen) return;

    final myPub = PubkeyCodec.encode(identity.masterPublicKey);
    String? groupId;
    String? fromPub;
    try {
      final m = jsonDecode(n.payload) as Map<String, dynamic>;
      groupId = m['group_id'] as String?;
      fromPub = m['from_pub'] as String?;
    } catch (_) {}
    if (groupId == null || fromPub == null) return;

    // Update admin locally
    await storage.groups.setAdmin(groupId, myPub);

    // Notify original admin that we accepted
    final payload = Uint8List.fromList(utf8.encode(jsonEncode({
      'type': 'group_admin_transfer_accepted',
      'group_id': groupId,
      'new_admin': myPub,
    })));
    try {
      final env = await messaging.encryptBox(fromPub, payload);
      final contact = await storage.contacts.findByMasterPub(fromPub);
      await transport.sendEnvelope(env, transportAddresses: contact?.transportAddresses);
    } catch (_) {}

    await storage.notifications.updateStatus(n.id!, 'accepted');
    await _load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Вы стали администратором группы')),
      );
    }
  }

  Future<void> _declineAdminTransfer(AppNotification n) async {
    final storage   = ref.read(storageProvider);
    final messaging = ref.read(messagingServiceProvider);
    final transport = ref.read(compositeTransportProvider);
    if (messaging == null || !storage.isOpen) return;

    String? groupId;
    String? fromPub;
    try {
      final m = jsonDecode(n.payload) as Map<String, dynamic>;
      groupId = m['group_id'] as String?;
      fromPub = m['from_pub'] as String?;
    } catch (_) {}
    if (groupId == null || fromPub == null) return;

    // Notify original admin that we declined
    final payload = Uint8List.fromList(utf8.encode(jsonEncode({
      'type': 'group_admin_transfer_declined',
      'group_id': groupId,
    })));
    try {
      final env = await messaging.encryptBox(fromPub, payload);
      final contact = await storage.contacts.findByMasterPub(fromPub);
      await transport.sendEnvelope(env, transportAddresses: contact?.transportAddresses);
    } catch (_) {}

    await storage.notifications.updateStatus(n.id!, 'declined');
    await _load();
  }

  Widget _buildItem(AppNotification n) {
    if (n.type == 'group_invite') {
      return _buildGroupInvite(n);
    }
    if (n.type == 'group_admin_transfer') {
      return _buildAdminTransfer(n);
    }
    return const SizedBox.shrink();
  }

  Widget _buildAdminTransfer(AppNotification n) {
    String groupId = '?';
    String fromPub = n.fromPub;
    try {
      final m = jsonDecode(n.payload) as Map<String, dynamic>;
      groupId = m['group_id'] as String? ?? '?';
      fromPub = m['from_pub'] as String? ?? n.fromPub;
    } catch (_) {}
    final fromShort = fromPub.length > 8 ? fromPub.substring(0, 8) : fromPub;
    final groupShort = groupId.length > 8 ? groupId.substring(0, 8) : groupId;

    return Card(
      color: const Color(0xFF1C2733),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const CircleAvatar(
                  radius: 20,
                  backgroundColor: Colors.orange,
                  child: Icon(Icons.admin_panel_settings, color: Colors.white, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Передача прав администратора',
                          style: TextStyle(color: Colors.white70, fontSize: 12)),
                      const SizedBox(height: 2),
                      Text('Группа: $groupShort…',
                          style: const TextStyle(color: Colors.white,
                              fontWeight: FontWeight.w600, fontSize: 15)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('От: $fromShort…',
                style: const TextStyle(color: Colors.white38, fontSize: 13)),
            const SizedBox(height: 4),
            const Text('Текущий администратор хочет передать вам права управления группой.',
                style: TextStyle(color: Colors.white60, fontSize: 13)),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => _declineAdminTransfer(n),
                  child: const Text('Отказаться',
                      style: TextStyle(color: Colors.white54)),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () => _acceptAdminTransfer(n),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('Принять'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupInvite(AppNotification n) {
    String groupName = '?';
    String adminPub = n.fromPub;
    int memberCount = 0;
    try {
      final m = jsonDecode(n.payload) as Map<String, dynamic>;
      groupName = m['name'] as String? ?? '?';
      adminPub = m['admin'] as String? ?? n.fromPub;
      memberCount = (m['members'] as List?)?.length ?? 0;
    } catch (_) {}

    final adminShort = adminPub.length > 8 ? adminPub.substring(0, 8) : adminPub;
    final time = DateTime.fromMillisecondsSinceEpoch(n.createdAt * 1000);
    final timeStr = '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';

    return Card(
      color: const Color(0xFF1C2733),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: const Color(0xFF2AABEE),
                  child: Text(
                    groupName.isNotEmpty ? groupName[0].toUpperCase() : '#',
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Приглашение в группу',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        groupName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  timeStr,
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'От: $adminShort',
              style: const TextStyle(color: Colors.white38, fontSize: 13),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => _decline(n),
                  child: const Text(
                    'Отклонить',
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () => _accept(n),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2AABEE),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text('Принять'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

}
