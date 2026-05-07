# HubCore Chat Stability — Fix Roadmap

## Principles

All fixes follow:
- **Clean Architecture**: domain → application → infrastructure → features
- **DDD**: use case per business operation, aggregates protected
- **Modular monolith**: each fix — 1-2 classes, no cross dependencies

---

## Phase 1: Infrastructure (no UI changes)

### 1.1 Cryptographically secure random for group ID

**Problem**: `_randomId()` uses `DateTime.microsecond & 0xFF` — all 16 bytes are identical, predictable, collisions possible.

**Solution**: Replace with `_sodium.randombytes.buf(16)`.

**Layer**: Infrastructure (`group_messaging_service.dart:346`)

```dart
// Before:
static String _randomId() {
  final bytes = Uint8List(16)
    ..setRange(0, 16, List.generate(16, (_) =>
        DateTime.now().microsecondsSinceEpoch & 0xFF));
  return base58.encode(bytes);
}

// After:
String _randomId() {
  return base58.encode(_sodium.randombytes.buf(16));
}
```

---

### 1.2 Atomic wipe (DB + keystore)

**Problem**: `_wipe()` closes DB before deleting key. If `_secure.deleteAll()` fails — user is locked out with accessible DB.

**Solution**: New `WipeTransaction` — delete keys first (more critical), then close/delete DB.

**Layer**: Infrastructure (`storage/wipe_transaction.dart`)

```dart
class WipeTransaction {
  Future<bool> wipeAll(void Function() onWipe) async {
    try {
      await _secure.deleteAll();     // 1. Keys — most important
      await _storage.close();        // 2. Close DB
      await _shredDbFile();          // 3. Overwrite file with random and delete
      onWipe();
      return true;
    } catch (e) {
      // If keys deleted but DB not closed — still safe
      // If keys NOT deleted — critical error
      ...
    }
  }
}
```

**Files**: `storage/wipe_transaction.dart` (new), `storage/lock_manager.dart` (refactoring)

---

### 1.3 message_id for group messages

**Problem**: `sendGroupMessage()` doesn't generate `messageId`. Delivery receipts for group messages are impossible.

**Solution**: Generate `messageId` like for DM, include in `_GroupPayload` wire format.

**Layer**: Infrastructure (`group_messaging_service.dart`)

**Changes**:
1. `_GroupPayload` — add `messageId` field
2. `sendGroupMessage()` — generate mid, save in Message and payload
3. `receiveGroupEnvelope()` — extract mid from payload, save in Message

---

### 1.4 message_receipts on direct sendMessage

**Problem**: `MessagingService.sendMessage()` saves Message but does NOT create `message_receipts` record. Only `QueueService.sendOrQueue()` creates receipts.

**Solution**: In `sendMessage()` always create receipt record.

**Layer**: Infrastructure (`messaging_service.dart`)

```dart
// After Message insert:
await _storage.messageReceipts.markSent(
  mid, contactMasterPub58, 'pending', now);
```

---

### 1.5 Assertions for senderEphPub

**Problem**: `senderEphPub` must be sent only at `counter == 0` or until `session_confirmed`. No protection against regression.

**Solution**: Add assert on send + validation on receive.

**Layer**: Infrastructure (`messaging_service.dart`, `receive_envelope_use_case.dart`)

---

## Phase 2: Application Layer (use cases)

### 2.1 ProcessReceiptUseCase — single receipt handler

**Problem**: Two paths for handling `msg_delivered`:
- `ReceiveEnvelopeUseCase` updates `messages.status`
- Provider callback updates `message_receipts`
An error in one causes desync.

**Solution**: One use case atomically updates both:

**Layer**: Application (`application/use_cases/messaging/process_receipt_use_case.dart`)

```dart
class ProcessReceiptUseCase {
  Future<void> processDeliveryReceipt({
    required String messageId,
    required String senderPub,
    required int deliveredAt,
  }) async {
    // Atomic: messages.status + message_receipts
    final msg = await _messages.findByMessageId(messageId);
    if (msg?.id != null && msg!.status == MessageStatus.sent) {
      await _messages.updateStatus(msg.id!, MessageStatus.delivered);
      _bus.emit(MessageStatusUpdatedEvent(...));
    }
    await _receipts.markDelivered(messageId, senderPub, deliveredAt);
  }
}
```

**Remove**: `onMarkDelivered`/`onMarkRead` callbacks from `ReceiveEnvelopeUseCase` — replace with `ProcessReceiptUseCase`.

---

### 2.2 Delete TtlService, keep SweepExpiredUseCase

**Problem**: Both `TtlService` and `SweepExpiredUseCase` do the same thing — sweep expired messages. Duplication.

**Solution**:
1. Delete `application/services/ttl_service.dart`
2. Add timer to `SweepExpiredUseCase` (start/stop/dispose)
3. Delete `ttlServiceProvider`, create `sweepExpiredUseCaseProvider`

---

