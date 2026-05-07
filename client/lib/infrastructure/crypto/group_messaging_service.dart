import 'dart:convert';
import 'dart:typed_data';

import 'package:bs58/bs58.dart';
import 'package:sodium_libs/sodium_libs.dart';

import '../../crypto/identity.dart';
import '../../crypto/keys.dart';
import '../../crypto/sender_keys.dart';
import '../../domain/entities/file_transfer.dart';
import '../../domain/entities/group.dart' show GroupRole, GroupPermissions;
import '../../domain/entities/group_invite.dart';
import '../../domain/entities/envelope.dart';
import '../../shared/utils/logger.dart';
import '../../shared/utils/pubkey_codec.dart';
import '../../storage/storage_service.dart';

export '../../domain/entities/group_invite.dart' show GroupInvite;

/// Wire format for a group message envelope body.
///
/// JSON layout:
///   {
///     "type":     "group_msg",
///     "group_id": "<base58>",
///     "c":        "<base64 nonce||ciphertext>",
///     "n":        <counter int>,
///     "rk":       "<base64 newRatchetPub>" | null,  // present on DH ratchet
///     "t":        <ttlSeconds int>  | omitted,       // 0 = no expiry
///     "id":       "<messageId hex>" | omitted
///   }
class _GroupPayload {
  final String groupId;
  final Uint8List ciphertext;
  final int counter;
  final Uint8List? newRatchetPub;
  final String? messageId;
  /// Sender's TTL setting: null = old client (use local), 0 = no expiry, >0 = seconds
  final int? ttlSeconds;

  _GroupPayload({
    required this.groupId,
    required this.ciphertext,
    required this.counter,
    this.newRatchetPub,
    this.messageId,
    this.ttlSeconds,
  });

  Uint8List encode() {
    return Uint8List.fromList(utf8.encode(jsonEncode({
      'type': 'group_msg',
      'group_id': groupId,
      'c': base64.encode(ciphertext),
      'n': counter,
      if (newRatchetPub != null) 'rk': base64.encode(newRatchetPub!),
      if (messageId != null) 'id': messageId,
      if (ttlSeconds != null) 't': ttlSeconds,
    })));
  }

  static _GroupPayload? tryDecode(Uint8List bytes) {
    try {
      final m = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (m['type'] != 'group_msg') return null;
      return _GroupPayload(
        groupId: m['group_id'] as String,
        ciphertext: base64.decode(m['c'] as String),
        counter: m['n'] as int,
        newRatchetPub: m['rk'] != null ? base64.decode(m['rk'] as String) : null,
        messageId: m['id'] as String?,
        ttlSeconds: m['t'] as int?,
      );
    } catch (e) {
      AppLogger.w('GroupMsg', 'payload decode failed: $e');
      return null;
    }
  }
}

/// Wire format for a sender-key distribution message.
///
/// Sent DM-encrypted (via MessagingService) to each member when they join.
/// JSON layout:
/// Manages group E2E encryption using the Sender Keys protocol.
class GroupMessagingService {
  final Sodium _sodium;
  final Identity _identity;
  final StorageService _storage;
  final SenderKeys _senderKeys;

  /// In-memory cache: groupId → memberPub → SenderChainState.
  final _chains = <String, Map<String, SenderChainState>>{};

  /// Called to send a delivery receipt back to the message sender.
  void Function(String recipientPub58, String mid)? onSendDeliveryReceipt;

  /// Called when a FileOffer arrives via group Sender Keys.
  /// Args: senderPub58, senderYggKey (may be null), offer.
  void Function(String senderPub, String? yggKey, FileOffer offer)? onFileOffer;

  GroupMessagingService({
    required Sodium sodium,
    required Identity identity,
    required StorageService storage,
  })  : _sodium = sodium,
        _identity = identity,
        _storage = storage,
        _senderKeys = SenderKeys(sodium);

  // ── Create group ────────────────────────────────────────────────────────────

