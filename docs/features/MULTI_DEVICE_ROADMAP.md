# Multi-Device Roadmap

**Goal:** One identity, N devices. Each device has its own DR session per contact.
All devices receive all messages. Fully P2P, no central server.

**Model:** Master key is global (identity). Each device has its own X25519 keypair.
Sender encrypts once per recipient device. Devices of same user relay messages
to each other via Yggdrasil P2P.

---

## Resolved Design Problems

The following critical issues were identified during analysis and resolved before
implementation begins:

### Problem 1 (Critical): Device Discovery Without Server

**Issue:** `cross_device_inbox` was described as a local table, but if device B is
offline and device A receives a message, B never gets it — no one forwards it.

**Resolution: Device-as-relay pattern.**
- When contact C sends to user Bob, C encrypts for ALL of Bob's known devices
- Each device in the recipients list that is online processes its own copy
- If device B2 is offline, device B1 stores the raw MultiDevicePayload in its
  `cross_device_inbox` table, addressed for B2
- When B2 comes online, it sends a `device_sync_request` to B1 (known via
  my_devices table) — B1 responds with pending payloads
- B2 decrypts independently; no keys are shared between devices

**Wire message (new):**
```json
{ "type": "device_sync_request", "since_ts": 1700000000 }
{ "type": "device_sync_response", "payloads": [...] }
```

---

### Problem 2 (Critical): Signing Key Rotation with N Devices

**Issue:** Weekly signing key rotation — which device performs it? If only
device A rotates, device B still has the old cert and contacts see inconsistent
signing keys.

**Resolution: Master device owns rotation.**
- First registered device is `master_device` (flag in `my_devices`)
- Only master device generates new signing key + cert
- After rotation, master broadcasts cert_update to ALL own devices via
  `device_sync_response` mechanism
- Other devices apply the new cert and broadcast it to contacts via next contact_hello
- If master device is lost, user can promote another device to master via
  Settings → Devices

**New field:** `my_devices.is_master INTEGER DEFAULT 0`

---

### Problem 3 (Critical): DH Ratchet Desync Across Devices

**Issue:** DR performs a DH ratchet step every 100 messages (new ephemeral key).
Device B1 updates `peer_eph_pub`. Device B2 was offline — it still expects
the old eph key → decryption fails permanently.

**Resolution: No DH ratchet for multi-device sessions.**
- `multi_sessions` uses **symmetric-only ratchet** (chain key advancement only)
- DH ratchet step is disabled: `sendSinceRatchet` never triggers rotation
- This is the same trade-off Signal makes for sealed-sender multi-device
- Forward secrecy is provided by per-message key derivation from chain key
- When a device goes offline for a long time, it re-syncs via `device_sync_request`
  which provides fresh payloads; old chain state is preserved

**Implementation:** `encryptDmMultiDevice()` calls `_ratchet.encryptSymmetricOnly()`
which skips DH ratchet. New flag in `RatchetState.multiDeviceMode = true`.

---

### Problem 4 (Critical): sender_eph_sig Verification

**Issue:** Roadmap said `_identity.sign(_identity.devicePublicKey)` — unclear
which key signs. If device_key signs, receiver must know device_pubkey before
the first message, but it arrives via contact_hello which may come AFTER first message.

**Resolution:** `sender_eph_sig` is always signed by the **signing key** (same
as v=1). The device_pubkey is included in `contact_hello.devices[]` but is NOT
used for senderEphSig. This maintains backward compat and ensures verifiability
before device list is known.

---

### Problem 5 (High): New Device Not Visible to Contacts

**Issue:** After adding device B2, contacts still only know about B1 and continue
encrypting only for B1. B2 receives nothing.

**Resolution:** On device registration, immediately broadcast contact_hello to
all contacts with updated `devices[]` list. This is triggered by
`Identity.registerDevice()` emitting a `DeviceRegisteredEvent` which
`MessageRouter` listens to and calls `broadcastHello()`.

---

### Problem 6 (High): send_queue Retry for N Devices

**Issue:** `send_queue.encrypted_body` stores one ciphertext. Multi-device needs
N ciphertexts. On retry, already-delivered devices get duplicate decryption attempts.

**Resolution:** `send_queue.per_device_status` (JSON) tracks delivery per device:
```json
{"device_B1": "acked", "device_B2": "pending", "device_B3": "failed"}
```
Retry only sends to `pending` and `failed` devices. `acked` entries are skipped.
When all devices are `acked`, entry is removed from queue (existing behavior).

---

### Problem 7 (Medium): Delivery Receipts Semantics

**Issue:** When to send `msg_delivered`? After first device? After all devices?

