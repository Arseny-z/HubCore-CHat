# Client (Flutter)

Android from a single codebase.

## Requirements

- **Android**: API 23+ (Android 6.0, 2015) — required for Android Keystore
- **Flutter**: 3.x+, Dart 3.x+

## Structure

```
client/
├── lib/
│   ├── main.dart
│   ├── app.dart                      — MaterialApp, routing, themes
│   │
│   ├── crypto/                       — crypto core
│   │   ├── identity.dart             — Master + Signing keypair, signatures, rotation
│   │   ├── double_ratchet.dart       — Double Ratchet protocol
│   │   ├── sender_keys.dart          — Sender Keys for groups
│   │   ├── file_crypto.dart          — file encryption
│   │   └── keystore.dart             — Android Keystore
│   │
│   ├── storage/                      — local storage
│   │   ├── database.dart             — SQLCipher initialization
│   │   ├── lock_manager.dart         — DB lock / unlock
│   │   ├── wipe_service.dart         — cryptographic storage erasure
│   │   ├── dao/
│   │   │   ├── contacts_dao.dart
│   │   │   ├── messages_dao.dart
│   │   │   ├── sessions_dao.dart
│   │   │   ├── groups_dao.dart
│   │   │   └── files_dao.dart
│   │   └── migrations/
│   │
│   ├── network/                      — network layer
│   │   └── message_router.dart      — incoming message routing
│   │
│   ├── features/
│   │   ├── onboarding/               — key generation, first launch
│   │   ├── contacts/                 — contact list, QR scanner
│   │   ├── chat/                     — direct chat
│   │   ├── groups/                   — group chats
│   │   ├── files/                    — file transfer
│   │   └── settings/                 — app settings
│   │
│   └── shared/
│       ├── models/                   — data models
│       ├── widgets/                  — reusable widgets
│       └── utils/                    — utilities (base58, qr, etc.)
│
├── android/
│   └── app/src/main/kotlin/          — Keystore platform channel
├── test/
│   ├── crypto/                       — crypto unit tests
│   └── integration/                  — integration tests
└── pubspec.yaml
```

## Dependencies

```yaml
# pubspec.yaml
dependencies:
  # Crypto
  sodium_libs: ^2.0.0               # FFI to libsodium

  # DB
  sqflite_sqlcipher: ^2.0.0         # SQLite + SQLCipher encryption

  # Secure key storage
  flutter_secure_storage: ^9.0.0    # Android Keystore / iOS Keychain

  # QR code
  qr_flutter: ^4.1.0                # QR generation
  mobile_scanner: ^3.5.0            # QR scanning

  # Serialization
  messagepack: ^0.2.0               # MessagePack

  # State management
  flutter_riverpod: ^2.4.0
  riverpod_annotation: ^2.3.0

  # UI
  go_router: ^12.0.0

dev_dependencies:
  build_runner: ^2.4.0
  riverpod_generator: ^2.3.0
  flutter_test:
    sdk: flutter
```

## Crypto — libsodium Integration

```dart
// crypto/identity.dart
import 'package:sodium_libs/sodium_libs.dart';

class Identity {
  final Uint8List publicKey;   // Ed25519, 32 bytes
  // privateKey stored in Keystore, not in Dart memory

  static Future<Identity> generate() async {
    final keypair = await Sodium.instance.crypto.sign.keypair();
    // Store privateKey in Keystore
    await KeystoreService.storeIdentityKey(keypair.secretKey);
    return Identity(publicKey: keypair.publicKey);
  }

  Future<Uint8List> sign(Uint8List message) async {
    final privateKey = await KeystoreService.getIdentityKey();
    return Sodium.instance.crypto.sign.detached(
      message: message,
      secretKey: privateKey,
    );
  }

  String get fingerprint {
    // BLAKE3(publicKey)[0:16] → hex → "A3F2-9B1C-E847-2D05"
    final hash = Blake3.hash(publicKey).sublist(0, 16);
    return _formatFingerprint(hash);
  }

  String get qrData => base58.encode(publicKey);
}
```

## Lock / Unlock

