import 'package:sqflite_sqlcipher/sqflite.dart';

class SettingsDao {
  final Database _db;
  SettingsDao(this._db);

  Future<String?> get(String key) async {
    final rows = await _db.query('settings', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> set(String key, String value) => _db.insert(
        'settings',
        {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<Map<String, String>> all() async {
    final rows = await _db.query('settings');
    return {for (final r in rows) r['key'] as String: r['value'] as String};
  }
}