**Resolution:** Send `msg_delivered` when **any** of the recipient's devices
processes the message and is explicitly opened (read). For transport-level
delivery (not read), the first device to receive sends `msg_received`.
UI shows: "✓✓ Доставлено" when at least one device delivered; no per-device breakdown
in v1 of this feature.

---

### Problem 8 (Medium): contact_hello Size with devices[]

**Issue:** With avatar (up to 32KB) + per-device data (~130 bytes × N), contact_hello
can grow to 33KB+ with 5 devices.

**Resolution:**
- Avatar is sent only when changed (hash-based caching, existing `alias_customized`
  pattern extended to avatar)
- `contact_hello` includes `devices_version` counter; receiver skips device list
  processing if version unchanged
- Delta updates: `devices_changed[]` + `devices_removed[]` when only partial update

---

## Key Hierarchy

```
User (logical)
  ├── Master Key (Ed25519, permanent)              ← global identity
  ├── Signing Key (Ed25519, weekly rotation)       ← rotated by master device only
  └── Devices
        ├── Device A  [master_device=1]
        │     ├── device_id = SHA256(masterPub || os || registered_at)
        │     ├── device_keypair (Ed25519) — cert signed by Master
        │     └── device_eph_keypair (X25519) — for initial DR handshake
        ├── Device B
        │     └── same, master_device=0
        └── Device N ...
```

---

## Wire Format v=2

```json
{
  "v": 2,
  "sender_device_id": "sha256hex",
  "sender_eph_pub":   "base64",
  "sender_eph_sig":   "base64",        // signed by signing_key (not device_key)
  "recipients": [
    { "device_id": "sha256hex", "ciphertext": "base64", "counter": 42 },
    { "device_id": "sha256hex", "ciphertext": "base64", "counter": 7  }
  ],
  "t":   86400,
  "id":  "hex8",
  "rid": "hex8 or null"
}
```

Size: ~400 bytes base + ~100 bytes per device.
3 devices → ~700 bytes. 5 devices → ~900 bytes.

---

## contact_hello Extension

```json
{
  "type": "contact_hello",
  "devices_version": 5,
  "devices_changed": [
    {
      "device_id":     "sha256hex",
      "device_pubkey": "base58",
      "device_eph_pub":"base58",
      "device_cert":   "base64",
      "transport_addresses": {"yggdrasil": "...", "reticulum": "..."},
      "os": "android"
    }
  ],
  "devices_removed": ["sha256hex_old_device"]
}
```

Existing fields unchanged. `devices_changed` only sent when `devices_version`
differs from receiver's cached version.

---

## Database Schema (migration v24)

```sql
-- My own devices
CREATE TABLE my_devices (
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
  is_master       INTEGER NOT NULL DEFAULT 0   -- only one master allowed
);

-- Contact's devices
CREATE TABLE contact_devices (
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
);

-- Per-device DR sessions (symmetric-only ratchet, no DH step)
CREATE TABLE multi_sessions (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  contact_id      INTEGER NOT NULL REFERENCES contacts(id),
  device_id       TEXT    NOT NULL,
  root_key        BLOB    NOT NULL,
  send_chain_key  BLOB    NOT NULL,
  recv_chain_key  BLOB    NOT NULL,
  my_eph_pub      BLOB    NOT NULL,
  my_eph_priv     BLOB    NOT NULL,
  peer_eph_pub    BLOB,
  send_counter    INTEGER NOT NULL DEFAULT 0,
  recv_counter    INTEGER NOT NULL DEFAULT 0,
  recv_counter_in_chain  INTEGER NOT NULL DEFAULT 0,
  recv_chain_index       INTEGER NOT NULL DEFAULT 0,
  skipped_keys    TEXT    NOT NULL DEFAULT '[]',
  updated_at      INTEGER NOT NULL,
  hmac            BLOB,
  UNIQUE(contact_id, device_id)
);

-- Inbox for messages to our other (offline) devices
CREATE TABLE cross_device_inbox (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  message_id      TEXT    NOT NULL UNIQUE,
  sender_pub      TEXT    NOT NULL,
  sender_device_id TEXT,
  target_device_ids TEXT  NOT NULL,   -- JSON array
  encrypted_payload BLOB  NOT NULL,   -- raw MultiDevicePayload bytes
  received_at     INTEGER NOT NULL,
  processed       INTEGER NOT NULL DEFAULT 0,
  expires_at      INTEGER             -- TTL, NULL = keep until processed
);

-- contacts additions
ALTER TABLE contacts ADD COLUMN devices_version  INTEGER NOT NULL DEFAULT 0;
ALTER TABLE contacts ADD COLUMN devices_synced_at INTEGER;

-- messages: which device sent/received
ALTER TABLE messages ADD COLUMN sender_device_id TEXT;

-- send_queue: per-device delivery tracking
ALTER TABLE send_queue ADD COLUMN per_device_status TEXT;  -- JSON
```

