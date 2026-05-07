import 'dart:convert';
import 'dart:typed_data';

import '../../events/app_event_bus.dart';
import '../../../infrastructure/crypto/group_messaging_service.dart' show GroupMessagingService;
import '../../../shared/utils/logger.dart';
import '../../../infrastructure/crypto/messaging_service.dart' show MessagingService;
import '../../../domain/entities/group_invite.dart';
import '../../../domain/entities/envelope.dart';

/// Processes a received [GroupInvite] and joins the group.
///
/// Business rules enforced here:
///   1. Group record is upserted in the DB (delegated to [GroupMessagingService.acceptInvite]).
///   2. Admin's sender chain is imported; our own chain is created.
///   3. Our chain state is sent back to admin and other members via NaCl box
///      so they can decrypt our future messages.
///   4. [GroupJoinedEvent] is emitted on success.
class AcceptGroupInviteUseCase {
  final GroupMessagingService _groupMessaging;
  final MessagingService _messaging;
  final AppEventBus _bus;
  final void Function(Envelope)? onSendRaw;

  AcceptGroupInviteUseCase({
    required GroupMessagingService groupMessaging,
    required MessagingService messaging,
    required AppEventBus bus,
    this.onSendRaw,
  })  : _groupMessaging = groupMessaging,
        _messaging = messaging,
        _bus = bus;

  /// Process [invite] and join the group.
  ///
  /// Returns the groupId on success, or null if the invite is malformed.
  Future<String?> execute(GroupInvite invite) async {
    final groupId = await _groupMessaging.acceptInvite(invite);
    if (groupId == null) return null;

    // Send our chain state to all members so they can decrypt our messages.
    // This is critical — without this, other members have all-zero placeholder
    // chains for us and can't decrypt anything we send.
    await _syncChainToMembers(groupId, invite.members);

    _bus.emit(GroupJoinedEvent(groupId: groupId, groupName: invite.name));
    return groupId;
  }

  /// Notify all members that we joined + send our chain state.
  Future<void> _syncChainToMembers(
    String groupId,
    List<String> memberPubs,
  ) async {
    final chainPayload = await _groupMessaging.buildInvitePayload(groupId);

    // Build "group_joined" notification with our chain state embedded
    final joinedMsg = jsonEncode({
      'type': 'group_joined',
      'group_id': groupId,
      if (chainPayload != null) 'chain': base64Encode(chainPayload),
    });
    final plain = Uint8List.fromList(utf8.encode(joinedMsg));

    final myPub = _messaging.myMasterPub58;
    for (final pub in memberPubs) {
      if (pub == myPub) continue; // skip self
      try {
        final env = await _messaging.encryptBox(pub, plain);
        onSendRaw?.call(env);
        AppLogger.d('AcceptGroupInvite', 'group_joined sent to ${pub.substring(0, 8)}…');
      } catch (e) {
        AppLogger.w('AcceptGroupInvite', 'chain sync to ${pub.substring(0, 8)}… failed: $e');
      }
    }
  }
}
