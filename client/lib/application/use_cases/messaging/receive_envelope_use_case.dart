import 'dart:convert';
import 'dart:typed_data';

import '../../../domain/entities/contact.dart';
import '../../../domain/entities/message.dart';
import '../../../shared/utils/logger.dart';
import '../../../domain/ports/crypto_port.dart';
import '../../../domain/repositories/contact_repository.dart';
import '../../../domain/repositories/message_repository.dart';
import '../../events/app_event_bus.dart';
import '../../../domain/entities/envelope.dart';
import '../../../domain/entities/file_transfer.dart';
import '../../../domain/entities/group_invite.dart';
import 'process_receipt_use_case.dart';
import '../../../infrastructure/crypto/multi_device_payload_codec.dart';
import '../../../infrastructure/crypto/multi_session_manager.dart';

/// Routes and processes an incoming [Envelope].
///
/// Handles:
///   1. file_ack    — raw JSON, injected into FileService
///   2. file_offer  — NaCl box containing FileOffer, delegated to FileService
///   3. file_chunk  — raw JSON chunk, delegated to FileService
///   4. box         — NaCl box (system: ttl_delete, receipts)
///   5. JSON        — contact_hello, cert_update
///   6. DM          — Double Ratchet ciphertext
class ReceiveEnvelopeUseCase {
  final CryptoPort _crypto;
  final ContactRepository _contacts;
  final MessageRepository _messages;
  final AppEventBus _bus;
  final String _myPub58;

  /// Reads local TTL setting for a conversation (fallback for old clients).
  final Future<int?> Function(String conversationId) _readTtl;

  /// Called to send a raw envelope (e.g. delivery receipt, ack).
  final void Function(Envelope env)? onSendRaw;

  /// Called when a contact_hello updates a contact's keys.
  final Future<void> Function(String masterPub, Map<String, dynamic> json)? onContactHello;

  /// Called when a contact_hello arrives — triggers sending our hello back
  /// so the sender gets our latest addresses (Yggdrasil + Reticulum).
  void Function(String senderPub)? onContactHelloReply;

  /// Called when a cert_update arrives.
  final void Function(String masterPub, Map<String, dynamic> json)? onCertUpdate;

  /// Called when a file_offer (box-encrypted) arrives.
  /// Args: senderMasterPub58, senderYggPubKeyHex (may be null), offer.
  final Future<void> Function(String, String?, FileOffer)? onFileOffer;

  /// Called when a raw file_chunk arrives.
  /// Returns file name when all chunks received, null otherwise.
  final Future<String?> Function(String senderPub, FileChunk chunk)? onFileChunk;

  /// Called when a raw file_ack arrives.
  final void Function(FileAck ack)? onFileAck;

  /// Called when a file_cancel arrives — asks FileService to abort incoming transfer.
  final void Function(String transferId)? onFileCancel;

  /// Called when a group_msg envelope arrives.
  /// Returns plaintext if decrypted successfully, null otherwise.
  final Future<String?> Function(Envelope envelope)? onGroupMessage;

  /// Called when a group_invite is received inside a DM.
  final Future<String?> Function(GroupInvite invite)? onGroupInvite;

  /// Called when a group_joined is received — import member's chain into existing group.
  final Future<void> Function(String groupId, String memberPub, Uint8List chainBlob)? onImportMemberChain;

  /// Called when group_rename received — update group name locally.
  final Future<void> Function(String groupId, String newName)? onGroupRename;

  /// Called when group_kick received — remove member locally.
  final Future<void> Function(String groupId, String kickedPub)? onGroupRemoveMember;

  /// Called when group_delete received — delete group and all its data locally.
  final Future<void> Function(String groupId)? onGroupDelete;

  /// Returns the admin pubkey for a group. Used to verify admin-only operations.
  final Future<String?> Function(String groupId)? getGroupAdmin;

  /// Called to save a notification (e.g. group_invite) to the DB.
  final Future<void> Function(String type, String payload, String fromPub)? onSaveNotification;

  /// Multi-device session manager for v=2 envelope decryption.
  final MultiSessionManager? multiSessionManager;

  /// Called to decrypt a v=2 multi-device envelope.
  final Future<String?> Function(Envelope, MultiDevicePayload)? onReceiveMultiDevice;

