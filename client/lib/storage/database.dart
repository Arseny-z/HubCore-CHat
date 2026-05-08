import 'dart:typed_data';
import 'package:sqflite_sqlcipher/sqflite.dart';

/// SQLCipher-encrypted database.
///
/// Call [open] with the db encryption key after user authenticates.
/// Call [close] / [lock] when the app goes to background.
class AppDatabase {
  static const _dbName = 'hubcore.db';
  static const _schemaVersion = 25;

  Database? _db;

  Database get db {
    if (_db == null) throw StateError('Database is locked — call open() first.');
    return _db!;
  }

  bool get isOpen => _db != null;

  /// Returns the resolved path to the database file, or null if not yet opened.
  Future<String?> dbPath() async {
    try {
      return await databaseFactory.getDatabasesPath().then((dir) => '$dir/$_dbName');
    } catch (_) {
      return null;
    }
  }

  Future<void> open(Uint8List key) async {
    if (_db != null) return;
    // Convert to hex string required by SQLCipher, then zero the raw bytes
    // immediately — the hex String itself is immutable in Dart and will be
    // collected by GC; raw bytes are the higher-risk copy.
    final hexKey = _bytesToHexKey(key);
    key.fillRange(0, key.length, 0);
    _db = await openDatabase(
      _dbName,
      password: hexKey,
      version: _schemaVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE contacts (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        master_pub  TEXT    NOT NULL UNIQUE,  -- base58
        signing_pub TEXT    NOT NULL,         -- base58 (latest)
        x25519_pub      TEXT,                  -- base58 X25519 identity key (from QR)
        ygg_pub_key_hex      TEXT,              -- hex Ed25519 Yggdrasil node key (legacy, mirrors transport_addresses)
        transport_addresses  TEXT,              -- JSON map protocol→address (e.g. {"yggdrasil":"fd00::...","reticulum":"..."})
        alias       TEXT    NOT NULL DEFAULT '',
        alias_customized INTEGER NOT NULL DEFAULT 0,  -- 1 = user edited manually, auto-hello won't overwrite
        added_at    INTEGER NOT NULL,         -- unix seconds
        last_seen   INTEGER,
        muted       INTEGER NOT NULL DEFAULT 0,  -- 1 = notifications silenced
        relationship TEXT    NOT NULL DEFAULT 'contact',  -- 'contact'|'stranger'|'blocked'
        devices_version  INTEGER NOT NULL DEFAULT 0,
        devices_synced_at INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE sessions (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        contact_id      INTEGER NOT NULL REFERENCES contacts(id),
        root_key        BLOB    NOT NULL,
        send_chain_key  BLOB    NOT NULL,
        recv_chain_key  BLOB    NOT NULL,
        my_eph_pub      BLOB    NOT NULL,
        my_eph_priv     BLOB    NOT NULL,  -- encrypted at DB level by SQLCipher
        peer_eph_pub    BLOB,
        send_counter    INTEGER NOT NULL DEFAULT 0,
        recv_counter    INTEGER NOT NULL DEFAULT 0,
        send_since_ratchet INTEGER NOT NULL DEFAULT 0,
        recv_counter_in_chain INTEGER NOT NULL DEFAULT 0,
        recv_chain_index      INTEGER NOT NULL DEFAULT 0,
        skipped_keys          TEXT    NOT NULL DEFAULT '[]',
        updated_at      INTEGER NOT NULL,
        hmac            BLOB                    -- BLAKE2b-MAC over key material (v21+)
      )
    ''');

    await db.execute('CREATE INDEX idx_sessions_contact ON sessions(contact_id)');

    await db.execute('''
      CREATE TABLE groups (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        group_id    TEXT    NOT NULL UNIQUE,  -- random base58
        name        TEXT    NOT NULL,
        admin_pub   TEXT,                     -- base58 master pubkey of creator (legacy, kept for compat)
        owner_pub   TEXT,                     -- base58 original creator — cannot be demoted
        created_at  INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE group_members (
        group_id    TEXT    NOT NULL REFERENCES groups(group_id),
        master_pub  TEXT    NOT NULL REFERENCES contacts(master_pub),
        chain_key   BLOB    NOT NULL,
        ratchet_pub BLOB,
        counter     INTEGER NOT NULL DEFAULT 0,
        role        TEXT    NOT NULL DEFAULT 'write',  -- 'admin'|'write'|'read'|'banned'
        PRIMARY KEY (group_id, master_pub)
      )
    ''');

    await db.execute('''
      CREATE TABLE messages (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id TEXT    NOT NULL,  -- master_pub for DM, group_id for group
        is_group        INTEGER NOT NULL DEFAULT 0,
        sender_pub      TEXT    NOT NULL,
        body            BLOB    NOT NULL,  -- plaintext (DB itself is encrypted)
        content_type    TEXT    NOT NULL DEFAULT 'text',
        sent_at         INTEGER NOT NULL,
        received_at     INTEGER,
        status          TEXT    NOT NULL DEFAULT 'sent',  -- queued|sent|delivered|read
        expires_at      INTEGER,            -- unix seconds; NULL = no expiry
        message_id      TEXT,               -- hex-8 random ID for delivery receipts
        transport       TEXT,               -- 'yggdrasil'|'reticulum'|'meshcore'|null
        reply_to_id     TEXT                -- messageId of the quoted message (null = no reply)
      )
    ''');
    await db.execute('CREATE INDEX idx_messages_conv ON messages(conversation_id, sent_at)');
    await db.execute('CREATE INDEX idx_messages_mid ON messages(message_id)');
    await db.execute('CREATE INDEX idx_messages_expires ON messages(expires_at) WHERE expires_at IS NOT NULL');

    await db.execute('''
      CREATE TABLE send_queue (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        message_id      TEXT    NOT NULL,
        recipients      TEXT    NOT NULL,  -- JSON [{"pub":"...","addrs":{...}}]
        encrypted_body  BLOB    NOT NULL,  -- ready-to-send Envelope.body bytes (DR encrypted once)
        content_type    TEXT    NOT NULL DEFAULT 'text',
        attempts        INTEGER NOT NULL DEFAULT 0,
        created_at      INTEGER NOT NULL,
        next_retry      INTEGER,
        ack_pending     INTEGER NOT NULL DEFAULT 0,  -- 1 = sent, waiting for msg_delivered
        max_attempts    INTEGER NOT NULL DEFAULT 30,  -- 0=unlimited; delete entry after N retries
        per_device_status TEXT                        -- JSON: {device_id: sent|acked|failed}
      )
    ''');
    await db.execute('CREATE UNIQUE INDEX idx_send_queue_mid ON send_queue(message_id)');
    await db.execute('CREATE INDEX idx_send_queue_retry ON send_queue(next_retry)');

    await db.execute('''
      CREATE TABLE message_receipts (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        message_id    TEXT    NOT NULL,
        recipient_pub TEXT    NOT NULL,
        transport     TEXT,
        status        TEXT    NOT NULL DEFAULT 'queued',  -- queued|sent|delivered|read
        sent_at       INTEGER,
        delivered_at  INTEGER,
        read_at       INTEGER,
        UNIQUE(message_id, recipient_pub)
      )
    ''');
    await db.execute('CREATE INDEX idx_receipts_message ON message_receipts(message_id)');

    await db.execute('''
      CREATE TABLE files (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        message_id      INTEGER REFERENCES messages(id),
        file_key        BLOB    NOT NULL,  -- 32-byte XChaCha20-Poly1305 key
        file_nonce      BLOB    NOT NULL,
        local_path      TEXT    NOT NULL,
        mime_type       TEXT,
        size_bytes      INTEGER NOT NULL,
        created_at      INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE settings (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    await db.execute('CREATE INDEX idx_contacts_relationship ON contacts(relationship)');
    await _createEphemeralKeys(db);
    await _createNotifications(db);
    await _createMultiDeviceTables(db);
    await _createMessageReactions(db);

    // Default settings
    await db.execute(
      "INSERT INTO settings(key, value) VALUES ('polling_interval', 'fiveMinutes')",
    );
    await db.execute(
      "INSERT INTO settings(key, value) VALUES ('incoming_contacts_policy', 'all')",
    );
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _createEphemeralKeys(db);
    }
    if (oldVersion < 3) {
      await db.execute('ALTER TABLE contacts ADD COLUMN x25519_pub TEXT');
    }
    if (oldVersion < 4) {
      await db.execute('ALTER TABLE contacts ADD COLUMN ygg_pub_key_hex TEXT');
    }
    if (oldVersion < 5) {
      await db.execute('ALTER TABLE messages ADD COLUMN expires_at INTEGER');
    }
    if (oldVersion < 6) {
      await db.execute('ALTER TABLE sessions ADD COLUMN recv_counter_in_chain INTEGER NOT NULL DEFAULT 0');
      await db.execute('ALTER TABLE sessions ADD COLUMN recv_chain_index INTEGER NOT NULL DEFAULT 0');
      await db.execute("ALTER TABLE sessions ADD COLUMN skipped_keys TEXT NOT NULL DEFAULT '[]'");
    }
    if (oldVersion < 7) {
      await db.execute('ALTER TABLE messages ADD COLUMN message_id TEXT');
    }
    if (oldVersion < 8) {
      await db.execute('ALTER TABLE contacts ADD COLUMN transport_addresses TEXT');
    }
    if (oldVersion < 9) {
      await db.execute("ALTER TABLE contacts ADD COLUMN alias TEXT NOT NULL DEFAULT ''");
    }
    if (oldVersion < 10) {
      await db.execute('ALTER TABLE messages ADD COLUMN transport TEXT');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS send_queue (
          id           INTEGER PRIMARY KEY AUTOINCREMENT,
          message_id   TEXT    NOT NULL,
          recipients   TEXT    NOT NULL,
          plaintext    TEXT    NOT NULL,
          content_type TEXT    NOT NULL DEFAULT 'text',
          attempts     INTEGER NOT NULL DEFAULT 0,
          created_at   INTEGER NOT NULL,
          next_retry   INTEGER
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS message_receipts (
          id            INTEGER PRIMARY KEY AUTOINCREMENT,
          message_id    TEXT    NOT NULL,
          recipient_pub TEXT    NOT NULL,
          transport     TEXT,
          status        TEXT    NOT NULL DEFAULT 'queued',
          sent_at       INTEGER,
          delivered_at  INTEGER,
          read_at       INTEGER,
          UNIQUE(message_id, recipient_pub)
        )
      ''');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_receipts_message ON message_receipts(message_id)');
    }
    if (oldVersion < 11) {
      await _createNotifications(db);
    }
    if (oldVersion < 12) {
      // ack_pending: 1 = transport sent but no msg_delivered receipt yet
      await db.execute(
          'ALTER TABLE send_queue ADD COLUMN ack_pending INTEGER NOT NULL DEFAULT 0');
    }
    if (oldVersion < 13) {
      await db.execute(
          'ALTER TABLE send_queue ADD COLUMN max_attempts INTEGER NOT NULL DEFAULT 30');
    }
    if (oldVersion < 14) {
      await db.execute(
          'ALTER TABLE messages ADD COLUMN reply_to_id TEXT');
    }
    if (oldVersion < 15) {
      await db.execute(
          'ALTER TABLE contacts ADD COLUMN muted INTEGER NOT NULL DEFAULT 0');
    }
    if (oldVersion < 16) {
      // Replace plaintext column with encrypted_body blob.
      // SQLite doesn't support DROP COLUMN before 3.35 — recreate table.
      await db.execute('''
        CREATE TABLE send_queue_new (
          id              INTEGER PRIMARY KEY AUTOINCREMENT,
          message_id      TEXT    NOT NULL,
          recipients      TEXT    NOT NULL,
          encrypted_body  BLOB    NOT NULL DEFAULT '',
          content_type    TEXT    NOT NULL DEFAULT 'text',
          attempts        INTEGER NOT NULL DEFAULT 0,
          created_at      INTEGER NOT NULL,
          next_retry      INTEGER,
          ack_pending     INTEGER NOT NULL DEFAULT 0,
          max_attempts    INTEGER NOT NULL DEFAULT 30
        )
      ''');
      // Old rows are dropped — they would re-encrypt incorrectly anyway.
      await db.execute('DROP TABLE send_queue');
      await db.execute('ALTER TABLE send_queue_new RENAME TO send_queue');
    }
    if (oldVersion < 17) {
      // Indices for production workloads — fast lookups by message_id.
      await db.execute('CREATE INDEX IF NOT EXISTS idx_messages_mid ON messages(message_id)');
      await db.execute('CREATE UNIQUE INDEX IF NOT EXISTS idx_send_queue_mid ON send_queue(message_id)');
    }
    if (oldVersion < 18) {
      await db.execute('CREATE INDEX IF NOT EXISTS idx_sessions_contact ON sessions(contact_id)');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_send_queue_retry ON send_queue(next_retry)');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_messages_expires ON messages(expires_at) WHERE expires_at IS NOT NULL');
    }
    if (oldVersion < 19) {
      await db.execute('ALTER TABLE groups ADD COLUMN admin_pub TEXT');
    }
    if (oldVersion < 20) {
      await db.execute('ALTER TABLE contacts ADD COLUMN alias_customized INTEGER NOT NULL DEFAULT 0');
    }
    if (oldVersion < 21) {
      await db.execute('ALTER TABLE sessions ADD COLUMN hmac BLOB');
    }
    if (oldVersion < 22) {
      await db.execute(
        "ALTER TABLE contacts ADD COLUMN relationship TEXT NOT NULL DEFAULT 'contact'",
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_contacts_relationship ON contacts(relationship)',
      );
      // Default setting: anyone can start a conversation
      await db.execute(
        "INSERT OR IGNORE INTO settings(key, value) VALUES ('incoming_contacts_policy', 'all')",
      );
    }
    if (oldVersion < 23) {
      // Add role column to group_members: 'admin'|'write'|'read'|'banned'
      await db.execute(
        "ALTER TABLE group_members ADD COLUMN role TEXT NOT NULL DEFAULT 'write'",
      );
      // Add owner_pub to groups (original creator, cannot be demoted)
      await db.execute('ALTER TABLE groups ADD COLUMN owner_pub TEXT');
      // Migrate: existing admin_pub → role='admin' in group_members, owner_pub in groups
      await db.execute('''
        UPDATE group_members SET role = 'admin'
        WHERE (group_id, master_pub) IN (
          SELECT group_id, admin_pub FROM groups WHERE admin_pub IS NOT NULL
        )
      ''');
      await db.execute(
        'UPDATE groups SET owner_pub = admin_pub WHERE admin_pub IS NOT NULL',
      );
    }
    if (oldVersion < 24) {
      await _createMultiDeviceTables(db);
      // Add device tracking columns to contacts
      await db.execute(
        'ALTER TABLE contacts ADD COLUMN devices_version INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE contacts ADD COLUMN devices_synced_at INTEGER',
      );
      // Add sender_device_id to messages
      await db.execute(
        'ALTER TABLE messages ADD COLUMN sender_device_id TEXT',
      );
      // Add per_device_status to send_queue
      await db.execute(
        'ALTER TABLE send_queue ADD COLUMN per_device_status TEXT',
      );
    }
    if (oldVersion < 25) {
      await _createMessageReactions(db);
    }
  }

  static Future<void> _createMessageReactions(Database db) async {
    // One reaction per (message_id, reactor_pub) — Telegram-style.
    // Lookups are always by message_id, so we index it.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS message_reactions (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        message_id   TEXT    NOT NULL,
        reactor_pub  TEXT    NOT NULL,
        emoji        TEXT    NOT NULL,
        created_at   INTEGER NOT NULL,
        UNIQUE(message_id, reactor_pub)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_reactions_message '
      'ON message_reactions(message_id)');
  }

  static Future<void> _createNotifications(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS notifications (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        type        TEXT    NOT NULL,   -- 'group_invite'
        payload     TEXT    NOT NULL,   -- JSON blob
        from_pub    TEXT    NOT NULL,   -- sender masterPub
        created_at  INTEGER NOT NULL,
        status      TEXT    NOT NULL DEFAULT 'pending'  -- pending|accepted|declined
      )
    ''');
  }

  static Future<void> _createEphemeralKeys(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ephemeral_keys (
        eph_pub   TEXT PRIMARY KEY,  -- base64 X25519 public key
        eph_priv  BLOB NOT NULL,     -- raw private key bytes (DB encrypted by SQLCipher)
        created_at INTEGER NOT NULL
      )
    ''');
  }

  static Future<void> _createMultiDeviceTables(Database db) async {
    // My own registered devices
    await db.execute('''
      CREATE TABLE IF NOT EXISTS my_devices (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        device_id       TEXT    NOT NULL UNIQUE,
        device_pubkey   BLOB    NOT NULL,
        device_eph_pub  BLOB,
        device_cert     BLOB,
        device_os       TEXT    NOT NULL DEFAULT 'android',
        transport_addresses TEXT,
        registered_at   INTEGER NOT NULL,
        last_heartbeat  INTEGER,
        is_active       INTEGER NOT NULL DEFAULT 1,
        is_master       INTEGER NOT NULL DEFAULT 0
      )
    ''');

    // Devices of each contact (for multi-device encryption)
    await db.execute('''
      CREATE TABLE IF NOT EXISTS contact_devices (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        contact_id      INTEGER NOT NULL REFERENCES contacts(id),
        device_id       TEXT    NOT NULL,
        device_pubkey   BLOB    NOT NULL,
        device_eph_pub  BLOB,
        device_cert     BLOB,
        device_os       TEXT,
        transport_addresses TEXT,
        registered_at   INTEGER,
        last_seen       INTEGER,
        is_active       INTEGER NOT NULL DEFAULT 1,
        UNIQUE(contact_id, device_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_contact_devices_contact ON contact_devices(contact_id)',
    );

    // Per-device DR sessions (symmetric-only ratchet)
    await db.execute('''
      CREATE TABLE IF NOT EXISTS multi_sessions (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        contact_id      INTEGER NOT NULL REFERENCES contacts(id),
        device_id       TEXT    NOT NULL,
        root_key        BLOB    NOT NULL,
        send_chain_key  BLOB    NOT NULL,
        recv_chain_key  BLOB    NOT NULL,
        my_eph_pub      BLOB    NOT NULL,
        my_eph_priv     BLOB    NOT NULL,
        peer_eph_pub    BLOB,
        send_counter             INTEGER NOT NULL DEFAULT 0,
        recv_counter             INTEGER NOT NULL DEFAULT 0,
        recv_counter_in_chain    INTEGER NOT NULL DEFAULT 0,
        recv_chain_index         INTEGER NOT NULL DEFAULT 0,
        skipped_keys    TEXT    NOT NULL DEFAULT '[]',
        updated_at      INTEGER NOT NULL,
        hmac            BLOB,
        UNIQUE(contact_id, device_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_multi_sessions_contact ON multi_sessions(contact_id)',
    );

    // Inbox for messages addressed to our other (offline) devices
    await db.execute('''
      CREATE TABLE IF NOT EXISTS cross_device_inbox (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        message_id      TEXT    NOT NULL UNIQUE,
        sender_pub      TEXT    NOT NULL,
        sender_device_id TEXT,
        target_device_ids TEXT  NOT NULL,
        encrypted_payload BLOB  NOT NULL,
        received_at     INTEGER NOT NULL,
        processed       INTEGER NOT NULL DEFAULT 0,
        expires_at      INTEGER
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_cross_device_unprocessed ON cross_device_inbox(processed, expires_at)',
    );
  }

  /// SQLCipher key must be a hex string: "x'<64 hex chars>'"
  static String _bytesToHexKey(Uint8List key) {
    final hex = key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return "x'$hex'";
  }
}
