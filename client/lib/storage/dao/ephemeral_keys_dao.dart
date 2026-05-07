import 'dart:typed_data';
import 'package:sqflite_sqlcipher/sqflite.dart';

/// DAO for one-time ephemeral X25519 keypairs uploaded as KeyPackages.
///
/// Private keys are persisted in SQLCipher so they survive app restarts.
/// Each key is consumed (deleted) when the corresponding KeyPackage is used
/// to init an inbound session.
class EphemeralKeysDao {
  final Database _db;

  EphemeralKeysDao(this._db);

  /// Store a new ephemeral keypair keyed by base64-encoded public key.
  Future<void> insert(String ephPubB64, Uint8List ephPrivBytes) async {
    await _db.insert(
      'ephemeral_keys',
      {
        'eph_pub': ephPubB64,
        'eph_priv': ephPrivBytes,
        'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// Retrieve the private key for [ephPubB64], then delete it (one-time use).
  ///
  /// Returns null if not found.
  Future<Uint8List?> consume(String ephPubB64) async {
    final rows = await _db.query(
      'ephemeral_keys',
      columns: ['eph_priv'],
      where: 'eph_pub = ?',
      whereArgs: [ephPubB64],
      limit: 1,
    );
    if (rows.isEmpty) return null;

    final privBytes = rows.first['eph_priv'] as Uint8List;
    await _db.delete('ephemeral_keys', where: 'eph_pub = ?', whereArgs: [ephPubB64]);
    return privBytes;
  }

  /// Number of stored ephemeral keys (= KeyPackages we can respond to as receiver).
  Future<int> count() async {
    final result = await _db.rawQuery('SELECT COUNT(*) as c FROM ephemeral_keys');
    return (result.first['c'] as int?) ?? 0;
  }

  /// Delete ephemeral keys older than [ageSecs] seconds.
  ///
  /// Keys that were never consumed (peer never initiated a session) accumulate
  /// indefinitely otherwise. 30 days is a reasonable TTL.
  Future<int> deleteOlderThan(int ageSecs) async {
    final cutoff = DateTime.now().millisecondsSinceEpoch ~/ 1000 - ageSecs;
    return _db.delete('ephemeral_keys', where: 'created_at < ?', whereArgs: [cutoff]);
  }

  /// Delete all ephemeral keys (called by WipeService).
  Future<void> deleteAll() async {
    await _db.delete('ephemeral_keys');
  }
}
