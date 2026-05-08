import 'dart:convert';

import 'package:sqflite_sqlcipher/sqflite.dart';

class AppNotification {
  final int? id;
  final String type;
  final String payload; // JSON
  final String fromPub;
  final int createdAt;
  final String status; // pending|accepted|declined

  const AppNotification({
    this.id,
    required this.type,
    required this.payload,
    required this.fromPub,
    required this.createdAt,
    this.status = 'pending',
  });

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'type': type,
        'payload': payload,
        'from_pub': fromPub,
        'created_at': createdAt,
        'status': status,
      };

  static AppNotification fromMap(Map<String, dynamic> m) => AppNotification(
        id: m['id'] as int?,
        type: m['type'] as String,
        payload: m['payload'] as String,
        fromPub: m['from_pub'] as String,
        createdAt: m['created_at'] as int,
        status: m['status'] as String? ?? 'pending',
      );

  /// Decode the payload JSON.
  Map<String, dynamic> get payloadMap =>
      jsonDecode(payload) as Map<String, dynamic>;
}

class NotificationsDao {
  final Database _db;
  NotificationsDao(this._db);

  Future<int> insert(AppNotification n) =>
      _db.insert('notifications', n.toMap());

  Future<List<AppNotification>> pending() async {
    final rows = await _db.query(
      'notifications',
      where: 'status = ?',
      whereArgs: ['pending'],
      orderBy: 'created_at DESC',
    );
    return rows.map(AppNotification.fromMap).toList();
  }

  Future<int> pendingCount() async {
    final result = await _db.rawQuery(
        "SELECT COUNT(*) as cnt FROM notifications WHERE status = 'pending'");
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// Latest pending key_change notification for a given contact (or null).
  Future<AppNotification?> pendingKeyChangeForContact(String contactPub) async {
    final rows = await _db.query(
      'notifications',
      where: "type = 'key_change' AND status = 'pending' AND from_pub = ?",
      whereArgs: [contactPub],
      orderBy: 'created_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : AppNotification.fromMap(rows.first);
  }

  Future<void> updateStatus(int id, String status) =>
      _db.update('notifications', {'status': status},
          where: 'id = ?', whereArgs: [id]);

  Future<void> delete(int id) =>
      _db.delete('notifications', where: 'id = ?', whereArgs: [id]);
}
