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

- [ ] P4-1 Group message statuses — receipt tracking per member, N/M counter in UI
- [ ] P4-2 Files in group chats (2 MB limit, fan-out to all members)
- [ ] P4-3 Group management — add/remove member, rename, key rotation on kick
- [ ] P4-4 Group roles — admin/write/read/banned, max 3 admins (~5.5 days)

## P5 — Reticulum (critical path)

- [ ] P5-1 Go port of core RNS into `rnsbind.go` — **everything else in P5 is blocked on this** (~1–3 weeks)
- [ ] P5-2 `ReticulumService.kt` + `ReticulumNode.dart` — Kotlin/Dart wrappers (~3–4 days)
- [ ] P5-3 `ReticulumTransport` implementation
- [ ] P5-4 Reticulum address exchange via QR + `contact_hello`
- [ ] P5-5 RNS propagation node — store-and-forward replacement for removed relay

## P6 — Polish

- [ ] P6-1 Notification on contact key change
- [ ] P6-2 Panic button — shake gesture → wipe
- [ ] P6-3 Message search
- [ ] P6-4 Message reactions
- [ ] P6-5 Embed public Yggdrasil peer list in APK
- [ ] P6-6 Channels (Telegram-like feed, ~17 days)
- [ ] P6-7 Desktop client + MLS for large groups
