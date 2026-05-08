import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import '../../shared/utils/l10n.dart';
import 'package:path_provider/path_provider.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../shared/providers/app_providers.dart' show Message, MessageStatus, ContentType;
import '../../storage/dao/message_reactions_dao.dart' show MessageReaction;
import '../../shared/utils/logger.dart';
import 'video_circle_widgets.dart';
import 'voice_message_widgets.dart';

// ── Colours ──────────────────────────────────────────────────────────────────

const _kBgOwn   = Color(0xFF2B5278); // Telegram "own" bubble
const _kBgOther = Color(0xFF182533); // Telegram "other" bubble
const _kBgDate  = Color(0x99182533); // date separator pill

/// Fixed emoji set for message reactions (Telegram-style minimal palette).
const List<String> kReactionEmojis = [
  '👍', '❤️', '😂', '😮', '😢', '🔥', '🙏', '🎉',
];
const _kTick1   = Color(0xFF8EADC1); // sent/delivered tick
const _kTick2   = Color(0xFF52B8EA); // read tick

// Sender-name colours (cycling by first char of pubkey).
const _kSenderColors = [
  Color(0xFFE17076), Color(0xFFFAA774), Color(0xFFA695E7),
  Color(0xFF7BC862), Color(0xFF6EC9CB), Color(0xFF65AADD),
  Color(0xFFEE7AAE),
];

Color senderColor(String pub) =>
    _kSenderColors[pub.isEmpty ? 0 : pub.codeUnitAt(0) % _kSenderColors.length];

// ── Message list builder ─────────────────────────────────────────────────────

/// Builds a merged list of date separators + message widgets.
/// [messages] must be sorted oldest → newest.
List<Widget> buildMessageList({
  required List<Message> messages,
  required String myPub58,
  required bool isGroup,
  Map<String, String>? aliases, // pubkey → display name (for groups)
  dynamic fileSvc,
  dynamic storage,
  /// messageId → upload/download progress (0.0–1.0). null = complete.
  Map<int, double>? fileProgress,
  /// messageId → (attempts, maxAttempts) for pending messages.
  Map<String, (int, int)>? queueAttempts,
  /// messageId → (delivered, total). Only shown for group messages with > 1 recipient.
  Map<String, (int, int)>? deliveryCounts,
  void Function(Message msg)? onDeliveryTap,
  void Function(Message msg)? onDeleteQueued,
  void Function(Message msg)? onDeleteMe,
  void Function(Message msg)? onDeleteForAll,
  /// Called when an incoming message becomes visible on screen (for read receipts).
  void Function(Message msg)? onMessageVisible,
  /// Called when user taps "Reply" on a message.
  void Function(Message msg)? onReply,
  /// Called when user taps "Forward" on a message.
  void Function(Message msg)? onForward,
  /// Active in-chat search query — highlights matches in each bubble.
  String? searchQuery,
  /// Message id of the currently-focused search hit (extra emphasis on bubble).
  int? currentHitMsgId,
  /// GlobalKeys for matched messages — used by caller to scroll-to-hit.
  /// Caller pre-allocates one key per match; passes id → key here.
  Map<int, GlobalKey>? messageKeys,
  /// messageId (text) → list of reactions to render under that bubble.
  Map<String, List<MessageReaction>>? reactionsByMid,
  /// Called when user taps a reaction chip — toggle add/remove.
  void Function(Message msg, String emoji)? onReactionTap,
}) {
  final items = <Widget>[];
  DateTime? lastDay;

  for (int i = 0; i < messages.length; i++) {
    final msg = messages[i];
    final dt = DateTime.fromMillisecondsSinceEpoch(msg.sentAt * 1000);
    final day = DateTime(dt.year, dt.month, dt.day);

    if (lastDay == null || day != lastDay) {
      items.add(_DateSeparator(date: day));
      lastDay = day;
    }

    final isMe = msg.senderPub == myPub58;
    // First in a series = no same-side bubble right before
    final prevMsg = i > 0 ? messages[i - 1] : null;
    final isFirst = prevMsg == null ||
        prevMsg.senderPub != msg.senderPub ||
        (msg.sentAt - prevMsg.sentAt) > 60; // gap > 1 min → new group

    // System messages (e.g. "X joined the group") — centered, no bubble
    if (msg.contentType == ContentType.system) {
      items.add(Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white10,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              msg.body,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
        ),
      ));
      continue;
    }

    final mid = msg.messageId;
    final progress = (msg.id != null && fileProgress != null)
        ? fileProgress[msg.id!]
        : null;
    final retry = (msg.messageId != null && queueAttempts != null)
        ? queueAttempts[msg.messageId!]
        : null;
    final searchKey = (msg.id != null && messageKeys != null)
        ? messageKeys[msg.id!]
        : null;
    items.add(MessageBubble(
      key: searchKey ?? ValueKey('msg_${msg.id ?? msg.sentAt}'),
      message: msg,
      isMe: isMe,
      isGroup: isGroup,
      isFirst: isFirst,
      showSenderName: isGroup && !isMe,
      senderName: isGroup && !isMe
          ? (aliases?[msg.senderPub] ??
              (msg.senderPub.length > 8
                  ? msg.senderPub.substring(0, 8)
                  : msg.senderPub))
          : null,
      fileSvc: fileSvc,
      storage: storage,
      fileProgress: progress,
      retryCount: retry,
      deliveryCount: (mid != null && deliveryCounts != null) ? deliveryCounts[mid] : null,
      onDeliveryTap: onDeliveryTap != null ? () => onDeliveryTap(msg) : null,
      onDelete: onDeleteQueued != null ? () => onDeleteQueued(msg) : null,
      onDeleteMe: onDeleteMe != null ? () => onDeleteMe(msg) : null,
      onDeleteForAll: onDeleteForAll != null ? () => onDeleteForAll(msg) : null,
      onVisible: (!isMe && msg.status != MessageStatus.read && onMessageVisible != null)
          ? () => onMessageVisible(msg)
          : null,
      onReply: onReply != null ? (m) => onReply(m) : null,
      onForward: onForward != null ? (m) => onForward(m) : null,
      searchQuery: searchQuery,
      isCurrentHit: msg.id != null && msg.id == currentHitMsgId,
      reactions: (mid != null && reactionsByMid != null)
          ? reactionsByMid[mid]
          : null,
      myPub58: myPub58,
      onReactionTap: onReactionTap != null
          ? (emoji) => onReactionTap(msg, emoji)
          : null,
    ));
  }

  return items;
}

