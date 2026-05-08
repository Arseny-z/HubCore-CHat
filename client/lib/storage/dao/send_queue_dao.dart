import 'dart:convert';
import 'dart:typed_data';
import 'package:sqflite_sqlcipher/sqflite.dart';

class SendQueueEntry {
  final int? id;
  final String messageId;
  final List<QueueRecipient> recipients;
  /// DR-encrypted Envelope.body — encrypted once, retried as-is.
  /// Never re-encrypted on retry to avoid DR counter desync.
  final Uint8List encryptedBody;
  final String contentType;
  final int attempts;
  final int createdAt;
  final int? nextRetry;
  /// 1 = envelope was sent to transport, waiting for msg_delivered receipt.
  /// 0 = not yet sent (or send failed).
  final int ackPending;
  /// Max retry attempts before giving up. 0 = unlimited.
  final int maxAttempts;
  /// Per-device delivery status for v=2 multi-device payloads.
  /// JSON: {"device_id": "sent|acked|failed"}. Null for v=1.
  final String? perDeviceStatus;

  const SendQueueEntry({
    this.id,
    required this.messageId,
    required this.recipients,
    required this.encryptedBody,
    required this.contentType,
    this.attempts = 0,
    required this.createdAt,
    this.nextRetry,
    this.ackPending = 0,
    this.maxAttempts = 30,
    this.perDeviceStatus,
  });

  factory SendQueueEntry.fromMap(Map<String, dynamic> m) => SendQueueEntry(
        id: m['id'] as int?,
        messageId: m['message_id'] as String,
        recipients: (jsonDecode(m['recipients'] as String) as List)
            .map((e) => QueueRecipient.fromMap(e as Map<String, dynamic>))
            .toList(),
        encryptedBody: m['encrypted_body'] as Uint8List,
        contentType: m['content_type'] as String,
        attempts: m['attempts'] as int,
        createdAt: m['created_at'] as int,
        nextRetry: m['next_retry'] as int?,
        ackPending: (m['ack_pending'] as int?) ?? 0,
        maxAttempts: (m['max_attempts'] as int?) ?? 30,
        perDeviceStatus: m['per_device_status'] as String?,
      );

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'message_id': messageId,
        'recipients': jsonEncode(recipients.map((r) => r.toMap()).toList()),
        'encrypted_body': encryptedBody,
        'content_type': contentType,
        'attempts': attempts,
        'created_at': createdAt,
        if (nextRetry != null) 'next_retry': nextRetry,
        'ack_pending': ackPending,
        'max_attempts': maxAttempts,
        if (perDeviceStatus != null) 'per_device_status': perDeviceStatus,
      };
}

class QueueRecipient {
  final String pub;
  /// All known transport addresses: protocol → address.
  final Map<String, String> transportAddresses;

  QueueRecipient({
    required this.pub,
    Map<String, String>? transportAddresses,
  }) : transportAddresses = transportAddresses ?? {};

  factory QueueRecipient.fromMap(Map<String, dynamic> m) {
    final pub = m['pub'] as String;
    // New format: {"pub":"...","addrs":{"yggdrasil":"..."}}
    if (m.containsKey('addrs')) {
      final addrs = (m['addrs'] as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, v as String));
      return QueueRecipient(pub: pub, transportAddresses: addrs);
    }
    // Legacy format: {"pub":"...","ygg":"..."}
    final ygg = m['ygg'] as String?;
    return QueueRecipient(
      pub: pub,
      transportAddresses: ygg != null && ygg.isNotEmpty
          ? {'yggdrasil': ygg}
          : {},
    );
  }

  Map<String, dynamic> toMap() => {
        'pub': pub,
        if (transportAddresses.isNotEmpty) 'addrs': transportAddresses,
      };
}

class SendQueueDao {
  final Database _db;
  SendQueueDao(this._db);

  /// Visible for transaction support in ProcessReceiptUseCase.
  Database get db => _db;

