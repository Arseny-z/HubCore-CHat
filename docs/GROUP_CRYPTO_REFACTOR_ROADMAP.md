# Group Crypto Refactor — Per-Post Wrap (Scheme B)

**Status:** Draft / awaiting approval
**Author:** —
**Created:** 2026-05-08
**Supersedes (when adopted):** crypto sections of `CHANNELS_ROADMAP.md`,
parts of `CRYPTO.md`

---

## 1. Goal

Replace **Sender Keys** in groups (and use the same scheme for upcoming
channels) with a **per-post wrap** model: each post carries a fresh
ephemeral content key wrapped via NaCl box for every recipient and signed
by the sender.

Drivers:

- Eliminate per-sender ratchet state and `O(N²)` chain rotation on member
  removal (current cost dominates kicks).
- Bring group messages onto the **same crypto path** that already handles
  control envelopes (`group_kick`, `group_rename`, `group_chain_update`,
  `msg_reaction`, …) — one mechanism, less code, fewer edge cases.
- Make member churn (add / remove / ban) **stateless** — no chain rotation,
  no skipped-key cache, no out-of-order cache.
- Per-post forward secrecy via ephemeral content keys instead of "FS only
  at ratchet step" of Sender Keys.

Non-goals:

- DM remains on Double Ratchet — DR is a good fit for parity messaging
  and we are not touching it.
