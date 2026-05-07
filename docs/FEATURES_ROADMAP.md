# Features Roadmap

## Priority 1 — Core Messenger Features

### 1. Unread message counter
**What:** Badge with unread count on contact/group row in chat list.
**Why:** Without it there's no way to know if there are new messages without opening each chat.
**How:**
- `forConversation` returns messages, count where `status != read AND senderPub != myPub`
- Add badge to `ConversationListItem`
- Update via `MessageReceivedEvent`

**Files:** `main_screen.dart`, `messages_dao.dart`
**Complexity:** Low

---

### 2. Reply to message
**What:** Long tap → "Reply" → quote preview above input field → message with quote.
**Why:** Basic feature of any messenger, hard to hold a conversation without it.
**How:**
- Schema: add `reply_to_id INTEGER REFERENCES messages(id)` to messages table (migration)
- Protocol: add `"rid": replyId` to `DmPayload` (optional field)
- UI: show quote above bubble if `reply_to_id != null`
- `_ReplyPreview` widget above `ChatInputBar`
- Long tap → "Reply" option in bottom sheet

**Files:** `database.dart`, `dm_payload_codec.dart`, `chat_widgets.dart`, `chat_screen.dart`, `group_chat_screen.dart`
**Complexity:** Medium

---

### 3. Message history pagination
**What:** Load last N messages, load more on scroll up.
**Why:** Currently loads entire history — lags and OOM on large conversations.
**How:**
- `messages_dao.forConversation(id, limit: 50, beforeId: int?)` — LIMIT/OFFSET by sentAt
- `ScrollController.addListener` — load previous page when top is reached
- Keep `_hasMore` flag and `_oldestLoadedId`
- Works for DM and groups

**Files:** `messages_dao.dart`, `chat_screen.dart`, `group_chat_screen.dart`
**Complexity:** Medium

---

### 4. Group management
**What:** Add/remove member after creation, rename group.
**Why:** Currently group is immutable after creation.
**How:**
- **Add member:** send `group_invite` to new contact with current chain key state
- **Remove member:** send `group_kick` to others, rotate chain key (otherwise kicked member can read future messages)
- **Rename:** `group_rename` message to all members
- UI: "Manage" button in members drawer → list with delete option, "Add" button

**Files:** `group_messaging_service.dart`, `group_chat_screen.dart`, new `group_settings_screen.dart`
**Complexity:** High (key rotation on kick)

---

### 5. Message search
**What:** Search message text in local DB. Fast, no network.
**Why:** Can't find old messages without manual scrolling.
**How:**
- `messages_dao.search(query, conversationId?)` — `WHERE body LIKE '%query%'`
- Global search (all chats) or within one chat
- UI: magnifier button in chat AppBar / separate search screen in `main_screen`
- Results show context (chat name, date, message excerpt)
- Tap on result → opens chat and scrolls to message

**Files:** `messages_dao.dart`, `chat_screen.dart`, `main_screen.dart`, new `search_screen.dart`
**Complexity:** Medium

---

## Priority 2 — Convenience

### 6. Forward messages
**What:** Long tap → "Forward" → select contact/group → send.
**Complexity:** Low

### 7. Delete message for everyone (text)
**What:** Already implemented for files via `ttl_delete`. Needed for text messages.
**Complexity:** Low (infrastructure exists)

### 8. Mute conversation
**What:** Disable notifications for a specific chat.
**Schema:** `contacts.muted INTEGER DEFAULT 0`
**Complexity:** Low

### 9. Typing indicator
**What:** "typing..." when contact is entering text.
**Protocol:** Separate NaCl box `{"type":"typing","ts":...}` — not saved to DB.
**Complexity:** Medium

### 10. Take photo from chat
**What:** Camera button next to attachment for capturing and sending photos.
**Complexity:** Low (file_picker supports camera)

### 11. Media gallery
**What:** Screen with all photos/files from a conversation.
**Complexity:** Medium

---

## Priority 3 — Advanced Features

### 12. Pin conversation
**Schema:** `contacts.pinned INTEGER DEFAULT 0`
**Complexity:** Low

### 13. Message reactions
**Protocol:** `{"type":"reaction","mid":"...","emoji":"👍"}`
**Schema:** New table `message_reactions`
**Complexity:** Medium

### 14. Online/offline status
**What:** Show "online" if contact sent `contact_hello` recently.
**Schema:** `contacts.last_seen` already exists
**Complexity:** Low

### 15. Edit message
**Protocol:** `{"type":"edit","mid":"...","text":"new text"}`
**Schema:** `messages.edited_at`
**Complexity:** Medium

---

## Priority 4 — Transport (hardware dependent)

### Phase 4: contact_hello multi-protocol
Pass Reticulum/Meshcore addresses in hello. Relevant when at least one is available.

### Phase 5: ConnectivityWatcher multi-transport
Watch all transports, flush on any channel becoming available.

### Phase 6: Reticulum
Transport implementation. Requires RNS daemon.

### Phase 7: Meshcore
BLE/USB to Meshcore node.

---

## Technical Debt

| # | Task |
|---|------|
| TD-1 | PIN hashing via Argon2id instead of BLAKE2b |
| TD-2 | FLAG_SECURE for release build |
| TD-3 | Release keystore + signing |
| TD-4 | Remove diagnostic print logs from release |
| TD-5 | canReach() with real ping instead of optimistic |
| TD-6 | HelloUseCase — 10 attempts too many, need backoff |

---

## Implementation Order

```
P1.1 Unread counter      ← low complexity, high impact
P1.2 Reply               ← basic feature
P1.3 Pagination          ← stability
P1.4 Group management    ← high complexity, do separately
P1.5 Search              ← after pagination (related)

P2.x Convenience — as ready
P3.x Advanced — after P2
P4.x Transport — when hardware available
```
