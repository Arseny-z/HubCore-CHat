# Security Model

## Threat Model

### What we protect

| Asset | Threat | Protection |
|---|---|---|
| Message content | Network interception | E2E encryption (ChaCha20-Poly1305) |
| Master Key | Theft from device | Android Keystore (non-extractable, rarely used) |
| Signing Key | Compromise / leak | Rotated weekly, old key deleted immediately |
| Message history | Physical device access | SQLCipher + screen lock |
| Metadata (who talks to whom) | Traffic analysis | Padding, Yggdrasil hides recipient IP |
| Session keys | Memory compromise | Keys zeroed immediately after use |
| Future messages | Key compromise | DH Ratchet rotation |
| Past messages | Key compromise | Forward Secrecy (MessageKey deleted after use) |

### Attacker model

**Passive network observer:**
- Can see: IP addresses, packet sizes (mitigated by padding), message frequency
- Cannot see: content (TLS + E2E)

**Physical access to locked device:**
- Can see: encrypted database (SQLCipher)
- Cannot: read without PIN/biometrics (DBKey in Keystore)

**Physical access to unlocked device:**
- Can see: open database, message history
- Mitigation: auto-lock on background

**Physical access + wipe performed:**
- Can see: random bytes on disk (data without keys)
- Cannot: recover — keys are physically deleted from TEE/StrongBox

### What we do NOT protect against

- Device compromise (root, malware) — out of scope
- Yggdrasil peers see encrypted traffic but not its content or recipients
- Message timestamps — visible to Yggdrasil peers as traffic volume

---

## Key Lifecycle

### Master Key (Ed25519, permanent)

```
Creation:  First launch → keygen() → privkey in Android Keystore ('hubcore_master_key')
Storage:   Keystore/TEE/StrongBox only, never plaintext in Dart memory
Usage:     Only to sign Signing Key cert and encrypted backup
Export:    Encrypted backup only (password + PBKDF2)
Deletion:  WipeService → Keystore.deleteEntry('hubcore_master_key') → physically from chip
```

### Signing Key (Ed25519, rotatable)

```
Creation:  First launch and on each rotation → keygen() → Keystore ('hubcore_signing_key')
Storage:   Keystore only
Rotation:  On schedule (3 days / week / month) or manually
           Old key → deleteEntry() immediately after broadcasting new cert
Deletion:  WipeService → Keystore.deleteEntry('hubcore_signing_key')
```

### Session Keys (Double Ratchet)

```
Creation:  On first message exchange
Storage:   ChainKey in SQLCipher (encrypted with DBKey)
Rotation:  DH step every 100 messages / 24h
MessageKey: Generated, used, IMMEDIATELY zeroed from memory
```

### DB Key

```
Creation:  First launch → random[32] → Android Keystore ('hubcore_db_key')
Access:    Only via Keystore API (requires PIN / biometrics)
In memory: Only while DB is open; zeroed out on lock
Deletion:  WipeService → Keystore.deleteEntry('hubcore_db_key')
           After this all DB data and FileKeys become cryptographically inaccessible
```

---

## Cryptographic Storage Erasure

Physical file deletion on Flash/SSD does not guarantee data destruction due to wear leveling. The only reliable method is key destruction.

### Wipe sequence (< 1 second)

```
1. Database.close()
2. Keystore.deleteEntry('hubcore_master_key')   ← TEE/StrongBox physically deletes
3. Keystore.deleteEntry('hubcore_signing_key')
4. Keystore.deleteEntry('hubcore_db_key')       ← all data becomes garbage
5. deleteDirectory(vault/)                    ← optional, for cleanliness
6. deleteFile(hubcore.db)
7. SharedPreferences.clear()
```

Steps 5–7 are optional from a security standpoint — without keys, files are unreadable. They are performed to avoid leaving traces of data volume.

### Four wipe triggers

| Trigger | Confirmation | Description |
|---|---|---|
| Settings → Reset account | PIN + dialog | Normal reset |
| Panic Button (hold 3 sec) | None | Instant, no traces |
| N wrong PINs in a row | None (automatic) | Default: 10 attempts |
| Duress PIN | None | Wipe under coercion (see below) |