  /// Called when a device_sync_request arrives from another own device.
  final Future<void> Function(String deviceId, Map<String, String> addrs, int sinceTs)? onDeviceSyncRequest;

  /// Called when a device_sync_response arrives with pending payloads.
  final Future<void> Function(List<String> payloadsB64)? onDeviceSyncResponse;

  /// Called when a profile_sync arrives from another own device.
  final Future<void> Function(Map<String, dynamic> json)? onProfileSync;

  /// Called on Device A when a device_pairing_handshake arrives from Device B.
  final Future<void> Function(Map<String, dynamic> json, Map<String, String> addrs)? onDevicePairingHandshake;

  /// Called on Device B when a device_pairing_ack arrives from Device A.
  final Future<void> Function(Map<String, dynamic> json)? onDevicePairingAck;

  /// Called when group admin ownership is transferred to a new member.
  final Future<void> Function(String groupId, String newAdminPub)? onSetGroupAdmin;

  /// Called to change a member's role in a group.
  final Future<void> Function(String groupId, String masterPub, String role)? onSetMemberRole;

  /// Returns a member's current role. Used to verify admin-only operations.
  final Future<String?> Function(String groupId, String masterPub)? onGetMemberRole;

  /// Returns current admin count for a group.
  final Future<int> Function(String groupId)? onGetAdminCount;

  /// Returns owner pubkey for a group.
  final Future<String?> Function(String groupId)? onGetOwnerPub;

  /// Called when a new stranger writes for the first time — send them our
  /// public profile (name + public avatar) so they see who they're talking to.
  void Function(String senderPub, Map<String, String> transportAddresses)? onSendPublicHello;

  /// Called when DM decryption fails — triggers a contact_hello back to sender
  /// so the sender resets their session too.
  void Function(String senderPub)? onSessionDesync;

  /// Unified receipt processor — replaces onMarkDelivered/onMarkRead callbacks.
  final ProcessReceiptUseCase? processReceipt;

  ReceiveEnvelopeUseCase({
    required CryptoPort crypto,
    required ContactRepository contacts,
    required MessageRepository messages,
    required AppEventBus bus,
    required Future<int?> Function(String) readTtl,
    required String myPub58,
    this.onSendRaw,
    this.onContactHello,
    this.onCertUpdate,
    this.onFileOffer,
    this.onFileChunk,
    this.onFileAck,
    this.onFileCancel,
    this.onGroupMessage,
    this.onGroupInvite,
    this.onImportMemberChain,
    this.onGroupRename,
    this.onGroupRemoveMember,
    this.onGroupDelete,
    this.onSaveNotification,
    this.onSendPublicHello,
    this.multiSessionManager,
    this.onReceiveMultiDevice,
    this.onDeviceSyncRequest,
    this.onDeviceSyncResponse,
    this.onProfileSync,
    this.onDevicePairingHandshake,
    this.onDevicePairingAck,
    this.onSetGroupAdmin,
    this.onSetMemberRole,
    this.onGetMemberRole,
    this.onGetAdminCount,
    this.onGetOwnerPub,
    this.onSessionDesync,
    this.processReceipt,
    this.getGroupAdmin,
  })  : _crypto = crypto,
        _contacts = contacts,
        _messages = messages,
        _bus = bus,
        _myPub58 = myPub58,
        _readTtl = readTtl;

