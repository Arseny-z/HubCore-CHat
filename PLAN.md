# HubCore Chat — Development Plan

## P0 — Security (release blockers)

- [x] P0-1 Sign `contact_hello` with sender's signing key — MITM key substitution possible without this
- [x] P0-2 Sign `senderEphPub` in DM payload
- [x] P0-3 Verify signing key on every incoming message
- [x] P0-4 Remove auto-delete session on decrypt error — any garbage packet resets session (DoS vector)
- [x] P0-5 Fix fire-and-forget futures in `message_router.dart` — send errors swallowed silently
- [x] P0-6 Fix `_sendDeliveredReceipt()` ignoring returned Future — wrong delivery status shown in UI
- [x] P0-7 Add `messageId` to group messages — delivery receipts impossible without it

## P1 — Correctness bugs

- [x] P1-1 `ProcessReceiptUseCase` — unify two desynchronized receipt paths
- [x] P1-2 `EnsureSessionUseCase` — add mutex on session init to fix race condition on parallel send
- [x] P1-3 `AppLockUseCase` — null lockManager leaves DB open in background
- [x] P1-4 Write `message_receipts` rows on direct `sendMessage`
- [x] P1-5 `AcceptGroupInviteUseCase` — new member cannot decrypt existing messages, fix chain sync
- [x] P1-6 Keep sending `senderEphPub` until `msg_delivered` receipt confirmed
- [x] P1-7 `ErrorEvent` in EventBus + Snackbar for crypto/transport init failures

## P2 — Core UX

- [x] P2-1 Unread badge in chat list — no way to know new messages exist
- [x] P2-2 Reply to message (DB migration + protocol + UI)
- [x] P2-3 Message history pagination — LIMIT/OFFSET in DAO, OOM risk on large chats
- [x] P2-4 ChatScreen refactor — 35 setState + 17 `_loadMessages` → `messagesStreamProvider`
- [x] P2-5 Contacts & Privacy — stranger/blocked/policy, "New conversations" section, block UI (~6.5 days)
- [x] P2-6 Profile privacy — public vs contacts profile, per-recipient profile selection (~3 days)

## P3 — Multi-device

- [x] P3-1 Complete device pairing UI — `PairDeviceScreen` (show QR) + `ScanPairingScreen` (scan QR)
- [x] P3-2 `DevicePairingCrypto` — QR bundle encrypt/decrypt
- [x] P3-3 `DevicePairingService` — handshake/ack logic + save devices + broadcast hello
- [x] P3-4 Cross-device sync service (`device_sync_request/response`)
- [x] P3-5 `send_queue` per-device status
- [x] P3-6 Signing key rotation on master device only
- [x] P3-7 Device management UI

## P4 — Groups

- [x] P4-1 Group message statuses — receipt tracking per member, N/M counter in UI
- [x] P4-2 Files in group chats (2 MB limit, fan-out to all members)
- [x] P4-3 Group management — add/remove member, rename, key rotation on kick, delete group, admin transfer
- [x] P4-4 Group roles — admin/write/read/banned, max 3 admins, owner immutable

## P5 — Reticulum

- [x] P5-1 Go port of core RNS into `rnsbind.go` (Identity, Destination, Packet, Announce, Transport, fragmentation)
- [x] P5-2 `ReticulumService.kt` + `ReticulumNode.dart` — Kotlin/Dart wrappers (foreground service, watchdog)
- [x] P5-3 `ReticulumTransport` implementation, wired into CompositeTransport
- [x] P5-4 Reticulum address exchange via QR (`rk` field) + `contact_hello` propagation
- [ ] P5-5 RNS propagation node — store-and-forward для офлайн-доставки (deferred)

## P6 — Polish

