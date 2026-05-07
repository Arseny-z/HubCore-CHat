import 'package:sqflite_sqlcipher/sqflite.dart';

import '../../domain/entities/message.dart';
export '../../domain/entities/message.dart';

class MessagesDao {
  final Database _db;
  MessagesDao(this._db);

  Future<int> insert(Message m) => _db.insert('messages', m.toMap());

  /// Latest [limit] messages for a conversation, newest first.
  Future<List<Message>> forConversation(
    String conversationId, {
    int limit = 50,
    int? beforeId,
  }) async {
    final rows = await _db.query(
      'messages',
      where: beforeId != null
          ? 'conversation_id = ? AND id < ?'
          : 'conversation_id = ?',
      whereArgs: beforeId != null ? [conversationId, beforeId] : [conversationId],
      orderBy: 'sent_at DESC',
      limit: limit,
    );
    return rows.map(Message.fromMap).toList();
  }

  Future<Message?> lastMessage(String conversationId) async {
    final rows = await _db.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'sent_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : Message.fromMap(rows.first);
  }

  /// Count incoming unread messages for a conversation.
  Future<int> unreadCount(String conversationId, String myPub) async {
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) as cnt FROM messages '
      'WHERE conversation_id = ? AND sender_pub != ? AND status != ?',
      [conversationId, myPub, MessageStatus.read.name],
    );
    return (rows.first['cnt'] as int?) ?? 0;
  }

  Future<void> updateStatus(int id, MessageStatus status) => _db.update(
        'messages',
        {'status': status.name},
        where: 'id = ?',
        whereArgs: [id],
      );

  Future<void> updateStatusAndTransport(
          int id, MessageStatus status, String transport) =>
      _db.update(
        'messages',
        {'status': status.name, 'transport': transport},
        where: 'id = ?',
        whereArgs: [id],
      );

  Future<void> deleteConversation(String conversationId) => _db.delete(
        'messages',
        where: 'conversation_id = ?',
        whereArgs: [conversationId],
      );

  /// Set expiry on a message by its id.
  Future<void> setExpiry(int id, int expiresAt) => _db.update(
        'messages',
        {'expires_at': expiresAt},
        where: 'id = ?',
        whereArgs: [id],
      );

  /// Return all messages whose expires_at <= [nowSeconds] (non-null).
  Future<List<Message>> expiredBefore(int nowSeconds) async {
    final rows = await _db.query(
      'messages',
      where: 'expires_at IS NOT NULL AND expires_at <= ?',
      whereArgs: [nowSeconds],
    );
    return rows.map(Message.fromMap).toList();
  }

  /// Find a message by its hex message_id (for delivery receipt correlation).
  Future<Message?> findByMessageId(String messageId) async {
    final rows = await _db.query(
      'messages',
      where: 'message_id = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    return rows.isEmpty ? null : Message.fromMap(rows.first);
  }

  /// Full-text search across all conversations. Returns newest-first, limit 100.
  Future<List<Message>> search(String query, {String? conversationId}) async {
    final like = '%$query%';
    final rows = await _db.query(
      'messages',
      where: conversationId != null
          ? 'conversation_id = ? AND body LIKE ? AND content_type = ?'
          : 'body LIKE ? AND content_type = ?',
      whereArgs: conversationId != null
          ? [conversationId, like, 'text']
          : [like, 'text'],
      orderBy: 'sent_at DESC',
      limit: 100,
    );
    return rows.map(Message.fromMap).toList();
  }

  /// Delete a single message by id. Returns number of rows deleted.
  Future<int> deleteById(int id) =>
      _db.delete('messages', where: 'id = ?', whereArgs: [id]);
}