  /// Process [envelope] and return the plaintext if it was a regular DM,
  /// or null for system messages / failed decryption.
  Future<String?> execute(Envelope envelope) async {
    final senderPub = envelope.from;

    // ── Own-device messages: handle before contact lookup ─────────────────
    // device_sync packets come from our own masterPub — skip contact logic.
    if (senderPub == _myPub58) {
      try {
        final json = jsonDecode(utf8.decode(envelope.body)) as Map<String, dynamic>;
        final type = json['type'] as String?;
        if (type == 'device_sync_request') {
          final sinceTs   = json['since_ts'] as int? ?? 0;
          final requester = json['device_id'] as String? ?? senderPub;
          await onDeviceSyncRequest?.call(requester, {}, sinceTs);
          return null;
        }
        if (type == 'device_sync_response') {
          final payloads = (json['payloads'] as List?)?.cast<String>() ?? [];
          await onDeviceSyncResponse?.call(payloads);
          return null;
        }
        if (type == 'profile_sync') {
          await onProfileSync?.call(json);
          return null;
        }
        if (type == 'device_pairing_handshake') {
          await onDevicePairingHandshake?.call(json, {});
          return null;
        }
        if (type == 'device_pairing_ack') {
          await onDevicePairingAck?.call(json);
          return null;
        }
      } catch (_) {}
      return null; // drop all other self-addressed packets
    }

    // ── Auto-add unknown sender ───────────────────────────────────────────
    var contact = await _contacts.findByMasterPub(senderPub);
    if (contact == null) {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await _contacts.insert(Contact(
        masterPub:    senderPub,
        signingPub:   senderPub,
        alias:        senderPub.length > 8 ? senderPub.substring(0, 8) : senderPub,
        addedAt:      now,
        relationship: 'stranger',
      ));
      contact = await _contacts.findByMasterPub(senderPub);
      if (contact == null) return null;
      _bus.emit(ContactUpdatedEvent(masterPub: senderPub));
      // Send our public profile back so the stranger sees our name/avatar
      onSendPublicHello?.call(senderPub, contact.transportAddresses);
    }

    // Silently drop everything from blocked contacts.
    if (contact.isBlocked) return null;

    // ── Multi-device v=2 payload ──────────────────────────────────────────
    if (multiSessionManager != null) {
      final mdPayload = MultiDevicePayload.tryDecode(envelope.body);
      if (mdPayload != null) {
        final plain = await onReceiveMultiDevice?.call(envelope, mdPayload);
        if (plain != null) {
          _bus.emit(MessageReceivedEvent(
            conversationId: senderPub,
            isGroup: false,
            senderPub: senderPub,
          ));
        }
        return plain;
      }
    }

    // ── file_ack (raw JSON, no encryption) ────────────────────────────────
    final rawAck = FileAck.tryDecode(envelope.body);
    if (rawAck != null) {
      onFileAck?.call(rawAck);
      return null;
    }

    // ── file_chunk (raw JSON, no encryption) ──────────────────────────────
    final rawChunk = FileChunk.tryDecode(envelope.body);
    if (rawChunk != null) {
      final fileName = await onFileChunk?.call(senderPub, rawChunk);
      if (fileName != null) {
        _bus.emit(MessageReceivedEvent(
          conversationId: senderPub,
          isGroup: false,
          senderPub: senderPub,
        ));
      }
      return fileName;
    }

    // ── Try box (system messages + file_offer + group_invite) ─────────────
    final boxPlain = _crypto.decryptBox(envelope.body);
    if (boxPlain != null) {
      // Check for group_joined notification first
      try {
        final boxJson = jsonDecode(utf8.decode(boxPlain)) as Map<String, dynamic>;
        if (boxJson['type'] == 'group_joined') {
          final groupId = boxJson['group_id'] as String?;
          AppLogger.d('ReceiveUC', 'group_joined from $senderPub for group=$groupId');
          // Verify sender was actually invited — must exist in group_members
          if (groupId != null) {
            final existingRole = await onGetMemberRole?.call(groupId, senderPub);
            if (existingRole == null) {
              AppLogger.w('ReceiveUC',
                  'group_joined REJECTED: $senderPub not in members of $groupId');
              return null;
            }
            if (existingRole == 'banned') {
              AppLogger.w('ReceiveUC',
                  'group_joined REJECTED: $senderPub is banned in $groupId');
              return null;
            }
          }
          // Import their chain state (NOT via acceptInvite — that would overwrite the group)
          final chainB64 = boxJson['chain'] as String?;
          if (chainB64 != null && groupId != null && onImportMemberChain != null) {
            final chainBytes = base64Decode(chainB64);
            final chainInvite = GroupInvite.tryDecode(chainBytes);
            if (chainInvite != null) {
              await onImportMemberChain!(groupId, senderPub, chainInvite.chainKeyBlob);
              AppLogger.d('ReceiveUC', 'imported member chain from $senderPub for group=$groupId');
            }
          }
          // Save system message in group chat
          if (groupId != null) {
            final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
            final shortPub = senderPub.length > 8
                ? senderPub.substring(0, 8)
                : senderPub;
            // Look up contact alias
            final c = await _contacts.findByMasterPub(senderPub);
            final name = (c?.alias.isNotEmpty == true) ? c!.alias : shortPub;
            await _messages.insert(Message(
              conversationId: groupId,
              isGroup: true,
              senderPub: 'system',
              body: '$name вступил в группу',
              contentType: ContentType.system,
              sentAt: now,
              receivedAt: now,
              status: MessageStatus.delivered,
            ));
            _bus.emit(MessageReceivedEvent(
              conversationId: groupId,
              isGroup: true,
              senderPub: 'system',
            ));
            _bus.emit(GroupJoinedEvent(groupId: groupId, groupName: ''));
          }
          // No notification needed — system message in chat is enough
          return null;
        }

        // group_rename — admin renamed the group
        if (boxJson['type'] == 'group_rename') {
          final groupId = boxJson['group_id'] as String?;
          final newName = boxJson['name'] as String?;
          if (groupId != null && newName != null) {
            // Verify sender is admin via role system
            final senderRole = await onGetMemberRole?.call(groupId, senderPub);
            if (senderRole != 'admin') {
              // Fallback to legacy adminPub for backward compat with old clients
              final admin = await getGroupAdmin?.call(groupId);
              if (admin != null && admin != senderPub) {
                AppLogger.w('ReceiveUC', 'group_rename REJECTED: $senderPub is not admin of $groupId');
                return null;
              }
            }
            await onGroupRename?.call(groupId, newName);
            final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
            final c = await _contacts.findByMasterPub(senderPub);
            final name = (c?.alias.isNotEmpty == true) ? c!.alias : senderPub.substring(0, 8);
            await _messages.insert(Message(
              conversationId: groupId, isGroup: true, senderPub: 'system',
              body: '$name переименовал группу в "$newName"',
              contentType: ContentType.system, sentAt: now, receivedAt: now,
              status: MessageStatus.delivered,
            ));
            _bus.emit(MessageReceivedEvent(
                conversationId: groupId, isGroup: true, senderPub: 'system'));
          }
          return null;
        }

        // group_role_change — admin changed a member's role
        if (boxJson['type'] == 'group_role_change') {
          final groupId   = boxJson['group_id']   as String?;
          final targetPub = boxJson['target_pub'] as String?;
          final newRole   = boxJson['new_role']   as String?;
          if (groupId != null && targetPub != null && newRole != null) {
            // Verify sender is admin in group_members
            final senderRole = await onGetMemberRole?.call(groupId, senderPub);
            if (senderRole != 'admin') {
              AppLogger.w('ReceiveUC', 'group_role_change REJECTED: $senderPub is not admin');
              return null;
            }
            // Enforce max 3 admins
            if (newRole == 'admin') {
              final count = await onGetAdminCount?.call(groupId) ?? 0;
              if (count >= 3) {
                AppLogger.w('ReceiveUC', 'group_role_change REJECTED: max 3 admins reached');
                return null;
              }
            }
            // Owner cannot be demoted
            final ownerPub = await onGetOwnerPub?.call(groupId);
            if (ownerPub != null && targetPub == ownerPub && newRole != 'admin') {
              AppLogger.w('ReceiveUC', 'group_role_change REJECTED: cannot demote owner');
              return null;
            }
            await onSetMemberRole?.call(groupId, targetPub, newRole);
            final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
            final tc = await _contacts.findByMasterPub(targetPub);
            final tName = tc?.alias.isNotEmpty == true ? tc!.alias : targetPub.substring(0, 8);
            final roleLabel = _roleLabel(newRole);
            await _messages.insert(Message(
              conversationId: groupId, isGroup: true, senderPub: 'system',
              body: '$tName — роль изменена на "$roleLabel"',
              contentType: ContentType.system, sentAt: now, receivedAt: now,
              status: MessageStatus.delivered,
            ));
            _bus.emit(MessageReceivedEvent(
                conversationId: groupId, isGroup: true, senderPub: 'system'));
          }
          return null;
        }

        // group_chain_update — member rotated their chain (e.g. after kick)
        if (boxJson['type'] == 'group_chain_update') {
          final groupId = boxJson['group_id'] as String?;
          final chainB64 = boxJson['chain'] as String?;
          if (groupId != null && chainB64 != null && onImportMemberChain != null) {
            final chainBytes = base64Decode(chainB64);
            final chainInvite = GroupInvite.tryDecode(chainBytes);
            if (chainInvite != null) {
              await onImportMemberChain!(groupId, senderPub, chainInvite.chainKeyBlob);
            }
          }
          return null;
        }

        // group_left — member voluntarily left the group
        if (boxJson['type'] == 'group_left') {
          final groupId = boxJson['group_id'] as String?;
          if (groupId != null) {
            await onGroupRemoveMember?.call(groupId, senderPub);
            final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
            final c = await _contacts.findByMasterPub(senderPub);
            final name = (c?.alias.isNotEmpty == true)
                ? c!.alias : senderPub.substring(0, 8);
            await _messages.insert(Message(
              conversationId: groupId, isGroup: true, senderPub: 'system',
              body: '$name покинул группу',
              contentType: ContentType.system, sentAt: now, receivedAt: now,
              status: MessageStatus.delivered,
            ));
            _bus.emit(MessageReceivedEvent(
                conversationId: groupId, isGroup: true, senderPub: 'system'));
          }
          return null;
        }

        // group_kick — admin removed a member
        if (boxJson['type'] == 'group_kick') {
          final groupId = boxJson['group_id'] as String?;
          final kickedPub = boxJson['kicked'] as String?;
          final myPub = _myPub58;
          if (groupId != null && kickedPub != null) {
            // Verify sender is admin via role system (with legacy fallback)
            final senderRole = await onGetMemberRole?.call(groupId, senderPub);
            if (senderRole != 'admin') {
              final admin = await getGroupAdmin?.call(groupId);
              if (admin != null && admin != senderPub) {
                AppLogger.w('ReceiveUC', 'group_kick REJECTED: $senderPub is not admin of $groupId');
                return null;
              }
            }
            if (kickedPub == myPub) {
              // We were kicked — leave group locally
              await onGroupRemoveMember?.call(groupId, myPub);
              final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
              await _messages.insert(Message(
                conversationId: groupId, isGroup: true, senderPub: 'system',
                body: 'Вы были удалены из группы',
                contentType: ContentType.system, sentAt: now, receivedAt: now,
                status: MessageStatus.delivered,
              ));
            } else {
              // Someone else was kicked — remove them locally
              await onGroupRemoveMember?.call(groupId, kickedPub);
              final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
              final c = await _contacts.findByMasterPub(kickedPub);
              final name = (c?.alias.isNotEmpty == true)
                  ? c!.alias : kickedPub.substring(0, 8);
              await _messages.insert(Message(
                conversationId: groupId, isGroup: true, senderPub: 'system',
                body: '$name удалён из группы',
                contentType: ContentType.system, sentAt: now, receivedAt: now,
                status: MessageStatus.delivered,
              ));
            }
            _bus.emit(MessageReceivedEvent(
                conversationId: groupId, isGroup: true, senderPub: 'system'));
          }
          return null;
        }

        // group_admin_transfer — admin proposes transferring ownership to us
        if (boxJson['type'] == 'group_admin_transfer') {
          final groupId  = boxJson['group_id'] as String?;
          final newAdmin = boxJson['new_admin'] as String?;
          final myPub    = _myPub58;
          if (groupId != null && newAdmin == myPub) {
            // Verify sender is admin via role system (with legacy fallback)
            final senderRole = await onGetMemberRole?.call(groupId, senderPub);
            final isAdmin = senderRole == 'admin' ||
                (await getGroupAdmin?.call(groupId)) == senderPub;
            if (!isAdmin) {
              AppLogger.w('ReceiveUC', 'group_admin_transfer REJECTED: $senderPub is not admin of $groupId');
              return null;
            }
            // Save as pending notification so the user can Accept/Decline
            await onSaveNotification?.call(
              'group_admin_transfer',
              jsonEncode({'group_id': groupId, 'from_pub': senderPub}),
              senderPub,
            );
            _bus.emit(GroupAdminTransferReceivedEvent(
                groupId: groupId, fromPub: senderPub));
          }
          return null;
        }

        // group_admin_transfer_accepted — new admin accepted ownership
        if (boxJson['type'] == 'group_admin_transfer_accepted') {
          final groupId  = boxJson['group_id'] as String?;
          final newAdmin = boxJson['new_admin'] as String?;
          if (groupId != null && newAdmin != null) {
            final admin = await getGroupAdmin?.call(groupId);
            if (admin == null || admin != _myPub58) {
              return null; // only current admin processes this
            }
            await onSetGroupAdmin?.call(groupId, newAdmin);
            final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
            final c = await _contacts.findByMasterPub(newAdmin);
            final name = c?.alias.isNotEmpty == true ? c!.alias : newAdmin.substring(0, 8);
            await _messages.insert(Message(
              conversationId: groupId, isGroup: true, senderPub: 'system',
              body: '$name стал новым администратором',
              contentType: ContentType.system, sentAt: now, receivedAt: now,
              status: MessageStatus.delivered,
            ));
            _bus.emit(MessageReceivedEvent(
                conversationId: groupId, isGroup: true, senderPub: 'system'));
            _bus.emit(GroupAdminChangedEvent(groupId: groupId, newAdminPub: newAdmin));
          }
          return null;
        }

        // group_admin_transfer_declined — proposed new admin declined
        if (boxJson['type'] == 'group_admin_transfer_declined') {
          final groupId = boxJson['group_id'] as String?;
          if (groupId != null) {
            _bus.emit(GroupAdminTransferDeclinedEvent(groupId: groupId));
          }
          return null;
        }

        // group_delete — admin dissolved the group
        if (boxJson['type'] == 'group_delete') {
          final groupId = boxJson['group_id'] as String?;
          if (groupId != null) {
            // Verify sender is admin via role system (with legacy fallback)
            final senderRole = await onGetMemberRole?.call(groupId, senderPub);
            if (senderRole != 'admin') {
              final admin = await getGroupAdmin?.call(groupId);
              if (admin != null && admin != senderPub) {
                AppLogger.w('ReceiveUC', 'group_delete REJECTED: $senderPub is not admin of $groupId');
                return null;
              }
            }
            await onGroupDelete?.call(groupId);
            _bus.emit(GroupDeletedEvent(groupId: groupId));
          }
          return null;
        }
      } catch (_) {
        // Not JSON — fall through to other decoders
      }

      // group_invite comes as NaCl box
      final invite = GroupInvite.tryDecode(boxPlain);
      if (invite != null) {
        AppLogger.d('ReceiveUC', 'box group_invite detected! group=${invite.groupId}');
        await onSaveNotification?.call(
          'group_invite', utf8.decode(boxPlain), senderPub);
        _bus.emit(GroupInviteReceivedEvent(
          groupId: invite.groupId,
          groupName: invite.name,
          adminMasterPub: invite.adminPub58,
        ));
        return null;
      }
      // file_offer comes as NaCl box
      final offer = FileOffer.tryDecode(boxPlain);
      if (offer != null) {
        await onFileOffer?.call(senderPub, contact.yggPubKeyHex, offer);
        return null;
      }
      return await _handleBoxMessage(senderPub, boxPlain);
    }

    // ── Try plain JSON system messages (contact_hello, cert_update) ───────
    try {
      final json = jsonDecode(utf8.decode(envelope.body)) as Map<String, dynamic>;
      final type = json['type'] as String?;
      if (type == 'contact_hello') {
        await onContactHello?.call(senderPub, json);
        // Always reply so sender gets our latest addresses (incl. Reticulum)
        onContactHelloReply?.call(senderPub);
        _bus.emit(ContactHelloReceivedEvent(
          senderMasterPub: senderPub,
          yggAddress: json['yk'] as String? ?? '',
        ));
        // Notify chat screen to reload contact (last_seen updated)
        _bus.emit(ContactUpdatedEvent(masterPub: senderPub));
        return null;
      }
      if (type == 'cert_update') {
        onCertUpdate?.call(senderPub, json);
        _bus.emit(ContactUpdatedEvent(masterPub: senderPub));
        return null;
      }
      // ── Device sync (own devices only) ────────────────────────────────────
      // SECURITY: only process if the sender is ourselves (own masterPub).
      // This prevents any external contact from triggering inbox drain.
      if (type == 'device_sync_request') {
        if (senderPub != _myPub58) {
          AppLogger.w('ReceiveUC',
              'device_sync_request REJECTED: sender ${senderPub.substring(0, 8)}… is not self');
          return null;
        }
        final sinceTs   = json['since_ts'] as int? ?? 0;
        final requester = json['device_id'] as String? ?? senderPub;
        final contact   = await _contacts.findByMasterPub(senderPub);
        await onDeviceSyncRequest?.call(
          requester,
          contact?.transportAddresses ?? {},
          sinceTs,
        );
        return null;
      }
      if (type == 'device_sync_response') {
        if (senderPub != _myPub58) {
          AppLogger.w('ReceiveUC',
              'device_sync_response REJECTED: sender ${senderPub.substring(0, 8)}… is not self');
          return null;
        }
        final payloads = (json['payloads'] as List?)?.cast<String>() ?? [];
        await onDeviceSyncResponse?.call(payloads);
        return null;
      }
      if (type == 'msg_received') {
        final mid = json['mid'] as String?;
        if (mid != null) {
          await processReceipt?.processReceivedReceipt(
            messageId: mid, senderPub: senderPub);
        }
        return null;
      }
    } catch (_) {
      // Not a JSON system message — fall through to DM decryption.
    }

    // ── Try group message ─────────────────────────────────────────────────
    if (onGroupMessage != null) {
      AppLogger.d('ReceiveUC', 'trying group_msg decode for ${envelope.body.length}b from $senderPub');
      final groupPlain = await onGroupMessage!(envelope);
      AppLogger.d('ReceiveUC', 'group_msg result: ${groupPlain != null ? "${groupPlain.length}b" : "null"}');
      if (groupPlain != null) {
        _bus.emit(MessageReceivedEvent(
          conversationId: _extractGroupId(envelope.body) ?? senderPub,
          isGroup: true,
          senderPub: senderPub,
        ));
        return groupPlain;
      }
    }

    // ── Try DM (Double Ratchet) ───────────────────────────────────────────
    return await _handleDm(senderPub, envelope.body, transport: envelope.transport);
  }