  /// Create a new group, generate our sender chain, invite [memberPubs].
  ///
  /// Returns the new groupId. Caller must distribute invites via
  /// [buildInvitePayload] sent through [MessagingService.sendMessage].
  Future<String> createGroup({
    required String name,
    required List<String> memberPubs,
  }) async {
    final groupId = _randomId();
    final myPub58 = PubkeyCodec.encode(_identity.masterPublicKey);

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _storage.groups.insertGroup(Group(
      groupId: groupId,
      name: name,
      adminPub: myPub58,
      ownerPub: myPub58,
      createdAt: now,
    ));

    // Create our own sender chain — creator is admin
    final myChain = _senderKeys.createSenderChain();
    await _saveMemberChain(groupId, myPub58, myChain, role: GroupRole.admin);

    // Also set owner_pub in groups table
    await _storage.groups.setAdmin(groupId, myPub58);

    // Add all members as placeholders (chain filled when invite accepted)
    for (final pub in memberPubs) {
      await _storage.groups.upsertMember(GroupMember(
        groupId: groupId,
        masterPub: pub,
        chainKey: Uint8List(32),
        counter: 0,
        role: GroupRole.write,
      ));
    }

    return groupId;
  }

  /// Build the invite payload to send to [recipientPub58].
  ///
  /// Must be called after [createGroup]. Encode result into an Envelope body
  /// and send via MessagingService (DM-encrypted to each member).
  Future<Uint8List?> buildInvitePayload(String groupId) async {
    final myPub58 = PubkeyCodec.encode(_identity.masterPublicKey);
    final myChain = await _loadChain(groupId, myPub58);
    if (myChain == null) return null;

    final members = await _storage.groups.memberPubs(groupId);
    final group = await _storage.groups.findGroup(groupId);
    if (group == null) return null;

    final blob = _senderKeys.exportChainState(myChain);
    return GroupInvite(
      groupId: groupId,
      name: group.name,
      members: members,
      chainKeyBlob: blob,
      adminPub58: myPub58,
    ).encode();
  }

  // ── Accept invite ───────────────────────────────────────────────────────────

  /// Process a received [GroupInvite]. Returns groupId on success.
  Future<String?> acceptInvite(GroupInvite invite) async {
    // Create or update group record
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _storage.groups.insertGroup(Group(
      groupId: invite.groupId,
      name: invite.name,
      adminPub: invite.adminPub58,
      createdAt: now,
    ));

    // Import the admin's sender chain — admin keeps role='admin'
    final adminChain = _senderKeys.importChainState(invite.chainKeyBlob);
    await _saveMemberChain(invite.groupId, invite.adminPub58, adminChain,
        role: GroupRole.admin);

    // Register other members with empty chains (filled when they send)
    final myPub58 = PubkeyCodec.encode(_identity.masterPublicKey);
    for (final pub in invite.members) {
      if (pub == invite.adminPub58) continue;
      if (pub == myPub58) continue; // added below with own chain
      final existing = await _storage.groups.member(invite.groupId, pub);
      if (existing == null) {
        await _storage.groups.upsertMember(GroupMember(
          groupId: invite.groupId,
          masterPub: pub,
          chainKey: Uint8List(32),
          counter: 0,
          role: GroupRole.write,
        ));
      }
    }

    // Create our own sender chain — joining as regular write member
    final myChain = _senderKeys.createSenderChain();
    await _saveMemberChain(invite.groupId, myPub58, myChain,
        role: GroupRole.write);

    return invite.groupId;
  }

  // ── Group offer (for files/voice/video via Sender Keys) ────────────────────

  /// Encrypt raw [bytes] as a group Sender Keys payload WITHOUT saving to DB.
  /// Used for FileOffer so it travels through the same encrypted channel as
  /// text messages — no X25519 keys required.
  Future<List<Envelope>> encryptGroupOffer(String groupId, Uint8List bytes) async {
    final myPub58 = PubkeyCodec.encode(_identity.masterPublicKey);
    final myChain = await _loadChain(groupId, myPub58);
    if (myChain == null) throw StateError('No sender chain for group $groupId');

    final gm = _senderKeys.encrypt(myChain, bytes, myPub58);
    await _saveMemberChain(groupId, myPub58, myChain);

    final payload = _GroupPayload(
      groupId: groupId,
      ciphertext: gm.ciphertext,
      counter: gm.counter,
      newRatchetPub: gm.newSenderKey,
      messageId: null,
    ).encode();

    final members = await _storage.groups.memberPubs(groupId);
    return members
        .where((pub) => pub != myPub58)
        .map((pub) => Envelope(from: myPub58, to: pub, body: payload))
        .toList();
  }

  // ── Send ────────────────────────────────────────────────────────────────────

