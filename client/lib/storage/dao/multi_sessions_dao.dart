import 'dart:typed_data';
import 'package:sqflite_sqlcipher/sqflite.dart';

class MultiSessionRecord {
  final int? id;
  final int contactId;
  final String deviceId;
  final Uint8List rootKey;
  final Uint8List sendChainKey;
  final Uint8List recvChainKey;
  final Uint8List myEphPub;
  final Uint8List myEphPriv;
  final Uint8List? peerEphPub;
  final int sendCounter;
  final int recvCounter;
  final int recvCounterInChain;
  final int recvChainIndex;
  final String skippedKeys;
  final int updatedAt;
  final Uint8List? hmac;

  const MultiSessionRecord({
    this.id,
    required this.contactId,
    required this.deviceId,
    required this.rootKey,
    required this.sendChainKey,
    required this.recvChainKey,
    required this.myEphPub,
    required this.myEphPriv,
    this.peerEphPub,
    this.sendCounter = 0,
    this.recvCounter = 0,
    this.recvCounterInChain = 0,
    this.recvChainIndex = 0,
    this.skippedKeys = '[]',
    required this.updatedAt,
    this.hmac,
  });

  factory MultiSessionRecord.fromMap(Map<String, dynamic> m) => MultiSessionRecord(
    id: m['id'] as int?,
    contactId: m['contact_id'] as int,
    deviceId: m['device_id'] as String,
    rootKey: m['root_key'] as Uint8List,
    sendChainKey: m['send_chain_key'] as Uint8List,
    recvChainKey: m['recv_chain_key'] as Uint8List,
    myEphPub: m['my_eph_pub'] as Uint8List,
    myEphPriv: m['my_eph_priv'] as Uint8List,
    peerEphPub: m['peer_eph_pub'] as Uint8List?,
    sendCounter: m['send_counter'] as int? ?? 0,
    recvCounter: m['recv_counter'] as int? ?? 0,
    recvCounterInChain: m['recv_counter_in_chain'] as int? ?? 0,
    recvChainIndex: m['recv_chain_index'] as int? ?? 0,
    skippedKeys: m['skipped_keys'] as String? ?? '[]',
    updatedAt: m['updated_at'] as int,
    hmac: m['hmac'] as Uint8List?,
  );

  Map<String, dynamic> toMap() => {
    'contact_id': contactId,
    'device_id': deviceId,
    'root_key': rootKey,
    'send_chain_key': sendChainKey,
    'recv_chain_key': recvChainKey,
    'my_eph_pub': myEphPub,
    'my_eph_priv': myEphPriv,
    if (peerEphPub != null) 'peer_eph_pub': peerEphPub,
    'send_counter': sendCounter,
    'recv_counter': recvCounter,
    'recv_counter_in_chain': recvCounterInChain,
    'recv_chain_index': recvChainIndex,
    'skipped_keys': skippedKeys,
    'updated_at': updatedAt,
    if (hmac != null) 'hmac': hmac,
  };
}

class MultiSessionsDao {
  final Database _db;
  MultiSessionsDao(this._db);

  Future<void> upsert(MultiSessionRecord r) =>
      _db.insert('multi_sessions', r.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);

  Future<MultiSessionRecord?> forContactDevice(
      int contactId, String deviceId) async {
    final rows = await _db.query('multi_sessions',
        where: 'contact_id = ? AND device_id = ?',
        whereArgs: [contactId, deviceId],
        limit: 1);
    return rows.isEmpty ? null : MultiSessionRecord.fromMap(rows.first);
  }

  Future<List<MultiSessionRecord>> forContact(int contactId) async {
    final rows = await _db.query('multi_sessions',
        where: 'contact_id = ?', whereArgs: [contactId]);
    return rows.map(MultiSessionRecord.fromMap).toList();
  }

  Future<void> deleteForContact(int contactId) =>
      _db.delete('multi_sessions',
          where: 'contact_id = ?', whereArgs: [contactId]);

  Future<void> deleteForDevice(int contactId, String deviceId) =>
      _db.delete('multi_sessions',
          where: 'contact_id = ? AND device_id = ?',
          whereArgs: [contactId, deviceId]);
}