  // ── Box system messages ───────────────────────────────────────────────────

  Future<String?> _handleBoxMessage(
    String senderPub,
    Uint8List plain,
  ) async {
    try {
      final sys = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
      final type = sys['type'] as String?;

      if (type == 'ttl_delete') {
        final ids = (sys['ids'] as List).cast<int>();
        for (final id in ids) {
          await _messages.deleteById(id);
        }
        _bus.emit(MessagesDeletedEvent(conversationIds: {senderPub}));
        return null;
      }

      if (type == 'msg_received') {
        final mid = sys['mid'] as String?;
        if (mid != null) {
          await processReceipt?.processReceivedReceipt(
            messageId: mid, senderPub: senderPub);
        }
        return null;
      }

      if (type == 'msg_delivered') {
        final mid = sys['mid'] as String?;
        if (mid != null) {
          final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          await processReceipt?.processDeliveryReceipt(
            messageId: mid, senderPub: senderPub, deliveredAt: now);
        }
        return null;
      }

      if (type == 'msg_read') {
        final mid = sys['mid'] as String?;
        if (mid != null) {
          final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          await processReceipt?.processReadReceipt(
            messageId: mid, senderPub: senderPub, readAt: now);
        }
        return null;
      }

      if (type == 'file_cancel') {
        final tid = sys['tid'] as String?;
        AppLogger.d('File', 'received file_cancel tid=$tid');
        if (tid != null) onFileCancel?.call(tid);
        return null;
      }
    } catch (e) {
      AppLogger.w('Recv', 'failed to parse system box message', error: e);
    }
    return null;
  }

