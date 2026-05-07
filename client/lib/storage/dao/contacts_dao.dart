import 'dart:convert';

import 'package:sqflite_sqlcipher/sqflite.dart';

import '../../domain/entities/contact.dart';
export '../../domain/entities/contact.dart';

class ContactsDao {
  final Database _db;
  ContactsDao(this._db);

  Future<int> insert(Contact c) =>
      _db.insert('contacts', c.toMap(), conflictAlgorithm: ConflictAlgorithm.ignore);

  Future<Contact?> findByYggPubKeyHex(String yggHex) async {
    final rows = await _db.query('contacts',
        where: 'ygg_pub_key_hex = ?', whereArgs: [yggHex]);
    return rows.isEmpty ? null : Contact.fromMap(rows.first);
  }

  Future<Contact?> findByMasterPub(String masterPub) async {
    final rows = await _db.query('contacts', where: 'master_pub = ?', whereArgs: [masterPub]);
    return rows.isEmpty ? null : Contact.fromMap(rows.first);
  }

  /// All contacts, optionally filtered by relationship.
  /// Pass [relationship] = 'contact' | 'stranger' | 'blocked' to filter.
  Future<List<Contact>> all({String? relationship}) async {
    final rows = await _db.query(
      'contacts',
      where: relationship != null ? 'relationship = ?' : null,
      whereArgs: relationship != null ? [relationship] : null,
      orderBy: 'alias ASC',
    );
    return rows.map(Contact.fromMap).toList();
  }

  Future<List<Contact>> strangers() => all(relationship: 'stranger');
  Future<List<Contact>> blocked()   => all(relationship: 'blocked');

  Future<void> setRelationship(String masterPub, String relationship) =>
      _db.update(
        'contacts',
        {'relationship': relationship},
        where: 'master_pub = ?',
        whereArgs: [masterPub],
      );

  Future<void> updateDevicesVersion(String masterPub, int version) =>
      _db.update(
        'contacts',
        {
          'devices_version': version,
          'devices_synced_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        },
        where: 'master_pub = ?',
        whereArgs: [masterPub],
      );

  Future<void> updateYggPubKey(String masterPub, String yggPubKeyHex) =>
      _db.update(
        'contacts',
        {'ygg_pub_key_hex': yggPubKeyHex},
        where: 'master_pub = ?',
        whereArgs: [masterPub],
      );

  Future<void> updateX25519Pub(String masterPub, String x25519Pub) =>
      _db.update(
        'contacts',
        {'x25519_pub': x25519Pub},
        where: 'master_pub = ?',
        whereArgs: [masterPub],
      );

  Future<void> updateSigningPub(String masterPub, String newSigningPub) =>
      _db.update(
        'contacts',
        {'signing_pub': newSigningPub},
        where: 'master_pub = ?',
        whereArgs: [masterPub],
      );

  Future<void> updateAlias(String masterPub, String alias) =>
      _db.update(
        'contacts',
        {'alias': alias},
        where: 'master_pub = ?',
        whereArgs: [masterPub],
      );

  /// Set alias as user-chosen — prevents auto-hello from overwriting it.
  Future<void> setCustomAlias(String masterPub, String alias) =>
      _db.update(
        'contacts',
        {'alias': alias, 'alias_customized': 1},
        where: 'master_pub = ?',
        whereArgs: [masterPub],
      );

  Future<void> touchLastSeen(String masterPub) =>
      _db.update(
        'contacts',
        {'last_seen': DateTime.now().millisecondsSinceEpoch ~/ 1000},
        where: 'master_pub = ?',
        whereArgs: [masterPub],
      );

  Future<void> updateLastSeen(String masterPub, int ts) =>
      _db.update(
        'contacts',
        {'last_seen': ts},
        where: 'master_pub = ?',
        whereArgs: [masterPub],
      );

  Future<void> setMuted(String masterPub, bool muted) =>
      _db.update(
        'contacts',
        {'muted': muted ? 1 : 0},
        where: 'master_pub = ?',
        whereArgs: [masterPub],
      );

  Future<void> delete(String masterPub) =>
      _db.delete('contacts', where: 'master_pub = ?', whereArgs: [masterPub]);

  /// Update a single transport address for [protocol] (e.g. 'yggdrasil', 'reticulum').
  /// Merges with existing addresses — does not overwrite other protocols.
  Future<void> updateTransportAddress(
      String masterPub, String protocol, String address) async {
    final contact = await findByMasterPub(masterPub);
    if (contact == null) return;
    final updated = Map<String, String>.from(contact.transportAddresses)
      ..[protocol] = address;
    await _db.update(
      'contacts',
      {'transport_addresses': jsonEncode(updated)},
      where: 'master_pub = ?',
      whereArgs: [masterPub],
    );
    // Keep legacy column in sync
    if (protocol == 'yggdrasil') {
      await updateYggPubKey(masterPub, address);
    }
  }
}
