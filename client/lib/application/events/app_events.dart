import '../../domain/entities/message.dart';

/// Base class for all application-level events.
///
/// Events flow from Use Cases → AppEventBus → UI (or other Use Cases).
/// They replace the callback fields and fragmented streams that previously
/// lived on MessagingService, TtlService, and MessageRouter.
abstract class AppEvent {
  const AppEvent();
}

// ── Messaging ─────────────────────────────────────────────────────────────────

/// A new DM or group message was received and persisted.
class MessageReceivedEvent extends AppEvent {
  /// The conversation this message belongs to
  /// (masterPub for DM, groupId for group).
  final String conversationId;
  final bool isGroup;
  final String senderPub;

  const MessageReceivedEvent({
    required this.conversationId,
    required this.isGroup,
    required this.senderPub,
  });
}

/// A message was successfully sent (persisted + dispatched to transport).
class MessageSentEvent extends AppEvent {
  final int messageDbId;
  final String conversationId;

  const MessageSentEvent({
    required this.messageDbId,
    required this.conversationId,
  });
}

/// A delivery or read receipt arrived for one of our sent messages.
class MessageStatusUpdatedEvent extends AppEvent {
  final int messageDbId;
  final MessageStatus status;

  const MessageStatusUpdatedEvent({
    required this.messageDbId,
    required this.status,
  });
}

/// One or more messages were deleted (TTL sweep or peer ttl_delete request).
class MessagesDeletedEvent extends AppEvent {
  /// Conversations that had messages removed — UI should refresh these.
  final Set<String> conversationIds;

  const MessagesDeletedEvent({required this.conversationIds});
}

// ── Contacts ─────────────────────────────────────────────────────────────────

/// A contact_hello was received — contact may have been created or updated.
class ContactHelloReceivedEvent extends AppEvent {
  final String senderMasterPub;

  /// Yggdrasil address carried in the hello payload.
  final String yggAddress;

  const ContactHelloReceivedEvent({
    required this.senderMasterPub,
    required this.yggAddress,
  });
}

/// A contact's keys or metadata were updated (cert_update, alias change, etc.).
class ContactUpdatedEvent extends AppEvent {
  final String masterPub;

  const ContactUpdatedEvent({required this.masterPub});
}

/// Contact's security key has changed (epoch advanced — possible reinstall).
class ContactKeyChangeEvent extends AppEvent {
  final String contactPub;
  final int newEpoch;

  const ContactKeyChangeEvent({
    required this.contactPub,
    required this.newEpoch,
  });
}

// ── Groups ────────────────────────────────────────────────────────────────────

/// A group invite was received and is pending acceptance.
class GroupInviteReceivedEvent extends AppEvent {
  final String groupId;
  final String groupName;
  final String adminMasterPub;

  const GroupInviteReceivedEvent({
    required this.groupId,
    required this.groupName,
    required this.adminMasterPub,
  });
}

/// We successfully joined a group (invite accepted).
class GroupJoinedEvent extends AppEvent {
  final String groupId;
  final String groupName;

  const GroupJoinedEvent({required this.groupId, required this.groupName});
}

/// A group was deleted by the admin — all participants should remove it locally.
class GroupDeletedEvent extends AppEvent {
  final String groupId;

  const GroupDeletedEvent({required this.groupId});
}

/// Admin proposed transferring group ownership to us.
class GroupAdminTransferReceivedEvent extends AppEvent {
  final String groupId;
  final String fromPub;
  const GroupAdminTransferReceivedEvent({required this.groupId, required this.fromPub});
}

/// New admin accepted — group admin changed.
class GroupAdminChangedEvent extends AppEvent {
  final String groupId;
  final String newAdminPub;
  const GroupAdminChangedEvent({required this.groupId, required this.newAdminPub});
}

/// Proposed new admin declined the transfer.
class GroupAdminTransferDeclinedEvent extends AppEvent {
  final String groupId;
  const GroupAdminTransferDeclinedEvent({required this.groupId});
}

/// Queue retry attempt counter updated for a message.
class MessageRetryUpdatedEvent extends AppEvent {
  final String messageId; // wire messageId
  final int attempts;
  final int maxAttempts;

  const MessageRetryUpdatedEvent({
    required this.messageId,
    required this.attempts,
    required this.maxAttempts,
  });
}

// ── File transfer ─────────────────────────────────────────────────────────────

/// Progress update for an in-flight file transfer.
/// Emitted both for outgoing (sender) and incoming (receiver) transfers.
class FileTransferProgressEvent extends AppEvent {
  final int    messageId;   // DB message id of the placeholder/received message
  final double progress;    // 0.0 → 1.0
  final bool   done;        // true = transfer complete

  const FileTransferProgressEvent({
    required this.messageId,
    required this.progress,
    this.done = false,
  });
}

// ── Identity ──────────────────────────────────────────────────────────────────

/// The local signing key was rotated and broadcast sent to all contacts.
class SigningKeyRotatedEvent extends AppEvent {
  const SigningKeyRotatedEvent();
}

/// Fired on Device B when Device A confirms the pairing (ack received).
class DevicePairingAckEvent extends AppEvent {
  const DevicePairingAckEvent();
}

/// Fired on Device A when Device B's handshake is received and processed.
class DevicePairingCompleteEvent extends AppEvent {
  const DevicePairingCompleteEvent();
}

/// Fired when profile_sync from another own device is applied locally.
/// UI should refresh alias/avatar display.
class ProfileSyncedEvent extends AppEvent {
  const ProfileSyncedEvent();
}
