# Crypto Design

## Primitives

| Purpose | Algorithm | Library |
|---|---|---|
| Master Key (permanent ID) | Ed25519 | libsodium |
| Signing Key (rotatable) | Ed25519 | libsodium |
| ECDH key exchange | X25519 | libsodium |
| Symmetric encryption | ChaCha20-Poly1305 (AEAD) | libsodium |
| Key derivation | HKDF-SHA512 | libsodium |
| Hashing | BLAKE3 | libsodium / blake3 |
| Random numbers | CSPRNG | libsodium randombytes |

## Identity — Two-Level Keys

Each user has two levels of keys:

```
LEVEL 1 — Master Key (long-term)
─────────────────────────────────────
master_keypair = Ed25519.keygen()
  master_privkey → Android Keystore (never leaves, non-exportable)
  master_pubkey  → permanent user ID, shared via QR

  Used only for:
    - signing Signing Key on creation / rotation
    - verifying continuity when Signing Key changes
    - backup (encrypted export)

  Changed only on compromise or explicit reset.


LEVEL 2 — Signing Key (rotatable)
──────────────────────────────────
signing_keypair = Ed25519.keygen()
  signing_privkey → Android Keystore (separate from master)
  signing_pubkey  → published, used for everything

  signing_cert = {
    signing_pubkey: bytes[32],
    valid_from:     uint64,        // unix timestamp
    valid_until:    uint64,        // valid_from + rotation_period
    signature:      Ed25519.sign(master_privkey, signing_pubkey || valid_from || valid_until)
  }

  Used for:
    - signing all messages
    - signing KeyPackage
    - authenticating requests

  Rotated on schedule (default: weekly).


fingerprint = BLAKE3(master_pubkey)[0:16]
  → hex → "A3F2-9B1C-E847-2D05"
  Fingerprint is stable — tied to master, does not change on signing rotation.
```

Master pubkey is base58url-encoded for QR codes and links — this is the user's permanent address.

### Signing Key Rotation

```
1. Generate new signing_keypair
2. Sign new signing_pubkey with master_privkey → signing_cert
3. Broadcast signing_cert to all contacts via offline queue
   (signed with old signing_privkey — last message with old key)
4. Upload new signing_cert
5. Old signing_privkey → delete from Keystore

Contact receives signing_cert:
  Ed25519.verify(master_pubkey, cert.signature, cert.signing_pubkey || ...) → OK
  → update contact's signing_pubkey
  → verify all new messages with new signing_pubkey
```

If device is lost and old signing_privkey is unavailable — rotation is initiated with **master_privkey** (from backup). Contacts accept new signing_cert signed by master.

### Rotation Settings

```
Settings → Security → Signing Key Rotation
  Automatic: [every week ▼]
  Options: 3 days / week / month / manual
```

## Double Ratchet — Direct Chats

Implementation of the Signal Protocol Double Ratchet.

### Session Establishment (simplified X3DH)

```
Alice wants to message Bob:
  1. Alice generates ephemeral X25519 keypair: (ek_a, EK_A)
  2. DH1 = X25519(ek_a, IK_B)          — ephemeral Alice × identity Bob
  3. DH2 = X25519(ik_a, EK_B_prekey)   — identity Alice × prekey Bob
  4. DH3 = X25519(ek_a, EK_B_prekey)   — ephemeral Alice × prekey Bob

  master_secret = HKDF(DH1 || DH2 || DH3)
  RootKey, ChainKey_send = HKDF(master_secret, "hubcore_init")

  Alice sends: { EK_A, encrypted first message }
```

### Symmetric Ratchet (every message)

```
MessageKey_n  = HKDF(ChainKey_n, "msg")
ChainKey_n+1  = HKDF(ChainKey_n, "chain")

Encryption: ChaCha20-Poly1305(MessageKey_n, plaintext, associated_data)
  associated_data = { sender_pubkey, recipient_pubkey, message_counter, timestamp }

After use:
  MessageKey_n  → immediately zeroed from memory
  ChainKey_n    → immediately zeroed from memory (replaced by ChainKey_n+1)
```

### DH Ratchet (rotation, every 100 messages or 24h)

