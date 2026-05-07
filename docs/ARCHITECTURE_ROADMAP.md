# Architecture Roadmap — Clean Architecture / DDD

Goal: eliminate all Clean Architecture violations in HubCore Chat/client.
Dependency rule: UI → Application → Domain ← Infrastructure.
Domain knows nothing outside itself. Infrastructure implements ports from Domain.

Tasks are grouped by topic and ordered from least to most risky.
Within each group — priority top to bottom.

---

## Current Violation Map

```
VIOLATION 1: Application → Services (should be via ports)
  application/use_cases/contacts/send_contact_hello_use_case.dart
    → services/messaging_service.dart

  application/use_cases/messaging/receive_envelope_use_case.dart
    → services/file_service.dart  (only show FileOffer, FileChunk, FileAck)

  application/use_cases/groups/accept_group_invite_use_case.dart
    → services/group_messaging_service.dart

  application/use_cases/identity/rotate_signing_key_use_case.dart
    → services/keystore_service.dart

VIOLATION 2: Network → Application (should be reversed)
  network/message_router.dart
    → application/use_cases/messaging/receive_envelope_use_case.dart
    → services/messaging_service.dart
    → services/notification_service.dart

VIOLATION 3: Services — wrong layer
  services/messaging_service.dart    (crypto + codec) → infrastructure/crypto/
  services/group_messaging_service.dart (sender keys) → infrastructure/crypto/
  services/file_service.dart         (file protocol) → infrastructure/file_transfer/
  services/ttl_service.dart          (business logic) → application/
  services/connectivity_watcher.dart (infra wrapper) → infrastructure/
  services/notification_service.dart (infra wrapper) → infrastructure/
  services/keystore_service.dart     (infra wrapper) → infrastructure/

VIOLATION 4: Network — wrong layer
  network/polling_service.dart → infrastructure/transport/

VIOLATION 5: app_providers.dart — God Object (449 lines, all layers mixed)
  → split into multiple files by responsibility
```

---

## 1. File Moves Without Logic Changes

### ARCH-MOVE-1: services/keystore_service.dart → infrastructure/keystore/ ✅
**Status:** Done
**Complexity:** Low — rename imports only

### ARCH-MOVE-2: services/notification_service.dart → infrastructure/notifications/ ✅
**Status:** Done
**Complexity:** Low — rename imports only

### ARCH-MOVE-3: services/connectivity_watcher.dart → infrastructure/connectivity/ ✅
**Status:** Done
**Complexity:** Low

### ARCH-MOVE-4: network/polling_service.dart → infrastructure/transport/ ✅
**Status:** Done
**Complexity:** Low

### ARCH-MOVE-5: services/ttl_service.dart → application/services/ ✅
**Status:** Done
**Complexity:** Low

---

## 2. Move Types from services/ to domain/

### ARCH-TYPES-1: FileOffer / FileChunk / FileAck → domain/entities/ ✅
**Status:** Done
**Problem:** `receive_envelope_use_case.dart` (application) imports `services/file_service.dart` only for these three types.
**Task:** move `FileOffer`, `FileChunk`, `FileAck` → `domain/entities/file_transfer.dart`

### ARCH-TYPES-2: GroupInvite → domain/entities/ ✅
**Status:** Done
**Problem:** `accept_group_invite_use_case.dart` (application) imports `services/group_messaging_service.dart` only for `GroupInvite`.

---

## 3. MessageRouter Refactoring (Network → Infrastructure)

### ARCH-ROUTER-1: Remove direct import of ReceiveEnvelopeUseCase from MessageRouter ✅
**Status:** Done
**Solution:** pass use case as callback/function on init, don't import the type.
```dart
// message_router.dart — only callback, no use_case import
class MessageRouter {
  final Future<void> Function(IncomingEnvelope) onIncoming;
  MessageRouter({required this.onIncoming, ...});
}
```

### ARCH-ROUTER-2: Remove MessagingService import from MessageRouter ✅
**Status:** Done
**Solution:** MessageRouter works only with raw bytes, delegates decoding via callback.

---

## 4. Use Case Refactoring — Remove services/ Dependencies

### ARCH-UC-1: SendContactHelloUseCase — remove MessagingService import ✅
**Status:** Done

### ARCH-UC-2: RotateSigningKeyUseCase — remove KeystoreService import ✅
**Status:** Done

---

## 5. Move crypto/codec Logic from services/ to infrastructure/

### ARCH-INFRA-1: MessagingService → infrastructure/crypto/ ✅
**Status:** Done
**Complexity:** High — 8 importers, 700+ lines

### ARCH-INFRA-2: GroupMessagingService → infrastructure/crypto/ ✅
**Status:** Done