// ── DateSeparator ─────────────────────────────────────────────────────────────

class _DateSeparator extends StatelessWidget {
  final DateTime date;
  const _DateSeparator({required this.date});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: _kBgDate,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          _label(date, context),
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ),
    );
  }

  static String _label(DateTime date, BuildContext context) {
    final l10n = context.l10n;
    final now = DateTime.now();
    final today    = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    if (date == today) return l10n.today;
    if (date == yesterday) return l10n.yesterday;
    final months = [
      '', l10n.monthJan, l10n.monthFeb, l10n.monthMar, l10n.monthApr,
      l10n.monthMay, l10n.monthJun, l10n.monthJul, l10n.monthAug,
      l10n.monthSep, l10n.monthOct, l10n.monthNov, l10n.monthDec,
    ];
    final sameYear = date.year == now.year;
    return sameYear
        ? '${date.day} ${months[date.month]}'
        : '${date.day} ${months[date.month]} ${date.year}';
  }
}

// ── MessageBubble ─────────────────────────────────────────────────────────────

class MessageBubble extends StatelessWidget {
  final Message message;
  final bool isMe;
  final bool isGroup;
  final bool isFirst;       // first in a run → show tail
  final bool showSenderName;
  final String? senderName;
  final dynamic fileSvc;
  final dynamic storage;
  /// Upload/download progress for file messages (0.0–1.0). null = complete.
  final double? fileProgress;
  /// Retry counter for pending messages: (attempts, maxAttempts). null = not pending.
  final (int, int)? retryCount;
  /// Delivery counter: (delivered, total). null = not available (only shown in groups).
  final (int, int)? deliveryCount;
  /// Called when tapping the bubble (own messages) to show delivery details.
  final VoidCallback? onDeliveryTap;
  /// Called when user chooses "Delete (cancel send)" from long-press menu (queued only).
  final VoidCallback? onDelete;
  /// Called when user chooses "Удалить у себя" (delete locally only).
  final VoidCallback? onDeleteMe;
  /// Called when user chooses "Удалить у всех" (send ttl_delete to peer + delete locally).
  final VoidCallback? onDeleteForAll;
  /// Called once when this message first becomes visible on screen.
  final VoidCallback? onVisible;
  /// Called when user taps "Reply" — passes the message to reply to.
  final void Function(Message)? onReply;
  /// Called when user taps "Forward".
  final void Function(Message)? onForward;
  /// Active in-chat search query — highlights matches in the body.
  final String? searchQuery;
  /// True if this is the currently-focused search hit (extra emphasis).
  final bool isCurrentHit;
  /// All reactions on this message (raw rows, one per reactor).
  final List<MessageReaction>? reactions;
  /// Caller's own master pubkey — used to highlight your own reaction.
  final String? myPub58;
  /// Tap handler for a reaction chip — toggle add/remove for that emoji.
  final void Function(String emoji)? onReactionTap;

