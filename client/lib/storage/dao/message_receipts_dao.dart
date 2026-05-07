import 'package:sqflite_sqlcipher/sqflite.dart';

enum ReceiptStatus { queued, sent, delivered, read }

extension ReceiptStatusX on ReceiptStatus {
  String get value => name;
  static ReceiptStatus fromString(String s) =>
      ReceiptStatus.values.firstWhere((e) => e.name == s,
          orElse: () => ReceiptStatus.queued);
}

class MessageReceipt {
  final int? id;
  final String messageId;
  final String recipientPub;
  final String? transport;
  final ReceiptStatus status;
  final int? sentAt;
  final int? deliveredAt;
  final int? readAt;

  const MessageReceipt({
    this.id,
    required this.messageId,
    required this.recipientPub,
    this.transport,
    this.status = ReceiptStatus.queued,
    this.sentAt,
    this.deliveredAt,
    this.readAt,
  });

  factory MessageReceipt.fromMap(Map<String, dynamic> m) => MessageReceipt(
        id: m['id'] as int?,
        messageId: m['message_id'] as String,
        recipientPub: m['recipient_pub'] as String,
        transport: m['transport'] as String?,
        status: ReceiptStatusX.fromString(m['status'] as String),
        sentAt: m['sent_at'] as int?,
        deliveredAt: m['delivered_at'] as int?,
        readAt: m['read_at'] as int?,
      );

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'message_id': messageId,
        'recipient_pub': recipientPub,
        if (transport != null) 'transport': transport,
        'status': status.value,
        if (sentAt != null) 'sent_at': sentAt,
        if (deliveredAt != null) 'delivered_at': deliveredAt,
        if (readAt != null) 'read_at': readAt,
      };
}

class MessageReceiptsDao {
  final Database _db;
  MessageReceiptsDao(this._db);

  Future<void> upsert(MessageReceipt receipt) async {
    await _db.insert(
      'message_receipts',
      receipt.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<MessageReceipt>> forMessage(String messageId) async {
    final rows = await _db.query(
      'message_receipts',
      where: 'message_id = ?',
      whereArgs: [messageId],
    );
    return rows.map(MessageReceipt.fromMap).toList();
  }

  Future<MessageReceipt?> forRecipient(
          String messageId, String recipientPub) async {
    final rows = await _db.query(
      'message_receipts',
      where: 'message_id = ? AND recipient_pub = ?',
      whereArgs: [messageId, recipientPub],
      limit: 1,
    );
    return rows.isEmpty ? null : MessageReceipt.fromMap(rows.first);
  }

  Future<void> markSent(String messageId, String recipientPub,
      String transport, int sentAt) async {
    await _db.insert(
      'message_receipts',
      {
        'message_id': messageId,
        'recipient_pub': recipientPub,
        'transport': transport,
        'status': ReceiptStatus.sent.value,
        'sent_at': sentAt,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> markDelivered(
      String messageId, String recipientPub, int deliveredAt) async {
    await _db.rawUpdate(
      '''UPDATE message_receipts
         SET status = ?, delivered_at = ?
         WHERE message_id = ? AND recipient_pub = ?''',
      [ReceiptStatus.delivered.value, deliveredAt, messageId, recipientPub],
    );
  }

  Future<void> markRead(
      String messageId, String recipientPub, int readAt) async {
    await _db.rawUpdate(
      '''UPDATE message_receipts
         SET status = ?, read_at = ?
         WHERE message_id = ? AND recipient_pub = ?''',
      [ReceiptStatus.read.value, readAt, messageId, recipientPub],
    );
  }

  /// Returns (delivered, total) counts for a message.
  Future<(int delivered, int total)> deliveryCount(String messageId) async {
    final rows = await _db.query(
      'message_receipts',
      columns: ['status'],
      where: 'message_id = ?',
      whereArgs: [messageId],
    );
    final total = rows.length;
    final delivered = rows
        .where((r) =>
            r['status'] == ReceiptStatus.delivered.value ||
            r['status'] == ReceiptStatus.read.value)
        .length;
    return (delivered, total);
  }

  Future<void> deleteForMessage(String messageId) async {
    await _db.delete('message_receipts',
        where: 'message_id = ?', whereArgs: [messageId]);
  }
}