- [x] P6-1 Notification on contact key change
- [x] P6-2 Panic button — shake gesture → wipe (Soft countdown / Hard instant, low/medium/high sensitivity)
- [x] P6-3 Message search (global SearchScreen + per-chat search bar with hit navigation in DM/groups)
- [x] P6-4 Message reactions (Telegram-style: 1 per user, 8-emoji palette, cascades with message)
- [x] P6-5 Embed public Yggdrasil peer list in APK (kYggdrasilDefaultPeers, read-only, hardcoded TLS+QUIC peers)
- [ ] P6-6 Channels (Telegram-like feed) — **subsumed by P7 phase 5** (channels ship on the new crypto scheme directly)
- [ ] P6-7 Desktop client (Flutter Desktop) — MLS path dropped, see `docs/GROUP_CRYPTO_REFACTOR_ROADMAP.md`

## P7 — Group / Channel crypto refactor (Scheme B: per-post wrap)

> Replaces Sender Keys with NaCl-box-per-recipient wraps + Ed25519 signature.
> Channels ship on B from day 1; existing groups stay on Sender Keys (legacy).
> Full rationale, threat model, and impact map in `docs/GROUP_CRYPTO_REFACTOR_ROADMAP.md`.

### P7-0 Decisions gate
- [ ] P7-0 Resolve §9 open decisions (wire format approval, subscriber cap, `crypto_version` vs `protocol_version` naming, envelope discriminator string)

### P7-1 Codec + tests (3–4 days)
- [ ] P7-1 `GroupPostEnvelope` dataclass + canonical JSON encode/decode
- [ ] P7-2 `group_post_codec.dart` — wrap-per-recipient (NaCl box) + Ed25519 signature transcript + verify
- [ ] P7-3 Unit tests: roundtrip, tamper-ciphertext, tamper-signature, missing-wrap drop, wrong-recipient cannot decrypt

### P7-2 Schema + DAO (1–2 days)
- [ ] P7-4 Schema v26: `groups.crypto_version` + `groups.epoch` columns + migration
- [ ] P7-5 `Group` entity + `GroupsDao` reads/writes new columns
- [ ] P7-6 `createGroup` flow: new groups created with `crypto_version=2`

### P7-3 Receive path (2 days)
- [ ] P7-7 `group_post` (v=2) handler in `ReceiveEnvelopeUseCase` with signature verification
- [ ] P7-8 Roster/epoch sync, dedup by `messageId`, `MessageReceivedEvent` emit

### P7-4 Send path + UI integration (3–4 days)
- [ ] P7-9 `SendGroupPostUseCase` (build wraps, sign, fan-out)
- [ ] P7-10 `GroupChatScreen` send paths (text / image / audio / video) branch on `crypto_version`
- [ ] P7-11 Adapt `AcceptGroupInviteUseCase` for v=2 (roster + epoch, no chain import)
- [ ] P7-12 Kick path in v=2: skip `rotateMyChain`, bump `epoch`, broadcast `group_kick`
- [ ] P7-13 `FileService.sendFile` for groups: branch on `crypto_version` for `FileOffer` envelope wrapping

### P7-5 Channels MVP on B (~10 days)
- [ ] P7-14 Schema: `channels`, `channel_members` tables + `ChannelsDao`
- [ ] P7-15 Channel envelopes (`channel_invite`, `channel_post`, `channel_unsubscribe`, `channel_kick`, `channel_update`) — `channel_post` reuses `GroupPostEnvelope`
- [ ] P7-16 `ChannelsTab` in MainScreen
- [ ] P7-17 `ChannelScreen` (feed + composer for admin) + reactions/replies (free from P6-4)
- [ ] P7-18 `CreateChannelScreen` + `ChannelSettingsScreen` (subscribers, kick, edit metadata)
- [ ] P7-19 Discovery via QR + share-link (`hubcorechannel://…`)
- [ ] P7-20 Subscriber cap enforcement (default 100, hard-coded)

### P7-6 Hardening + docs (3–5 days)
- [ ] P7-21 Multi-device tests across kicks / adds (P3 stack)
- [ ] P7-22 Update `CRYPTO.md`, `PROTOCOL.md`, `CHANNELS_ROADMAP.md`
- [ ] P7-23 `flutter analyze` clean; remove TODO/stub markers