  const MessageBubble({
    super.key,
    required this.message,
    required this.isMe,
    this.isGroup = false,
    required this.isFirst,
    this.showSenderName = false,
    this.senderName,
    this.fileSvc,
    this.storage,
    this.fileProgress,
    this.retryCount,
    this.deliveryCount,
    this.onDeliveryTap,
    this.onDelete,
    this.onDeleteMe,
    this.onDeleteForAll,
    this.onVisible,
    this.onReply,
    this.onForward,
    this.searchQuery,
    this.isCurrentHit = false,
    this.reactions,
    this.myPub58,
    this.onReactionTap,
  });

  @override
  Widget build(BuildContext context) {
    // Кружочки (video) — прозрачный фон, круг сам является контентом
    final isVideoCircle = message.contentType == ContentType.video;
    final bgColor = isVideoCircle ? Colors.transparent : (isMe ? _kBgOwn : _kBgOther);
    final align   = isMe ? Alignment.centerRight : Alignment.centerLeft;

    // Border radius: tail corner is square on "first" bubble.
    final radius = BorderRadius.only(
      topLeft:     const Radius.circular(16),
      topRight:    const Radius.circular(16),
      bottomLeft:  Radius.circular(isMe ? 16 : (isFirst ? 4 : 16)),
      bottomRight: Radius.circular(isMe ? (isFirst ? 4 : 16) : 16),
    );

    final bubble = GestureDetector(
      onTap: isMe ? onDeliveryTap : null,
      onLongPress: () => _onLongPress(context),
      child: Align(
        alignment: align,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78,
          ),
          margin: EdgeInsets.only(
            top: isFirst ? 6 : 2,
            bottom: 2,
            left: isMe ? 48 : 8,
            right: isMe ? 8 : 48,
          ),
          padding: isVideoCircle
              ? EdgeInsets.zero
              : const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: isVideoCircle ? null : radius,
            border: isCurrentHit
                ? Border.all(color: const Color(0xFFFFB300), width: 2)
                : null,
          ),
          child: Column(
            crossAxisAlignment:
                isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showSenderName && senderName != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    senderName!,
                    style: TextStyle(
                      color: senderColor(message.senderPub),
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
              if (message.replyToId != null)
                ReplyBubble(
                  key: ValueKey('reply_${message.id}'),
                  replyToId: message.replyToId!,
                  storage: storage,
                ),
            if (message.contentType == ContentType.image && message.id != null)
                fileProgress != null
                  ? _FileProgressWidget(
                      fileName: message.body,
                      progress: fileProgress!,
                      isImage: true,
                      onCancel: isMe ? onDeleteMe : null,
                    )
                  : _ImagePreview(
                      key: ValueKey('img_${message.id}'),
                      messageId: message.id!, fileSvc: fileSvc, storage: storage)
              else if (message.contentType == ContentType.file && message.id != null)
                fileProgress != null
                  ? _FileProgressWidget(
                      fileName: message.body,
                      progress: fileProgress!,
                      isImage: false,
                      onCancel: isMe ? onDeleteMe : null,
                    )
                  : _FilePreview(
                      key: ValueKey('file_${message.id}'),
                      messageId: message.id!, fileName: message.body,
                      fileSvc: fileSvc, storage: storage)
              else if (message.contentType == ContentType.video && message.id != null)
                fileProgress != null
                  ? _VideoCircleProgress(
                      progress: fileProgress!,
                      onCancel: isMe ? onDeleteMe : null,
                    )
                  : VideoCirclePlayer(
                      key: ValueKey('video_${message.id}'),
                      messageId: message.id!,
                      fileSvc: fileSvc,
                      storage: storage,
                      onPlay: (!isMe && message.status != MessageStatus.read)
                          ? onVisible
                          : null,
                    )
              else if (message.contentType == ContentType.audio && message.id != null)
                fileProgress != null
                  ? _AudioProgress(
                      progress: fileProgress!,
                      isMe: isMe,
                      onCancel: isMe ? onDeleteMe : null,
                    )
                  : VoiceMessagePlayer(
                      key: ValueKey('voice_${message.id}'),
                      messageId: message.id!,
                      fileSvc: fileSvc,
                      storage: storage,
                      isMe: isMe,
                      onPlay: (!isMe && message.status != MessageStatus.read)
                          ? onVisible
                          : null,
                    )
              else
                _highlightedBody(message.body, searchQuery),
              const SizedBox(height: 2),
              if (retryCount != null) ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    context.l10n.sendAttempt(retryCount!.$1, retryCount!.$2),
                    style: const TextStyle(
                      color: Color(0xFFEF9A3A),
                      fontSize: 10,
                    ),
                  ),
                ),
              ],
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (message.expiresAt != null) ...[
                    _ExpiryBadge(expiresAt: message.expiresAt!),
                    const SizedBox(width: 4),
                  ],
                  Text(
                    _formatTime(message.sentAt),
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                  if (!isMe && message.transport != null) ...[
                    const SizedBox(width: 3),
                    Text(
                      _transportLabel(message.transport!),
                      style: const TextStyle(
                          color: Colors.white24, fontSize: 10),
                    ),
                  ],
                  if (isMe) ...[
                    const SizedBox(width: 4),
                    _StatusTick(status: message.status),
                    if (message.transport != null) ...[
                      const SizedBox(width: 3),
                      Text(
                        _transportLabel(message.transport!),
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 10),
                      ),
                    ],
                    if (isGroup && deliveryCount != null &&
                        deliveryCount!.$2 > 1) ...[
                      const SizedBox(width: 4),
                      GestureDetector(
                        onTap: onDeliveryTap,
                        child: Text(
                          '${deliveryCount!.$1}/${deliveryCount!.$2}',
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 11),
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );

    final hasReactions = reactions != null && reactions!.isNotEmpty;
    final content = hasReactions
        ? Column(
            crossAxisAlignment: isMe
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              bubble,
              _ReactionsRow(
                reactions: reactions!,
                isMe: isMe,
                myPub58: myPub58,
                onTap: onReactionTap,
              ),
            ],
          )
        : bubble;

    if (onVisible == null) return content;

    // Audio and video mark themselves as read on play — skip VisibilityDetector.
    final mediaType = message.contentType;
    if (mediaType == ContentType.audio || mediaType == ContentType.video) {
      return content;
    }

    return VisibilityDetector(
      key: Key('vis_${message.id ?? message.sentAt}'),
      onVisibilityChanged: (info) {
        if (info.visibleFraction >= 0.5) {
          onVisible!();
        }
      },
      child: content,
    );
  }

