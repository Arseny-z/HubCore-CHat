# Channels Roadmap

**Goal:** Telegram-like channels — admin publishes posts, subscribers read and comment.  
**Reference:** Telegram channels with comments enabled.

---

## Channel vs Group: Key Differences

| | Group (current) | Channel |
|---|---|---|
| Who can post | Any member | Admins/moderators only |
| Who can read | Members only | All subscribers (public) |
| Message model | Chat (real-time) | Feed (posts) |
| Replies | Flat thread | Comments under each post |
| Scale | ~50 members | Unlimited subscribers |
| Discovery | Invite only | Public or invite |
| Crypto | Sender Keys (all equal) | Sender Keys (admin posts only) |

---

## Architecture

Channels reuse ~70% of group crypto infrastructure (Sender Keys, XChaCha20-Poly1305).  
The main difference is the data model and UI.

```
ChannelMessagingService
 └── reuses SenderKeys from GroupMessagingService
      ├── channel posts → same encryption as group messages
      └── comments → separate Sender Keys chain per channel
```

---

## Database Schema

**Migration v22** (or v23 if group roles ships first):

```sql
CREATE TABLE channels (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  channel_id   TEXT    NOT NULL UNIQUE,  -- random base58
  display_name TEXT    NOT NULL,
  description  TEXT,
  owner_pub    TEXT    NOT NULL,         -- base58, creator
  is_public    INTEGER NOT NULL DEFAULT 1,
  created_at   INTEGER NOT NULL,
  avatar_hash  TEXT,
  pinned_post_id TEXT
);

CREATE TABLE channel_subscribers (
  channel_id     TEXT    NOT NULL,
  subscriber_pub TEXT    NOT NULL,       -- base58 master_pub
  subscribed_at  INTEGER NOT NULL,
  muted          INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (channel_id, subscriber_pub)
);

CREATE TABLE channel_moderators (
  channel_id    TEXT    NOT NULL,
  moderator_pub TEXT    NOT NULL,
  added_at      INTEGER NOT NULL,
  PRIMARY KEY (channel_id, moderator_pub)
);

-- Posts (not messages)
CREATE TABLE channel_posts (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  post_id      TEXT    NOT NULL UNIQUE,  -- random base58
  channel_id   TEXT    NOT NULL,
  author_pub   TEXT    NOT NULL,
  content_type TEXT    NOT NULL DEFAULT 'text',  -- text|image|video|file
  body         TEXT    NOT NULL,                 -- plaintext (stored locally after decrypt)
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER,
  deleted_at   INTEGER,                          -- soft delete
  reply_to_id  TEXT,                             -- for post threads (optional)
  pinned       INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX idx_channel_posts_channel ON channel_posts(channel_id, created_at DESC);
CREATE INDEX idx_channel_posts_pinned  ON channel_posts(channel_id, pinned);

-- Comments on posts
CREATE TABLE post_comments (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  comment_id        TEXT    NOT NULL UNIQUE,
  post_id           TEXT    NOT NULL,
  author_pub        TEXT    NOT NULL,
  body              TEXT    NOT NULL,
  content_type      TEXT    NOT NULL DEFAULT 'text',
  created_at        INTEGER NOT NULL,
  updated_at        INTEGER,
  deleted_at        INTEGER,
  parent_comment_id TEXT    -- max 1 level nesting
);

CREATE INDEX idx_comments_post ON post_comments(post_id, created_at ASC);

-- Reactions on posts and comments
CREATE TABLE post_reactions (
  post_id      TEXT    NOT NULL,
  reactor_pub  TEXT    NOT NULL,
  emoji        TEXT    NOT NULL,  -- '👍', '❤️', '😂', etc.
  reacted_at   INTEGER NOT NULL,
  PRIMARY KEY (post_id, reactor_pub, emoji)
);
```

---

## Protocol Wire Format

**Channel post** (sent by admin/mod to all subscribers, encrypted with Sender Keys):

```json
{
  "type": "channel_post",
  "channel_id": "<base58>",
  "post_id": "<base58>",
  "c": "<base64 encrypted body>",
  "n": 42,
  "rk": "<base64 ratchet pub | null>"
}
```

