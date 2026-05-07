import 'package:sqflite_sqlcipher/sqflite.dart';

import '../../domain/entities/group.dart';
export '../../domain/entities/group.dart';

class GroupsDao {
  final Database _db;
  GroupsDao(this._db);

  // ── Groups ──────────────────────────────────────────────────────────────────

  Future<void> insertGroup(Group g) async {
    await _db.insert('groups', g.toMap(), conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<List<Group>> allGroups() async {
    final rows = await _db.query('groups', orderBy: 'created_at DESC');
    return rows.map(Group.fromMap).toList();
  }

  Future<Group?> findGroup(String groupId) async {
    final rows = await _db.query(
      'groups',
      where: 'group_id = ?',
      whereArgs: [groupId],
      limit: 1,
    );
    return rows.isEmpty ? null : Group.fromMap(rows.first);
  }

  Future<String?> adminPub(String groupId) async {
    final rows = await _db.query(
      'groups',
      columns: ['admin_pub'],
      where: 'group_id = ?',
      whereArgs: [groupId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['admin_pub'] as String?;
  }

  Future<String?> ownerPub(String groupId) async {
    final rows = await _db.query(
      'groups',
      columns: ['owner_pub'],
      where: 'group_id = ?',
      whereArgs: [groupId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['owner_pub'] as String?;
  }

  Future<void> setAdmin(String groupId, String newAdminPub) async {
    await _db.update('groups', {'admin_pub': newAdminPub},
        where: 'group_id = ?', whereArgs: [groupId]);
    // Also update role in group_members to keep tables in sync
    await _db.update(
      'group_members',
      {'role': 'admin'},
      where: 'group_id = ? AND master_pub = ?',
      whereArgs: [groupId, newAdminPub],
    );
  }

  // ── Member roles ────────────────────────────────────────────────────────────

  Future<String?> memberRole(String groupId, String masterPub) async {
    final rows = await _db.query(
      'group_members',
      columns: ['role'],
      where: 'group_id = ? AND master_pub = ?',
      whereArgs: [groupId, masterPub],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['role'] as String? ?? GroupRole.write;
  }

  Future<void> setMemberRole(String groupId, String masterPub, String role) =>
      _db.update(
        'group_members',
        {'role': role},
        where: 'group_id = ? AND master_pub = ?',
        whereArgs: [groupId, masterPub],
      );

  Future<List<String>> adminPubs(String groupId) async {
    final rows = await _db.query(
      'group_members',
      columns: ['master_pub'],
      where: "group_id = ? AND role = 'admin'",
      whereArgs: [groupId],
    );
    return rows.map((r) => r['master_pub'] as String).toList();
  }

  Future<int> adminCount(String groupId) async {
    final result = await _db.rawQuery(
      "SELECT COUNT(*) as cnt FROM group_members WHERE group_id = ? AND role = 'admin'",
      [groupId],
    );
    return result.first['cnt'] as int? ?? 0;
  }

  Future<void> renameGroup(String groupId, String newName) async {
    await _db.update(
      'groups',
      {'name': newName},
      where: 'group_id = ?',
      whereArgs: [groupId],
    );
  }

  Future<void> deleteGroup(String groupId) async {
    await _db.delete('groups', where: 'group_id = ?', whereArgs: [groupId]);
    await _db.delete('group_members', where: 'group_id = ?', whereArgs: [groupId]);
  }

  // ── Members ─────────────────────────────────────────────────────────────────

  Future<void> upsertMember(GroupMember m) async {
    await _db.insert(
      'group_members',
      m.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<GroupMember>> membersOf(String groupId) async {
    final rows = await _db.query(
      'group_members',
      where: 'group_id = ?',
      whereArgs: [groupId],
    );
    return rows.map(GroupMember.fromMap).toList();
  }

  Future<GroupMember?> member(String groupId, String masterPub) async {
    final rows = await _db.query(
      'group_members',
      where: 'group_id = ? AND master_pub = ?',
      whereArgs: [groupId, masterPub],
      limit: 1,
    );
    return rows.isEmpty ? null : GroupMember.fromMap(rows.first);
  }

  Future<void> removeMember(String groupId, String masterPub) async {
    await _db.delete(
      'group_members',
      where: 'group_id = ? AND master_pub = ?',
      whereArgs: [groupId, masterPub],
    );
  }

  Future<List<String>> memberPubs(String groupId) async {
    final rows = await _db.query(
      'group_members',
      columns: ['master_pub'],
      where: 'group_id = ?',
      whereArgs: [groupId],
    );
    return rows.map((r) => r['master_pub'] as String).toList();
  }
}