  void _onLongPress(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF182533),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            if (onReactionTap != null && message.messageId != null) ...[
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: kReactionEmojis.map((e) {
                    return InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: () {
                        Navigator.pop(context);
                        onReactionTap!(e);
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(e,
                            style: const TextStyle(fontSize: 26)),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const Divider(height: 8, color: Colors.white12),
            ],
            if (onReply != null && message.contentType == ContentType.text)
              ListTile(
                leading: const Icon(Icons.reply, color: Colors.white70),
                title: Text(context.l10n.reply, style: const TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  onReply!(message);
                },
              ),
            if (onForward != null && message.contentType == ContentType.text)
              ListTile(
                leading: const Icon(Icons.forward, color: Colors.white70),
                title: Text(context.l10n.forward, style: const TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  onForward!(message);
                },
              ),
            ListTile(
              leading: const Icon(Icons.copy, color: Colors.white70),
              title: Text(context.l10n.copyText, style: const TextStyle(color: Colors.white)),
              onTap: () {
                Clipboard.setData(ClipboardData(text: message.body));
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(context.l10n.copied),
                    duration: const Duration(seconds: 1),
                  ),
                );
              },
            ),
            if (message.status == MessageStatus.queued && onDelete != null)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Color(0xFFEF5350)),
                title: Text(context.l10n.deleteCancelSend,
                    style: const TextStyle(color: Color(0xFFEF5350))),
                onTap: () {
                  Navigator.pop(context);
                  onDelete!();
                },
              ),
            if (isMe && message.status != MessageStatus.queued) ...[
              if (onDeleteMe != null)
                ListTile(
                  leading: const Icon(Icons.delete_outline, color: Colors.white54),
                  title: Text(context.l10n.deleteLocally,
                      style: const TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(context);
                    onDeleteMe!();
                  },
                ),
              if (onDeleteForAll != null)
                ListTile(
                  leading: const Icon(Icons.delete_forever, color: Color(0xFFEF5350)),
                  title: Text(context.l10n.deleteForAll,
                      style: const TextStyle(color: Color(0xFFEF5350))),
                  onTap: () {
                    Navigator.pop(context);
                    onDeleteForAll!();
                  },
                ),
            ],
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  static String _formatTime(int unixSeconds) {
    final dt = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  static String _transportLabel(String protocol) {
    switch (protocol) {
      case 'yggdrasil': return 'ygg';
      case 'reticulum': return 'ret';
      case 'meshcore':  return 'mesh';
      default: return protocol.length > 4 ? protocol.substring(0, 4) : protocol;
    }
  }
}