### Duress PIN — protection against forced unlock

Addresses the "hand over your phone and tell me your PIN" threat:

```
User sets two PINs:
  Normal PIN:  1234  → normal unlock
  Duress PIN:  0000  → looks identical, but:

On Duress PIN entry:
  1. Screen shows a loading animation (~1–2 sec)
  2. In background: WipeService.wipeAll()  ← keys deleted from Keystore
  3. Empty onboarding is shown — like a fresh install
  4. Attacker sees an "unlocked" app with no data
  5. No indication that a wipe occurred
```

The Duress PIN is stored as an Argon2id hash in SharedPreferences (separate from the main PIN, not tied to DBKey). Verification happens before any attempt to open the database.

Optionally: the Duress PIN can open a pre-configured "decoy" account with a few harmless messages — for plausible deniability.

---

## Forward Secrecy

If ChainKey_N is compromised, the attacker gains access only to messages from N onward. Messages 1..N-1 are inaccessible because ChainKey_N-1, N-2... have already been deleted.

```
ChainKey_1 → deleted after generating MessageKey_1
ChainKey_2 → deleted after generating MessageKey_2
...
COMPROMISE of ChainKey_N
  → MessageKey_N, N+1, N+2... accessible to attacker ✗
  → MessageKey_1...N-1 inaccessible ✓ (Forward Secrecy)
```

## Post-Compromise Security

After a DH Ratchet step, the attacker loses access even if they knew the previous ChainKey:

```
Attacker knows ChainKey_N (compromised)
  → reads messages N, N+1, ..., until rotation

DH Ratchet step (every 100 messages / 24h):
  new_DH = X25519(new_ephemeral, peer_pubkey)
  new_RootKey = HKDF(old_RootKey || new_DH)
  new_ChainKey = HKDF(new_RootKey)

  Attacker does not know new_ephemeral → cannot compute new_DH
  → Access lost ✓ (Post-Compromise Security)
```

---

## Key Verification (MITM protection)

The initial key exchange happens via QR code — no intermediaries by design. Protection against substitution on first contact:

1. **Direct QR exchange**: scanning QR = direct transfer of {masterPub, signingPub, yggAddr} with no intermediaries
2. **Fingerprint verification**: users compare fingerprints verbally / via another channel
3. **Key change warning**: if a contact's pubkey changes — red warning displayed

```
Fingerprint = BLAKE3(pubkey)[0:16]
Displayed as: "A3F2 9B1C E847 2D05"

Verification: both parties show each other their fingerprint
(voice, video, in person)
After verification: contact is marked as verified ✓
```

---

## Padding — protection against size analysis

Packet size analysis reveals content type. Solution — padding to fixed block sizes:

```
Text messages:
  < 256 bytes  → pad to 256
  < 1024 bytes → pad to 1024
  < 4096 bytes → pad to 4096

System messages (ack, ratchet update): pad to 256 bytes
File metadata: pad to 512 bytes
Group updates: pad to 2048 bytes
```

---

## Audit and Verification

### What requires external audit

1. Double Ratchet implementation — correctness of ratchet step
2. Key erasure from memory — no leaks through Dart GC
3. Android Keystore integration — key is non-exportable
4. SQLCipher initialization — no opening without key
5. Signature verification — no bypass
6. Random number generation — libsodium CSPRNG only

### Crypto tests

```dart
// test/crypto/double_ratchet_test.dart
void main() {
  test('forward secrecy: old message keys cannot decrypt new messages', () {});
  test('post-compromise: after ratchet step attacker loses access', () {});
  test('message counter prevents replay', () {});
  test('session keys deleted after use', () {});
  test('concurrent ratchet steps handled correctly', () {});
}
```

---

## Known Limitations

| Limitation | Description | Mitigation |
|---|---|---|
| Metadata | Yggdrasil peers see traffic volume | Padding, Tor overlay |
| Multi-device | One account = one device (for now) | Roadmap |
| Offline delivery | Cannot send if recipient is offline | Sender-side queue |
| Backup | Device loss = history loss | Encrypted backup (Roadmap) |
| Group MITM | Admin controls membership — could add an attacker | Member verification |
