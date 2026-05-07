import 'dart:io';

import 'package:sqflite_sqlcipher/sqflite.dart';

import '../../domain/entities/file_record.dart';
export '../../domain/entities/file_record.dart';

class FilesDao {
  final Database _db;
  FilesDao(this._db);

  Future<int> insert(FileRecord r) =>
      _db.insert('files', r.toMap());

  Future<FileRecord?> forMessage(int messageId) async {
    final rows = await _db.query(
      'files',
      where: 'message_id = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    return rows.isEmpty ? null : FileRecord.fromMap(rows.first);
  }

  Future<void> updateMessageId(int fileId, int messageId) async {
    await _db.update(
      'files',
      {'message_id': messageId},
      where: 'id = ?',
      whereArgs: [fileId],
    );
  }

  Future<void> deleteAll() async {
    await _db.delete('files');
  }

  /// Delete file record for a single message and remove the file from disk.
  Future<void> deleteForMessage(int messageId) async {
    final rows = await _db.query(
      'files',
      columns: ['local_path'],
      where: 'message_id = ?',
      whereArgs: [messageId],
    );
    for (final row in rows) {
      final path = row['local_path'] as String?;
      if (path != null) {
        final f = File(path);
        if (await f.exists()) await f.delete();
      }
    }
    await _db.delete('files', where: 'message_id = ?', whereArgs: [messageId]);
  }

  Future<void> deleteForConversation(String conversationId) async {
    final rows = await _db.rawQuery(
      'SELECT local_path FROM files '
      'WHERE message_id IN '
      '(SELECT id FROM messages WHERE conversation_id = ?)',
      [conversationId],
    );
    for (final row in rows) {
      final path = row['local_path'] as String?;
      if (path != null) {
        final f = File(path);
        if (await f.exists()) await f.delete();
      }
    }
    await _db.rawDelete(
      'DELETE FROM files '
      'WHERE message_id IN '
      '(SELECT id FROM messages WHERE conversation_id = ?)',
      [conversationId],
    );
  }
}
