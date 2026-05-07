import 'dart:convert';
import 'dart:typed_data';
import 'package:sqflite_sqlcipher/sqflite.dart';

class MyDevice {
  final int? id;
  final String deviceId;
  final Uint8List devicePubkey;
  final Uint8List? deviceEphPub;
  final Uint8List? deviceCert;
  final String deviceOs;
  final Map<String, String> transportAddresses;
  final int registeredAt;
  final int? lastHeartbeat;
  final bool isActive;
  final bool isMaster;

  const MyDevice({
    this.id,
    required this.deviceId,
    required this.devicePubkey,
    this.deviceEphPub,
    this.deviceCert,
    this.deviceOs = 'android',
    this.transportAddresses = const {},
    required this.registeredAt,
    this.lastHeartbeat,
    this.isActive = true,
    this.isMaster = false,
  });

  factory MyDevice.fromMap(Map<String, dynamic> m) {
    Map<String, String> addrs = {};
    final raw = m['transport_addresses'] as String?;
    if (raw != null && raw.isNotEmpty) {
      try { addrs = Map<String, String>.from(jsonDecode(raw)); } catch (_) {}
    }
    return MyDevice(
      id: m['id'] as int?,
      deviceId: m['device_id'] as String,
      devicePubkey: m['device_pubkey'] as Uint8List,
      deviceEphPub: m['device_eph_pub'] as Uint8List?,
      deviceCert: m['device_cert'] as Uint8List?,
      deviceOs: m['device_os'] as String? ?? 'android',
      transportAddresses: addrs,
      registeredAt: m['registered_at'] as int,
      lastHeartbeat: m['last_heartbeat'] as int?,
      isActive: (m['is_active'] as int? ?? 1) == 1,
      isMaster: (m['is_master'] as int? ?? 0) == 1,
    );
  }

  Map<String, dynamic> toMap() => {
    'device_id': deviceId,
    'device_pubkey': devicePubkey,
    if (deviceEphPub != null) 'device_eph_pub': deviceEphPub,
    if (deviceCert != null) 'device_cert': deviceCert,
    'device_os': deviceOs,
    if (transportAddresses.isNotEmpty)
      'transport_addresses': jsonEncode(transportAddresses),
    'registered_at': registeredAt,
    if (lastHeartbeat != null) 'last_heartbeat': lastHeartbeat,
    'is_active': isActive ? 1 : 0,
    'is_master': isMaster ? 1 : 0,
  };
}

class MyDevicesDao {
  final Database _db;
  MyDevicesDao(this._db);

  Future<void> upsert(MyDevice d) =>
      _db.insert('my_devices', d.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);

  Future<List<MyDevice>> all() async {
    final rows = await _db.query('my_devices', orderBy: 'registered_at ASC');
    return rows.map(MyDevice.fromMap).toList();
  }

  Future<List<MyDevice>> active() async {
    final rows = await _db.query('my_devices',
        where: 'is_active = 1', orderBy: 'registered_at ASC');
    return rows.map(MyDevice.fromMap).toList();
  }

  Future<MyDevice?> findById(String deviceId) async {
    final rows = await _db.query('my_devices',
        where: 'device_id = ?', whereArgs: [deviceId], limit: 1);
    return rows.isEmpty ? null : MyDevice.fromMap(rows.first);
  }

  Future<MyDevice?> masterDevice() async {
    final rows = await _db.query('my_devices',
        where: 'is_master = 1 AND is_active = 1', limit: 1);
    return rows.isEmpty ? null : MyDevice.fromMap(rows.first);
  }

  Future<void> updateHeartbeat(String deviceId) =>
      _db.update('my_devices',
          {'last_heartbeat': DateTime.now().millisecondsSinceEpoch ~/ 1000},
          where: 'device_id = ?', whereArgs: [deviceId]);

  Future<void> deactivate(String deviceId) =>
      _db.update('my_devices', {'is_active': 0},
          where: 'device_id = ?', whereArgs: [deviceId]);

  Future<void> promoteMaster(String deviceId) async {
    await _db.transaction((txn) async {
      await txn.update('my_devices', {'is_master': 0});
      await txn.update('my_devices', {'is_master': 1},
          where: 'device_id = ?', whereArgs: [deviceId]);
    });
  }
}
