# Group Crypto Refactor — Per-Post Wrap (Scheme B)

**Status:** P7-0 decisions resolved 2026-05-09 — phase 1 unblocked
**Author:** —
**Created:** 2026-05-08
**Supersedes (when adopted):** crypto sections of `CHANNELS_ROADMAP.md`,
parts of `CRYPTO.md`

## 0. Decisions resolved (P7-0, 2026-05-09)

| # | Question | Resolution |
|---|---|---|
| 1 | Wire format §3.2 | **Per-recipient envelope** — singular `wrap` (not a list); each recipient gets their own envelope with only their key wrap. Avoids `O(N)` wire-bloat and metadata leak (channel subscribers don't see each other). |
| 2a | Subscriber cap (channels MVP) | **100** |
| 2b | File limit in channel posts | **2 MB** (matches group file limit) |
| 3 | DM crypto | **Stays on Double Ratchet.** Pair-to-pair messaging is well-served by DR — no change. |
| 4 | Existing groups migration | **Hard cutover.** No production deployments yet → Sender Keys code is removed entirely; no `crypto_version` flag needed. |
| 5 | Roster counter column name | **`epoch`** (`groups.epoch INTEGER NOT NULL DEFAULT 0`) |
| 6 | Envelope discriminator | **`group_post`** (works for both groups and channels) |

These decisions are reflected throughout this doc — sections affected:
§3.2 (wire format), §3.3 (operations), §4 (migration → cutover), §5
(code impact: deletions of Sender Keys + no version branching), §6
(phased roadmap: shorter, with explicit `Phase 0 — Removal`).

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

### 3.2 Wire format

**Per-recipient envelope** — sender produces N envelopes, one per
recipient. Each envelope carries the same content ciphertext and the
recipient's own key wrap. No recipient sees the others.

```
GroupPostEnvelope {                  // one per recipient
  type:          "group_post"
  group_id:      base58              // conversation id
  epoch:         uint32              // group roster epoch (bumped on add / kick / role change)
  content:       {
    nonce:       bytes[24]           // XChaCha20-Poly1305 nonce
    ciphertext:  bytes               // AEAD(content_key, plaintext, nonce, AAD)
  }
  wrap:          {                   // singular — only this recipient's key share
    box_nonce: bytes[24]             // NaCl box nonce
    eph_pub:   bytes[32]             // ephemeral X25519 pub
    box:       bytes[32+16]          // NaCl box of content_key
  }
  msg_id:        hex8                // for receipts and dedup
  ttl_seconds:   uint32?             // optional disappearing TTL
  sender_pub:    base58              // sender signing-pub (Ed25519)
  signature:     bytes[64]           // Ed25519.sign(signing_priv, transcript)
}

transcript = SHA256(
  "hubcore-group-post-v1" ||
  group_id                ||
  epoch                   ||
  msg_id                  ||
  content.nonce           ||
  content.ciphertext
)

AAD for content AEAD = "hubcore-content-v1" || group_id || epoch || msg_id
```

The signature is **identical for every recipient** of the same post —
it doesn't depend on the wrap. It authenticates the *content* and the
sender's group context (group_id + epoch + msg_id), which is what
matters.

Sizes (per envelope sent to one recipient):

- Content overhead ≈ 24 (nonce) + 16 (Poly1305 tag) = 40 B
- One wrap ≈ 24 (box_nonce) + 32 (eph_pub) + 48 (box ciphertext) = 104 B
- Signature + sender_pub ≈ 96 B
- Header / framing ≈ 50 B

Per-envelope total (text post 200 B body): **~ 490 B**.

Total bytes the sender uploads for one post:

| Recipients (N) | Total upload |
|---|---|
| 50 | ~ 24 KB |
| 100 | ~ 49 KB |
| 200 | ~ 98 KB |

Compared to the bundled-wraps alternative considered earlier in the
design (one envelope to all, list of N wraps inside) this is **N×
cheaper on wire** (no quadratic growth) and gives channel subscribers
member-list privacy for free.

### 3.3 Operations

#### Send a post

```
content_key  = randombytes(32)
nonce        = randombytes(24)
ciphertext   = chacha20poly1305_encrypt(content_key, plaintext, nonce, AAD)
transcript   = sha256("hubcore-group-post-v1" || group_id || epoch || msg_id
                      || nonce || ciphertext)
signature    = ed25519_sign(signing_priv, transcript)

envelopes    = []
for member in active_members(group):                  // excludes 'banned' + self
    eph        = x25519.keygen()
    box_nonce  = randombytes(24)
    box        = nacl_box(member.x25519_pub, eph.priv, content_key, box_nonce)
    envelopes.append(Envelope {
      to:        member.master_pub,
      body:      GroupPostEnvelope {
        group_id, epoch, content { nonce, ciphertext },
        wrap     { box_nonce, eph_pub: eph.pub, box },
        msg_id, ttl_seconds, sender_pub, signature
      }
    })
zeroize(content_key)
for env in envelopes: transport.send(env)             // CompositeTransport per-pair
```

`content_key` is generated once, used to AEAD-encrypt the body, then
discarded. Each member receives a different envelope (different `wrap`)
but the same `content`, `signature`, and metadata.

#### Receive a post

```
verify(signature) using sender_pub               // signing pub known via contact_hello
                                                  // reject if sender not a current group member
content_key = nacl_box_open(my_x25519_priv,
                            wrap.eph_pub,
                            wrap.box,
                            wrap.box_nonce)       // None → drop silently
plaintext   = chacha20poly1305_decrypt(content_key, content.ciphertext,
                                       content.nonce, AAD)
zeroize(content_key)
if message_already_seen(msg_id, sender_pub): return  // dedup
store_message(plaintext)
send_msg_received_receipt(sender_pub, msg_id)
```

#### Add a member

1. Admin (or member with `canAddMembers`) sends a `group_join_invite`
   control envelope (NaCl box) to the new member. Payload: group
   metadata + current `epoch` + current roster (master pubs only).
2. New member persists the group locally with the supplied `epoch`.
3. Admin bumps `groups.epoch` and broadcasts a `group_member_added`
   control envelope to all members.
4. Subsequent posts include `new_pub` in their per-recipient fan-out.

No chain key is exchanged. New members **cannot decrypt past posts**
unless an explicit history-share flow is added later (out of scope).

#### Remove a member

1. Admin sends `group_kick(removed_pub)` to all members including the
   removed one (existing behaviour).
2. Admin bumps `groups.epoch`.
3. Subsequent posts simply omit `removed_pub` from the recipient list.

There is **no `rotateMyChain` step**. The kicked member never had a
shared chain to revoke — they only had the wraps for posts they've
already received, and those past content keys are already discarded by
the sender.

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
  will include B in the recipient list — B (still holding its X25519)
  will decrypt that one stale post. Mitigated by `epoch` sync on
  kick/add (control plane is fast and reliable).

### 3.6 Comparison vs Sender Keys

| Property | Sender Keys (current) | Scheme B (resolved) |
|---|---|---|
| Forward secrecy | Per ratchet step (every 100 msgs) | Per post (always) |
| PCS | None | None |
| Code size | 521 + 219 LOC + cache + ratchet sched | ~150 LOC codec + reuse of existing `encryptBox` |
| State per device | N chains × group | Zero (stateless) |
| Add member cost | 1 invite + chain | 1 invite, no chain |
| Kick cost | `(N-1)²` rotation envelopes | 1 control envelope + epoch bump |
| Out-of-order | Skipped-keys cache | Trivially OK |
| Per-recipient envelope size | ~50 B framing | ~ 490 B (text 200 B + 104 B wrap + 96 B sig + framing) |
| Total upload at N=100 (text) | ~50 KB | ~ 49 KB |
| Ciphertext fan-out | N envelopes (per-pair) | N envelopes (per-pair, identical content + per-recipient wrap) |
| Authentication of sender | Implicit (chain-only writer) | Explicit Ed25519 signature |
| Recipients see each other? | Yes (membership table) | **No** (no recipient list in envelope — channel privacy free) |
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

So the wire format change is a one-liner per send site: route the
`FileOffer` body through `SendGroupPostUseCase` instead of the deleted
`encryptGroupOffer`.

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

## 4. Migration strategy — Hard cutover

There are no production deployments yet, so there is **no installed
base of Sender Keys groups to migrate**. We use the freedom to do a
clean refactor:

- **Sender Keys is removed entirely** in this work — `sender_keys.dart`,
  the chain caches in `GroupMessagingService`, the `_GroupPayload`
  envelope type, and the `chain_key` / `ratchet_pub` / `counter`
  columns from `group_members` all go away.
- **No `crypto_version` flag.** Every group from this commit forward is
  on scheme B; there is nothing to branch on.
- **Channels** ship on B from day 1 (they did not exist before).
- **Schema migration v26**: drop `group_members.chain_key`,
  `group_members.ratchet_pub`, `group_members.counter`; add
  `groups.epoch INTEGER NOT NULL DEFAULT 0`. Rebuild any existing dev
  groups manually if needed (no production data).

**Why this is safer than soft-fork in our case:** soft-fork keeps two
crypto paths in production code forever, doubling the test surface and
the maintenance cost. Hard cutover is one path, one set of tests, one
mental model. The trade-off is "cannot migrate live groups" which we
do not need to do.

---

## 5. Code impact map

### 5.1 Files to delete (Sender Keys removal)

| File | Reason |
|---|---|
| `lib/crypto/sender_keys.dart` (~219 LOC) | Sender Keys primitive — fully replaced by `group_post_codec` |
| `test/crypto/sender_keys_test.dart` | Tests for the deleted primitive |
| Sender-Keys-only methods in `group_messaging_service.dart` (`buildInvitePayload` for chain, `acceptInvite`, `importMemberChain`, `rotateMyChain`, `evictMemberChain`, `_chains` cache, `encryptGroupOffer`, `_GroupPayload` codec) | Replaced by per-post wrap — file becomes a thin orchestration layer or is renamed to `group_crypto_service.dart` |

### 5.2 New files (groups B + channels MVP)

| File | Purpose | LOC est. |
|---|---|---|
| `lib/infrastructure/crypto/group_post_codec.dart` | Encode / decode `GroupPostEnvelope`, signature, transcript, AEAD, NaCl box wrap/unwrap | ~150 |
| `lib/application/use_cases/groups/send_group_post_use_case.dart` | Orchestrates send: gen content key, AEAD, sign, fan-out per recipient | ~80 |
| `lib/storage/dao/channels_dao.dart` | Channel + subscriber CRUD | ~150 |
| `lib/features/channels/channels_tab.dart` | List of joined channels in MainScreen | ~120 |
| `lib/features/channels/channel_screen.dart` | Channel feed + composer (admin only) | ~250 |
| `lib/features/channels/create_channel_screen.dart` | Form: name / desc / avatar | ~120 |
| `lib/features/channels/channel_settings_screen.dart` | Subscribers, kick, edit metadata | ~200 |
| `lib/application/use_cases/channels/*` (5 files) | Create / publish / subscribe / unsubscribe / kick | ~300 total |
| `test/crypto/group_post_codec_test.dart` | Roundtrip, tamper-content, tamper-signature, wrong-recipient drop | ~150 |
| `test/use_cases/send_group_post_use_case_test.dart` | Signature transcript, fan-out correctness | ~100 |
| `test/integration/groups_b_test.dart` | 3-member group with kick + post sequence | ~150 |

### 5.3 Modified files

#### Crypto layer

| File | Change |
|---|---|
| `lib/infrastructure/crypto/group_messaging_service.dart` | Strip Sender Keys methods; keep only group lifecycle / fan-out helpers; rewire to `SendGroupPostUseCase`. May rename to `group_crypto_service.dart`. |
| `lib/infrastructure/crypto/messaging_service.dart` | _untouched_ (DM = DR) |
| `lib/infrastructure/crypto/double_ratchet.dart` | _untouched_ |

#### Use cases / Application

| File | Change |
|---|---|
| `lib/application/use_cases/messaging/receive_envelope_use_case.dart` | Replace `group_msg` (Sender Keys) handler with `group_post` (B) handler. No version branching. |
| `lib/application/use_cases/groups/accept_group_invite_use_case.dart` | Single path: persist roster + epoch on invite acceptance. No chain import. |

#### Storage

| File | Change |
|---|---|
| `lib/storage/database.dart` | Schema **v26**: drop `group_members.chain_key`, `group_members.ratchet_pub`, `group_members.counter`; add `groups.epoch INTEGER NOT NULL DEFAULT 0`; new `channels` + `channel_members` tables. |
| `lib/storage/dao/groups_dao.dart` | Drop chain accessors; add `epoch` accessor + bump helper. |
| `lib/domain/entities/group.dart` | Drop chain fields from `GroupMember`; add `epoch` to `Group`. |
| `lib/domain/entities/group_invite.dart` | Replace `chainKeyBlob` with `roster: List<String>` + `epoch: int`. |

#### File transfer

| File | Change |
|---|---|
| `lib/infrastructure/file_transfer/file_service.dart` | In `sendFile(isGroup: true, …)`: replace `encryptGroupOffer` call with `SendGroupPostUseCase` carrying `FileOffer.encode()`. |
| `lib/crypto/file_encryption.dart` (SF03) | _untouched_ |
| `lib/features/chat/voice_message_widgets.dart` / `video_circle_widgets.dart` | _untouched_ — they hand bytes to `FileService` |

#### Group invite + membership UI

| File | Change |
|---|---|
| `lib/features/groups/group_settings_screen.dart` | `_addMember`: invite payload = roster + epoch (no chain). `_removeMember`: bump epoch + broadcast `group_kick`. **No `rotateMyChain` call.** |
| `lib/features/groups/create_group_screen.dart` | Initialise group with `epoch=0`. |
| `lib/features/groups/group_chat_screen.dart` | Replace `groupSvc.sendGroupMessage(...)` calls (text / image / audio / video) with `SendGroupPostUseCase`. Single path. |

#### Routing / transport / DM

| File | Change |
|---|---|
| `lib/network/message_router.dart` | _untouched_ |
| `lib/infrastructure/transport/composite_transport.dart` | _untouched_ |
| `lib/infrastructure/transport/{yggdrasil,reticulum,meshcore}_transport.dart` | _untouched_ |
| `lib/features/chat/chat_screen.dart` (DM) | _untouched_ |
| `lib/application/use_cases/contacts/send_contact_hello_use_case.dart` | _untouched_ |
| `lib/features/contacts/*` | _untouched_ |
| `lib/shared/widgets/my_qr_code.dart` | _untouched_ — QR format unchanged |

#### Documentation

| File | Change |
|---|---|
| `docs/CRYPTO.md` | Replace Sender Keys section with "Per-Post Wrap" |
| `docs/PROTOCOL.md` | Replace `group_msg` envelope spec with `group_post`; add `channel_post` |
| `docs/CHANNELS_ROADMAP.md` | Replace crypto section with a pointer to this doc |

### 5.4 Counts at a glance

| Category | Files deleted | Files modified | Files new |
|---|---|---|---|
| Crypto | 1 (`sender_keys.dart`) | 1 (`group_messaging_service`) | 1 (`group_post_codec`) |
| Use cases | 0 | 2 (receive, accept_invite) | 1 + 5 (`SendGroupPost` + 5 channels) |
| Storage | 0 | 3 (database, groups_dao, group entity) + 1 (group_invite entity) | 1 (`channels_dao`) |
| File transfer | 0 | 1 (`file_service.sendFile`) | 0 |
| Group UI | 0 | 3 (create / chat / settings) | 0 |
| Channels UI | 0 | 0 | 4 |
| Network / transport / DM / contacts | 0 | 0 | 0 |
| Tests | 1 (sender_keys_test) | 0 | 3 |
| Docs | 0 | 3 | 1 (this) |
| **Total** | **2** | **~14** | **~16** |

Single code path post-cutover. No `crypto_version` branches anywhere.

---

## 6. Phased roadmap

> Effort estimates assume one focused engineer. Tests and code review
> included. Hard cutover means no parallel-path work.

### Phase 1 — Codec + tests (3–4 days)

- `GroupPostEnvelope` Dart class + canonical JSON encode/decode
- `group_post_codec.dart`: AEAD content encrypt/decrypt; per-recipient
  NaCl box wrap/unwrap; signature transcript + Ed25519 sign/verify
- Unit tests:
  - Roundtrip (encrypt → wrap → unwrap → decrypt)
  - Wrong recipient (foreign X25519 priv) cannot decrypt
  - Tampered ciphertext rejected (AEAD MAC fails)
  - Tampered signature rejected
  - Stale `epoch` accepted but flagged for caller (no hard drop)

**Exit criteria:** all unit tests green; no UI / wire integration yet.

### Phase 2 — Schema cutover v26 + groups DAO (1–2 days)

- Schema **v26**: drop `group_members.chain_key`, `group_members.ratchet_pub`,
  `group_members.counter`; add `groups.epoch INTEGER NOT NULL DEFAULT 0`.
- Update `Group` and `GroupMember` entities (drop chain fields, add `epoch`).
- Update `GroupsDao` and `GroupMembersDao` accessors.
- Update `GroupInvite` entity: `chainKeyBlob` → `roster: List<String>` + `epoch`.

**Exit criteria:** schema migrates cleanly on a fresh dev DB; old chain
columns are gone; all DAO callers compile.

### Phase 3 — Receive path in `ReceiveEnvelopeUseCase` (2 days)

- Replace `group_msg` (Sender Keys) handler with `group_post` (B) handler.
- Verify signature against `sender_pub` (known via `contact_hello`).
- Decrypt + dedupe by `(msg_id, sender)` + write to `messages` + emit
  `MessageReceivedEvent`.
- Drop posts whose sender is not a current member (or is banned).

**Exit criteria:** sending a `group_post` envelope from one device to
another causes the message to appear correctly.

### Phase 4 — Send path + UI integration (2–3 days)

- `SendGroupPostUseCase` orchestrates: gen content key, AEAD body,
  build per-recipient wraps, sign once, fan-out N envelopes.
- `GroupChatScreen` send paths (text / image / audio / video) call the
  use case directly. **No version branching.**
- `_addMember` / `_removeMember` in `GroupSettingsScreen`: bump `epoch`,
  send `group_kick` / `group_member_added` control envelopes. Drop the
  `rotateMyChain` call entirely.
- `FileService.sendFile` for groups: replace `encryptGroupOffer` with
  `SendGroupPostUseCase` for the `FileOffer`.

**Exit criteria:** group send / receive end-to-end on two real devices,
covering text, image, voice, video, file, reaction, reply.

### Phase 5 — Sender Keys removal (1 day)

- Delete `lib/crypto/sender_keys.dart` and
  `test/crypto/sender_keys_test.dart`.
- Strip Sender Keys methods from `group_messaging_service.dart`
  (rename to `group_crypto_service.dart` if appropriate).
- Confirm `flutter analyze` shows zero references to deleted symbols.

**Exit criteria:** no Sender Keys code in the repo; all tests still pass.

### Phase 6 — Channels on B (~10 days)

- Schema: `channels`, `channel_members` tables + `ChannelsDao`.
- New envelopes: `channel_invite`, `channel_post` (reuses
  `GroupPostEnvelope` with channel routing), `channel_unsubscribe`,
  `channel_kick`, `channel_update`.
- UI: `ChannelsTab` (in MainScreen), `ChannelScreen` (feed + composer
  for admins), `CreateChannelScreen`, `ChannelSettingsScreen`.
- Discovery via QR + share-link (`hubcorechannel://…`).
- Subscriber cap **100**; file limit in posts **2 MB** (matches groups).
- Reactions on posts (free, inherited from P6-4).

**Exit criteria:** end-to-end channel flow for 1 admin + N subscribers
on real devices (manual test up to 10 subscribers).

### Phase 7 — Hardening + docs (2–4 days)

- Multi-device tests across kicks / adds / role changes (P3 stack).
- Update `docs/CRYPTO.md` (replace Sender Keys section), `docs/PROTOCOL.md`
  (envelope spec), `docs/CHANNELS_ROADMAP.md` (point at this doc).
- `flutter analyze` clean; remove TODO / stub markers.

**Exit criteria:** ready for release notes / changelog entry.

### Total

| Phase | Days |
|---|---|
| 1. Codec + tests | 3–4 |
| 2. Schema cutover | 1–2 |
| 3. Receive path | 2 |
| 4. Send + UI | 2–3 |
| 5. Sender Keys removal | 1 |
| 6. Channels | ~10 |
| 7. Hardening + docs | 2–4 |
| **Total** | **~21–26 days** |

Hard cutover lets us cut Phase 4 by a day (no branching) and add the
removal phase. Net effort is essentially the same as the soft-fork
plan but ends with **no legacy code in the repo**.

---

## 7. Open design questions (post-P7-0)

The following are minor implementation choices left to the engineer
during Phase 1; they do not block the start of work.

1. **Banned members:** treated as kicked for recipient-list purposes
   (omitted from fan-out). No special encoding.

2. **History sharing on join:** scheme B does not share past posts
   with new joiners. If we want history-on-join later, it is a
   separate feature (a one-shot "history blob" for the new member).
   Out of scope here.

3. **Group epoch governance:** only admins bump `epoch` (existing role
   check). Receivers reject `epoch` bumps from non-admins.

4. **Kicked-member visibility window:** between kick broadcast and the
   next post, an in-flight post the admin already sent before
   processing the kick may still reach the removed member. Same risk
   profile as Sender Keys today. Acceptable.

5. **Future migration (v2 → v3, e.g. MLS):** post-cutover we have a
   single path; future protocol changes are easier to add cleanly than
   to a soft-fork codebase. If/when needed we add a version flag at
   that point — costs nothing now to defer.

---

## 8. Risks & rollback

| Risk | Mitigation |
|---|---|
| Bug in signature transcript → forged messages accepted | Strong unit test pass on Phase 1: tamper-content, tamper-signature, wrong-key-verify |
| Wire-size bloat at large group sizes | Hard cap members/group at 200 in UI |
| Receiver fails to decrypt their wrap (missing X25519 priv) | Drop silently with `AppLogger.w`; sender sees no `msg_received` from that recipient |
| Cipher / nonce reuse | `nonce = randombytes(24)` per post; XChaCha20 gives 192-bit randomness margin; new ephemeral key per box wrap |
| Mis-built migration v26 dropping data on a real device | No production data to lose; dev DBs can be rebuilt; CI runs migration tests |

**Rollback:** `git revert` of the cutover commit restores Sender Keys
in full. There is no on-disk legacy state to be incompatible with —
schema v26 is the new floor, and we are pre-release.

---

## 9. Decisions resolved (P7-0, 2026-05-09)

| # | Decision | Resolution |
|---|---|---|
| 1 | Wire format §3.2 | Per-recipient envelope (singular `wrap`) |
| 2a | Subscriber cap (channels MVP) | 100 |
| 2b | File limit in channel posts | 2 MB |
| 3 | DM crypto | Stays on Double Ratchet |
| 4 | Existing-groups migration | Hard cutover (no `crypto_version` flag) |
| 5 | Roster counter column name | `epoch` |
| 6 | Envelope discriminator | `group_post` |

**Phase 1 is unblocked.** See PLAN.md `P7-1` and onward for trackable
sub-tasks.