---

## Implementation Plan

### Phase 1 — Device Identity + DB (Week 1)

**`crypto/identity.dart`**
- Add `deviceId`, `devicePublicKey`, `devicePrivateKey`, `isMasterDevice`
- Add `registerDevice(isMaster: bool)`: generates device_id, keypair, cert
- Cert = `Sign(masterPriv, devicePubkey || os || registered_at)`

**`infrastructure/keystore/keystore_service.dart`**
- New keys: `hubcore.device_id`, `hubcore.device_pub`, `hubcore.device_priv`, `hubcore.device_is_master`

**`storage/database.dart`**
- Migration v24: all new tables

**`storage/dao/`**
- `my_devices_dao.dart`, `contact_devices_dao.dart`
- `multi_sessions_dao.dart`, `cross_device_inbox_dao.dart`

---

### Phase 2 — Device Discovery (Week 1–2)

**`infrastructure/crypto/messaging_service.dart`**

Extend `_handleContactHello()`:
```dart
final devicesVersion = json['devices_version'] as int? ?? 0;
final cachedVersion  = contact.devicesVersion ?? 0;
if (devicesVersion > cachedVersion) {
  for (final d in json['devices_changed'] ?? []) {
    await _storage.contactDevices.upsert(ContactDevice.fromJson(d, contact.id!));
  }
  for (final id in json['devices_removed'] ?? []) {
    await _storage.contactDevices.deactivate(contact.id!, id);
  }
  await _storage.contacts.updateDevicesVersion(senderPub, devicesVersion);
}
```

**`network/message_router.dart`**

Extend `buildContactHello` callback to include devices list.
Listen to `DeviceRegisteredEvent` → trigger `broadcastHello()`.

---

### Phase 3 — Multi-Device Session Manager (Week 2)

**`infrastructure/crypto/session_manager.dart`**

```dart
Future<RatchetState?> loadDeviceSession(int contactId, String deviceId);
Future<void> saveDeviceSession(int contactId, String deviceId, RatchetState s);
Future<List<String>> activeDeviceIdsFor(int contactId);

// Symmetric-only init (no DH ratchet)
Future<void> initOutboundForDevice({
  required int contactId,
  required String deviceId,
  required Uint8List peerDeviceEphPub,
});
```

**`crypto/double_ratchet.dart`**

Add `encryptSymmetricOnly()` — same as `encrypt()` but never triggers
DH ratchet (ignores `sendSinceRatchet >= 100` condition).
Used exclusively for multi-device sessions.

---

### Phase 4 — Multi-Device Encryption (Week 2–3)

**`infrastructure/crypto/dm_payload_codec.dart`**

New `MultiDevicePayload` class with `decode()` / `encode()`.
`DmPayload` unchanged for v=1 backward compat.

**`infrastructure/crypto/messaging_service.dart`**

New `encryptDmMultiDevice()`:
1. Fetch active devices for contact from `contact_devices`
2. If empty → fallback to single-device v=1
3. For each device: init or load session from `multi_sessions`
4. Call `_ratchet.encryptSymmetricOnly(state, plaintext)` per device
5. Build `MultiDevicePayload`

---

### Phase 5 — Multi-Device Decryption (Week 3)

**`infrastructure/crypto/messaging_service.dart`**

New `receiveEnvelopeMultiDevice()`:
1. Find `recipients` entry for `MY_DEVICE_ID`
2. If found: decrypt, save message, emit events as normal
3. If not found: store raw payload in `cross_device_inbox` for other own devices

**`application/use_cases/messaging/receive_envelope_use_case.dart`**

Detect `"v": 2` in payload, route to `receiveEnvelopeMultiDevice()`.
Fallback: if `v` missing or 1 → existing `DmPayload` path.

---

### Phase 6 — Cross-Device Sync (Week 3–4)

**`services/device_sync_service.dart`** (new)

```dart
class DeviceSyncService {
  // Called at app start and on ContactHelloReceivedEvent from own devices
  Future<void> requestSync(String ownDeviceYggAddress) async {
    // Send device_sync_request to all own devices
    // They respond with pending cross_device_inbox entries
  }

  Future<void> handleSyncRequest(String fromDeviceId) async {
    // Send all unprocessed cross_device_inbox entries for fromDeviceId
  }

  Future<void> processSyncResponse(List<Uint8List> payloads) async {
    // For each payload: call receiveEnvelopeMultiDevice()
    // Mark as processed in cross_device_inbox
  }
}
```

