# Contacts & Privacy Roadmap

**Goal:** Separate contacts from chats. Let users communicate with strangers without adding them
to contacts. Give full control over who can reach them.

**Motivation:** A shop owner wants to chat with anyone who writes, add regulars to contacts,
and block bad actors — all without forcing every stranger into the contacts list.

---

## User-Facing Model

### Three relationship states

```
[stranger writes] → STRANGER (chat only, not in contacts)
                        ├─ [user adds]    → CONTACT
                        └─ [user blocks]  → BLOCKED

CONTACT  → [block]   → BLOCKED
BLOCKED  → [unblock] → CONTACT
```

| State | ContactsTab | ChatsScreen | Can write to me | I can write |
|---|---|---|---|---|
| `stranger` | ❌ | ✅ "New conversations" section | ✅ | ✅ |
| `contact` | ✅ | ✅ main section | ✅ | ✅ |
| `blocked` | ❌ | ❌ | ❌ silent drop | ❌ |

### Privacy setting (Settings screen)

```
Who can start a conversation with me:
  ● Everyone              ← default (good for shops, open profiles)
  ○ My contacts only      ← private mode
  ○ Nobody                ← full silence
```

- **Everyone**: strangers create a `stranger` chat, appear in "New conversations"
- **Contacts only**: `contact_hello` from strangers is silently dropped, no chat created
- **Nobody**: all incoming from non-contacts dropped silently

---

## Implementation Plan

### Step 1 — Database migration (0.5 days)

**File:** `client/lib/storage/database.dart` — migration v22

```sql
ALTER TABLE contacts ADD COLUMN relationship TEXT NOT NULL DEFAULT 'contact';
-- Values: 'contact' | 'stranger' | 'blocked'

-- Migrate existing rows: all current contacts stay as 'contact'
UPDATE contacts SET relationship = 'contact';

CREATE INDEX IF NOT EXISTS idx_contacts_relationship ON contacts(relationship);
```

Also add settings key in migration:
```sql
INSERT OR IGNORE INTO settings(key, value) VALUES ('incoming_contacts_policy', 'all');
-- Values: 'all' | 'contacts_only' | 'nobody'
```

---

### Step 2 — DAO layer (0.5 days)

**File:** `client/lib/storage/dao/contacts_dao.dart`

New / changed methods:

```dart
// Existing all() — keep but add optional relationship filter
Future<List<Contact>> all({String? relationship});

// New
Future<List<Contact>> strangers();   // relationship = 'stranger'
Future<List<Contact>> blocked();     // relationship = 'blocked'

Future<void> setRelationship(String masterPub, String relationship);
Future<String?> getRelationship(String masterPub); // returns 'contact'|'stranger'|'blocked'|null
```

**File:** `client/lib/domain/entities/contact.dart`

Add field:
```dart
final String relationship; // 'contact' | 'stranger' | 'blocked'

bool get isContact  => relationship == 'contact';
bool get isStranger => relationship == 'stranger';
bool get isBlocked  => relationship == 'blocked';
```

---

### Step 3 — Incoming message policy (1 day)

**File:** `client/lib/infrastructure/crypto/messaging_service.dart`

Replace auto-add logic in `receiveEnvelope()` (lines 290–300):

```dart
var contact = await _storage.contacts.findByMasterPub(senderPub);
if (contact == null) {
  final policy = await _storage.settings.get('incoming_contacts_policy') ?? 'all';

  if (policy == 'nobody' || policy == 'contacts_only') {
    AppLogger.d('Msg', 'incoming from stranger dropped: policy=$policy');
    return null; // silent drop
  }

  // policy == 'all': create as stranger
  await _storage.contacts.insert(Contact(
    masterPub:    senderPub,
    signingPub:   senderPub,
    alias:        senderPub.substring(0, 8),
    addedAt:      DateTime.now().millisecondsSinceEpoch ~/ 1000,
    relationship: 'stranger',          // ← key change
  ));
  contact = await _storage.contacts.findByMasterPub(senderPub);
  if (contact == null) return null;
}

// Blocked: silent drop regardless of policy
if (contact.isBlocked) {
  AppLogger.d('Msg', 'incoming from blocked contact ${senderPub.substring(0,8)}… dropped');
  return null;
}
```

Also update `_handleContactHello()`: skip key update and reply for blocked contacts.

Notification behaviour for strangers:
- No sound / no vibration (use a silent notification channel)
- Badge on "New conversations" counter in ChatsScreen

---

### Step 4 — ChatsScreen: "New conversations" section (1.5 days)

**File:** `client/lib/features/main/chats_screen.dart`

Split the chat list into two groups:

