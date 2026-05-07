# Device Pairing Roadmap

**Goal:** Allow a user to add a second (or third) device to their HubCore Chat identity so
that all devices receive and can send the same messages, without any central server.

**Current state:** All cryptographic infrastructure is ready (multi_sessions,
MultiDevicePayload v=2, DeviceSyncService, cross_device_inbox). The only missing
piece is the pairing UI and the handshake protocol that registers device B with
device A.

---

## How It Works (User Flow)

```
Device A (existing)               Device B (new, fresh install)
════════════════════               ══════════════════════════════

1. Settings → Devices → "+"
   → Generates QR (5-min TTL)
     QR contains encrypted
     identity_bundle + ygg_addr ─scan─> 2. Onboarding screen
                                           → "Войти с другого устройства"
                                           → Camera scans QR from A
                                           → Decrypts identity_bundle
                                           → Saves identity to keystore
                                           → Sends device_pairing_handshake

3. Receives handshake from B
   → Validates device cert
   → Saves B in my_devices
   → Sends ack to B         ─────> 4. Receives ack from A
                                       → Saves A in my_devices
                                       → Goes to /lock → ready

5. Broadcasts contact_hello to
   all contacts (with updated
   devices[] list)
```

---

## Security Design

**What the QR code contains (public data only — no private keys ever in QR):**
```json
{
  "type": "hubcore_pair_v1",
  "master_pub": "<base58>",
  "x25519_pub": "<base58>",
  "ygg_pub":    "<hex>",
  "ygg_addr":   "<fd00::...>",
  "token":      "<base64 XChaCha20-Poly1305 encrypted ephemeral key>",
  "expires_at": 1234567890
}
```

**Temporary token:**
- 32-byte ephemeral symmetric key, encrypted with BLAKE2b(masterPrivKey || "pairing")
- TTL: 5 minutes, single-use
- Allows device B to establish an encrypted channel to A without knowing A's private keys

**Handshake (device B → A, encrypted with temp key):**
```json
{
  "type":        "device_pairing_handshake",
  "device_id":   "<hex64>",
  "device_pub":  "<base64 Ed25519>",
  "device_cert": "<base64 DeviceCert>",
  "ygg_pub":     "<hex>",
  "transport_addresses": { "yggdrasil": "..." }
}
```

**Ack (device A → B, encrypted with temp key):**
```json
{
  "type":        "device_pairing_ack",
  "device_id_a": "<hex64>",
  "device_pub_a": "<base64>",
  "device_cert_a": "<base64>",
  "transport_addresses_a": { "yggdrasil": "..." }
}
```

**Security properties:**
- QR never contains private keys
- Token expires in 5 minutes and is single-use
- Handshake encrypted with ephemeral key (not reusable)
- DeviceCert validated: Sign(masterPriv, devicePub) — both devices share master key

---

## Identity Import for Device B

Device B needs the same master/signing/x25519 private keys as device A.

**Chosen approach: QR with encrypted identity bundle (no separate backup step)**

1. On A: Settings → Devices → "+" → shows pairing QR (5-min TTL)
   QR contains: `ephemeral_pub + encrypted_identity_bundle + ygg_addr + expires_at`
   `identity_bundle` = XChaCha20-Poly1305(temp_key, {master_priv, signing_priv, x25519_priv})
   `temp_key` = BLAKE2b(masterPriv || "pairing" || expires_at)
2. On B: onboarding → "Войти с другого устройства" → scans QR from A
3. B decrypts identity_bundle with temp_key → saves identity to keystore
4. B sends `device_pairing_handshake` to A (ygg_addr from QR)
5. A validates handshake → saves B in my_devices → sends ack → broadcastHello()
6. B receives ack → saves A in my_devices → goes to /lock

**Security properties:**
- QR never leaves the screen — physical proximity required to scan
- temp_key expires in 5 minutes and is derived from master private key (never transmitted)
- identity_bundle is encrypted with XChaCha20-Poly1305 — attacker with QR photo
  has at most 5 minutes to brute-force, and must know master private key to derive temp_key
- This is equivalent security to Signal's "Link Device" QR flow

---