New wire types: `device_sync_request`, `device_sync_response`
Processed in `receive_envelope_use_case.dart`.

---

### Phase 7 — Signing Key Rotation (Week 4)

**`infrastructure/crypto/messaging_service.dart`**

Signing key rotation only on master device:
```dart
Future<void> rotateSingingKey() async {
  if (!_identity.isMasterDevice) return; // non-master devices skip
  // ... existing rotation logic ...
  // After rotation: broadcast cert_update to own devices via device_sync
  await _deviceSync.broadcastCertToOwnDevices(newCert);
}
```

Own devices receive new cert via `device_sync_response`, update
their signing key, then include it in next contact_hello.

---

### Phase 8 — send_queue Multi-Device (Week 4)

**`services/queue_service.dart`**

Extend `_trySend()` to handle `per_device_status`:
```dart
final statusMap = jsonDecode(entry.perDeviceStatus ?? '{}');
for (final recipient in payload.recipients) {
  if (statusMap[recipient.deviceId] == 'acked') continue;
  // Send to this device only
  final result = await _transport.sendEnvelope(...);
  if (result.success) statusMap[recipient.deviceId] = 'sent';
}
await _storage.sendQueue.updatePerDeviceStatus(entry.id!, statusMap);
```

Entry deleted from queue only when all devices are `acked`.

---

### Phase 9 — Device Management UI (Week 4–5)

**`features/settings/devices_screen.dart`** (new):
```
Мои устройства
──────────────────────────────────────────
  📱 Samsung Galaxy (этот)     [Master] [активен]
  💻 Pixel Tablet              [был: 2ч назад]
  ──────────────────────────────
  [+ Добавить устройство]
  [Экспорт аккаунта]
```

- "Добавить устройство" → shows QR with device_cert + master_pub
- Tap device → "Удалить устройство" → deactivates, broadcasts revocation
- "Назначить главным" → promotes to master (old master demoted)

**Settings → Security → Linked Devices** row (existing settings_screen.dart).

---

### Phase 10 — Backward Compatibility (Week 5)

**Sending to legacy contact (no entries in contact_devices):**
- Use v=1 `DmPayload` — no change

**Receiving v=1 on multi-device client:**
- Parse as `DmPayload`
- Use existing `sessions` table (not `multi_sessions`)

**Migration of existing sessions:**
```dart
// On first launch after upgrade: copy sessions → multi_sessions
// with default device_id = SHA256(masterPub || "_legacy")
final defaultDeviceId = sha256(masterPub + "_legacy");
await storage.multiSessions.migrateFrom(storage.sessions, defaultDeviceId);
```

---

## Effort Estimate

| Phase | Task | Days |
|---|---|---|
| 1 | Device identity + DB | 4 |
| 2 | Device discovery | 3 |
| 3 | Multi-session manager + symmetric ratchet | 4 |
| 4 | Multi-device encryption | 4 |
| 5 | Multi-device decryption | 3 |
| 6 | Cross-device sync service | 5 |
| 7 | Signing key rotation on master | 2 |
| 8 | send_queue multi-device | 3 |
| 9 | Device management UI | 4 |
| 10 | Backward compat + migration | 3 |
| — | Integration testing (3+ devices) | 5 |
| **Total** | | **~40 days** |

---

## Security Properties

| Property | Status | Notes |
|---|---|---|
| E2E encryption | ✅ | Each device decrypts independently |
| Forward secrecy | ✅ (partial) | Per-message keys via symmetric ratchet; DH ratchet disabled for multi-device sessions |
| Break-in recovery | ⚠️ | Weaker than single-device: no DH ratchet means longer exposure window after compromise |
| Device isolation | ✅ | Compromising device B doesn't expose device A's chain keys |
| Master key compromise | ❌ | Attacker can register new devices if master key leaked |
| Signing key rotation | ✅ | Master device owns rotation, synced to other devices |
| Device revocation | ✅ | Deactivate in my_devices + broadcast revocation via contact_hello |
| Offline delivery | ✅ | cross_device_inbox via P2P device-as-relay |

**Note on forward secrecy trade-off:** Using symmetric-only ratchet for
multi-device sessions reduces forward secrecy compared to single-device DR.
This is the same trade-off made by Signal for multi-device. Future improvement:
gossip DH ratchet state between own devices when both are online.

---

## Out of Scope (v1)

- Message history sync between own devices
- Read receipt sync between own devices ("read on tablet" shown on phone)
- Simultaneous send from two devices to same contact (last-write-wins)
- DH ratchet gossip between own devices (future improvement)
- More than 5 active devices per user (soft limit recommended)