```dart
// Load
final contacts  = await storage.contacts.all(relationship: 'contact');
final strangers = await storage.contacts.strangers();
final groups    = await storage.groups.allGroups();

// Build items
final mainItems     = _buildItems(contacts, groups);   // sorted by lastMessage
final pendingItems  = _buildItems(strangers, []);       // sorted by lastMessage
```

UI structure:
```
ListView:
  ├─ [main chat rows — contacts + groups]
  │
  └─ if pendingItems.isNotEmpty:
       ├─ SectionHeader("New conversations (N)")  ← collapsible
       └─ [stranger chat rows]
```

Stranger row visual: grey avatar placeholder `[?]`, no notification badge sound.

---

### Step 5 — Stranger banner in ChatScreen (1 day)

**File:** `client/lib/features/chat/chat_screen.dart`

Show a banner at the top when `contact.isStranger`:

```dart
if (_contact?.isStranger == true)
  _StrangerBanner(
    onAdd:   _addToContacts,
    onBlock: _blockContact,
  )
```

**`_StrangerBanner` widget:**
```
┌─────────────────────────────────────────┐
│ ⚠  Unknown contact                      │
│    [+ Add to contacts]  [🚫 Block]      │
└─────────────────────────────────────────┘
```

Actions:
```dart
Future<void> _addToContacts() async {
  await storage.contacts.setRelationship(_contact!.masterPub, 'contact');
  setState(() => _contact = _contact!.copyWith(relationship: 'contact'));
}

Future<void> _blockContact() async {
  await _doBlock(_contact!.masterPub); // see Step 6
  if (mounted) context.pop();
}
```

---

### Step 6 — Block / unblock in ContactProfileScreen (1 day)

**File:** `client/lib/features/contacts/contact_profile_screen.dart`

Add block button in the danger zone section:

```dart
// If not blocked: show red "Block" button
// If blocked: show "Unblock" button + "Delete" button
```

**Block flow (`_doBlock`):**
1. Show confirmation dialog: "Block this contact? They won't be able to send you messages."
   - Option: "Also delete message history" (checkbox, default off)
2. On confirm:
   ```dart
   await storage.contacts.setRelationship(masterPub, 'blocked');
   await storage.sessions.deleteForContact(contactId); // wipe DR session
   if (deleteHistory) await storage.messages.deleteConversation(masterPub);
   eventBus.emit(ContactUpdatedEvent(masterPub: masterPub));
   ```
3. Navigate back

**Unblock flow:**
```dart
await storage.contacts.setRelationship(masterPub, 'contact');
eventBus.emit(ContactUpdatedEvent(masterPub: masterPub));
```

---

### Step 7 — Privacy settings UI (0.5 days)

**File:** `client/lib/features/settings/settings_screen.dart`

Add new section "Privacy":

```
Privacy
─────────────────────────────
Who can message me
  ● Everyone
  ○ My contacts only
  ○ Nobody
```

Saves to `storage.settings.set('incoming_contacts_policy', value)`.

---

### Step 8 — Blocked contacts list in Settings (0.5 days)

**File:** `client/lib/features/settings/settings_screen.dart` or new screen

"Blocked contacts" row → opens list screen:

```
Blocked contacts
─────────────────────────
  [avatar] a1b2c3d4…     [Unblock]
  [avatar] Spam Bot       [Unblock]
─────────────────────────
  (empty state: "No blocked contacts")
```

Each "Unblock" sets `relationship = 'contact'`.

---

## Files Changed

| File | Change |
|---|---|
| `storage/database.dart` | migration v22: `relationship` column + index + policy setting |
| `domain/entities/contact.dart` | add `relationship` field + helpers |
| `storage/dao/contacts_dao.dart` | `strangers()`, `blocked()`, `setRelationship()`, filter in `all()` |
| `infrastructure/crypto/messaging_service.dart` | policy check, create as `stranger`, drop blocked |
| `features/main/chats_screen.dart` | two-section list |
| `features/chat/chat_screen.dart` | stranger banner |
| `features/contacts/contact_profile_screen.dart` | block/unblock UI + wipe flow |
| `features/settings/settings_screen.dart` | privacy section + blocked list |

---

## Effort Estimate

| Step | Days |
|---|---|
| DB migration | 0.5 |
| DAO + entity | 0.5 |
| Incoming policy | 1 |
| ChatsScreen sections | 1.5 |
| Stranger banner in chat | 1 |
| Block/unblock in profile | 1 |
| Privacy settings | 0.5 |
| Blocked list | 0.5 |
| **Total** | **6.5 days** |

---

## What's Out of Scope (v1)

- Reporting / forwarding block to a moderation service (no server)
- Temporary block with auto-expiry
- Block by Yggdrasil address (not just masterPub)
- Export/import block list