// ── In-chat search highlight ──────────────────────────────────────────────────

/// Renders [text] with [query] occurrences highlighted (case-insensitive).
/// Falls back to a plain Text when [query] is null/empty.
Widget _highlightedBody(String text, String? query) {
  const baseStyle = TextStyle(color: Colors.white, fontSize: 15);
  if (query == null || query.isEmpty) {
    return Text(text, style: baseStyle);
  }
  final lower  = text.toLowerCase();
  final lowerQ = query.toLowerCase();
  final spans  = <TextSpan>[];
  int start = 0;
  while (true) {
    final idx = lower.indexOf(lowerQ, start);
    if (idx < 0) {
      if (start < text.length) {
        spans.add(TextSpan(text: text.substring(start)));
      }
      break;
    }
    if (idx > start) {
      spans.add(TextSpan(text: text.substring(start, idx)));
    }
    spans.add(TextSpan(
      text: text.substring(idx, idx + query.length),
      style: const TextStyle(
        backgroundColor: Color(0xFFFFB300),
        color: Colors.black,
        fontWeight: FontWeight.w600,
      ),
    ));
    start = idx + query.length;
  }
  return RichText(text: TextSpan(style: baseStyle, children: spans));
}

// ── Reactions row ─────────────────────────────────────────────────────────────

class _ReactionsRow extends StatelessWidget {
  final List<MessageReaction> reactions;
  final bool isMe;
  final String? myPub58;
  final void Function(String emoji)? onTap;