  // ── DM decryption ─────────────────────────────────────────────────────────

  Future<String?> _handleDm(String senderPub, Uint8List body, {String? transport}) async {
    // Parse wire payload.
    late Map<String, dynamic> payloadMap;
    try {
      payloadMap = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }

    final counter      = payloadMap['n'] as int? ?? 0;
    final ciphertext   = _b64(payloadMap['c']);
    final newEphPub    = payloadMap['e'] != null ? _b64(payloadMap['e']) : null;
    final senderEphPub = payloadMap['s'] != null ? _b64(payloadMap['s']) : null;
    final senderEphSig = payloadMap['ss'] != null ? _b64(payloadMap['ss']) : null;
    final newEphSig    = payloadMap['es'] != null ? _b64(payloadMap['es']) : null;
    final ttlSeconds   = payloadMap.containsKey('t') ? payloadMap['t'] as int? : null;
    final mid          = payloadMap['id'] as String?;
    final replyToId    = payloadMap['rid'] as String?;

    if (ciphertext == null) return null;

    final meta = IncomingDmMeta(
      counter: counter,
      senderEphPub: senderEphPub,
      newEphPub: newEphPub,
      senderEphSig: senderEphSig,
      newEphSig: newEphSig,
    );

    final plaintext = await _crypto.decryptDm(senderPub, ciphertext, meta);
    if (plaintext == null) {
      // Session out of sync — ask sender to reset by sending them a contact_hello.
      onSessionDesync?.call(senderPub);
      return null;
    }

    // ── Check for group_invite inside decrypted DM ──────────────────────
    final invite = GroupInvite.tryDecode(Uint8List.fromList(utf8.encode(plaintext)));
    AppLogger.d('ReceiveUC', 'group_invite parsed: ${invite != null}');
    if (invite != null) {
      // Save as pending notification — user must accept/decline
      await onSaveNotification?.call(
        'group_invite', plaintext, senderPub);
      _bus.emit(GroupInviteReceivedEvent(
        groupId: invite.groupId,
        groupName: invite.name,
        adminMasterPub: invite.adminPub58,
      ));
      return null;
    }

    // ── Determine effective TTL ───────────────────────────────────────────
    // ttlSeconds == null  → old client; use local setting
    // ttlSeconds == 0     → sender disabled TTL; no expiry
    // ttlSeconds > 0      → use sender's value
    int? effectiveTtl;
    if (ttlSeconds == null) {
      effectiveTtl = await _readTtl(senderPub);
    } else if (ttlSeconds > 0) {
      effectiveTtl = ttlSeconds;
    }

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final expiresAt = effectiveTtl != null ? now + effectiveTtl : null;

    await _messages.insert(Message(
      conversationId: senderPub,
      isGroup: false,
      senderPub: senderPub,
      body: plaintext,
      sentAt: now,
      receivedAt: now,
      status: MessageStatus.delivered,
      expiresAt: expiresAt,
      messageId: mid,
      replyToId: replyToId,
      transport: transport,
    ));

    await _contacts.touchLastSeen(senderPub);

    // ── Send our hello so sender gets our avatar/alias ────────────────────
    // Route is confirmed working (we just received their message).
    // Rate-limited inside sendHelloTo — fires at most once per 30s per contact.
    onContactHelloReply?.call(senderPub);

    // ── Send delivery receipt ─────────────────────────────────────────────
    if (mid != null) {
      _sendDeliveredReceipt(senderPub, mid);
    }

    _bus.emit(MessageReceivedEvent(
      conversationId: senderPub,
      isGroup: false,
      senderPub: senderPub,
    ));

    return plaintext;
  }