```
Alice generates new ephemeral X25519: (new_ek_a, NEW_EK_A)
  new_DH     = X25519(new_ek_a, IK_B)
  new_RootKey, new_ChainKey = HKDF(RootKey || new_DH, "hubcore_ratchet")

Alice sends NEW_EK_A in the next message
Bob receives NEW_EK_A:
  new_DH     = X25519(ik_b, NEW_EK_A)
  new_RootKey, new_ChainKey_recv = HKDF(RootKey || new_DH, "hubcore_ratchet")

Result: Post-Compromise Security ✓
  If old ChainKey leaked — after rotation attacker loses access
```

### Session State (stored in SQLCipher)

```
Session {
  peer_pubkey:        bytes[32]   // peer identifier
  root_key:           bytes[32]
  send_chain_key:     bytes[32]
  recv_chain_key:     bytes[32]
  send_counter:       uint64
  recv_counter:       uint64
  my_ephemeral_key:   bytes[32]   // current DH ratchet key
  peer_ephemeral_key: bytes[32]
  last_ratchet_at:    timestamp
  next_ratchet_after: uint64      // message counter until next rotation
}
```

## Sender Keys + Ratchet — Group Chats

### Group Creation

```
Admin generates:
  group_id          = random[16]
  sender_chain_key  = random[32]  // initial SenderChainKey

For each member P:
  session_key_P = current Double Ratchet MessageKey with P
  encrypted_sk_P = ChaCha20-Poly1305(session_key_P, sender_chain_key)
  → send encrypted_sk_P to member P
```

### Sending a Group Message

```
MessageKey      = HKDF(SenderChainKey, "msg")
SenderChainKey  = HKDF(SenderChainKey, "chain")   // ratchet step

ciphertext = ChaCha20-Poly1305(MessageKey, plaintext)
  associated_data = { group_id, sender_pubkey, message_counter }

Send to all members:
  { group_id, sender_pubkey, counter, ciphertext }
  (same ciphertext for all — efficient)

MessageKey → zeroed from memory immediately
```

### Group Key Rotation

**Triggers:**
- Member leaves / is removed (mandatory, immediate)
- Every 100 messages (configurable)
- Every 24 hours (configurable)
- Manually by admin

```
Rotation (initiated by admin or any member in turn):
  new_sender_chain_key = random[32]

  For each remaining member P:
    encrypted_new_sk_P = ChaCha20-Poly1305(session_key_P, new_sender_chain_key)
    → send to P via private channel (Double Ratchet)

  Old SenderChainKey → zeroed from memory
```

### Post-Compromise Security

```
Before rotation:
  SenderChainKey compromised → attacker sees all messages until rotation ✗

After rotation:
  New random SenderChainKey — attacker does not know it ✓
  Forward Secrecy: old MessageKeys deleted — old messages inaccessible ✓
```

## File Encryption

```
FileKey    = random[32]          // unique per file
FileNonce  = random[24]

// Large files — chunked encryption
chunk_size = 64KB
for i, chunk in chunks(file):
  chunk_nonce = FileNonce XOR uint64(i)   // unique nonce per chunk
  encrypted_chunk = ChaCha20-Poly1305(FileKey, chunk, chunk_nonce)

// FileKey is sent to recipient via Double Ratchet (private channel)
// or via encrypted group message
```

## Local Database Encryption

```
DBKey = random[32]    // generated on first launch
  → stored in Android Keystore (requires biometrics / PIN to retrieve)

Lock:
  DBKey is unloaded from RAM
  DB is inaccessible until authentication

Unlock:
  PIN / biometrics → Keystore returns DBKey
  SQLCipher receives DBKey → DB is open
```

## Protection Against Attacks

| Attack | Protection |
|---|---|
| Message replay | message_counter in associated_data, monotonically increasing |
| Sender spoofing | Ed25519 signature on every message |
| Traffic analysis | all blobs padded to fixed size (256B / 1KB / 4KB) |
| Server compromise | server only sees encrypted blobs |
| Key compromise | DH Ratchet restores security after rotation |
| PIN brute force | Argon2id with high cost, lockout after N attempts |

## Security Parameters (configurable)

```dart
class CryptoConfig {
  final int dhRatchetAfterMessages;   // default: 100
  final Duration dhRatchetAfterTime;  // default: 24h
  final int groupKeyRotationMessages; // default: 100
  final Duration groupKeyRotationTime; // default: 24h
  final int filePaddingBlockSize;     // default: 65536 (64KB)
}
```