## Device ID Stability

Device ID = `SHA-256(masterPub || osCode || registeredAt)`.
`registeredAt` is set **once** and stored in Keystore. It must NOT change on
app reinstall (but can change on Clear Data, which is acceptable — treat it as a new
device registration).

**On import:** Device B generates a new `registeredAt = now()` → new device_id.
This is correct — B is a different device even if it shares the master key.

---

## Implementation Plan

### Phase 1 — Crypto Layer (2 days)

**New: `lib/infrastructure/crypto/device_pairing_crypto.dart`**
```dart
class DevicePairingCrypto {
  // Device A: generate QR payload with encrypted identity bundle
  // identity_bundle = XChaCha20(temp_key, {master_priv, signing_priv, x25519_priv})
  // temp_key = BLAKE2b(masterPriv || "pairing" || expires_at)
  PairingQrPayload generatePairingQr(Identity identity, String yggPub, String yggAddr);

  // Device B: decrypt identity bundle from QR and reconstruct Identity
  Identity decryptIdentityFromQr(PairingQrPayload qr, Sodium sodium);

  // Encrypt/decrypt handshake with temp_key (for device_pairing_handshake msg)
  Uint8List encryptHandshake(Map json, Uint8List tempKey);
  Map decryptHandshake(Uint8List encrypted, Uint8List tempKey);

  // Validate device certificate: Sign(masterPriv, devicePub || os || registered_at)
  bool validateDeviceCert(Uint8List devicePub, Uint8List certBytes, Uint8List masterPub);
}
```

**New: `lib/domain/entities/device_pairing_payload.dart`**
```dart
class PairingQrPayload { ... encode()/decode() ... }
// QR JSON: {"type":"hubcore_pair_v1","mp":"<base58>","bundle":"<base64 encrypted>",
//           "yk":"<hex>","ya":"<fd00::...>","exp":<unix_ts>}
class DevicePairingHandshake { ... }
class DevicePairingAck { ... }
```

**`lib/shared/providers/crypto_providers.dart`** — `IdentityNotifier`:
```dart
// New method for Device B after QR import
Future<void> importFromPairing(Identity identity) async {
  final keystore = KeystoreService(sodium);
  await keystore.saveIdentity(identity);
  state = identity;
  await _registerDeviceIfOpen(identity); // registers as non-master device
}
```

---

### Phase 2 — Service Layer (3 days)

**New: `lib/services/device_pairing_service.dart`**
```dart
class DevicePairingService {
  // Called on device A: generate QR payload (valid 5 min)
  Future<PairingQrPayload> startPairing();
  
  // Called on device B: process scanned QR, send handshake to A
  Future<void> completePairingAsSlave(PairingQrPayload qr);
  
  // Called on device A: handle handshake from B, send ack
  Future<void> handlePairingHandshake(String fromPub, Map handshakeJson);
  
  // Called on device B: handle ack from A, finalize
  Future<void> handlePairingAck(Map ackJson);
}
```

**Wire message handling** in `receive_envelope_use_case.dart`:
- Add `device_pairing_handshake` and `device_pairing_ack` to own-device message path
  (same early-exit block as `device_sync_request`, before contact lookup)

**Wire message handling** in `messaging_service.dart`:
- `buildContactHello` already includes `devices[]` — no change needed

---

### Phase 3 — UI (3 days)

**New: `lib/features/settings/pair_device_screen.dart`** (Device A side — shows QR)
```
PairDeviceScreen
├── QR widget (existing QrImageView) with identity_bundle
├── Countdown: "Expires in 4:32"
├── Auto-refresh after expiry
└── Success: "✓ Устройство добавлено" when handshake/ack arrives
```

**New: `lib/features/onboarding/scan_pairing_screen.dart`** (Device B side — scans QR)
```
ScanPairingScreen
├── Camera QR scanner (existing MobileScanner)
├── On decode: decrypt identity_bundle → importFromPairing()
├── Progress indicator while handshake in flight
└── On ack: context.go('/lock')
```

**Updates to existing files:**

`lib/features/onboarding/onboarding_screen.dart`:
- Add second button "Войти с другого устройства" → `/onboarding/scan-pairing`
- Below existing "Создать новый аккаунт" button

