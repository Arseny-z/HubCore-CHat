# File Transfer & Message Status — Roadmap

## Principles

- **Single module** for files: DM and groups served by the same code
- **Clean Architecture**: domain/ports → application/use_cases → infrastructure
- **DDD**: FileTransfer as aggregate, Receipt as value object
- **Modular monolith**: file module does not depend on specific transport/crypto

---

## Current State

### What works (DM)
- File sending: XChaCha20-Poly1305, 8KB chunks, 3x retry
- Receiving: pre-allocate + random-access write, ACK debounce
- FileOffer → FileChunks → FileAck protocol
- `message_receipts` table: per-recipient tracking
- Statuses: queued → sent → delivered → read
- Transport protocol recorded in receipt
- UI: ticks ✓/✓✓/blue ✓✓, tap → modal with details

### What doesn't work / not implemented
- Files in groups
- Arbitrary file selection (only photos from gallery)
- File message doesn't appear in chat immediately
- No progress indicator on bubble
- Group message statuses not tracked
- Transport protocol not shown on status tap
- No size limit for groups

---

## Architecture: Single File Module

```
domain/
  entities/
    file_transfer.dart      — FileOffer, FileChunk, FileAck
    message.dart            — ContentType: text|image|video|audio|file|system
  ports/
    file_transfer_port.dart — send/receive abstraction

application/
  use_cases/
    files/
      send_file_use_case.dart        — SINGLE use case for DM and groups
      receive_file_use_case.dart     — incoming file handling
      file_progress_notifier.dart    — progress stream for UI

infrastructure/
  file_transfer/
    file_service.dart       — chunk engine
    file_crypto.dart        — file encryption (extracted from file_service)
    file_chunk_sender.dart  — chunk sending via transport
    file_chunk_receiver.dart — chunk receiving

features/
  chat/
    widgets/
      file_message_bubble.dart  — file bubble (preview/icon/progress)
      file_picker_sheet.dart    — bottom sheet: Photo/Video, Document
```

### Key Decision: DM vs Group

| | DM | Group |
|---|---|---|
| FileOffer | DR-encrypted, 1 recipient | NaCl box, N recipients |
| FileChunks | Raw envelope, 1 recipient | Raw envelope, N recipients (fan-out) |
| FileAck | 1 ACK | N ACKs (per-member) |
| Max size | 200 MB | **2 MB** |
| Body encryption | XChaCha20-Poly1305 (file key) | Same (file key shared for all) |

Fan-out: the same encrypted file is sent to each member.
All recipients have the same file key (from FileOffer).

---

## Phase 1: Group Message Statuses

### 1.1 Receipt tracking for group messages

**Current:** `message_receipts` already supports per-recipient records, but group messages don't create receipts.

**Solution:**
1. On `sendGroupMessage()` → create `message_receipts` record for each recipient
2. Group message recipient → send `msg_delivered` receipt back to sender
3. On opening group chat → send `msg_read` receipt

**Wire format** (unchanged — use existing):
```json
{"type": "msg_delivered", "mid": "<hex-8>"}
{"type": "msg_read", "mid": "<hex-8>"}
```

**Files:**
- `group_messaging_service.dart` — create receipt records on send
- `receive_envelope_use_case.dart` — send delivery receipt on group_msg receipt
- `group_chat_screen.dart` — send read receipt on view

### 1.2 Status UI in groups

**Bubble display:**
- ✓ (grey) — sent
- ✓✓ (grey) — at least 1 delivered (N/M)
- ✓✓ (blue) — at least 1 read

**Tap on status → details:**
```
┌─────────────────────────────┐
│  Delivery Status            │
├─────────────────────────────┤
│  ✓✓ Alice  · yggdrasil     │
│     delivered 10:15         │
│  ✓  Bob    · —              │
│     sent 10:14              │
│  ✓✓ Charlie · yggdrasil    │
│     read 10:16 (blue)       │
└─────────────────────────────┘
```

Shows:
- Contact name/alias
- Status: sent/delivered/read
- Transport protocol (yggdrasil, reticulum, meshcore)
- Time of each transition

**Files:**
- `chat_widgets.dart` — `_DeliveryDetailsSheet`
- `group_chat_screen.dart` — load `deliveryCounts`, connect `onDeliveryTap`

### 1.3 Transport protocol in delivery details

**Current:** `MessageReceipt.transport` is recorded but not shown in delivery details UI.

**Solution:** In the delivery details modal show `receipt.transport` next to recipient name.

**Files:** `chat_widgets.dart` — `_DeliveryDetailsSheet`

---

## Phase 2: Single File Use Case

### 2.1 SendFileUseCase (refactoring)

**Current:** `FileService.sendFile()` tied to DM (one recipient).

**New use case:**
```dart
class SendFileUseCase {
  /// Send file to DM or group.
  /// [recipients] — recipient list (1 for DM, N for group).
  Future<void> execute({
    required File sourceFile,
    required String conversationId,
    required bool isGroup,
    required List<Recipient> recipients,
    required String myPub58,
    String? mimeType,
    int? ttlSeconds,
    void Function(double)? onProgress,
  }) async {
    // 1. Check size
    final size = await sourceFile.length();
    if (isGroup && size > _maxGroupFileSize) {
      throw FileSizeExceededException(size, _maxGroupFileSize);
    }

    // 2. Encrypt file (once, one key)
    final encrypted = await _fileCrypto.encrypt(sourceFile);

    // 3. Create Message + FileRecord in DB (status=queued)
    final msg = await _createFileMessage(conversationId, isGroup, ...);

    // 4. Send FileOffer to each recipient
    for (final r in recipients) {
      await _sendOffer(r, encrypted.offer);
      await _createReceipt(msg.messageId, r.pub);
    }

    // 5. Send chunks to each recipient (fan-out)
    await _sendChunks(recipients, encrypted.chunks, onProgress);

    // 6. Collect ACKs
    await _collectAcks(recipients, encrypted.transferId);
  }

  static const _maxGroupFileSize = 2 * 1024 * 1024; // 2 MB
}
```

