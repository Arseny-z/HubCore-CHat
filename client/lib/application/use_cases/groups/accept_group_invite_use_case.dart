import 'dart:convert';
import 'dart:typed_data';

import '../../../domain/entities/envelope.dart';
import '../../../domain/entities/group.dart';
import '../../../domain/entities/group_invite.dart';
import '../../../domain/repositories/group_repository.dart';
import '../../../infrastructure/crypto/messaging_service.dart' show MessagingService;
import '../../../shared/utils/logger.dart';
import '../../events/app_event_bus.dart';

/// Processes a received [GroupInvite] and joins the group.
///
/// Under the per-post-wrap scheme (P7) there is no chain to import —
/// the invite is just metadata: group_id + name + admin + roster + epoch.
/// We persist that locally and notify every member that we joined.
///
/// 1. Upsert the group with the supplied [GroupInvite.epoch].
/// 2. Upsert the admin as `role='admin'`.
/// 3. Upsert every other member as `role='write'`.
/// 4. Upsert ourselves as `role='write'`.
/// 5. Fan out `group_joined` (NaCl box) to every member so they can show
///    a system message.
/// 6. Emit [GroupJoinedEvent].
class AcceptGroupInviteUseCase {
  final GroupRepository _groups;
  final MessagingService _messaging;
  final AppEventBus _bus;
  final void Function(Envelope)? onSendRaw;

  AcceptGroupInviteUseCase({
    required GroupRepository groups,
    required MessagingService messaging,
    required AppEventBus bus,
    this.onSendRaw,
  })  : _groups = groups,
        _messaging = messaging,
        _bus = bus;

  /// Process [invite] and join the group. Returns the groupId on success.
  Future<String?> execute(GroupInvite invite) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // 1. Persist the group with the supplied epoch.
    await _groups.insertGroup(Group(
      groupId:   invite.groupId,
      name:      invite.name,
      adminPub:  invite.adminPub58,
      ownerPub:  invite.adminPub58,
      createdAt: now,
      epoch:     invite.epoch,
    ));

    // 2-4. Roster.
    final myPub = _messaging.myMasterPub58;
    final seen = <String>{};

    // Admin first — explicit role='admin'.
    await _upsertMemberOnce(
        invite.groupId, invite.adminPub58, GroupRole.admin, seen);

    // Other members (default write).
    for (final pub in invite.members) {
      await _upsertMemberOnce(invite.groupId, pub, GroupRole.write, seen);
    }

    // Ourselves — must be in roster too, otherwise we cannot send.
    await _upsertMemberOnce(invite.groupId, myPub, GroupRole.write, seen);

    // 5. Notify everyone we joined. Empty payload — no chain to share.
    await _broadcastJoined(invite.groupId, [...seen]);

    // 6. Event.
    _bus.emit(GroupJoinedEvent(groupId: invite.groupId, groupName: invite.name));
    return invite.groupId;
  }

  Future<void> _upsertMemberOnce(
    String groupId,
    String pub,
    String role,
    Set<String> seen,
  ) async {
    if (!seen.add(pub)) return;
    final existing = await _groups.member(groupId, pub);
    if (existing != null) return;
    await _groups.upsertMember(GroupMember(
      groupId:   groupId,
      masterPub: pub,
      chainKey:  Uint8List(0),    // Sender Keys is gone — placeholder until Phase 5 drops the column
      counter:   0,
      role:      role,
    ));
  }

  Future<void> _broadcastJoined(String groupId, List<String> memberPubs) async {
    final payload = Uint8List.fromList(utf8.encode(jsonEncode({
      'type':     'group_joined',
      'group_id': groupId,
    })));
    final myPub = _messaging.myMasterPub58;
    for (final pub in memberPubs) {
      if (pub == myPub) continue;
      try {
        final env = await _messaging.encryptBox(pub, payload);
        onSendRaw?.call(env);
      } catch (e) {
        AppLogger.w('AcceptGroupInvite',
            'group_joined to ${pub.substring(0, 8)}… failed: $e');
      }
    }
  }
}
