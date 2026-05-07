# Double Ratchet — Implementation Roadmap for HubCore Chat

## Current State

### What is implemented
- X3DH initialization (initiator/receiver)
- Double Ratchet with DH ratchet every 100 messages
- XChaCha20-Poly1305 AEAD
- KDF: HKDF-BLAKE2b with domain separation (`hubcore_init_v1`, `hubcore_chain_v1`, `hubcore_msg_v1`, `hubcore_ratchet_v1`)
- Skipped key cache (maxSkip=1000, maxSkippedKeys=2000)
- Commit-after-verify: ratchet state rolls back if AEAD fails
- NaCl Box for system messages (stateless)
- Sender Keys for groups
- CryptoPort / SessionPort abstractions
- Three-level key scheme: Master (Ed25519) → Signing (Ed25519, rotation) → X25519

### Critical Issues

| # | Problem | Risk | Location |
|---|---------|------|----------|
| 1 | `senderEphPub` only at counter==0 | Loss of M1 → session not created at recipient | `messaging_service.dart:207` |
| 2 | Session deleted on decrypt error | Attacker can reset session with a garbage packet | `double_ratchet_crypto_service.dart:114` |
| 3 | `contact_hello` not signed | MITM key substitution | `messaging_service.dart:584` |
| 4 | `senderEphPub` not signed with signing key | MITM on session re-creation | `dm_payload_codec.dart` |
| 5 | Signing key stored but not verified | Entire trust chain doesn't work | Nowhere verified |
| 6 | No notification on contact key change | Substitution is invisible to user | — |
| 7 | Reinstall breaks sessions (counters) | Messages after reinstall cannot be decrypted | `double_ratchet.dart` |
| 8 | Session init duplicated in two places | Code desync | `MessagingService` vs `DoubleRatchetSessionService` |

---

## Phases

### Phase 1: Signing and Verification (security)

**Goal:** close the trust chain Master → Signing → X25519 → Ephemeral.

#### 1.1 Sign `contact_hello`

Current format (plain JSON):
```json
{
  "type": "contact_hello",
  "mp": "<base58 masterPub>",
  "sp": "<base58 signingPub>",
  "x":  "<base58 x25519Pub>",
  "yk": "<hex yggPubKey>"
}
```

New format:
```json
{
  "type": "contact_hello",
  "mp": "<base58 masterPub>",
  "sp": "<base58 signingPub>",
  "x":  "<base58 x25519Pub>",
  "yk": "<hex yggPubKey>",
  "cert": "<base64 SigningCert>",
  "sig":  "<base64 Ed25519(signingPriv, canonical(mp||sp||x||yk))>"
}
```

- `cert` — 112-byte SigningCert: `signingPub(32) || validFrom(8) || validUntil(8) || masterSig(64)`
- `sig` — signature of entire payload (excluding `sig` field) with current signing key
- Recipient: verifies `cert` via `masterPub` from QR → verifies `sig` via `signingPub` from cert

**Files:** `messaging_service.dart:buildContactHello`, `receive_envelope_use_case.dart`, `messaging_service.dart:_handleContactHello`

#### 1.2 Sign `senderEphPub` in DM

Current DM payload:
```json
{"c": "...", "n": 0, "s": "<ephPub>", "e": null, "t": null, "id": "..."}
```

Add field `ss` (sender signature):
```json
{"c": "...", "n": 0, "s": "<ephPub>", "ss": "<base64 Ed25519(signingPriv, ephPub)>", ...}
```

- Only at `counter == 0` (bootstrap) or on DH ratchet (new ephemeral)
- Recipient **must** verify `ss` via contact's `signingPub` before `initReceiver`
- If signature invalid → reject, do not create session

**Files:** `dm_payload_codec.dart`, `messaging_service.dart:sendMessage`, `double_ratchet_crypto_service.dart:decryptDm`

#### 1.3 Signing key verification on receipt

On every incoming DM and contact_hello:
1. Load contact's `signingPub` from DB
2. If message contains `cert` — verify that `cert` is signed by contact's `masterPub`
3. If signing key changed — **do not accept automatically** (see Phase 2)

**Files:** `receive_envelope_use_case.dart:_handleDm`, `messaging_service.dart:receiveEnvelope`

---

### Phase 2: Session Resilience (reliability)

**Goal:** sessions don't break on message loss, reinstall, errors.

#### 2.1 Remove auto-deletion of session on decrypt error

Current behavior (`double_ratchet_crypto_service.dart:108-115`):
```dart
if (plainBytes == null) {
  _cache.remove(contact.id!);
  await _sessions.deleteForContact(contact.id!);
  return null;
}
```

New behavior:
```dart
if (plainBytes == null) {
  // DO NOT delete session
  // Mark message as "not decrypted"
  // Send re-request if counter > expected
  return null;
}
```

- Session survives — subsequent messages with correct counter will decrypt
- Garbage packets are simply ignored
- Skipped key cache handles out-of-order delivery

#### 2.2 `senderEphPub` until delivery confirmed

Current: `senderEphPub` included only at `counter == 0`.

New: include `senderEphPub` in **all messages** until `msg_delivered` receipt received.

```
if (!deliveryConfirmedForContact[pub]) {
  payload.senderEphPub = state.myEphemeral.publicKey;
  payload.senderEphSig = sign(signingPriv, senderEphPub);
}
```

This guarantees recipient can create session from any first delivered message, not only M1.

**Files:** `messaging_service.dart:sendMessage`, `dm_payload_codec.dart`