**Layer:** Application (`application/use_cases/files/send_file_use_case.dart`)

### 2.2 ReceiveFileUseCase

```dart
class ReceiveFileUseCase {
  /// Handle incoming FileOffer.
  Future<void> handleOffer(String senderPub, FileOffer offer);

  /// Handle incoming FileChunk.
  Future<void> handleChunk(String senderPub, FileChunk chunk);

  /// Handle FileAck.
  Future<void> handleAck(FileAck ack);
}
```

### 2.3 FileCryptoService

Extract file encryption/decryption from `FileService`:

```dart
class FileCryptoService {
  /// Encrypt file, return key + nonce + encrypted chunks.
  Future<EncryptedFile> encrypt(File source, {int chunkSize = 8192});

  /// Decrypt chunks, write result.
  Future<File> decrypt(List<Uint8List> chunks, Uint8List key, Uint8List nonce);
}
```

**Layer:** Infrastructure (`infrastructure/file_transfer/file_crypto.dart`)

---

## Phase 3: File UI

### 3.1 FilePickerSheet — file selection

**Bottom sheet instead of ImagePicker:**
```
┌─────────────────────────────┐
│  📷  Photo or Video         │
│  📄  Document               │
│  🎵  Audio                  │
└─────────────────────────────┘
```

**Group limit:** check size before sending, show:
```
"File too large (5.2 MB). Max for group: 2 MB"
```

**Files:** `features/chat/widgets/file_picker_sheet.dart` (new)

### 3.2 FileMessageBubble

**Photo/Video:** thumbnail + size
**Document:** format icon + file name + size
**Audio:** icon + duration + player (future)

**Bubble states:**
```
[Sending]    — progress indicator (0-100%), file name
[Sent]       — preview/icon, ✓
[Delivered]  — preview/icon, ✓✓
[Read]       — preview/icon, blue ✓✓
[Downloading] — progress indicator (recipient)
[Error]      — red icon, "Retry"
```

### 3.3 Send/receive progress

**Sender:**
- Message appears in chat immediately (status=queued)
- Progress bar on bubble (0→100%)
- On completion: normal bubble with preview

**Recipient:**
- Message appears on FileOffer receipt (before download starts)
- Download progress on bubble
- On completion: file available to view

**Mechanism:** `FileProgressNotifier` — Riverpod StateNotifier:
```dart
final fileProgressProvider = StateNotifierProvider.family<
    FileProgressNotifier, double?, String>(
  (ref, transferId) => FileProgressNotifier(),
);
```

UI subscribes: `ref.watch(fileProgressProvider(transferId))`

### 3.4 Attachment in group_chat_screen

Add attachment button to `group_chat_screen.dart` — identical to DM chat, but with 2 MB size check.

---

## Phase 4: Integration

### 4.1 Unified attachment button

Shared `AttachButton` widget used in both `chat_screen.dart` and `group_chat_screen.dart`:

```dart
class AttachButton extends StatelessWidget {
  final bool isGroup;
  final Function(File file, String? mimeType) onFileSelected;
  // Shows FilePickerSheet, checks size for groups
}
```

### 4.2 File format support

| Format | ContentType | Preview | Tap action |
|--------|-------------|---------|------------|
| jpg/png/gif/webp | image | thumbnail | Full-screen view |
| mp4/mov/avi | video | frame + ▶ | Video player |
| mp3/ogg/wav | audio | 🎵 + duration | Playback |
| pdf | file | 📄 PDF | System viewer |
| doc/xls/zip/etc | file | 📎 + name + size | "Open with..." |

MIME type determined by extension + magic bytes (first 4 bytes).

---

## Implementation Order

```
Phase 1 (statuses):
  1.1  Receipt tracking for group messages
  1.2  Status UI in groups (✓/✓✓/blue, N/M)
  1.3  Transport protocol in delivery details

Phase 2 (single module):
  2.1  SendFileUseCase (DM + groups)
  2.2  ReceiveFileUseCase
  2.3  FileCryptoService (extract from FileService)

Phase 3 (UI):
  3.1  FilePickerSheet (photo/video/document/audio)
  3.2  FileMessageBubble (preview/icon/progress)
  3.3  FileProgressNotifier (progress stream)
  3.4  Attachment button in group_chat_screen

Phase 4 (integration):
  4.1  Unified AttachButton
  4.2  Format support (MIME detection)
```

## New Files (plan)

```
application/use_cases/files/
  send_file_use_case.dart
  receive_file_use_case.dart
  file_progress_notifier.dart

infrastructure/file_transfer/
  file_crypto.dart

features/chat/widgets/
  file_message_bubble.dart
  file_picker_sheet.dart
  attach_button.dart
```

## New Dependencies

```yaml
file_picker: ^8.0.0   # arbitrary file selection
mime: ^1.0.0           # MIME type detection
```
