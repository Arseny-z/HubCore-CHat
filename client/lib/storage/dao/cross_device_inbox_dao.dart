import 'dart:convert';
import 'dart:typed_data';
import 'package:sqflite_sqlcipher/sqflite.dart';

class CrossDeviceInboxEntry {
  final int? id;
  final String messageId;
  final String senderPub;
  final String? senderDeviceId;
  final List<String> targetDeviceIds;
  final Uint8List encryptedPayload;
  final int receivedAt;
  final bool processed;
  final int? expiresAt;

  const CrossDeviceInboxEntry({
    this.id,
    required this.messageId,
    required this.senderPub,
    this.senderDeviceId,
    required this.targetDeviceIds,
    required this.encryptedPayload,
    required this.receivedAt,
    this.processed = false,
    this.expiresAt,
  });

  factory CrossDeviceInboxEntry.fromMap(Map<String, dynamic> m) {
    List<String> targets = [];
    try {
      targets = List<String>.from(jsonDecode(m['target_device_ids'] as String));
    } catch (_) {}
    return CrossDeviceInboxEntry(
      id: m['id'] as int?,
      messageId: m['message_id'] as String,
      senderPub: m['sender_pub'] as String,
      senderDeviceId: m['sender_device_id'] as String?,
      targetDeviceIds: targets,
      encryptedPayload: m['encrypted_payload'] as Uint8List,
      receivedAt: m['received_at'] as int,
      processed: (m['processed'] as int? ?? 0) == 1,
      expiresAt: m['expires_at'] as int?,
    );
  }

  Map<String, dynamic> toMap() => {
    'message_id': messageId,
    'sender_pub': senderPub,
    if (senderDeviceId != null) 'sender_device_id': senderDeviceId,
    'target_device_ids': jsonEncode(targetDeviceIds),
    'encrypted_payload': encryptedPayload,
    'received_at': receivedAt,
    'processed': processed ? 1 : 0,
    if (expiresAt != null) 'expires_at': expiresAt,
  };
}

class CrossDeviceInboxDao {
  final Database _db;
  CrossDeviceInboxDao(this._db);

  Future<void> insert(CrossDeviceInboxEntry e) =>
      _db.insert('cross_device_inbox', e.toMap(),
          conflictAlgorithm: ConflictAlgorithm.ignore);

  /// Pending entries where target_device_ids contains [deviceId].
  Future<List<CrossDeviceInboxEntry>> pendingFor(String deviceId) async {
    final rows = await _db.query('cross_device_inbox',
        where: "processed = 0 AND target_device_ids LIKE ?",
        whereArgs: ['%$deviceId%'],
        orderBy: 'received_at ASC');
    return rows
        .map(CrossDeviceInboxEntry.fromMap)
        .where((e) => e.targetDeviceIds.contains(deviceId))
        .toList();
  }

  Future<void> markProcessed(int id) =>
      _db.update('cross_device_inbox', {'processed': 1},
          where: 'id = ?', whereArgs: [id]);

  /// Delete entries older than [cutoffSeconds] that are already processed.
  Future<void> evictExpired() async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _db.delete('cross_device_inbox',
        where: 'processed = 1 OR (expires_at IS NOT NULL AND expires_at < ?)',
        whereArgs: [now]);
  }
}