```dart
// storage/lock_manager.dart
class LockManager {
  Uint8List? _dbKey;  // null = locked

  bool get isLocked => _dbKey == null;

  // Unlock: biometrics or PIN → retrieve DBKey from Keystore
  Future<bool> unlock({String? pin}) async {
    final key = await KeystoreService.getDbKey(pin: pin);
    if (key == null) return false;
    _dbKey = key;
    await Database.instance.open(key);
    return true;
  }

  // Lock: instant
  Future<void> lock() async {
    _dbKey = Uint8List(32)..fillRange(0, 32, 0); // zero out
    _dbKey = null;
    await Database.instance.close();
  }
}
```

## Database Schema (SQLCipher)

```sql
-- Contacts
CREATE TABLE contacts (
    pubkey      TEXT PRIMARY KEY,   -- base58 Ed25519 pubkey
    name        TEXT NOT NULL,
    fingerprint TEXT NOT NULL,
    verified    INTEGER DEFAULT 0,  -- 1 if fingerprint manually verified
    added_at    INTEGER NOT NULL
);

-- Double Ratchet sessions
CREATE TABLE sessions (
    peer_pubkey         TEXT PRIMARY KEY,
    root_key            BLOB NOT NULL,
    send_chain_key      BLOB NOT NULL,
    recv_chain_key      BLOB NOT NULL,
    send_counter        INTEGER DEFAULT 0,
    recv_counter        INTEGER DEFAULT 0,
    my_ephemeral_key    BLOB NOT NULL,
    peer_ephemeral_key  BLOB,
    last_ratchet_at     INTEGER NOT NULL,
    next_ratchet_after  INTEGER DEFAULT 100,
    updated_at          INTEGER NOT NULL
);

-- Messages
CREATE TABLE messages (
    id          TEXT PRIMARY KEY,   -- message UUID
    chat_id     TEXT NOT NULL,      -- contact pubkey or group_id
    sender      TEXT NOT NULL,
    type        INTEGER NOT NULL,   -- 1=text, 2=file, 3=voice, 4=video
    content     TEXT,               -- text content
    file_id     TEXT,               -- reference to files
    status      INTEGER DEFAULT 0,  -- 0=sending, 1=sent, 2=delivered, 3=read
    created_at  INTEGER NOT NULL
);

-- Files
CREATE TABLE files (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    mime        TEXT NOT NULL,
    size        INTEGER NOT NULL,
    file_key    BLOB NOT NULL,      -- FileKey encrypted with DBKey
    local_path  TEXT,               -- path after download
    hash        BLOB NOT NULL,      -- BLAKE3 hash of original
    created_at  INTEGER NOT NULL
);

-- Groups
CREATE TABLE groups (
    id               TEXT PRIMARY KEY,
    name             TEXT NOT NULL,
    admin_pubkey     TEXT NOT NULL,
    epoch            INTEGER DEFAULT 0,
    sender_chain_key BLOB NOT NULL,
    created_at       INTEGER NOT NULL
);

CREATE TABLE group_members (
    group_id    TEXT NOT NULL,
    pubkey      TEXT NOT NULL,
    added_at    INTEGER NOT NULL,
    PRIMARY KEY (group_id, pubkey)
);

-- Settings
CREATE TABLE settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
```

## Platform Channels — Android Keystore

Native code is required for Android Keystore operations:

```kotlin
// android/app/src/main/kotlin/.../KeystorePlugin.kt
class KeystorePlugin : FlutterPlugin, MethodCallHandler {
    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "generateKey" -> generateKeyInKeystore(call.argument("alias")!!, result)
            "sign"        -> signWithKeystore(call.argument("alias")!!, call.argument("data")!!, result)
            "encrypt"     -> encryptWithKeystore(call.argument("data")!!, result)
            "decrypt"     -> decryptWithKeystore(call.argument("data")!!, result)
            else          -> result.notImplemented()
        }
    }
}
```

`flutter_secure_storage` covers most cases — native channel is only needed for biometric authentication and signing without key extraction.

## Vault — Storage Structure

```
/data/data/com.hubcore.chat/              (inaccessible without root on Android)
├── databases/
│   └── hubcore.db                       (SQLCipher — chats, contacts, metadata)
└── files/
    └── vault/
        ├── files/                     (encrypted files, each with its own FileKey)
        ├── voice/                     (voice messages)
        └── video/                     (video circles)
```