**Comment** (sent by subscriber to channel, encrypted):

```json
{
  "type": "channel_comment",
  "channel_id": "<base58>",
  "post_id": "<base58>",
  "comment_id": "<base58>",
  "parent_comment_id": null,
  "c": "<base64 encrypted comment body>",
  "n": 5
}
```

**Subscription** (sent to channel owner):

```json
{
  "type": "channel_subscribe",
  "channel_id": "<base58>"
}
```

---

## New Files

```
lib/
  domain/
    entities/
      channel.dart              -- Channel, ChannelPost, PostComment
  storage/
    dao/
      channels_dao.dart         -- CRUD for all 5 channel tables
  infrastructure/
    crypto/
      channel_messaging_service.dart  -- SenderKeys for channels
  features/
    channels/
      channels_list_screen.dart       -- List of subscribed channels
      channel_feed_screen.dart        -- Post feed for one channel
      channel_post_detail_screen.dart -- Single post + comments
      channel_settings_screen.dart    -- Owner: name, description, mods
      browse_channels_screen.dart     -- Discovery (public channels)
      create_channel_screen.dart      -- Create new channel
```

---

## UI Screens

### ChannelsListScreen
- Tab alongside Chats / Contacts on main screen
- Row per channel: avatar + name + last post preview + unread dot
- FAB: Create Channel

### ChannelFeedScreen
- Posts in reverse-chron order (latest on top)
- Each post card: author (for multi-admin), body, media, reaction bar, comment count
- "New Post" FAB — visible only to admins/mods
- Tap comment count → PostDetailScreen

### ChannelPostDetailScreen
- Full post at top
- Comments list below (two-level: top-level + replies)
- Reply input at bottom (visible to all non-banned subscribers)
- Long-tap comment → delete (if owner) / report

### ChannelSettingsScreen (admin only)
- Change name/description/avatar
- Add/remove moderators
- Toggle public/private
- Pin a post
- Delete channel

### BrowseChannelsScreen
- Search by channel name
- List of public channels with subscriber count
- Subscribe button

### CreateChannelScreen
- Name + description + avatar + public toggle

---

## Reused from Groups (~70%)

| Component | Reuse |
|---|---|
| Sender Keys crypto | 95% — same encryption |
| File transfer (images/video in posts) | 80% |
| Contact avatar lookup | 100% |
| Notification service | 60% |
| DB encryption (SQLCipher) | 100% |
| Message bubble widgets | 50% (adapt for posts) |
| ChatInputBar → CommentInputBar | 40% |

---

## Encryption Model

- Channel has one Sender Keys chain shared among admins/mods (for posts)
- Comments use a separate Sender Keys chain shared among all subscribers
- Subscribers get the comment chain key when they subscribe
- Posts are end-to-end encrypted; only subscribers can read them
- Public channel = anyone can subscribe, but posts still encrypted (only active subscribers can decrypt)

**Note on public discovery:**  
In P2P without a server, "public channel" means channel_id is shareable (QR code, link).  
When someone subscribes, they get the Sender Keys chain. Discovery = share the channel_id out-of-band.

---

## Effort Estimate

| Task | Days |
|---|---|
| DB schema + migrations | 1 |
| Domain entities + DAOs | 1.5 |
| ChannelMessagingService | 2 |
| Protocol handlers in receive_envelope_use_case | 1 |
| ChannelsListScreen | 1 |
| ChannelFeedScreen | 2 |
| ChannelPostDetailScreen + comments | 2 |
| ChannelSettingsScreen | 1 |
| BrowseChannelsScreen + CreateChannelScreen | 1.5 |
| Reactions | 1 |
| Notifications for new posts | 1 |
| Testing + bug fixes | 2 |
| **Total** | **~17 days** |

---

## What's Out of Scope (v1)

- Polls in posts
- Scheduled posts
- Post analytics (view count) — not possible in P2P
- Channel forwarding
- Admin post signatures visible to subscribers (who posted what)
- Paid subscriptions
