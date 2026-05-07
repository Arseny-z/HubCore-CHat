# HubCore Chat UI/UX Roadmap

Goal — Telegram-level interface: fast, clear, no unnecessary screens.

---

## Phase U1 — Bottom navigation + unified chat list ✅ Done

- [x] Replace `ContactsScreen` + `GroupsScreen` with unified `ChatsScreen`
- [x] List combines direct chats and groups, sorted by last message time
- [x] Bottom navigation: **Chats** | **Contacts** | **Settings**
- [x] Avatar (name initial, colored background)
- [x] Contact name / group name
- [x] Last message preview (truncated to 1 line)
- [x] Last message time
- [x] Chat search in ChatsScreen (SearchBar in AppBar)
- [ ] Unread count badge in chat list

---

## Phase U2 — Chat screen ✅ Done

- [x] Message bubbles in Telegram style (own — right, others — left)
- [x] Bubble tail (first message in a series)
- [x] Message status: ✓ sent / ✓✓ delivered / ✓✓ read (blue)
- [x] Receipts update in real time without reload
- [x] Date separator between days
- [x] Name and avatar in header
- [x] Long press → menu: Copy, Delete
- [x] ↓ button with unread count when scrolled up
- [ ] "online" status / last seen time (requires TCP ping to fd00::)

---

## Phase U3 — Input field ✅ Done

- [x] Send button appears when text present, otherwise shows mic stub
- [x] Attach file button (via bottom sheet)
- [x] Multiline without height limit (scrollable)
- [x] TTL timer (button to select message lifetime)

---

## Phase U4 — Contact screen / profile ✅ Done

- [x] Tap on name opens contact profile
- [x] Avatar (initial, color by name)
- [x] Name / alias (inline editable)
- [x] Fingerprint (with copy button)
- [x] Buttons: Message, Delete contact

---

## Phase U5 — Group screen ✅ Done

- [x] View group members with aliases
- [x] Leave group button
- [ ] "Add member" button (currently missing in group chat UI)
- [ ] Separate group profile screen (currently — bottom sheet)

---

## Phase U6 — Search ✅ Done

- [x] Chat search in ChatsScreen (filter by name / last message text)
- [ ] Message search within chat (client-side)

---

## Phase U7 — Onboarding ⚠️ Partial

- [x] Welcome screen with HubCore Chat logo
- [x] Identity creation with one button
- [x] PIN keypad (numeric, 4 digits)
- [x] Duress PIN in security settings
- [ ] Step-by-step onboarding: 1) Create → 2) PIN → 3) Done (currently two separate screens)
- [ ] Animated transitions between steps

---

## Phase U8 — Security UI (new)

- [x] Duress PIN — set via Settings → Security, works on unlock
- [x] Brute-force attempt counter (shown on lock screen)
- [ ] Panic button — gesture for instant wipe (5× tap on lock icon or shake)
- [ ] Warning on contact key change (in-chat system message)

---

## Remaining Priority

```
U1 (unread badge) → U5 (Add member) → U7 (onboarding steps) → U8 (panic button)
```