### ARCH-INFRA-3: FileService → infrastructure/file_transfer/ ✅
**Status:** Done

---

## 6. Split app_providers.dart

### ARCH-PROVIDERS-1: Split app_providers.dart by zone ✅
**Status:** Done
**Task:** split `shared/providers/app_providers.dart` (449 lines) into:
```
shared/providers/
  ├── app_providers.dart        — re-exports + composition root only (≤50 lines)
  ├── crypto_providers.dart     — sodium, identity, crypto/session services
  ├── storage_providers.dart    — storageProvider, lockManager, wipe
  ├── transport_providers.dart  — composite/ygg/reticulum transports, connectivity
  ├── messaging_providers.dart  — messaging, group, file, queue services
  └── router_providers.dart     — messageRouter, receiveEnvelope, ttl, eventbus
```

---

## 7. Deep Refactoring (after all above)

### ARCH-SPLIT-1: Split MessagingService into codec + crypto + handlers ✅
**Status:** Done (partially)

### ARCH-SPLIT-2: Remove duplication between domain entities and DAO entities ✅
**Status:** Done

### ARCH-PORT-1: Add FileTransferPort to domain/ports/ ✅
**Status:** Done

---

## Execution Order

```
Phase 1 — Safe moves (no logic changes):
  ARCH-MOVE-1   keystore   → infrastructure/keystore/
  ARCH-MOVE-2   notifications → infrastructure/notifications/
  ARCH-MOVE-3   connectivity → infrastructure/connectivity/
  ARCH-MOVE-4   polling    → infrastructure/transport/
  ARCH-TYPES-1  FileOffer/Chunk/Ack → domain/entities/
  ARCH-TYPES-2  GroupInvite → domain/entities/

Phase 2 — MessageRouter (isolate from application):
  ARCH-ROUTER-1  remove ReceiveEnvelopeUseCase import
  ARCH-ROUTER-2  remove MessagingService import

Phase 3 — Infrastructure (move services):
  ARCH-INFRA-1  MessagingService → infrastructure/crypto/
  ARCH-INFRA-2  GroupMessagingService → infrastructure/crypto/
  ARCH-INFRA-3  FileService → infrastructure/file_transfer/
  ARCH-MOVE-5   ttl_service → application/services/
  ARCH-UC-1     SendContactHelloUseCase: remove MessagingService import

Phase 4 — Provider structure:
  ARCH-PROVIDERS-1  split app_providers.dart

Phase 5 — Deep refactoring (low priority):
  ARCH-SPLIT-1   split MessagingService
  ARCH-SPLIT-2   unify domain/DAO entities
  ARCH-PORT-1    FileTransferPort in domain/ports/
```

---

## Summary Table

| ID | Task | Phase | Complexity | Status |
|----|------|-------|------------|--------|
| ARCH-MOVE-1 | keystore → infrastructure/ | 1 | Low | ✅ Done |
| ARCH-MOVE-2 | notification → infrastructure/ | 1 | Low | ✅ Done |
| ARCH-MOVE-3 | connectivity → infrastructure/ | 1 | Low | ✅ Done |
| ARCH-MOVE-4 | polling → infrastructure/transport/ | 1 | Low | ✅ Done |
| ARCH-TYPES-1 | FileOffer/Chunk/Ack → domain/ | 1 | Low | ✅ Done |
| ARCH-TYPES-2 | GroupInvite → domain/ | 1 | Low | ✅ Done |
| ARCH-UC-2 | RotateSigningKey: keystore path | 1 | Low | ✅ Done |
| ARCH-ROUTER-1 | MessageRouter: remove use case import | 2 | Medium | ✅ Done |
| ARCH-ROUTER-2 | MessageRouter: remove MessagingService | 2 | Medium | ✅ Done |
| ARCH-INFRA-1 | MessagingService → infrastructure/ | 3 | High | ✅ Done |
| ARCH-INFRA-2 | GroupMessagingService → infrastructure/ | 3 | Medium | ✅ Done |
| ARCH-INFRA-3 | FileService → infrastructure/ | 3 | Medium | ✅ Done |
| ARCH-MOVE-5 | ttl_service → application/ | 3 | Low | ✅ Done |
| ARCH-UC-1 | SendContactHelloUseCase: remove MessagingService | 3 | Medium | ✅ Done |
| ARCH-PROVIDERS-1 | Split app_providers.dart | 4 | Medium | ✅ Done |
| ARCH-SPLIT-1 | Split MessagingService internally | 5 | High | ✅ Done (partial) |
| ARCH-SPLIT-2 | Unify domain/DAO entities | 5 | High | ✅ Done |
| ARCH-PORT-1 | FileTransferPort in domain/ports/ | 5 | Medium | ✅ Done |