  const _ReactionsRow({
    required this.reactions,
    required this.isMe,
    required this.myPub58,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Aggregate emoji → (count, mineSelected).
    final agg = <String, (int, bool)>{};
    for (final r in reactions) {
      final prev = agg[r.emoji] ?? (0, false);
      final mine = prev.$2 || (myPub58 != null && r.reactorPub == myPub58);
      agg[r.emoji] = (prev.$1 + 1, mine);
    }
    final entries = agg.entries.toList()
      ..sort((a, b) => b.value.$1.compareTo(a.value.$1));

    return Padding(
      padding: EdgeInsets.only(
        top: 2,
        bottom: 4,
        left: isMe ? 0 : 12,
        right: isMe ? 12 : 0,
      ),
      child: Wrap(
        alignment: isMe ? WrapAlignment.end : WrapAlignment.start,
        spacing: 4,
        runSpacing: 4,
        children: entries.map((e) {
          final emoji = e.key;
          final (count, mine) = e.value;
          return GestureDetector(
            onTap: onTap != null ? () => onTap!(emoji) : null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: mine
                    ? const Color(0xFF2AABEE).withAlpha(60)
                    : Colors.white12,
                borderRadius: BorderRadius.circular(12),
                border: mine
                    ? Border.all(color: const Color(0xFF2AABEE), width: 1)
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(emoji, style: const TextStyle(fontSize: 13)),
                  if (count > 1) ...[
                    const SizedBox(width: 3),
                    Text('$count',
                        style: TextStyle(
                          color: mine
                              ? const Color(0xFF2AABEE)
                              : Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        )),
                  ],
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ── Status tick ───────────────────────────────────────────────────────────────

class _StatusTick extends StatelessWidget {
  final MessageStatus status;
  const _StatusTick({required this.status});

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case MessageStatus.queued:
        return const Icon(Icons.access_time, size: 14, color: _kTick1);
      case MessageStatus.sent:
        return const Icon(Icons.check, size: 14, color: _kTick1);
      case MessageStatus.received:
        // Packet buffered on recipient's device, app was closed
        return const Icon(Icons.check, size: 14, color: Color(0xFF4CAF50));
      case MessageStatus.delivered:
        return const _DoubleTick(color: _kTick1);
      case MessageStatus.read:
        return const _DoubleTick(color: _kTick2);
    }
  }
}

class _DoubleTick extends StatelessWidget {
  final Color color;
  const _DoubleTick({required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 18,
      height: 14,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            child: Icon(Icons.check, size: 14, color: color),
          ),
          Positioned(
            left: 4,
            child: Icon(Icons.check, size: 14, color: color),
          ),
        ],
      ),
    );
  }
}

// ── Expiry badge ──────────────────────────────────────────────────────────────

class _ExpiryBadge extends StatelessWidget {
  final int expiresAt; // unix seconds
  const _ExpiryBadge({required this.expiresAt});

  @override
  Widget build(BuildContext context) {
    final remaining = expiresAt - DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final label = _label(remaining);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.timer_outlined,
          size: 11,
          color: remaining < 300 ? const Color(0xFFEF5350) : Colors.white38,
        ),
        const SizedBox(width: 2),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: remaining < 300 ? const Color(0xFFEF5350) : Colors.white38,
          ),
        ),
      ],
    );
  }

  static String _label(int seconds) {
    if (seconds <= 0) return '0s';
    if (seconds < 60) return '${seconds}s';
    if (seconds < 3600) return '${seconds ~/ 60}m';
    if (seconds < 86400) return '${seconds ~/ 3600}h';
    return '${seconds ~/ 86400}d';
  }
}

// ── Image preview ─────────────────────────────────────────────────────────────

class _ImagePreview extends StatefulWidget {
  final int messageId;
  final dynamic fileSvc;
  final dynamic storage;

  const _ImagePreview({
    super.key,
    required this.messageId,
    required this.fileSvc,
    required this.storage,
  });

  @override
  State<_ImagePreview> createState() => _ImagePreviewState();
}

class _ImagePreviewState extends State<_ImagePreview> {
  Uint8List? _bytes;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (widget.fileSvc == null || widget.storage == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final record = await widget.storage.files.forMessage(widget.messageId);
      if (record != null) {
        final bytes = await widget.fileSvc.decryptFile(record);
        if (mounted) setState(() { _bytes = bytes; _loading = false; });
        return;
      }
      AppLogger.w('ImagePreview', 'no FileRecord for messageId=${widget.messageId}');
    } catch (e, st) {
      AppLogger.e('ImagePreview', 'load error', error: e, stack: st);
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        width: 160,
        height: 120,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_bytes == null) return const Icon(Icons.broken_image_outlined, size: 48);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.memory(_bytes!, width: 200, fit: BoxFit.cover),
    );
  }
}

// ── Reply preview (quote in bubble) ───────────────────────────────────────

/// Compact quote shown inside a message bubble when replyToId is set.
class ReplyBubble extends StatefulWidget {
  final String replyToId;
  final dynamic storage;

  const ReplyBubble({
    super.key,
    required this.replyToId,
    required this.storage,
  });

  @override
  State<ReplyBubble> createState() => _ReplyBubbleState();
}

class _ReplyBubbleState extends State<ReplyBubble> {
  String? _body;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (widget.storage == null) { setState(() => _loaded = true); return; }
    try {
      final msg = await widget.storage.messages.findByMessageId(widget.replyToId);
      if (mounted) setState(() { _body = msg?.body; _loaded = true; });
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox(height: 24, width: 80,
        child: Center(child: SizedBox(width: 12, height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.5))));
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(6),
        border: const Border(left: BorderSide(color: Color(0xFF2AABEE), width: 3)),
      ),
      child: Text(
        _body ?? '…',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white54, fontSize: 12),
      ),
    );
  }
}

/// Reply bar shown above the input field when user taps "Reply".
class ReplyInputBar extends StatelessWidget {
  final String replyBody;
  final VoidCallback onCancel;

