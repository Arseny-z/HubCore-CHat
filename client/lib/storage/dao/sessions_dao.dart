import 'package:sqflite_sqlcipher/sqflite.dart';

import '../../domain/entities/session_record.dart';
export '../../domain/entities/session_record.dart';

class SessionsDao {
  final Database _db;
  SessionsDao(this._db);

  Future<int> insert(SessionRecord r) =>
      _db.insert('sessions', r.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);

  Future<SessionRecord?> forContact(int contactId) async {
    final rows = await _db.query(
      'sessions',
      where: 'contact_id = ?',
      whereArgs: [contactId],
      limit: 1,
    );
    return rows.isEmpty ? null : SessionRecord.fromMap(rows.first);
  }

  Future<void> update(SessionRecord r) => _db.update(
        'sessions',
        r.toMap(),
        where: 'id = ?',
        whereArgs: [r.id],
      );

  Future<void> deleteForContact(int contactId) =>
      _db.delete('sessions', where: 'contact_id = ?', whereArgs: [contactId]);
}