  /// Encrypt [plaintext] and return fan-out envelopes for every group member.
  ///
  /// The same ciphertext goes to all members — each gets an identical envelope.
  /// [ttlSeconds]: null = no TTL sent (receiver uses local setting),
  ///               0    = sender explicitly disabled TTL,
  ///               >0   = apply this TTL on receiver side.
  Future<List<Envelope>> sendGroupMessage(
    String groupId,
    String plaintext, {
    int? ttlSeconds,
  }) async {
    final myPub58 = PubkeyCodec.encode(_identity.masterPublicKey);

    // Check write permission before encrypting
    final myRole = await _storage.groups.memberRole(groupId, myPub58) ?? GroupRole.write;
    if (!GroupPermissions.canWrite(myRole)) {
      throw StateError('No write permission in group $groupId (role: $myRole)');
    }

    final myChain = await _loadChain(groupId, myPub58);
    if (myChain == null) throw StateError('No sender chain for group $groupId');

    final gm = _senderKeys.encrypt(
      myChain,
      Uint8List.fromList(utf8.encode(plaintext)),
      myPub58,
    );
    await _saveMemberChain(groupId, myPub58, myChain);

    // Generate message ID for delivery tracking
    final mid = _randomMid();

    // Save to local DB with TTL applied locally
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final expiresAt = (ttlSeconds != null && ttlSeconds > 0)
        ? now + ttlSeconds
        : null;
    await _storage.messages.insert(Message(
      conversationId: groupId,
      isGroup: true,
      senderPub: myPub58,
      body: plaintext,
      sentAt: now,
      status: MessageStatus.sent,
      messageId: mid,
      expiresAt: expiresAt,
    ));

    final payload = _GroupPayload(
      groupId: groupId,
      ciphertext: gm.ciphertext,
      counter: gm.counter,
      newRatchetPub: gm.newSenderKey,
      messageId: mid,
      ttlSeconds: ttlSeconds,
    ).encode();

    final members = await _storage.groups.memberPubs(groupId);
    final recipients = members.where((pub) => pub != myPub58).toList();

    // Create receipt entries for delivery tracking
    for (final pub in recipients) {
      await _storage.messageReceipts.markSent(mid, pub, 'pending', now);
    }

    return recipients
        .map((pub) => Envelope(from: myPub58, to: pub, body: payload))
        .toList();
  }

  // ── Receive ─────────────────────────────────────────────────────────────────

  /// Attempt to decrypt a group message from an incoming envelope.
  ///
  /// Returns plaintext if successful, null if not a group message or failed.
  Future<String?> receiveGroupEnvelope(Envelope envelope) async {
    final payload = _GroupPayload.tryDecode(envelope.body);
    if (payload == null) {
      AppLogger.d('GroupMsg', 'not a group_msg payload');
      return null;
    }

    final senderPub = envelope.from;
    AppLogger.d('GroupMsg', 'group=${payload.groupId} from=${senderPub.substring(0, 8)}… counter=${payload.counter}');

    // Drop messages from banned members
    final senderRole = await _storage.groups.memberRole(payload.groupId, senderPub);
    if (senderRole == GroupRole.banned) {
      AppLogger.d('GroupMsg', 'dropped message from banned ${senderPub.substring(0, 8)}… in group ${payload.groupId}');
      return null;
    }

    final senderChain = await _loadChain(payload.groupId, senderPub);
    if (senderChain == null) {
      AppLogger.w('GroupMsg', 'no chain for sender ${senderPub.substring(0, 8)}… in group ${payload.groupId}');
      return null;
    }
    AppLogger.d('GroupMsg', 'chain loaded: counter=${senderChain.counter} chainKey=${senderChain.chainKey.sublist(0, 4)}');

    late Uint8List plainBytes;
    try {
      plainBytes = _senderKeys.decrypt(
        senderChain,
        GroupMessage(
          ciphertext: payload.ciphertext,
          senderPubkey: senderPub,
          counter: payload.counter,
          newSenderKey: payload.newRatchetPub,
        ),
      );
    } catch (e) {
      AppLogger.w('GroupMsg', 'decrypt FAILED: $e');
      return null;
    }

    await _saveMemberChain(payload.groupId, senderPub, senderChain);

    // Check if the decrypted payload is a FileOffer (sent via Sender Keys).
    final offer = FileOffer.tryDecode(plainBytes);
    if (offer != null) {
      AppLogger.d('GroupMsg', 'file_offer via Sender Keys: tid=${offer.tid} name=${offer.name}');
      onFileOffer?.call(senderPub, null, offer);
      return null; // Not a chat message — handled by FileService
    }

    final plaintext = utf8.decode(plainBytes);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // Apply sender's TTL:
    //   null  → old client — no expiry (groups default: no TTL unless explicitly set)
    //   0     → sender disabled TTL
    //   >0    → use sender's value
    final expiresAt = (payload.ttlSeconds != null && payload.ttlSeconds! > 0)
        ? now + payload.ttlSeconds!
        : null;

    await _storage.messages.insert(Message(
      conversationId: payload.groupId,
      isGroup: true,
      senderPub: senderPub,
      body: plaintext,
      sentAt: now,
      receivedAt: now,
      status: MessageStatus.delivered,
      messageId: payload.messageId,
      expiresAt: expiresAt,
      transport: envelope.transport,
    ));

    // Send delivery receipt to message sender (best-effort)
    if (payload.messageId != null) {
      onSendDeliveryReceipt?.call(senderPub, payload.messageId!);
    }

    return plaintext;
  }

