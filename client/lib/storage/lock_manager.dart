import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sodium_libs/sodium_libs.dart';

import '../shared/utils/logger.dart';
import 'storage_service.dart';

const _kDbKey          = 'hubcore.db_key';
const _kPinHash        = 'hubcore.pin_hash';        // legacy BLAKE2b — kept for migration
const _kPinHashV2      = 'hubcore.pin_hash_v2';     // Argon2id PHC string
const _kDuressPinHash  = 'hubcore.duress_pin_hash'; // Argon2id PHC string (new installs)
const _kFailedAttempts = 'hubcore.failed_attempts';
const _kSessionMacKey  = 'hubcore.session_mac';     // 32-byte key for session HMAC
const _kMaxAttempts    = 10;

enum UnlockResult { success, wrongPin, wiped, notConfigured, keyMismatch }

/// Manages the DB encryption key and PIN-based unlock.
///
/// PIN hashing: Argon2id via libsodium pwhash (INTERACTIVE parameters).
/// Legacy BLAKE2b hashes (v1) are silently upgraded to Argon2id on first
/// successful unlock so existing users are not locked out.
///
/// Architecture:
///   - DB key = 32 random bytes stored in platform Keystore (never derived from PIN)
///   - PIN only gates *access* to the key — Argon2id adds cost against offline attacks
///   - Attempt counter (max 10) protects against online brute-force
class LockManager {
  final Sodium _sodium;
  final StorageService _storage;
  final FlutterSecureStorage _secure;

  bool get isUnlocked => _storage.isOpen;

  /// 32-byte BLAKE2b MAC key loaded after successful unlock.
  /// Used by SessionManager for session integrity checks.
  Uint8List? _sessionMacKey;
  Uint8List? get sessionMacKey => _sessionMacKey;

