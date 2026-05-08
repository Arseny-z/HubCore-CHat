import 'package:sqflite_sqlcipher/sqflite.dart';

class MessageReaction {
  final int? id;
  final String messageId;
  final String reactorPub;
  final String emoji;
  final int createdAt;

  const MessageReaction({
    this.id,
    required this.messageId,
    required this.reactorPub,
    required this.emoji,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'message_id':  messageId,
        'reactor_pub': reactorPub,
        'emoji':       emoji,
        'created_at':  createdAt,
      };

  static MessageReaction fromMap(Map<String, dynamic> m) => MessageReaction(
        id:         m['id'] as int?,
        messageId:  m['message_id']  as String,
        reactorPub: m['reactor_pub'] as String,
        emoji:      m['emoji']       as String,
        createdAt:  m['created_at']  as int,
      );
}

class MessageReactionsDao {
  final Database _db;
  MessageReactionsDao(this._db);

  /// Set (or replace) the reactor's emoji on the given message.
  /// One reaction per (messageId, reactorPub) — UNIQUE handles replace.
  Future<void> set(MessageReaction r) => _db.insert(
        'message_reactions',
        r.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  /// Remove the reactor's reaction from a message (no-op if none).
  Future<int> clear(String messageId, String reactorPub) =>
      _db.delete('message_reactions',
          where: 'message_id = ? AND reactor_pub = ?',
          whereArgs: [messageId, reactorPub]);

  /// All reactions for a single message (newest first).
  Future<List<MessageReaction>> forMessage(String messageId) async {
    final rows = await _db.query(
      'message_reactions',
      where: 'message_id = ?',
      whereArgs: [messageId],
      orderBy: 'created_at DESC',
    );
    return rows.map(MessageReaction.fromMap).toList();
  }

  /// All reactions for a list of messageIds (used to load a chat page).
  /// Returns: messageId → list of reactions.
  Future<Map<String, List<MessageReaction>>> forMessageIds(
      List<String> messageIds) async {
    if (messageIds.isEmpty) return const {};
    final placeholders = List.filled(messageIds.length, '?').join(',');
    final rows = await _db.rawQuery(
      'SELECT * FROM message_reactions '
      'WHERE message_id IN ($placeholders) '
      'ORDER BY created_at ASC',
      messageIds,
    );
    final out = <String, List<MessageReaction>>{};
    for (final r in rows) {
      final m   = MessageReaction.fromMap(r);
      out.putIfAbsent(m.messageId, () => []).add(m);
    }
    return out;
  }

  /// Delete all reactions for a message (called when the message is deleted).
  Future<int> deleteForMessage(String messageId) => _db.delete(
        'message_reactions',
        where: 'message_id = ?',
        whereArgs: [messageId],
      );

  /// Delete all reactions for a list of messageIds (clearChat / wipe path).
  Future<int> deleteForMessageIds(List<String> messageIds) async {
    if (messageIds.isEmpty) return 0;
    final placeholders = List.filled(messageIds.length, '?').join(',');
    return _db.rawDelete(
      'DELETE FROM message_reactions WHERE message_id IN ($placeholders)',
      messageIds,
    );
  }

  /// Cascade delete: drop reactions on every message of a conversation.
  /// Caller is responsible for ordering this BEFORE deleting the messages.
  Future<int> deleteForConversation(String conversationId) =>
      _db.rawDelete(
        'DELETE FROM message_reactions WHERE message_id IN ('
        '  SELECT message_id FROM messages '
        '  WHERE conversation_id = ? AND message_id IS NOT NULL'
        ')',
        [conversationId],
      );
}