### 2.3 AcceptGroupInviteUseCase — chain state sync

**Problem**: After accepting invite the member creates their chain, but other members (except admin) don't receive their chain state. Their messages can't be decrypted.

**Solution**: After accepting invite — send `group_chain_sync_request` to each member. On receiving request — send own chain state back.

**New system message type**:
```json
{"type": "group_chain_sync_request", "group_id": "...", "requesting_pub": "..."}
```

**Handler in `ReceiveEnvelopeUseCase`**:
1. Receive request
2. Find own chain for this group
3. Send `buildInvitePayload()` via NaCl box back

---

### 2.4 SendReceiptUseCase — reliable receipts

**Problem**: Delivery receipts sent fire-and-forget in `Future()` without error handling. If app is killed — receipt is lost.

**Solution**: Use case with explicit return status.

**Layer**: Application (`application/use_cases/messaging/send_receipt_use_case.dart`)

```dart
class SendReceiptUseCase {
  Future<bool> sendDeliveryReceipt(String recipientPub, String mid) async {
    try {
      final env = await _messaging.encryptBox(
        recipientPub,
        Uint8List.fromList(utf8.encode(
          jsonEncode({'type': 'msg_delivered', 'mid': mid}))));
      final result = await _transport.sendEnvelope(env);
      return result.success;
    } catch (e) {
      AppLogger.w('[SendReceipt] failed: $e');
      return false;
    }
  }
}
```

---

## Phase 3: Critical Concurrency and Security

### 3.1 AppLockUseCase — protection against null lockManager

**Problem**: If `lockManager == null` on background, app does NOT lock. DB stays open.

**Solution**: `AppLockUseCase` with fail-safe: if lockManager is null — force close app.

**Layer**: Application (`application/use_cases/identity/app_lock_use_case.dart`)

```dart
class AppLockUseCase {
  Future<void> lock() async {
    if (_lockManager == null) {
      await _onLockFailed?.call(); // exit app
      throw StateError('Lock manager not initialized');
    }
    await _lockManager.lock();
  }
}
```

---

### 3.2 EnsureSessionUseCase — mutex on session init

**Problem**: Race condition — two parallel `_send()` calls both see `!hasSession()`, both call `initOutbound`, creating duplicate/corruption.

**Solution**: Per-contact async mutex.

**Layer**: Application (`application/use_cases/messaging/ensure_session_use_case.dart`)

```dart
class EnsureSessionUseCase {
  final _locks = <String, Future<void>>{};

  Future<void> ensureSession(String contactPub, Uint8List peerIdPub) async {
    if (_locks.containsKey(contactPub)) {
      await _locks[contactPub]!;
      return;
    }
    if (await _sessionManager.hasSession(contactPub)) return;

    final future = _doInit(contactPub, peerIdPub);
    _locks[contactPub] = future;
    try { await future; } finally { _locks.remove(contactPub); }
  }
}
```

---

## Phase 4: Features

### 4.1 SendFileUseCase — null-safe file sending

**Problem**: `fileServiceProvider` can return null. Between check and use — async gap, possible crash.

**Solution**: `SendFileUseCase` with `isReady` check and fail-fast.

---

## Implementation Order

```
Phase 1 (infrastructure):
  1.1  _randomId() → sodium.randombytes
  1.2  WipeTransaction (atomic wipe)
  1.3  messageId for group messages
  1.4  message_receipts on sendMessage
  1.5  senderEphPub assertions

Phase 2 (application):
  2.1  ProcessReceiptUseCase
  2.2  Delete TtlService → SweepExpiredUseCase
  2.3  AcceptGroupInviteUseCase + chain sync
  2.4  SendReceiptUseCase

Phase 3 (security):
  3.1  AppLockUseCase
  3.2  EnsureSessionUseCase

Phase 4 (features):
  4.1  SendFileUseCase
```

Phases 1-2 — foundation, can be parallelized.
Phase 3 — depends on phase 1 (WipeTransaction).
Phase 4 — depends on phase 3 (EnsureSessionUseCase).

---

## Fix Dependencies

```
1.2 WipeTransaction ← 3.1 AppLockUseCase
3.2 EnsureSessionUseCase ← 4.1 SendFileUseCase
2.1 ProcessReceiptUseCase ← 2.4 SendReceiptUseCase (optional)
All others — independent
```

---

## New Files (plan)

```
application/use_cases/messaging/
  ensure_session_use_case.dart      (3.2)
  process_receipt_use_case.dart     (2.1)
  send_receipt_use_case.dart        (2.4)
  send_file_use_case.dart           (4.1)

application/use_cases/identity/
  app_lock_use_case.dart            (3.1)

storage/
  wipe_transaction.dart             (1.2)
```

## Deleted Files (plan)

```
application/services/ttl_service.dart  (2.2 — replaced by SweepExpiredUseCase)
infrastructure/crypto/double_ratchet_session_service.dart  (replaced by SessionManager)
```