- We do **not** target post-compromise security (PCS) at the group level.
  Achieving real PCS without a Delivery Service is the territory of MLS
  and is out of scope here. (See `MLS` discussion in this repo's notes.)
- We do **not** scale beyond a few hundred recipients per post. For
  large-broadcast channels, a future epoch-based scheme can be added on
  top.

### 1.1 What this refactor touches and what it does not

**Touched (group/channel content path only):**

- Group-message wire format: `_GroupPayload` → `GroupPostEnvelope`
- Group invite payload: chain-key blob → roster + epoch
- Kick path: drop `rotateMyChain` for v=2 groups
- File transfer in **groups**: only the `FileOffer` envelope wrapping
  (chunks themselves stay raw — see §3.8)

**Untouched:**

| Surface | Why it stays the same |
|---|---|
| Contact exchange (QR, `contact_hello`, `cert_update`) | All keys we need (`x25519_pub`, `signing_pub`) are already exchanged today; B introduces no new identity material. See §3.7. |
| DM (Double Ratchet) | Parity messaging is well-served by DR. We change nothing here. |
| File chunk pipeline | Chunks are pre-AEAD'd with `file_key` from `FileOffer`. Wire is raw bytes. No change. |
| Voice / video circles | Travel through the same `FileService` chunk pipeline. No change. |
| Reactions (`msg_reaction`) | Already a NaCl-box-per-recipient envelope, independent of group-message encryption. No change. |
| Replies | Just a `reply_to_id` on the `Message` row. Encryption is whatever encrypts the post. No change. |
| Forwards | Send a copy via the standard send path. No special crypto. |
| Read / delivered / received receipts | NaCl-box system envelopes. No change. |
| All group control envelopes (kick / rename / role / admin transfer / delete / chain_update for legacy) | Already NaCl-box-per-recipient. No change. |
| TTL (`expires_at`) | Already a field on `Message`; carried in the new envelope as `ttl_seconds`. |
| Send queue / retry / connectivity watcher | Operates on opaque envelope bytes. No change. |
| IncomingRawDb (Kotlin buffer when Flutter is dead) | Operates on opaque envelopes. No change. |
| Multi-device (P3) — pairing, device sync, signing-key broadcast | Independent layer. No change. |
| Transport layer (Yggdrasil, Reticulum, Meshcore, CompositeTransport) | Routing only. No change. |
| Search (P6-3), Panic (P6-2), Key-change banner (P6-1), Yggdrasil peer list (P6-5) | Independent features. No change. |
| QR-code format | Same `{mp, sp, x, yk, rk}`. |

---

## 2. Current state (Sender Keys)

> Inventory grounded in audit done 2026-05-08; cite line refs below.

### 2.1 Code surfaces

| Component | Path | Size |
|---|---|---|
| `GroupMessagingService` | `client/lib/infrastructure/crypto/group_messaging_service.dart` | **521 LOC** |
| `SenderKeys` primitive | `client/lib/crypto/sender_keys.dart` | **219 LOC** |
| `GroupsDao` | `client/lib/storage/dao/groups_dao.dart` | 167 LOC |
| `GroupInvite` wire | `client/lib/domain/entities/group_invite.dart` | 44 LOC |
| Schema (`groups`, `group_members`) | `client/lib/storage/database.dart:95-115` | v25 |
| Tests | `client/test/crypto/sender_keys_test.dart` | 6 cases (ratchet, replay, FS, DH-step) |

### 2.2 Crypto facts

- **DR is not used inside groups**. Group messages travel as a
  `_GroupPayload` JSON with Sender-Keys ciphertext. Group invites and all
  control envelopes (`group_kick`, `group_rename`, `group_role_change`,
  `group_chain_update`, `group_admin_transfer`, `msg_reaction`, …)
  travel via **NaCl box** (`encryptBox`, X25519 + XSalsa20-Poly1305,
  stateless).
- Sender Keys ratchet schedule: DH ratchet every **100 messages**
  (`senderKeyDHRatchetAfterMessages = 100`,
  `crypto/sender_keys.dart:7`).
- Each group member maintains state per other member: `chain_key` (32B),
  `counter` (int), optional `ratchet_pub` (32B) — persisted in
  `group_members`.
- In-memory cache: `_chains: Map<groupId, Map<memberPub, SenderChainState>>`
  in `GroupMessagingService`.

### 2.3 Pain points the refactor removes

- **`O(N²)` kick.** Removing one member requires every remaining member
  to call `rotateMyChain` and broadcast its new chain to everyone else —
  N-1 senders × N-1 recipients ≈ `(N-1)²` envelopes.
  ([`group_settings_screen.dart:268`](#))
- **`_chains` cache and DB synchronization** has been a recurring source
  of bugs — see commit `766ab4f` "fix(groups): кик участника — сброс кэша
  и уведомление удалённого" and commit `5163386`
  "fix(groups): корректная обработка отправки после кика".
- **Skipped-keys / out-of-order**: ratchet requires receivers to keep a
  bounded cache; mis-ordering across kicks complicates state.
- **Two crypto paths**: group messages use Sender Keys, control plane
  uses NaCl box. Two formats, two failure modes, two test surfaces.

---

## 3. Proposed scheme — Per-Post Wrap (B)

### 3.1 In one sentence

For each group/channel post: generate a 32-byte random *content key*,
AEAD-encrypt the body with it, then attach an N-list of NaCl-box-wrapped
copies of that content key — one per recipient — and sign the whole
envelope with the sender's signing key.

### 3.2 Wire format (DRAFT)

```
GroupPostEnvelope {
  type:          "group_post"      // discriminator
  v:             1                 // protocol version (allows future change)
  group_id:      base58            // conversation id
  epoch:         uint32            // group membership epoch (incremented on add/kick)
  content:       {
    nonce:       bytes[24]         // XChaCha20-Poly1305 nonce
    ciphertext:  bytes             // AEAD(content_key, plaintext, nonce, AAD)
  }
  wraps: [
    {
      to_pub:    base58            // recipient X25519 pub (32B)
      box_nonce: bytes[24]         // NaCl box nonce
      eph_pub:   bytes[32]         // ephemeral X25519 pub from this box
      box:       bytes[32+16]      // NaCl box ciphertext of content_key
    },
    …
  ]
  msg_id:        hex8              // for receipts and dedup
  ttl_seconds:   uint32?           // optional disappearing TTL
  sender_pub:    base58            // sender signing-pub (Ed25519)
  signature:     bytes[64]         // Ed25519.sign(signing_priv, transcript)
}

transcript = SHA256(
  "hubcore-group-post-v1"  ||
  group_id                 ||
  epoch                    ||
  msg_id                   ||
  content.nonce            ||
  content.ciphertext       ||
  // wraps order is canonical: sorted by to_pub
  ∀ wrap in wraps:
    wrap.to_pub || wrap.box_nonce || wrap.eph_pub || wrap.box
)

AAD for content AEAD = "hubcore-content-v1" || group_id || epoch || msg_id
```

Sizes (rough):

- Content overhead per post ≈ 24 (nonce) + 16 (Poly1305 tag) = 40 B
- Per-wrap ≈ 32 (to_pub) + 24 (nonce) + 32 (eph_pub) + 48 (box) = 136 B
- Signature + sender_pub ≈ 96 B
- Header / framing ≈ 50 B

For N=100 recipients: `100 × 136 ≈ 13.6 KB` overhead per post.
For N=50:  `~6.8 KB`.
For N=200: `~27 KB`.

### 3.3 Operations

#### Send a post

```
content_key   = randombytes(32)
nonce         = randombytes(24)
ciphertext    = chacha20poly1305_encrypt(content_key, plaintext, nonce, AAD)
wraps         = []
for member in active_members(group):                 // excludes 'banned' + self
    eph        = x25519.keygen()
    box_nonce  = randombytes(24)
    box        = nacl_box(member.x25519_pub, eph.priv, content_key, box_nonce)
    wraps.append({ to_pub: member.master_pub, box_nonce, eph_pub: eph.pub, box })
transcript    = sha256(...)
signature     = ed25519_sign(signing_priv, transcript)
envelope      = GroupPostEnvelope { ... }
broadcast(envelope)                                  // single envelope → all members
```

The envelope is identical for everyone — we send **one envelope to N
recipients** at the transport layer (CompositeTransport already supports
this; today Sender Keys also fan-outs N envelopes since each is per-pair —
the size is comparable to slightly smaller).

#### Receive a post

```
verify(signature) using sender_pub                    // reject if not a current group member
                                                       // (or signing_pub already known via contact_hello)
my_wrap       = wraps.find(w => w.to_pub == my_pub)
if my_wrap is None:
    drop_silently()                                    // I am no longer a recipient (kicked); ignore
content_key   = nacl_box_open(my_x25519_priv, my_wrap.eph_pub, my_wrap.box, my_wrap.box_nonce)
plaintext     = chacha20poly1305_decrypt(content_key, ciphertext, nonce, AAD)
zeroize(content_key)                                   // best-effort wipe
store_message(plaintext)
send_msg_received_receipt(...)
```

#### Add a member

1. Admin (or any member with `canAddMembers` permission) sends
   `group_join_invite` (control envelope, NaCl box) to the new member.
   Payload: group metadata + current epoch + current roster of x25519
   pubs.
2. New member creates local group state.
3. Admin bumps `epoch` and broadcasts a `group_member_added(new_pub)`
   control envelope to all members.
4. Subsequent posts include `new_pub` in their `wraps`.

No chain key needs to be sent. New members **cannot decrypt past posts**
unless an explicit history-share flow is added (intentionally).

#### Remove a member

1. Admin sends `group_kick(removed_pub)` to all members including the
   removed one (current behaviour).
2. Admin bumps `epoch`.
3. Subsequent posts simply omit `removed_pub` from `wraps`.

There is **no `rotateMyChain` step**. The kicked member already cannot
decrypt anything addressed to others — there is no shared key to revoke.

### 3.4 Replay & ordering

- `msg_id` (hex-8) is already in our `messages` table; receivers dedupe
  by `(message_id, sender_pub)` (already implemented).
- `epoch` lets a receiver detect a stale view and request roster sync if
  needed, but does **not** drop posts hard — late-arriving posts from a
  previous epoch are accepted if the sender is still a member.
- Order between two posts is best-effort (timestamp + delivery order).
  No tree, no transcript hash, no per-epoch transcripts.

### 3.5 Threat model (honest)

- **Sender forgery within group:** prevented by Ed25519 signature against
  sender's signing key (which we already verify on every DM via
  `verifyContact`).
- **Outsider eavesdrop:** content_key is encrypted under per-recipient
  X25519 (forward-secret per box via ephemeral key).
- **Long-term key compromise of recipient:** attacker can decrypt **past
  posts addressed to that recipient** — same exposure as Sender Keys
  bootstrap, since current scheme also relies on long-term X25519 to
  bootstrap chains.
- **Long-term key compromise of sender:** attacker can forge new posts
  but cannot read past ones (content keys are ephemeral and discarded).
  Identical to Sender Keys.
- **Compromised current member:** can decrypt all *future* posts they
  are wrapped into until they are removed. Same as Sender Keys.
- **Replay across epochs:** rejected by `(msg_id, sender)` dedup.
- **Roster drift:** if A thinks B is a member but B has been kicked, A
  will include B in `wraps` — B (still holding its X25519) will decrypt.
  Mitigated by `epoch` sync on kick/add (control plane is fast and
  reliable).

### 3.6 Comparison vs Sender Keys

| Property | Sender Keys (current) | Scheme B (proposed) |
|---|---|---|
| Forward secrecy | Per ratchet step (every 100 msgs) | Per post (always) |
| PCS | None | None |
| Code size | 521 + 219 LOC + cache + ratchet sched | ~150 LOC codec + reuse of existing `encryptBox` |
| State per device | N chains × group | Zero (stateless) |
| Add member cost | 1 invite + chain | 1 invite, no chain |
| Kick cost | `(N-1)²` rotation envelopes | 1 control envelope |
| Out-of-order | Skipped-keys cache | Trivially OK |
| Per-post overhead (N=100) | ~50 B framing | ~13.6 KB wraps |
| Ciphertext fan-out | N envelopes (per-pair) | 1 envelope to N recipients |
| Authentication of sender | Implicit (chain-only writer) | Explicit Ed25519 signature |
| Crypto paths in repo | 2 (Sender Keys + NaCl box) | 1 (NaCl box only) |

**Trade-off tally:**

- Bigger wire size for posts (offsetable by per-recipient wrap, still
  modest at N≤200).
- All other axes simpler / cheaper / safer.

### 3.7 Contact exchange — unchanged

All keys that B needs are already exchanged today via `contact_hello`
(NaCl box) and are stored in the `contacts` table:

| `contact_hello` field | Used by B for | Already in DB? |
|---|---|---|
| `mp` (master_pub, base58) | recipient ID, `to_pub` lookup | yes |
| `sp` (signing_pub, base58) | verify Ed25519 signature on `GroupPostEnvelope` | yes |
| `x` (x25519_pub, base58) | wrap content key with NaCl box | yes |
| `yk` / `rk` | transport routing | yes |
| `epoch` | replay defence on key rotation | yes |

**No new identity material.** No new handshake. The QR-code format stays
the same `{mp, sp, x, yk, rk}`.

Implicit constraint: B requires the X25519 public key of every group
member at send time. Sender Keys already requires the same — group
invites today travel via `encryptBox(member_x25519, …)`. No regression.

### 3.8 File transfer / voice / video

Today's split between metadata and content:

```
FileOffer (random file_key + file_nonce + filename + mime + size)
  ↑                                         ↑
  travels through the secret channel        identifies the AEAD key
  (DR for DM, Sender Keys for groups)       used to wrap chunks

FileChunk[N]   raw bytes, already AEAD'd by sender with file_key
FileAck        raw JSON
```

**In B, only one thing changes:** the `FileOffer` envelope in groups
moves from `encryptGroupOffer()` (Sender Keys) to a regular
`GroupPostEnvelope` whose `content.ciphertext` carries the encoded
`FileOffer`. Same content type, new wrapping.

All of the following remain **as-is**:

- The chunk pipeline (`FileService` chunking, retry, ack)
- SF03 streaming format (`file_encryption.dart`) — file content is
  already AEAD'd outside any session crypto
- Voice messages and video circles (they travel as files with audio/
  video `content_type`)
- DM file transfer (`FileOffer` over DR is unchanged)

So the wire format change is a one-liner per send site: pick `B` codec
when `group.crypto_version == 2`, else legacy.

### 3.9 Why this is OK without MLS

- HubCore-Chat is **server-less** — MLS' Delivery Service requirement is
  a hard architectural mismatch.
- Realistic group / channel sizes for self-hosted deployments are 5–200.
  At this scale, B's N-overhead is acceptable.
- We accept "no PCS" as today's reality (Sender Keys already lacks it).
- When (if) HubCore needs 1000+ recipients per channel post, we revisit
  with an epoch-based scheme or MLS. The new code is **more compatible**
  with such a future migration than today's Sender Keys.

---

## 4. Migration strategy

We will not in-place migrate existing groups. Two reasons:

1. The current `group_members` table holds chain state that is meaningful
   to old clients. A rolling rollout where some peers are old and some
   new must keep both code paths working.
2. There is no compelling user benefit in re-keying old conversations.

**Plan:**

- **Existing groups stay on Sender Keys forever.** `GroupMessagingService`
  remains in the codebase, marked legacy.
- **New groups created after vN.M use scheme B.** A flag on `groups`
  (`crypto_version: 1=sender_keys, 2=per_post_wrap`) decides at send and
  receive time which path to take.
- **Channels (P6-6) ship on B from day 1.** Channels are a new product
  surface — no legacy to support.
- After 6+ months and a confirmed low usage of legacy groups, deprecate
  Sender Keys (delete code + force re-create old groups).

This keeps risk bounded. Worst case we revert by stopping creation of
v=2 groups; existing v=1 unaffected.

---

## 5. Code impact map

### 5.1 New files (groups B + channels MVP)

| File | Purpose | LOC est. |
|---|---|---|
| `lib/infrastructure/crypto/group_post_codec.dart` | Encode / decode `GroupPostEnvelope`, signature, transcript | ~150 |
| `lib/application/use_cases/groups/send_group_post_use_case.dart` | Orchestrates send: build wraps, sign, broadcast | ~80 |
| `lib/storage/dao/channels_dao.dart` | Channel + subscriber CRUD | ~150 |
| `lib/features/channels/channels_tab.dart` | List of joined channels in MainScreen | ~120 |
| `lib/features/channels/channel_screen.dart` | Channel feed + composer (admin only) | ~250 |
| `lib/features/channels/create_channel_screen.dart` | Form: name / desc / avatar | ~120 |
| `lib/features/channels/channel_settings_screen.dart` | Subscribers, kick, edit metadata | ~200 |
| `lib/application/use_cases/channels/*` (5 files) | Create / publish / subscribe / unsubscribe / kick | ~300 total |
| `test/crypto/group_post_codec_test.dart` | Roundtrip, tampering, signature, replay, missing-wrap | ~150 |
| `test/use_cases/send_group_post_use_case_test.dart` | Wrap order, signature transcript, fan-out | ~100 |
| `test/integration/groups_v2_test.dart` | 3-member group with kick + post sequence | ~150 |

### 5.2 Modified files

#### Crypto layer

| File | Change | Risk |
|---|---|---|
| `lib/infrastructure/crypto/group_messaging_service.dart` | Add `sendGroupPostV2()` alongside existing `sendGroupMessage()`; do **not** remove legacy paths | Medium |
| `lib/crypto/sender_keys.dart` | _untouched_ (legacy support) | — |
| `lib/infrastructure/crypto/messaging_service.dart` | _untouched_ (DM = DR) | — |
| `lib/infrastructure/crypto/double_ratchet.dart` | _untouched_ | — |

#### Use cases / Application

| File | Change | Risk |
|---|---|---|
| `lib/application/use_cases/messaging/receive_envelope_use_case.dart` | New `group_post` (v=2) handler before existing `group_msg` (v=1); also routes `channel_post` to channels handler | Low — additive |
| `lib/application/use_cases/groups/accept_group_invite_use_case.dart` | Branch on `crypto_version`: v=2 path skips chain import, just persists roster + epoch | Medium |

#### Storage

| File | Change | Risk |
|---|---|---|
| `lib/storage/database.dart` | Schema **v26**: `groups.crypto_version INTEGER NOT NULL DEFAULT 1`, `groups.epoch INTEGER NOT NULL DEFAULT 0`; new `channels` + `channel_members` tables | Low — additive |
| `lib/storage/dao/groups_dao.dart` | Read/write `crypto_version`, `epoch` | Low |
| `lib/domain/entities/group.dart` | Add `cryptoVersion`, `epoch` fields | Low |
| `lib/domain/entities/group_invite.dart` | Add `cryptoVersion` field; for v=2 the `chainKeyBlob` is empty and `roster` is populated instead | Medium |
| Other DAOs (messages, contacts, files, settings, …) | _untouched_ | — |

#### File transfer

| File | Change | Risk |
|---|---|---|
| `lib/infrastructure/file_transfer/file_service.dart` | In `sendFile(isGroup: true, …)`, branch on `crypto_version`: v=1 → existing `encryptGroupOffer`, v=2 → `SendGroupPostUseCase` carrying `FileOffer.encode()` | Medium |
| `lib/crypto/file_encryption.dart` (SF03) | _untouched_ | — |
| `lib/features/chat/voice_message_widgets.dart` / `video_circle_widgets.dart` | _untouched_ — they hand bytes to `FileService` | — |

#### Group invite + membership

| File | Change | Risk |
|---|---|---|
| `lib/features/groups/group_settings_screen.dart` | `_addMember`: v=2 invite carries roster + epoch; `_removeMember`: v=2 path skips `rotateMyChain`, just bumps epoch + broadcasts `group_kick` | Medium |
| `lib/features/groups/create_group_screen.dart` | New groups created with `crypto_version=2` | Low |
| `lib/features/groups/group_chat_screen.dart` | Send paths (text / image / audio / video) branch on `crypto_version` | Medium |

#### Routing / receive paths / network

| File | Change | Risk |
|---|---|---|
| `lib/network/message_router.dart` | _untouched_ — it just forwards to the use case | — |
| `lib/infrastructure/transport/composite_transport.dart` | _untouched_ | — |
| `lib/infrastructure/transport/{yggdrasil,reticulum,meshcore}_transport.dart` | _untouched_ | — |

#### DM and contact flow

| File | Change | Risk |
|---|---|---|
| `lib/features/chat/chat_screen.dart` (DM) | _untouched_ | — |
| `lib/application/use_cases/contacts/send_contact_hello_use_case.dart` | _untouched_ | — |
| `lib/features/contacts/*` | _untouched_ | — |
| `lib/shared/widgets/my_qr_code.dart` | _untouched_ — QR format unchanged | — |

#### Documentation

| File | Change |
|---|---|
| `docs/CRYPTO.md` | Add a "Per-Post Wrap (v=2)" section after Sender Keys |
| `docs/PROTOCOL.md` | Document the `group_post` envelope and `channel_post` |
| `docs/CHANNELS_ROADMAP.md` | Replace crypto section with a pointer to this doc |

### 5.3 Counts at a glance

| Category | Files modified | Files new |
|---|---|---|
| Crypto | 1 (`group_messaging_service`) | 1 (`group_post_codec`) |
| Use cases | 2 (receive, accept_invite) | 1 + 5 (`SendGroupPost` + 5 channel use cases) |
| Storage | 3 (database, groups_dao, group entity) + 1 (group_invite entity) | 1 (`channels_dao`) |
| File transfer | 1 (`file_service.sendFile` branch) | 0 |
| Group UI | 3 (create / chat / settings) — branching only | 0 |
| Channels UI | 0 | 4 |
| Network / transport | 0 | 0 |
| DM / contacts | 0 | 0 |
| Tests | 0 | 3 |
| Docs | 3 | 1 (this) |
| **Total** | **~14** | **~16** |

All modifications are additive branches on `crypto_version`; no rewrite
of legacy paths.

---

## 6. Phased roadmap

> Effort estimates assume one focused engineer. Tests and code review
> included.

### Phase 1 — Codec + tests (3–4 days)

- `GroupPostEnvelope` Dart class + JSON encode/decode
- `group_post_codec.dart` send/receive helpers (no UI)
- Unit tests:
  - Roundtrip (encrypt → decrypt)
  - Wrong recipient cannot decrypt
  - Tampered ciphertext rejected
  - Tampered signature rejected
  - Member with no wrap entry drops silently

**Exit criteria:** all unit tests green, no UI changes yet.

### Phase 2 — Schema migration v26 + groups DAO (1–2 days)

- Add `groups.crypto_version` column (default 1 for legacy)
- Update `Group` entity + DAO read/write
- Plumb `cryptoVersion` through `GroupRepository`
- `createGroup` flow: new groups get `crypto_version=2`

**Exit criteria:** legacy groups still load with `crypto_version=1`; new
groups created with v=2.

### Phase 3 — Wire path in `ReceiveEnvelopeUseCase` (2 days)

- Add `group_post` (v=2) handler in box-JSON path
- Verify signature against `sender_pub` (already known via
  `contact_hello`)
- Decrypt + dedupe + write to `messages` + emit `MessageReceivedEvent`
- Add `onSessionDesync` style fallback if signature fails

**Exit criteria:** v=2 envelopes received and decrypted correctly. v=1
groups still functional (no regression).

### Phase 4 — Send path + UI integration (3–4 days)

- `SendGroupPostUseCase` (build wraps, sign, hand to transport)
- `GroupChatScreen` / `GroupMessagingService` branching by
  `crypto_version` on send
- Reactions, files, replies follow the same v=2 envelope (P6-2/P6-4
  hooks) — verify nothing assumes Sender Keys body
- Kick path: v=2 groups skip `rotateMyChain`

**Exit criteria:** v=2 groups send/receive end-to-end on real devices
including files and reactions.

### Phase 5 — Channels on B (P6-6) (~10 days)

- DB: `channels` table, `channel_members` (subscribers + role)
- New envelopes: `channel_invite`, `channel_post` (= reuse
  `GroupPostEnvelope` with channel routing), `channel_unsubscribe`,
  `channel_kick`, `channel_update`
- UI: ChannelsTab, CreateChannelScreen, ChannelScreen, ChannelSettings
- Subscriber cap (start: **100**, hard-coded; raise later if needed)
- Discovery via QR + share-link
- Reactions on posts (already universal post-P6-4)

**Exit criteria:** end-to-end channel flow working for 1 admin + N
subscribers (manual test up to 10).

### Phase 6 — Hardening + docs (3–5 days)

- Multi-device tests across kicks / adds (P3 stack)
- Update `CRYPTO.md`, `PROTOCOL.md`, `CHANNELS_ROADMAP.md`
- Remove "stub" / "TODO" markers
- `flutter analyze` clean

**Exit criteria:** ready for release notes / changelog.

### Total

**~25 working days** (~5 weeks) for Groups B + Channels B. Compared to
existing PLAN.md estimate of 17 days for "Channels (Telegram-like feed)"
that bakes in MLS. Net: similar duration, vastly less complexity / risk,
and we get the simpler crypto across the board.

---

## 7. Open design questions

1. **Should `wraps` include `to_pub` as full base58 or as a short hash?**
   Full pub adds 32 B per wrap. Short hash (e.g. first 8 B of BLAKE3)
   saves 24 B per wrap (24 KB on 1000 recipients). Trade-off is a
   negligible chance of collision and slightly slower lookup. *Default:
   full pub for now — clarity over micro-optimization.*

2. **Single envelope to N or N envelopes (one per recipient)?** Today's
   Sender Keys returns N envelopes (`receivers.map(...)`). For B, we
   could broadcast **one** envelope to all and let each recipient pick
   their wrap. CompositeTransport currently sends per-pair (`to: pub` is
   a per-recipient address). Decision: continue per-recipient
   transport-level addressing for now; revisit if we add a multicast
   transport in the future.

3. **Banned members:** treat as kicked for `wraps` purposes (omit). No
   special encoding.

4. **History sharing on join:** scheme B intentionally does not share
   past posts with new joiners (no chain). If we want history-on-join
   later, it is a separate feature that re-wraps a window of past posts
   into a one-shot "history blob" for the new member. Not in scope here.

5. **Group epoch governance:** who can bump epoch? Today only admins
   change roster. We keep that — only admins bump `epoch`. Receivers
   accept epoch bumps only from valid admins (via existing role check).

6. **Kicked-member visibility window:** between kick broadcast and the
   next post, the kicked member could in principle still receive an
   in-flight post (admin sent before processing kick). Same risk as
   today's Sender Keys (pending sends use stale chain state). Acceptable.

7. **Migration of existing groups (v=1 → v=2):** *deferred* — see §4.
   Possible later via a `group_crypto_upgrade` envelope that is
   essentially a fresh `group_join_invite` to all members in v=2 form.

---

## 8. Risks & rollback

| Risk | Mitigation |
|---|---|
| Bug in signature transcript → cross-version forgery | Strong test pass on Phase 1; canonical wrap ordering by `to_pub` |
| Wire-size bloat in large groups | Hard cap subscribers/group at 200 in v=2 (UI-enforced) |
| Receiver picks wrong wrap entry | Index by recipient pub, dedup'd transcript prevents tampering |
| Migration bug breaks legacy v=1 groups | v=1 path untouched; `crypto_version` is additive |
| Cipher key reuse / nonce reuse | `nonce = randombytes(24)` for every post; XChaCha20 gives 192-bit randomness margin |

**Rollback:** stop creating v=2 groups (feature flag in `createGroup`).
v=2 groups already in the wild can still be received because the v=2
handler stays compiled in. No data loss.

---

## 9. Decisions needed before Phase 1 starts

- [ ] Approve the wire format in §3.2 (or propose changes).
- [ ] Confirm subscriber cap **100** for channels MVP.
- [ ] Confirm we keep DR for DM (no changes there) — yes.
- [ ] Confirm we **do not** in-place migrate existing groups (§4).
- [ ] Decide naming: `crypto_version` vs `protocol_version` on `groups`.
- [ ] Pick the message envelope discriminator string —
      `group_post` vs `gp_v2` vs other.

When these are resolved, Phase 1 can start.
