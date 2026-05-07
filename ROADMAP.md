# HubCore Chat — Roadmap

> P2P messenger with E2EE. Yggdrasil transport. One APK — no configuration.

---

## Current Version Status (v0.2 — Yggdrasil transport)

Done:

- [x] Flutter client Android
- [x] Double Ratchet E2EE for direct chats
- [x] Sender Keys for group chats
- [x] Two-level keys (Master + Signing + SigningCert)
- [x] SQLCipher local storage
- [x] Auto-lock + FLAG_SECURE
- [x] Encrypted identity backup/restore
- [x] Encrypted file transfer (XChaCha20-Poly1305, up to 200 MB, chunked)
- [x] QR contact exchange
- [x] Yggdrasil node embedded in APK (foreground service, persistent key)
- [x] Direct P2P message delivery via Yggdrasil (fd00:: addresses)
- [x] Yggdrasil address cache for contacts in DB
- [x] Delivery and read receipts (✓ sent / ✓✓ delivered / ✓✓ read)
- [x] Message TTL (disappearing messages)
- [x] Duress PIN (silent wipe on unlock, set in Settings)
- [x] Brute-force protection (attempt counter + auto-wipe after 10)
- [x] Localization EN/RU

---

## Phase 8 — Yggdrasil transport (~95% complete)

### Remaining

- [ ] Embed public peer list (Moscow, SPB, Ekb, Novosibirsk, Omsk) in yggbind
- [ ] TCP ping to fd00:: for online status detection (without server)
- [ ] Phone relay mode — Settings → "Relay mode" (charging + WiFi only) *(optional)*

---

## Phase 9 — Security & Privacy (in progress)

- [x] Duress PIN (entry → wipe in background → empty app)
- [x] Disappearing messages (client-side TTL)
- [x] PIN brute-force protection (counter + auto-wipe after N attempts)
- [ ] Panic button (gesture → instant wipe, e.g. 5× tap on icon or shake)
- [ ] Notification on contact key change (on receiving new SigningCert)
- [ ] Yggdrasil address verification via QR (add `yk` to QR exchange)

---

## Phase 10 — Polish

- [ ] Unread badge in chat list (ChatsScreen)
- [ ] Push notifications (FCM as wakeup transport, not for content)
- [x] Voice messages
- [x] Video circles
- [ ] Message reactions
- [ ] Message search (client-side, within chat)
- [ ] Themes

---

## Tech Debt — Code Audit (2026-04)

> Found during pre-release audit. Grouped by priority.

---

### 🔴 P0 — Before release (blocks production)

#### TD-01 · Sensitive data in logs
**Files:** `receive_envelope_use_case.dart:434`, `process_receipt_use_case.dart:37,60,77,88`,
`file_service.dart:254-256`, `queue_service.dart:117,235`, `message_router.dart:117`

**Problem:** 122 `print()` calls in production code. Critical:
- `receive_envelope_use_case.dart:434` — logs **plaintext message content** to logcat
- `file_service.dart:254` — logs file names, transferId, TTL
- `process_receipt_use_case.dart:37` — exposes messageId, status, DB id
- Contact public keys visible via logcat to any app with READ_LOGS

**Solution (chosen B):** Replace all `print()` with `dart:developer` `log()` with severity levels.
Debug calls wrapped in `kDebugMode`. Error level kept in production (only critical failures without sensitive data).
- `lib/shared/utils/logger.dart` — unified facade: `AppLogger.d()`, `.w()`, `.e()`
- All `print()` → `AppLogger.d()` wrapped in kDebugMode
- `receive_envelope_use_case.dart:434` — **delete** (never log plaintext message content)

- [x] Implement `AppLogger` facade (`lib/shared/utils/logger.dart`)
- [x] Replace all `print()` in lib/ with `AppLogger.d/w/e`
- [x] Remove plaintext message content logging
- [x] Verify no sensitive data in release APK logcat

---

#### TD-02 · Empty catch blocks hide critical errors
**Files:** `transport_providers.dart:34,124`, `crypto_providers.dart:88`,
`messaging_service.dart:357`, `file_service.dart:144,765`,
`receive_envelope_use_case.dart:528`

**Problem:** 26 empty `catch (_) {}`. Critical locations:
- `transport_providers.dart:34` — transport init error swallowed → app starts without network, user doesn't know why
- `crypto_providers.dart:88` — crypto init error → chat silently doesn't work
- `messaging_service.dart:357` — decryption box error → message lost without trace