  /// Insert or ignore if message_id already in queue (dedup).
  Future<int> insert(SendQueueEntry entry) async {
    return await _db.insert(
      'send_queue',
      entry.toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<List<SendQueueEntry>> allPending() async {
    final rows = await _db.query('send_queue', orderBy: 'created_at ASC');
    return rows.map(SendQueueEntry.fromMap).toList();
  }

  /// Decode the [perDeviceStatus] JSON for an entry. Empty map for v=1
  /// (no per-device tracking) or malformed JSON.
  static Map<String, String> parsePerDeviceStatus(SendQueueEntry e) {
    final raw = e.perDeviceStatus;
    if (raw == null || raw.isEmpty) return const {};
    try {
      return (jsonDecode(raw) as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {
      return const {};
    }
  }

  /// Initialise [perDeviceStatus] = {deviceId: 'sent', ...} for a v=2 row.
  Future<void> setPerDeviceStatus(int qid, Map<String, String> status) =>
      _db.update(
        'send_queue',
        {'per_device_status': jsonEncode(status)},
        where: 'id = ?',
        whereArgs: [qid],
      );

  /// Mark [deviceId] as [status] (typically 'acked') in the entry whose
  /// `message_id == messageId`. Returns the updated map, or null if no row
  /// or no per-device tracking on that row.
  Future<Map<String, String>?> markDeviceStatus(
    String messageId,
    String deviceId,
    String status,
  ) async {
    final rows = await _db.query(
      'send_queue',
      where: 'message_id = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final entry = SendQueueEntry.fromMap(rows.first);
    final current = parsePerDeviceStatus(entry);
    if (current.isEmpty) return null;
    final next = {...current, deviceId: status};
    await _db.update(
      'send_queue',
      {'per_device_status': jsonEncode(next)},
      where: 'id = ?',
      whereArgs: [entry.id],
    );
    return next;
  }

  /// True if every entry in [status] is 'acked'. Empty map → false (caller
  /// should treat untracked rows as legacy and use the existing single-ack
  /// behaviour).
  static bool allAcked(Map<String, String> status) =>
      status.isNotEmpty && status.values.every((v) => v == 'acked');

  /// Returns entries that need a send attempt:
  /// - not yet sent (ack_pending = 0) with next_retry <= now
  /// - already sent but no receipt yet (ack_pending = 1) with next_retry <= now
  Future<List<SendQueueEntry>> dueForRetry(int nowUnix) async {
    final rows = await _db.query(
      'send_queue',
      where: 'next_retry IS NULL OR next_retry <= ?',
      whereArgs: [nowUnix],
      orderBy: 'created_at ASC',
    );
    return rows.map(SendQueueEntry.fromMap).toList();
  }

  /// Mark entry as sent-pending-ack: transport accepted, waiting for receipt.
  Future<void> setPendingAck(int id, int nextRetryUnix) =>
      _db.update(
        'send_queue',
        {'ack_pending': 1, 'next_retry': nextRetryUnix},
        where: 'id = ?',
        whereArgs: [id],
      );

  Future<void> updateAttempt(int id, int attempts, int nextRetry) =>
      _db.update(
        'send_queue',
        {'attempts': attempts, 'next_retry': nextRetry},
        where: 'id = ?',
        whereArgs: [id],
      );

  Future<void> delete(int id) =>
      _db.delete('send_queue', where: 'id = ?', whereArgs: [id]);

  Future<void> deleteByMessageId(String messageId) =>
      _db.delete('send_queue', where: 'message_id = ?', whereArgs: [messageId]);

  /// Delete all queued messages to a specific recipient (e.g. when blocking).
  /// Uses JSON-contains check on the recipients column.
  Future<int> deleteForRecipient(String masterPub) =>
      _db.delete('send_queue',
          where: "recipients LIKE ?", whereArgs: ['%$masterPub%']);
}
