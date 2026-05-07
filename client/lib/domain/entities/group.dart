import 'dart:typed_data';

/// A group conversation.
class Group {
  final int? id;
  final String groupId;    // random base58 identifier
  final String name;
  final String? adminPub;  // legacy compat — use group_members.role instead
  final String? ownerPub;  // original creator, cannot be demoted
  final int createdAt;     // unix seconds

  const Group({
    this.id,
    required this.groupId,
    required this.name,
    this.adminPub,
    this.ownerPub,
    required this.createdAt,
  });

  factory Group.fromMap(Map<String, dynamic> m) => Group(
        id: m['id'] as int?,
        groupId: m['group_id'] as String,
        name: m['name'] as String,
        adminPub: m['admin_pub'] as String?,
        ownerPub: m['owner_pub'] as String?,
        createdAt: m['created_at'] as int,
      );

  Map<String, dynamic> toMap() => {
        'group_id': groupId,
        'name': name,
        if (adminPub != null) 'admin_pub': adminPub,
        if (ownerPub != null) 'owner_pub': ownerPub,
        'created_at': createdAt,
      };
}

/// Role values for group members.
class GroupRole {
  static const admin  = 'admin';
  static const write  = 'write';
  static const read   = 'read';
  static const banned = 'banned';

  static const maxAdmins = 3;
}

/// Permission checks based on role.
class GroupPermissions {
  static bool canWrite(String role)       => role == GroupRole.admin || role == GroupRole.write;
  static bool canRead(String role)        => role != GroupRole.banned;
  static bool canRename(String role)      => role == GroupRole.admin;
  static bool canKick(String role)        => role == GroupRole.admin;
  static bool canAddMembers(String role)  => role == GroupRole.admin;
  static bool canChangeRoles(String role) => role == GroupRole.admin;
  static bool canDeleteGroup(String role) => role == GroupRole.admin;
}

/// A member's sender chain state within a group.
class GroupMember {
  final String groupId;
  final String masterPub;      // base58 master pubkey
  final Uint8List chainKey;    // 32-byte current chain key
  final Uint8List? ratchetPub; // latest known DH ratchet pubkey
  final int counter;
  final String role;           // 'admin'|'write'|'read'|'banned'

  bool get isAdmin  => role == GroupRole.admin;
  bool get canWrite => GroupPermissions.canWrite(role);
  bool get canRead  => GroupPermissions.canRead(role);

  const GroupMember({
    required this.groupId,
    required this.masterPub,
    required this.chainKey,
    this.ratchetPub,
    required this.counter,
    this.role = GroupRole.write,
  });

  factory GroupMember.fromMap(Map<String, dynamic> m) => GroupMember(
        groupId: m['group_id'] as String,
        masterPub: m['master_pub'] as String,
        chainKey: m['chain_key'] as Uint8List,
        ratchetPub: m['ratchet_pub'] as Uint8List?,
        counter: m['counter'] as int,
        role: m['role'] as String? ?? GroupRole.write,
      );

  Map<String, dynamic> toMap() => {
        'group_id': groupId,
        'master_pub': masterPub,
        'chain_key': chainKey,
        if (ratchetPub != null) 'ratchet_pub': ratchetPub,
        'counter': counter,
        'role': role,
      };
}