Media files are not stored in SQLite — only metadata and FileKey. Each file is encrypted with an individual FileKey (XChaCha20-Poly1305). FileKey is stored in the `files` table, encrypted with DBKey.

```dart
// storage/vault.dart
class Vault {
  static Directory get filesDir  => Directory('${appDir}/vault/files');
  static Directory get voiceDir  => Directory('${appDir}/vault/voice');
  static Directory get videoDir  => Directory('${appDir}/vault/video');
  static File      get dbFile    => File('${appDir}/databases/hubcore.db');
}
```

## WipeService — Cryptographic Erasure

### Why overwrite doesn't work on mobile

On SSD / eMMC / UFS (all modern Android) the filesystem uses wear leveling — on write, data goes to a **new** flash block, the old one is marked free but not physically erased. Overwriting a file does not reach the old data.

**The only reliable method** is cryptographic erasure: destroy the encryption keys. Data remains on disk, but without keys becomes random noise.

### Android Keystore — hardware key deletion

```
Android 9+ with StrongBox (Pixel: Titan M, Samsung: Knox):
  deleteEntry() → command goes to the secure chip
  Chip physically erases the key memory cell
  Root access to Android cannot help recover it

Android 6-8 (TEE):
  Key in Trusted Execution Environment
  deleteEntry() removes from isolated area
  Recovery is practically impossible
```

### WipeService Implementation

```dart
// storage/wipe_service.dart
enum WipeReason { userRequest, panicButton, pinBruteforce }

class WipeService {

  // Full cryptographic destruction of storage
  Future<void> wipeAll(WipeReason reason) async {
    // 1. Close DB if open
    await Database.instance.close();

    // 2. Delete all keys from Keystore
    //    After this step all data is cryptographically inaccessible
    await _keystoreService.deleteKey('hubcore_master_key');
    await _keystoreService.deleteKey('hubcore_signing_key');
    await _keystoreService.deleteKey('hubcore_db_key');

    // 3. Delete vault files (may remain on disk physically,
    //    but without FileKey from DB — unreadable; without DBKey — FileKey inaccessible too)
    await _deleteDirectory(Vault.filesDir);
    await _deleteDirectory(Vault.voiceDir);
    await _deleteDirectory(Vault.videoDir);

    // 4. Delete DB file
    await Vault.dbFile.delete();

    // 5. Clear SharedPreferences (settings)
    await SharedPreferences.getInstance().then((p) => p.clear());

    // 6. Intentionally NOT sent to any server — would reveal that wipe occurred
  }
}
```

### Wipe Scenarios

**Scenario 1: Settings → "Reset account"**
```
Confirmation → PIN entry → WipeService.wipeAll(userRequest)
→ app restarts as on first launch
```

**Scenario 2: Panic Wipe**
```
Settings → Security → Panic Wipe
  Gesture: hold lock button for 3 seconds
  OR special "destruction PIN" (e.g. 0000 when main PIN is 1234)

→ WipeService.wipeAll(panicButton) without confirmation
→ instant, < 1 second (Keystore deletion is synchronous)
→ app shows empty onboarding screen
```

**Scenario 3: Brute-force protection**
```
Settings → Security → After N wrong PINs:
  [ ] Lock for 30 minutes
  [ ] Erase storage  ← WipeService.wipeAll(pinBruteforce)

Default: erase after 10 attempts
```

### Post-wipe Guarantees

| What remains | Readable? |
|---|---|
| hubcore.db file (if not deleted by FS) | No — DBKey destroyed in Keystore |
| vault/ files (if not deleted by FS) | No — FileKey was in DB, DBKey destroyed |
| Keys in Keystore | No — physically deleted from TEE/StrongBox |

## UI Security

```dart
// Screenshot prevention (Android)
// In AndroidManifest.xml:
// android:flags="FLAG_SECURE"

// Auto-lock
AppLifecycleListener(
  onPause: () => LockManager.instance.lock(),  // background → lock
);

// Encryption indicator in chat
// Shows session key fingerprint
// "Verify" button — compare fingerprint with contact
```