**Solution (chosen B):** Split catch by meaning:
- IO errors (delete temp file, file.exists()) — silent, empty catch ok
- Crypto/network/init — `AppLogger.e(e)` + for critical ones emit `ErrorEvent` to EventBus
- UI subscribes to `ErrorEvent` → shows Snackbar/toast

- [x] Classify empty catches: IO vs crypto/network
- [x] Add `AppLogger.w()` to crypto/network catches
- [ ] `ErrorEvent` in EventBus for critical init errors
- [ ] Subscribe UI (ChatScreen / MainScreen) to ErrorEvent → Snackbar

---

#### TD-03 · MessagingService — no dispose() for StreamController
**File:** `messaging_service.dart:62-63`

**Problem:** `_statusCtrl = StreamController<StatusUpdate>.broadcast()` is never closed.

**Solution (chosen A):** Add `void dispose()` to MessagingService closing `_statusCtrl`,
call `ref.onDispose(() => messaging.dispose())` in provider.

- [x] Add `dispose()` to `MessagingService`
- [x] Call in `messagingServiceProvider` via `ref.onDispose`

---

### 🟡 P1 — Important (first 2 weeks after release)

#### TD-04 · Group messages — no read receipts
**Files:** `receive_envelope_use_case.dart`, `send_receipt_use_case.dart`, `process_receipt_use_case.dart`

**Problem:** Direct chats have full sent → delivered → read cycle. Groups: sent and delivered work, read — does not.

**Solution (chosen B):** On opening group chat send `msg_read` to the sender of each unread message. UI shows "N/M" counter (how many members read) next to the sender's tick.

- [x] Send `msg_read` on opening group chat for all unread messages
- [x] `process_receipt_use_case.processReadReceipt` — verify group messageId is correct
- [x] UI: "N/M" counter in `_StatusTick` for group message
- [x] Test: sender sees read progress as members open chat

---

#### TD-05 · Excessive setState in ChatScreen
**File:** `chat_screen.dart` — 35 setState calls, `_loadMessages()` called 17 times

**Solution (chosen B):** Move `_messages` to Riverpod `StreamProvider` listening to EventBus. ChatScreen uses `ref.watch` instead of manual `_loadMessages()` + setState.

- [ ] Create `messagesStreamProvider(convId)` → `Stream<List<Message>>` from DB + EventBus
- [ ] Move ChatScreen list to `ref.watch(messagesStreamProvider)`
- [ ] Remove `_messages`, `_loadMessages()`, related setState calls
- [ ] Verify scroll-to-bottom, pagination (loadMore) — adapt to StreamProvider

---

### 🟢 P2 — Quality of life (after stabilization)

#### TD-06 · Yggdrasil address verification via QR
Add `yk` field to QR payload → verify Yggdrasil key signature against master key on contact_hello.

#### TD-07 · Notification on contact key change
When new `x25519Pub` or `signingPub` received: show "⚠️ Ivan's security key changed — verify contact". Sticky banner in chat until user confirms.

#### TD-08 · Panic button
Shake gesture via accelerometer → immediate wipe without confirm dialog. Threshold: 3 fast shakes in 1 second.

- [ ] Add `sensors_plus` dependency
- [ ] `ShakeDetectorService` — listens to accelerometer, triggers on 3 shakes / 1 sec
- [ ] Connect to wipe pipeline (same as Duress PIN)
- [ ] Setting in Settings: "Panic gesture" on/off + sensitivity

#### TD-09 · Embed public Yggdrasil peer list
Peers: Moscow, SPB, Ekaterinburg, Novosibirsk, Omsk.
Hardcode in config + periodic update (signed peer list).

---

## Phase 11 — Multi-device (future)

- [ ] Session sync between user's devices
- [ ] Desktop client (Flutter Desktop)
- [ ] Migration to MLS for groups 100+ members

---

## Milestone Summary

| Milestone | Phase | Result |
|---|---|---|
| v0.1 | 0-7 | Centralized relay, E2EE, groups, files |
| v0.2 | 8 | Yggdrasil transport, P2P, receipts, TTL |
| v0.3 | 9 | Duress PIN ✓, panic button, key change notification |
| v1.0 | 10 | Polish, push, voice messages |
| v2.0 | 11 | Multi-device, Desktop |

---

## Principles

1. **Minimal metadata** — server sees only tokens (key hashes) and encrypted blobs, not the social graph
2. **Server never sees content** — only encrypted blobs
3. **Keys only on user's device** — never leave the device
4. **No lookup** — Yggdrasil addresses cached locally, server doesn't know who talks to whom
5. **One APK** — no server configuration for the user
6. **Fail secure** — on crypto error: block, don't bypass
7. **Minimal dependencies** — less code = fewer vulnerabilities