#### 2.3 Reinstall handling

On app launch after identity creation:
1. Send `contact_hello` to all contacts (partially done)
2. Add `epoch` to `contact_hello` — monotonic counter, incremented on each reinstall
3. Recipient compares epoch:
   - `epoch > saved_epoch` → contact keys changed, show warning
   - `epoch == saved_epoch` → normal update
   - `epoch < saved_epoch` → replay, ignore

Epoch stored in `settings` table: `identity_epoch = N`.

#### 2.4 Key change notification

When `contact_hello` is received with new `x25519Pub` or `signingPub`:
1. **Do not update keys automatically**
2. Show notification: "Security key of contact [name] has changed"
3. User confirms → keys updated, old session deleted, new one created on next exchange
4. User declines → keys not changed, messages from "new" contact rejected

**Files:** `notifications_dao.dart` (new type: `key_change`), `notifications_screen.dart`, `messaging_service.dart:_handleContactHello`

---

### Phase 3: Code Consolidation (architecture)

**Goal:** single path for session management, readiness for multi-transport.

#### 3.1 Unified SessionManager

Currently session init in two places:
- `MessagingService.initOutboundSession()` — old code, in-memory cache + DB
- `DoubleRatchetSessionService.initOutbound()` — new code, via SessionPort

Merge into one `SessionManager`:
```dart
class SessionManager implements SessionPort {
  final DoubleRatchet _ratchet;
  final SessionsDao _sessions;
  final Map<int, RatchetState> _cache = {};

  Future<bool> hasSession(String pub);
  Future<void> initOutbound({...});
  Future<void> initInbound({...});
  Future<RatchetState?> loadSession(int contactId);
  Future<void> saveSession(int contactId, RatchetState state);
  Future<void> deleteSession(String pub);
}
```

#### 3.2 CryptoPort extensions

Add to `CryptoPort`:
```dart
abstract class CryptoPort {
  // Existing methods...

  // New:

  /// Verify signing key signature via master key
  bool verifySigningCert(Uint8List cert, Uint8List masterPub);

  /// Sign data with current signing key
  Uint8List sign(Uint8List data);

  /// Verify contact's signature
  bool verify(Uint8List data, Uint8List signature, String contactPub58);

  /// Decrypt result with error reason
  Future<DecryptResult> decryptDmDetailed(
    String senderPub, Uint8List ciphertext, IncomingDmMeta meta);
}

enum DecryptError { noSession, badSignature, aedFailed, counterReplay }

class DecryptResult {
  final String? plaintext;
  final DecryptError? error;
}
```

#### 3.3 Transport abstraction

Current architecture is already correct:
```
CryptoPort (encrypt/decrypt) → Envelope → TransportPort (send/receive)
```

For Reticulum/Meshcore nothing in crypto needs to change. Envelope is the same for all transports. Only a new transport adapter is added.

---

### Phase 4: Sender Keys for Groups (improvements)

#### 4.1 Forward secrecy in groups

Current: Sender Keys without forward secrecy — compromising chain key reveals all future sender messages.

Solution: periodic rotation of sender chain:
- Every N messages (or on timer) member generates new chain
- Broadcasts new chain state to all members via DM (DR-encrypted)
- Old chain key deleted

#### 4.2 Invite via NaCl Box

Group invite is a system message, not a chat message. Send via `encryptBox`:
- Does not require DR session
- Requires contact's `x25519Pub`
- If `x25519Pub` not available — skip with warning, send later after `contact_hello` exchange

---

## Implementation Order

```
Phase 1.1  Sign contact_hello
Phase 1.2  Sign senderEphPub
Phase 1.3  Verify signing key
Phase 2.1  Remove auto-delete session
Phase 2.2  senderEphPub until delivery receipt
Phase 2.3  Epoch for reinstall
Phase 2.4  Key change notification
Phase 3.1  Unified SessionManager
Phase 3.2  CryptoPort extensions
Phase 4.1  Forward secrecy in groups
Phase 4.2  Invite via NaCl Box
```

Phases 1 and 2 — priority, close vulnerabilities.
Phase 3 — refactoring, does not block functionality.
Phase 4 — improvements, after main DR stabilizes.

---

## Reference: Current Formats

### DM Payload (wire)
```json
{
  "c":  "<base64 nonce(24) + AEAD ciphertext>",
  "n":  <counter: int>,
  "e":  "<base64 newEphPub(32)>" | null,
  "s":  "<base64 senderEphPub(32)>" | null,
  "t":  <ttlSeconds: int> | null,
  "id": "<hex-8 messageId>" | null
}
```

### SigningCert (112 bytes)
```
signingPub(32) || validFrom(8 BE) || validUntil(8 BE) || masterSig(64)
```

### Session Record (DB)
```
rootKey(32), sendChainKey(32), recvChainKey(32),
myEphPub(32), myEphPriv(32), peerEphPub(32?),
sendCounter, recvCounter, sendSinceRatchet,
recvCounterInChain, recvChainIndex,
skippedKeysJson: [{"ci":N, "ct":N, "k":"hex"}]
```

### KDF Info Strings
```
hubcore_init_v1     — X3DH → rootKey + chainKey
hubcore_chain_v1    — Advance chain
hubcore_msg_v1      — Derive message key
hubcore_ratchet_v1  — DH ratchet step
```

### Constants
```
dhRatchetAfterMessages = 100
maxSkip = 1000
maxSkippedKeys = 2000
AEAD = XChaCha20-Poly1305 (24-byte nonce)
```
