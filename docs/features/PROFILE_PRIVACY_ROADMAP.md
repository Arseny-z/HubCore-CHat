# Profile Privacy Roadmap

**Goal:** Two avatars and two display names — public (visible to everyone) and private
(visible only to contacts). Mirrors Telegram's contact/non-contact avatar model.

**Motivation:** A shop owner wants strangers to see their business name and logo, but
only show their personal photo and full name to people they've added as contacts.

---

## User-Facing Model

| | Public profile | Contacts profile |
|---|---|---|
| **Who sees it** | Anyone who messages you (strangers) | Only people in your contacts list |
| **Avatar** | Public avatar (e.g. logo, placeholder) | Full personal photo |
| **Name** | Public name (e.g. "Coffee Shop") | Personal name |
| **When sent** | contact_hello to stranger / unknown | contact_hello to contact |

If public avatar is not set → sends no avatar (receiver sees initials).  
If public name is not set → sends no name (receiver sees truncated pubkey).

---

## Implementation Plan

### Step 1 — Storage (0.5 days)

**`lib/shared/services/avatar_service.dart`** — add public avatar:

```dart
static const _myAvatarPublicFile  = 'my_avatar_public.jpg';
static const _myAvatarContactsFile = 'my_avatar.jpg'; // existing

Future<String?> myAvatarBase64({bool publicProfile = false}) async { ... }
Future<void> saveMyAvatar(File file, {bool publicProfile = false}) async { ... }
Future<void> deleteMyAvatar({bool publicProfile = false}) async { ... }
```

**`lib/storage/dao/settings_dao.dart`** — new keys:

```
'my_public_alias'    — public display name (separate from my_alias)
```

`my_alias` (existing) = contacts-only name.  
`my_public_alias` (new) = public name shown to strangers.

---

### Step 2 — Protocol: send correct profile (0.5 days)

**`lib/network/message_router.dart`** — `_broadcastHello` and `_sendHelloReply`:

```dart
// Determine which profile to send based on recipient relationship
Future<String?> _myAvatarFor(String recipientMasterPub) async {
  final contact = await _storage?.contacts.findByMasterPub(recipientMasterPub);
  final isContact = contact?.isContact == true;
  return AvatarService.instance.myAvatarBase64(publicProfile: !isContact);
}

Future<String?> _myNameFor(String recipientMasterPub) async {
  final contact = await _storage?.contacts.findByMasterPub(recipientMasterPub);
  final isContact = contact?.isContact == true;
  if (isContact) return _storage?.settings.get('my_alias');
  return _storage?.settings.get('my_public_alias'); // may be null
}
```

**`lib/application/use_cases/contacts/send_contact_hello_use_case.dart`** — pass
`publicProfile` flag based on recipient relationship.

---

### Step 3 — Auto-hello to stranger on first message (0.5 days)

**`lib/application/use_cases/messaging/receive_envelope_use_case.dart`**:

When a new `stranger` contact is created (first message received), immediately send
a `contact_hello` back with the **public** profile — so the stranger sees our name/avatar.

```dart
if (contact == null) {
  // ... create stranger ...
  // Send public profile hello back so they see who they're talking to
  onSendHelloToStranger?.call(senderPub, contact.transportAddresses);
}
```

This mirrors real-world messaging: when someone texts a business, they immediately
see the business name/logo even before being added as a contact.

Only fires when `incoming_contacts_policy == 'all'` (if policy is `contacts_only`,
strangers are dropped before this point).

---

### Step 4 — Profile setup UI (1 day)

**`lib/features/onboarding/profile_setup_screen.dart`** — add public profile section:

```
┌─────────────────────────────────────────────────────┐
│  Профиль для контактов                              │
│  [Avatar picker]  Ваше имя: [____________]          │
│  Виден только вашим контактам                       │
├─────────────────────────────────────────────────────┤
│  Публичный профиль (для незнакомцев)                │
│  [Avatar picker]  Публичное имя: [____________]     │
│  Виден всем кто напишет вам                         │
│  Если не задан — незнакомцы видят только иницалы    │
└─────────────────────────────────────────────────────┘
```

**`lib/features/main/profile_tab.dart`** — same two sections for editing after setup.

**`lib/features/settings/settings_screen.dart`** — "Profile" section links to profile editor.

---

### Step 5 — Contact profile display (0.5 days)

When viewing a contact's profile, show which avatar/name they sent us and a subtle
indicator of the profile type (not technically required, but good UX):

- If contact sent us their full photo (they added us as contact) → normal display
- If contact sent no avatar → show initials with "Public profile" note

---

## Wire Protocol (no changes needed)

`contact_hello` already has `av` (avatar base64) and `name` fields.  
The logic change is purely on the **sender side** — choosing which values to put in.

Receiver-side handling is unchanged: avatar/name are stored regardless of source.

---

## Files Changed

| File | Change |
|---|---|
| `shared/services/avatar_service.dart` | `publicProfile` param on save/load/delete |
| `storage/dao/settings_dao.dart` | `my_public_alias` key |
| `network/message_router.dart` | Per-recipient avatar/name selection |
| `use_cases/contacts/send_contact_hello_use_case.dart` | `publicProfile` flag |
| `use_cases/messaging/receive_envelope_use_case.dart` | Auto-hello to stranger |
| `features/onboarding/profile_setup_screen.dart` | Public profile section |
| `features/main/profile_tab.dart` | Public profile editing |

---

## Effort Estimate

| Step | Days |
|---|---|
| Storage (avatar service + settings key) | 0.5 |
| Protocol (send correct profile per recipient) | 0.5 |
| Auto-hello to stranger on first message | 0.5 |
| Profile setup + profile tab UI | 1 |
| Contact profile display indicator | 0.5 |
| **Total** | **3 days** |

---

## Edge Cases

- **No public avatar set**: sends `av: null` → receiver shows initials. OK.
- **No public name set**: sends `name: null` → receiver shows truncated pubkey. OK.
- **Contact demoted to stranger** (future): next hello will use public profile. OK.
- **Policy = contacts_only**: strangers never receive any hello. OK — they don't exist in our DB.
- **Existing users on upgrade**: `my_public_alias` is empty → public profile = anonymous. Consistent.