  // Best-effort delivery receipt — async but not awaited so message processing
  // isn't blocked. Runs in the current event loop without microtask delay.
  void _sendDeliveredReceipt(String recipientPub, String mid) async {
    try {
      final plain = Uint8List.fromList(
        utf8.encode(jsonEncode({'type': 'msg_delivered', 'mid': mid})),
      );
      final boxed = await _crypto.encryptBox(recipientPub, plain);
      AppLogger.d('ReceiveUC', 'sending msg_delivered to ${recipientPub.substring(0, 8)}… mid=${mid.substring(0, 8)}…');
      onSendRaw?.call(Envelope(from: _myPub58, to: recipientPub, body: boxed));
    } catch (e) {
      AppLogger.e('ReceiveUC', 'msg_delivered send error', error: e);
    }
  }

  static Uint8List? _b64(dynamic v) {
    if (v == null) return null;
    try {
      return base64.decode(v as String);
    } catch (_) {
      return null;
    }
  }

  /// Extract group_id from a group_msg body for event emission.
  static String? _extractGroupId(Uint8List body) {
    try {
      final m = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
      if (m['type'] == 'group_msg') return m['group_id'] as String?;
    } catch (_) {}
    return null;
  }

  static String _roleLabel(String role) {
    switch (role) {
      case 'admin':  return 'Администратор';
      case 'write':  return 'Участник';
      case 'read':   return 'Только чтение';
      case 'banned': return 'Заблокирован';
      default:       return role;
    }
  }
}