  // ── Import member chain (from group_joined) ─────────────────────────────

  /// Remove a member's chain from the in-memory cache and the DB.
  /// Must be called when kicking a member so their future messages can't
  /// be decrypted (prevents re-add via _saveMemberChain on stale cache hit).
  Future<void> evictMemberChain(String groupId, String memberPub) async {
    _chains[groupId]?.remove(memberPub);
    await _storage.groups.removeMember(groupId, memberPub);
  }

  /// Import a single member's sender chain into an existing group.
  /// Called when receiving a `group_joined` message — does NOT overwrite
  /// the group record or other members' chains.
  Future<void> importMemberChain(
    String groupId,
    String memberPub58,
    Uint8List chainKeyBlob,
  ) async {
    final chain = _senderKeys.importChainState(chainKeyBlob);
    await _saveMemberChain(groupId, memberPub58, chain);
    AppLogger.d('GroupMsg', 'imported member chain for ${memberPub58.substring(0, 8)}… in group $groupId');
  }

  // ── Chain rotation (forward secrecy) ─────────────────────────────────────

  /// Rotate our sender chain in [groupId] — creates a new chain and returns
  /// the invite payload (new chain state) for distribution to all members
  /// via DM-encrypted messages.
  ///
  /// Call this when:
  /// - A member is removed from the group
  /// - Periodically for forward secrecy (e.g. every N hours)
  Future<Uint8List?> rotateMyChain(String groupId) async {
    final myPub58 = PubkeyCodec.encode(_identity.masterPublicKey);

    // Dispose old chain
    final oldChain = _chains[groupId]?[myPub58];
    oldChain?.dispose();

    // Create fresh chain
    final newChain = _senderKeys.createSenderChain();
    await _saveMemberChain(groupId, myPub58, newChain);

    // Build invite-like payload so members can import the new chain
    return buildInvitePayload(groupId);
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  Future<SenderChainState?> _loadChain(String groupId, String memberPub) async {
    _chains[groupId] ??= {};
    if (_chains[groupId]!.containsKey(memberPub)) {
      return _chains[groupId]![memberPub];
    }

    final record = await _storage.groups.member(groupId, memberPub);
    if (record == null) return null;

    // If chainKey is all zeros it's a placeholder — no real state yet
    if (record.chainKey.every((b) => b == 0)) return null;

    final placeholder = KeyGen(_sodium).generateX25519();
    final state = SenderChainState(
      chainKey: Uint8List.fromList(record.chainKey),
      myRatchetKey: placeholder,
      peerRatchetPub: record.ratchetPub,
    )..counter = record.counter;

    _chains[groupId]![memberPub] = state;
    return state;
  }

  Future<void> _saveMemberChain(
    String groupId,
    String memberPub,
    SenderChainState state, {
    String? role,
  }) async {
    _chains[groupId] ??= {};
    _chains[groupId]![memberPub] = state;

    // Preserve existing role from DB — never overwrite with default.
    final existingRole = role
        ?? await _storage.groups.memberRole(groupId, memberPub)
        ?? GroupRole.write;

    await _storage.groups.upsertMember(GroupMember(
      groupId: groupId,
      masterPub: memberPub,
      chainKey: Uint8List.fromList(state.chainKey),
      ratchetPub: state.myRatchetKey.publicKey,
      counter: state.counter,
      role: existingRole,
    ));
  }

  String _randomId() {
    return base58.encode(_sodium.randombytes.buf(16));
  }

  String _randomMid() {
    return _sodium.randombytes.buf(4)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  void dispose() {
    for (final group in _chains.values) {
      for (final state in group.values) {
        state.dispose();
      }
    }
    _chains.clear();
  }
}