  const ReplyInputBar({
    super.key,
    required this.replyBody,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1C2733),
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      child: Row(
        children: [
          const Icon(Icons.reply, color: Color(0xFF2AABEE), size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(context.l10n.reply,
                    style: const TextStyle(color: Color(0xFF2AABEE), fontSize: 12,
                        fontWeight: FontWeight.w600)),
                Text(replyBody, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white54, fontSize: 12)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white38, size: 20),
            onPressed: onCancel,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }
}

// ── Video circle progress (receiving) ─────────────────────────────────────

class _VideoCircleProgress extends StatelessWidget {
  final double progress;
  final VoidCallback? onCancel;
  const _VideoCircleProgress({required this.progress, this.onCancel});

  @override
  Widget build(BuildContext context) {
    const size = 200.0;
    return SizedBox(
      width: size, height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Фон круга
          Container(
            width: size, height: size,
            decoration: const BoxDecoration(
              color: Color(0xFF1C2733),
              shape: BoxShape.circle,
            ),
          ),
          // Прогресс-кольцо
          SizedBox(
            width: size, height: size,
            child: CircularProgressIndicator(
              value: progress,
              strokeWidth: 4,
              backgroundColor: Colors.white12,
              valueColor: const AlwaysStoppedAnimation(Color(0xFF2AABEE)),
            ),
          ),
          // Крестик отмены в центре
          if (onCancel != null)
            GestureDetector(
              onTap: onCancel,
              child: Container(
                width: 44, height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black.withValues(alpha: 0.45),
                ),
                child: const Icon(Icons.close, color: Colors.white, size: 24),
              ),
            ),
          // Процент снизу
          Positioned(
            bottom: 36,
            child: Text(
              '${(progress * 100).toInt()}%',
              style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Audio progress (sending/receiving) ────────────────────────────────────

class _AudioProgress extends StatelessWidget {
  final double progress;
  final bool isMe;
  final VoidCallback? onCancel;
  const _AudioProgress({required this.progress, required this.isMe, this.onCancel});

  @override
  Widget build(BuildContext context) {
    final activeColor = isMe ? Colors.white : const Color(0xFF2AABEE);
    final trackColor  = isMe ? Colors.white24 : Colors.white12;
    final pct = (progress * 100).toInt();

    return SizedBox(
      width: 220,
      child: Row(
        children: [
          // Заглушка кнопки play (неактивна пока грузится)
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: activeColor.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: CircularProgressIndicator(
                strokeWidth: 2, color: activeColor,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 3,
                    backgroundColor: trackColor,
                    valueColor: AlwaysStoppedAnimation(activeColor),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '$pct%',
                  style: TextStyle(
                      color: activeColor.withValues(alpha: 0.7), fontSize: 11),
                ),
              ],
            ),
          ),
          if (onCancel != null) ...[
            const SizedBox(width: 4),
            GestureDetector(
              onTap: onCancel,
              child: Icon(Icons.close,
                  color: activeColor.withValues(alpha: 0.7), size: 18),
            ),
          ],
        ],
      ),
    );
  }
}

// ── File progress (sending/receiving) ─────────────────────────────────────

class _FileProgressWidget extends StatelessWidget {
  final String fileName;
  final double progress;
  final bool   isImage;
  final VoidCallback? onCancel;

  const _FileProgressWidget({
    required this.fileName,
    required this.progress,
    required this.isImage,
    this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final pct = (progress * 100).toInt();
    return Container(
      width: 200,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isImage ? Icons.image : Icons.insert_drive_file,
                color: const Color(0xFF52B8EA), size: 28,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  fileName,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 4,
              backgroundColor: Colors.white12,
              valueColor: const AlwaysStoppedAnimation(Color(0xFF2AABEE)),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(
                '$pct%',
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
              if (onCancel != null) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: onCancel,
                  child: const Icon(Icons.close, color: Colors.white38, size: 16),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

// ── File preview ──────────────────────────────────────────────────────────

class _FilePreview extends StatefulWidget {
  final int messageId;
  final String fileName;
  final dynamic fileSvc;
  final dynamic storage;

  const _FilePreview({
    super.key,
    required this.messageId,
    required this.fileName,
    required this.fileSvc,
    required this.storage,
  });

  @override
  State<_FilePreview> createState() => _FilePreviewState();
}

class _FilePreviewState extends State<_FilePreview> {
  bool _loading = false;

  IconData get _icon {
    final ext = widget.fileName.split('.').last.toLowerCase();
    return switch (ext) {
      'pdf' => Icons.picture_as_pdf,
      'doc' || 'docx' => Icons.description,
      'xls' || 'xlsx' => Icons.table_chart,
      'zip' || 'rar' || '7z' => Icons.folder_zip,
      'mp4' || 'avi' || 'mov' || 'mkv' => Icons.videocam,
      'mp3' || 'ogg' || 'wav' || 'aac' => Icons.audiotrack,
      'apk' => Icons.android,
      _ => Icons.insert_drive_file,
    };
  }

  Future<void> _open() async {
    if (_loading || widget.fileSvc == null || widget.storage == null) return;
    setState(() => _loading = true);
    try {
      final record = await widget.storage.files.forMessage(widget.messageId);
      if (record == null) return;
      final bytes = await widget.fileSvc.decryptFile(record);
      final dir = await getTemporaryDirectory();
      final tmpPath = '${dir.path}/${widget.fileName}';
      await File(tmpPath).writeAsBytes(bytes);
      await OpenFilex.open(tmpPath);
    } catch (e) {
      AppLogger.e('FilePreview', 'open error', error: e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _open,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_icon, color: const Color(0xFF52B8EA), size: 36),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.fileName,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    widget.fileName.split('.').last.toUpperCase(),
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                ],
              ),
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child: SizedBox(
                  width: 20, height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ── Input bar ─────────────────────────────────────────────────────────────────

class ChatInputBar extends StatefulWidget {
  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;
  final VoidCallback? onAttach;
  /// Called when user records and releases a voice message.
  final Future<void> Function(File audioFile)? onVoiceSend;
  /// Called when user records a video circle.
  final Future<void> Function(File videoFile)? onVideoCircleSend;

  const ChatInputBar({
    super.key,
    required this.controller,
    required this.sending,
    required this.onSend,
    this.onAttach,
    this.onVoiceSend,
    this.onVideoCircleSend,
  });

  @override
  State<ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<ChatInputBar> {
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    super.dispose();
  }

  void _onTextChanged() {
    final has = widget.controller.text.isNotEmpty;
    if (has != _hasText) setState(() => _hasText = has);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1C2733),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // Attach button — only when there's a handler
              if (widget.onAttach != null)
                IconButton(
                  onPressed: widget.sending ? null : widget.onAttach,
                  icon: const Icon(Icons.attach_file, color: Colors.white54),
                  tooltip: context.l10n.selectFileType,
                ),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF253341),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: TextField(
                    controller: widget.controller,
                    minLines: 1,
                    maxLines: 6,
                    textInputAction: TextInputAction.newline,
                    style: const TextStyle(color: Colors.white, fontSize: 15),
                    decoration: InputDecoration(
                      hintText: context.l10n.messageHint,
                      hintStyle: const TextStyle(color: Colors.white38),
                      border: InputBorder.none,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Send / mic button
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                transitionBuilder: (child, anim) =>
                    ScaleTransition(scale: anim, child: child),
                child: _hasText
                    ? _SendButton(
                        key: const ValueKey('send'),
                        sending: widget.sending,
                        onSend: widget.onSend,
                      )
                    : widget.onVoiceSend != null
                        ? VoiceRecordButton(
                            key: const ValueKey('mic'),
                            disabled: widget.sending,
                            onVoiceSend: widget.onVoiceSend!,
                            onVideoSend: widget.onVideoCircleSend,
                          )
                        : const _MicPlaceholder(key: ValueKey('mic')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  final bool sending;
  final VoidCallback onSend;
  const _SendButton({super.key, required this.sending, required this.onSend});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: sending ? null : onSend,
      child: Container(
        width: 44,
        height: 44,
        decoration: const BoxDecoration(
          color: Color(0xFF2AABEE),
          shape: BoxShape.circle,
        ),
        child: sending
            ? const Padding(
                padding: EdgeInsets.all(12),
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white),
              )
            : const Icon(Icons.send_rounded, color: Colors.white, size: 22),
      ),
    );
  }
}

class _MicPlaceholder extends StatelessWidget {
  const _MicPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: const BoxDecoration(
        color: Color(0xFF2AABEE),
        shape: BoxShape.circle,
      ),
      child: const Icon(Icons.mic_rounded, color: Colors.white, size: 22),
    );
  }
}
