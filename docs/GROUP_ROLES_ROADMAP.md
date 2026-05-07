# Group Roles & Permissions Roadmap

**Goal:** Replace single-admin model with a flexible role system:  
`admin (max 3) | write | read | banned`

---

## Current State

- Single `admin_pub TEXT` column in `groups` table — one admin per group
- All non-admin members have equal write access
- Operations: rename, kick, add member, delete group (admin only)
- No read-only, no ban, no role transfer

---

## Target Role Matrix

| Permission | admin | write | read | banned |
|---|---|---|---|---|
| Read messages | ✓ | ✓ | ✓ | ✗ |
| Send messages | ✓ | ✓ | ✗ | ✗ |
| Add members | ✓ | ✗ | ✗ | ✗ |
| Remove members | ✓ | ✗ | ✗ | ✗ |
| Rename group | ✓ | ✗ | ✗ | ✗ |
| Change roles | ✓ | ✗ | ✗ | ✗ |
| Delete group | owner only | ✗ | ✗ | ✗ |
| Max per group | 3 | unlimited | unlimited | unlimited |

**Owner** = creator (original admin) — cannot be demoted by other admins.

---

## Implementation Plan

### Phase 1: Database (Day 1)

**lib/storage/database.dart** — migration v22:

```sql
-- Add role column to group_members
ALTER TABLE group_members ADD COLUMN role TEXT NOT NULL DEFAULT 'write';

-- Mark original admin
-- (done in migration: UPDATE group_members SET role='admin'
--  WHERE (group_id, master_pub) IN (SELECT group_id, admin_pub FROM groups))

-- Mark original creator as owner
ALTER TABLE groups ADD COLUMN owner_pub TEXT;
UPDATE groups SET owner_pub = admin_pub;
```

Role values: `'admin'`, `'write'`, `'read'`, `'banned'`

**lib/storage/dao/groups_dao.dart** — new methods:

```dart
Future<String?> memberRole(String groupId, String masterPub);
Future<void> setMemberRole(String groupId, String masterPub, String role);
Future<List<String>> adminPubs(String groupId);  // all members with role='admin'
Future<int> adminCount(String groupId);
```

### Phase 2: Domain + Permissions (Day 1–2)

**lib/domain/entities/group.dart** — extend GroupMember:

```dart
class GroupMember {
  final String masterPub;
  final String role; // 'admin' | 'write' | 'read' | 'banned'

  bool get isAdmin => role == 'admin';
  bool get canWrite => role == 'admin' || role == 'write';
  bool get canRead => role != 'banned';
}

class GroupPermissions {
  static bool canRename(String role) => role == 'admin';
  static bool canKick(String role) => role == 'admin';
  static bool canChangeRoles(String role) => role == 'admin';
  static bool canWrite(String role) => role == 'admin' || role == 'write';
  static bool canRead(String role) => role != 'banned';
  static bool canAddMembers(String role) => role == 'admin';
}
```

### Phase 3: Protocol (Day 2–3)

New wire message type `group_role_change`, sent by admin to all members:

```json
{
  "type": "group_role_change",
  "group_id": "...",
  "target_pub": "<base58>",
  "new_role": "write",
  "changed_by": "<base58>"
}
```

**lib/application/use_cases/messaging/receive_envelope_use_case.dart** — add handler:

```dart
case 'group_role_change':
  // 1. Verify sender is admin for this group
  final senderRole = await storage.groups.memberRole(groupId, senderPub);
  if (senderRole != 'admin') return null; // reject

  // 2. Enforce max 3 admins
  if (newRole == 'admin') {
    final count = await storage.groups.adminCount(groupId);
    if (count >= 3) return null; // reject
  }

  // 3. Owner cannot be demoted
  final ownerPub = await storage.groups.ownerPub(groupId);
  if (targetPub == ownerPub && newRole != 'admin') return null;

  await storage.groups.setMemberRole(groupId, targetPub, newRole);
  eventBus.emit(GroupUpdatedEvent(groupId));
```

**lib/infrastructure/crypto/group_messaging_service.dart** — validate before send:

```dart
Future<List<Envelope>> sendGroupMessage(...) async {
  final myRole = await _storage.groups.memberRole(groupId, _myPub);
  if (!GroupPermissions.canWrite(myRole)) {
    throw StateError('No write permission in group $groupId');
  }
  // ... existing flow
}
```

Also: `sendRoleChange(groupId, targetPub, newRole)` — send `group_role_change` to all members.

### Phase 4: UI (Day 3–4)

**lib/features/groups/group_settings_screen.dart** — replace "remove" icon with role picker:

```
Member row:
  [Avatar] [Name]  [Role badge: admin/write/read/banned]  [▼ if I'm admin]
                    ↓ dropdown (if I'm admin):
                    ✓ write (current)
                      read
                      admin (if adminCount < 3)
                      banned
                      ─────
                      Remove from group
```

**lib/features/groups/group_chat_screen.dart** — hide input for read/banned:

```dart
// Replace ChatInputBar with status banner
if (!GroupPermissions.canWrite(_myRole)) {
  const Text('You have read-only access')
}
```

### Phase 5: Migration & Backward Compat (Day 4–5)

- Old groups (no `role` column): migration sets all members to `write`, original `admin_pub` → `admin`
- Old clients receiving `group_role_change`: unknown type, ignored (no crash)
- Old client trying to send in a group where new client set them to `read`: new client's UI blocks them locally; other new clients will ignore their messages (server-side enforcement not possible in P2P — rely on client-side only)

---

## Key Design Decisions

**Why max 3 admins?**  
More than 3 admins in a small P2P group creates coordination problems. Roles can conflict if two admins simultaneously change the same member.

**Banned vs Kicked:**  
- `banned` = stays in member list with role='banned', cannot read/write
- kicked (`group_kick`) = removed from group entirely (existing behavior, unchanged)
- Ban is enforced client-side: banned members' messages are ignored by compliant clients

**Chain rotation on role change:**  
- `read` → `write`: no rotation needed (they already have chain keys)
- `write` → `read` or `banned`: rotate sender chain (forward secrecy) — same as `group_kick` flow but member stays in list
- `member` → `admin`: no rotation needed

**Owner protection:**  
Owner (creator) cannot be demoted by other admins. Only the owner can transfer ownership (`group_transfer_ownership` — future feature).

---

## Effort Estimate

| Task | Days |
|---|---|
| DB migration + DAO | 1 |
| Domain entities + GroupPermissions | 0.5 |
| Protocol + receive handler | 1 |
| GroupMessagingService validation | 0.5 |
| UI (settings + chat input) | 1.5 |
| Migration + backward compat testing | 1 |
| **Total** | **5.5 days** |
