import 'dart:convert';
import 'dart:typed_data';
import 'package:sqflite_sqlcipher/sqflite.dart';

class ContactDevice {
  final int? id;
  final int contactId;
  final String deviceId;
  final Uint8List devicePubkey;
  final Uint8List? deviceEphPub;
  final Uint8List? deviceCert;
  final String? deviceOs;
  final Map<String, String> transportAddresses;
  final int? registeredAt;
  final int? lastSeen;
  final bool isActive;

  const ContactDevice({
    this.id,
    required this.contactId,
    required this.deviceId,
    required this.devicePubkey,
    this.deviceEphPub,
    this.deviceCert,
    this.deviceOs,
    this.transportAddresses = const {},
    this.registeredAt,
    this.lastSeen,
    this.isActive = true,
  });

  factory ContactDevice.fromMap(Map<String, dynamic> m) {
    Map<String, String> addrs = {};
    final raw = m['transport_addresses'] as String?;
    if (raw != null && raw.isNotEmpty) {
      try { addrs = Map<String, String>.from(jsonDecode(raw)); } catch (_) {}
    }
    return ContactDevice(
      id: m['id'] as int?,
      contactId: m['contact_id'] as int,
      deviceId: m['device_id'] as String,
      devicePubkey: m['device_pubkey'] as Uint8List,
      deviceEphPub: m['device_eph_pub'] as Uint8List?,
      deviceCert: m['device_cert'] as Uint8List?,
      deviceOs: m['device_os'] as String?,
      transportAddresses: addrs,
      registeredAt: m['registered_at'] as int?,
      lastSeen: m['last_seen'] as int?,
      isActive: (m['is_active'] as int? ?? 1) == 1,
    );
  }

  Map<String, dynamic> toMap() => {
    'contact_id': contactId,
    'device_id': deviceId,
    'device_pubkey': devicePubkey,
    if (deviceEphPub != null) 'device_eph_pub': deviceEphPub,
    if (deviceCert != null) 'device_cert': deviceCert,
    if (deviceOs != null) 'device_os': deviceOs,
    if (transportAddresses.isNotEmpty)
      'transport_addresses': jsonEncode(transportAddresses),
    if (registeredAt != null) 'registered_at': registeredAt,
    if (lastSeen != null) 'last_seen': lastSeen,
    'is_active': isActive ? 1 : 0,
  };
}

class ContactDevicesDao {
  final Database _db;
  ContactDevicesDao(this._db);

  Future<void> upsert(ContactDevice d) =>
      _db.insert('contact_devices', d.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);

  Future<List<ContactDevice>> forContact(int contactId) async {
    final rows = await _db.query('contact_devices',
        where: 'contact_id = ? AND is_active = 1',
        whereArgs: [contactId]);
    return rows.map(ContactDevice.fromMap).toList();
  }

  Future<ContactDevice?> find(int contactId, String deviceId) async {
    final rows = await _db.query('contact_devices',
        where: 'contact_id = ? AND device_id = ?',
        whereArgs: [contactId, deviceId],
        limit: 1);
    return rows.isEmpty ? null : ContactDevice.fromMap(rows.first);
  }

  Future<void> deactivate(int contactId, String deviceId) =>
      _db.update('contact_devices', {'is_active': 0},
          where: 'contact_id = ? AND device_id = ?',
          whereArgs: [contactId, deviceId]);

  Future<void> touchLastSeen(int contactId, String deviceId) =>
      _db.update('contact_devices',
          {'last_seen': DateTime.now().millisecondsSinceEpoch ~/ 1000},
          where: 'contact_id = ? AND device_id = ?',
          whereArgs: [contactId, deviceId]);

  Future<void> deleteForContact(int contactId) =>
      _db.delete('contact_devices',
          where: 'contact_id = ?', whereArgs: [contactId]);
}