  LockManager(this._sodium, this._storage)
      : _secure = const FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true),
        );

  // ── Setup ──────────────────────────────────────────────────────────────────

  Future<bool> hasPin() async {
    try {
      final v2 = await _secure.read(key: _kPinHashV2);
      if (v2 != null) return true;
      return (await _secure.read(key: _kPinHash)) != null;
    } catch (e) {
      AppLogger.w('LockManager', 'hasPin: secure storage read failed ($e)');
      return false;
    }
  }

  Future<void> initPin(String pin, {String? duressPin}) async {
    await _storage.close();

    try {
      final dbPath = await _storage.dbPath();
      if (dbPath != null) {
        final f = io.File(dbPath);
        if (await f.exists()) {
          await f.delete();
          AppLogger.d('LockManager', 'initPin: deleted existing DB file');
        }
      }
    } catch (e) {
      AppLogger.w('LockManager', 'initPin: could not delete DB file ($e)');
    }

    final dbKey = _sodium.randombytes.buf(32);
    try {
      final dbKeyB64 = base64.encode(dbKey);
      await _secure.write(key: _kDbKey, value: dbKeyB64);

      final hash = await _hashPin(pin);
      await _secure.write(key: _kPinHashV2, value: hash);
      await _secure.delete(key: _kPinHash); // remove legacy if present
      await _secure.write(key: _kFailedAttempts, value: '0');

      if (duressPin != null && duressPin.isNotEmpty) {
        await _secure.write(key: _kDuressPinHash, value: await _hashPin(duressPin));
      }

      // Generate session MAC key
      final macKey = _sodium.randombytes.buf(32);
      await _secure.write(key: _kSessionMacKey, value: base64.encode(macKey));
      _sessionMacKey = macKey;

      await _storage.open(dbKey);
    } finally {
      dbKey.fillRange(0, dbKey.length, 0);
    }
  }

  // ── Unlock ─────────────────────────────────────────────────────────────────

  Future<UnlockResult> unlock(String pin, {required void Function() onWipe}) async {
    final String? storedHashV2;
    final String? storedHashV1;
    try {
      storedHashV2 = await _secure.read(key: _kPinHashV2);
      storedHashV1 = await _secure.read(key: _kPinHash);
    } catch (e) {
      AppLogger.w('LockManager', 'unlock: secure storage read failed ($e)');
      return UnlockResult.notConfigured;
    }

    if (storedHashV2 == null && storedHashV1 == null) {
      return UnlockResult.notConfigured;
    }

    // Check duress PIN (Argon2id only — no legacy duress)
    try {
      final duressHash = await _secure.read(key: _kDuressPinHash);
      if (duressHash != null && await _verifyPin(pin, duressHash)) {
        await _wipe(onWipe);
        return UnlockResult.wiped;
      }
    } catch (_) {}

    // Check attempt counter
    int attempts = 0;
    try {
      attempts = int.parse(await _secure.read(key: _kFailedAttempts) ?? '0');
    } catch (_) {}
    if (attempts >= _kMaxAttempts) {
      await _wipe(onWipe);
      return UnlockResult.wiped;
    }

    // Verify PIN
    bool correct = false;
    bool needsMigration = false;

    if (storedHashV2 != null) {
      correct = await _verifyPin(pin, storedHashV2);
    } else if (storedHashV1 != null) {
      correct = _verifyPinLegacy(pin, storedHashV1);
      needsMigration = correct;
    }

    if (!correct) {
      try {
        await _secure.write(key: _kFailedAttempts, value: '${attempts + 1}');
      } catch (_) {}
      return UnlockResult.wrongPin;
    }

    // Correct PIN
    try {
      await _secure.write(key: _kFailedAttempts, value: '0');
    } catch (_) {}

    // Migrate legacy hash to Argon2id
    if (needsMigration) {
      try {
        final newHash = await _hashPin(pin);
        await _secure.write(key: _kPinHashV2, value: newHash);
        await _secure.delete(key: _kPinHash);
        AppLogger.i('LockManager', 'PIN migrated from BLAKE2b to Argon2id');
      } catch (e) {
        AppLogger.w('LockManager', 'PIN migration failed ($e) — will retry next unlock');
      }
    }

    return await _openDb(onWipe);
  }

  Future<UnlockResult> _openDb(void Function() onWipe) async {
    final String? dbKeyB64;
    try {
      dbKeyB64 = await _secure.read(key: _kDbKey);
    } catch (e) {
      AppLogger.w('LockManager', 'unlock: failed to read db key ($e)');
      await _wipe(onWipe);
      return UnlockResult.wiped;
    }

    if (dbKeyB64 == null) {
      AppLogger.w('LockManager', 'unlock: dbKey is null');
      await _wipe(onWipe);
      return UnlockResult.wiped;
    }

    try {
      final dbKey = base64.decode(dbKeyB64);
      if (dbKey.length != 32) {
        AppLogger.e('LockManager', 'unlock: dbKey length ${dbKey.length} != 32');
        dbKey.fillRange(0, dbKey.length, 0);
        await _wipe(onWipe);
        return UnlockResult.wiped;
      }
      try {
        await _storage.open(Uint8List.fromList(dbKey));
        AppLogger.d('LockManager', 'unlock: DB opened');
        // Load session MAC key
        try {
          final macB64 = await _secure.read(key: _kSessionMacKey);
          if (macB64 != null) {
            _sessionMacKey = base64.decode(macB64);
          } else {
            // Generate for existing installs that predate v21
            final macKey = _sodium.randombytes.buf(32);
            await _secure.write(key: _kSessionMacKey, value: base64.encode(macKey));
            _sessionMacKey = macKey;
          }
        } catch (e) {
          AppLogger.w('LockManager', 'session MAC key load failed ($e)');
        }
      } finally {
        dbKey.fillRange(0, dbKey.length, 0);
      }
    } catch (e) {
      AppLogger.e('LockManager', 'unlock: DB open failed: $e');
      final msg = e.toString().toLowerCase();
      if (msg.contains('not a database') ||
          msg.contains('notadb') ||
          msg.contains('file is encrypted') ||
          msg.contains('sqlite_notadb')) {
        return UnlockResult.keyMismatch;
      }
      rethrow;
    }
    return UnlockResult.success;
  }

  // ── Attempt counter ────────────────────────────────────────────────────────

  Future<int> failedAttempts() async {
    try {
      return int.parse(await _secure.read(key: _kFailedAttempts) ?? '0');
    } catch (_) {
      return 0;
    }
  }

  int get maxAttempts => _kMaxAttempts;

  // ── Lock ───────────────────────────────────────────────────────────────────

  Future<void> lock() => _storage.close();

  // ── PIN change ─────────────────────────────────────────────────────────────

  Future<bool> checkPin(String pin) async {
    final v2 = await _secure.read(key: _kPinHashV2);
    if (v2 != null) return _verifyPin(pin, v2);
    final v1 = await _secure.read(key: _kPinHash);
    if (v1 != null) return _verifyPinLegacy(pin, v1);
    return false;
  }

  Future<bool> changePin(String oldPin, String newPin) async {
    if (!await checkPin(oldPin)) return false;
    final hash = await _hashPin(newPin);
    await _secure.write(key: _kPinHashV2, value: hash);
    await _secure.delete(key: _kPinHash);
    return true;
  }

  Future<void> setDuressPin(String pin) async =>
      _secure.write(key: _kDuressPinHash, value: await _hashPin(pin));

  Future<void> clearDuressPin() async =>
      _secure.delete(key: _kDuressPinHash);

  // ── Wipe ───────────────────────────────────────────────────────────────────

  Future<void> wipe() => _wipe(() {});

  Future<void> _wipe(void Function() onWipe) async {
    try {
      await _secure.deleteAll();
    } catch (e) {
      AppLogger.e('LockManager', 'CRITICAL: key wipe failed', error: e);
    }
    try {
      await _storage.close();
    } catch (_) {}
    _sessionMacKey = null;
    onWipe();
  }

  // ── PIN hashing (Argon2id) ─────────────────────────────────────────────────

  /// Hash PIN with Argon2id (libsodium pwhash). Returns PHC-format string.
  /// Salt is embedded in the returned string — no separate storage needed.
  Future<String> _hashPin(String pin) async {
    return _sodium.crypto.pwhash.str(
      password: pin,
      opsLimit: _sodium.crypto.pwhash.opsLimitInteractive,
      memLimit: _sodium.crypto.pwhash.memLimitInteractive,
    );
  }

  /// Constant-time Argon2id verification (libsodium strVerify).
  Future<bool> _verifyPin(String pin, String phcHash) async {
    try {
      return _sodium.crypto.pwhash.strVerify(
        passwordHash: phcHash,
        password: pin,
      );
    } catch (_) {
      return false;
    }
  }

  /// Legacy BLAKE2b verification — used only during migration.
  bool _verifyPinLegacy(String pin, String storedB64) {
    final bytes = Uint8List.fromList(utf8.encode(pin));
    final hash = _sodium.crypto.genericHash.call(outLen: 32, message: bytes);
    final computed = base64.encode(hash);
    // constant-time compare
    if (computed.length != storedB64.length) return false;
    int diff = 0;
    for (int i = 0; i < computed.length; i++) {
      diff |= computed.codeUnitAt(i) ^ storedB64.codeUnitAt(i);
    }
    return diff == 0;
  }
}