`lib/features/settings/devices_screen.dart`:
- Add FAB "+" → navigate to `/pair-device`
- Show "No other devices" empty state with CTA

`lib/features/settings/settings_screen.dart`:
- Add "Linked devices" row in Security section → `/devices`
  (already exists, just make sure it's visible)

`lib/app.dart`:
- Add routes `/pair-device` and `/onboarding/scan-pairing`

---

### Phase 4 — Integration (2 days)

**After successful pairing on A:**
1. Save B in `my_devices` (isMaster: false)
2. Call `storage.myDevices.updateHeartbeat(B.deviceId)`
3. Call `router.broadcastHello()` → contacts learn about B
4. Show success snackbar

**After successful pairing on B:**
1. Save A in `my_devices` (isMaster: true)
2. Save B itself in `my_devices` (isMaster: false)
3. `_registerDeviceIfOpen` fires → broadcast hello to contacts (via retry loop)
4. `requestSyncFromAll()` fires → request pending messages from A

**Contacts learn about device B:**
- Next `contact_hello` from either A or B contains `devices[]` with both A and B
- Contact will encrypt future messages for both devices

---

### Phase 5 — Edge Cases & Polish (2 days)

**QR expiry:**
- After 5 minutes, regenerate token automatically
- Show "Expired — tap to refresh" if user doesn't complete in time

**Device B import flow:**
- If B has no identity yet (fresh install) → show "Import backup first" prompt
  with link to Settings → Backup → Import
- If B already has a DIFFERENT identity → warn: "This will replace your current
  identity. Your contacts and messages on this device will be lost."

**Multiple devices:**
- Pairing is symmetric — any existing device can initiate pairing with any new device
- Max recommended: 5 active devices (soft UI limit, not enforced cryptographically)

**Device name:**
- Default: OS model name (e.g. "Samsung Galaxy S22")
- Editable in Devices screen

---

## Files to Create / Modify

| File | Action | Notes |
|---|---|---|
| `lib/infrastructure/crypto/device_pairing_crypto.dart` | CREATE | Crypto: QR bundle encrypt/decrypt, cert validation |
| `lib/domain/entities/device_pairing_payload.dart` | CREATE | Data classes + codecs |
| `lib/services/device_pairing_service.dart` | CREATE | Core pairing logic (handshake, ack) |
| `lib/features/settings/pair_device_screen.dart` | CREATE | Device A: show QR with identity bundle |
| `lib/features/onboarding/scan_pairing_screen.dart` | CREATE | Device B: scan QR, import identity, go to /lock |
| `lib/application/use_cases/messaging/receive_envelope_use_case.dart` | MODIFY | Handle device_pairing_handshake / ack |
| `lib/storage/dao/my_devices_dao.dart` | MODIFY | +updateTransportAddresses |
| `lib/features/onboarding/onboarding_screen.dart` | MODIFY | Add "Войти с другого устройства" button |
| `lib/features/settings/devices_screen.dart` | MODIFY | Add FAB "+" |
| `lib/features/settings/settings_screen.dart` | MODIFY | Ensure "Linked devices" row visible |
| `lib/app.dart` | MODIFY | Add `/pair-device` and `/onboarding/scan-pairing` routes |
| `lib/shared/providers/crypto_providers.dart` | MODIFY | Add `importFromPairing()` to IdentityNotifier |
| `lib/shared/providers/messaging_providers.dart` | MODIFY | Wire pairing callbacks |

---

## Effort Estimate

| Phase | Days |
|---|---|
| Crypto layer | 2 |
| Service layer | 3 |
| UI | 3 |
| Integration + edge cases | 4 |
| **Total** | **~12 days** |

---

## What This Does NOT Cover

- History sync between devices (each device only gets new messages after pairing)
- Contact list sync (each device maintains its own contacts)
- Settings sync (each device has independent settings)
- Web client pairing (no Yggdrasil in browser)
- BLE/NFC pairing (future improvement)

These are intentional omissions — privacy by design. Users who want to share
history should use the standard backup/restore flow.
