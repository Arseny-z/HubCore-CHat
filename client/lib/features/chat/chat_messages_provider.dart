import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/events/app_event_bus.dart';
import '../../shared/providers/app_providers.dart';
import '../../shared/utils/pubkey_codec.dart';

/// Immutable view-model emitted by [chatMessagesProvider].
class ChatMessagesState {
  /// Messages ordered oldest-first (UI renders top-down, latest at bottom).
  final List<Message> messages;

  /// outbound messageId → (delivered, total) for group N/M ticks and
  /// per-recipient detail sheet.
  final Map<String, (int, int)> deliveryCounts;

  /// pending messageId → (attempts, maxAttempts) for retry counter UI.
  final Map<String, (int, int)> queueAttempts;

  /// More older messages exist on disk — page-up loads them.
  final bool hasMore;

  /// Page-up request currently in flight.
  final bool loadingMore;

  const ChatMessagesState({
    this.messages = const [],
    this.deliveryCounts = const {},
    this.queueAttempts = const {},
    this.hasMore = false,
    this.loadingMore = false,
  });

  ChatMessagesState copyWith({
    List<Message>? messages,
    Map<String, (int, int)>? deliveryCounts,
    Map<String, (int, int)>? queueAttempts,
    bool? hasMore,
    bool? loadingMore,
  }) =>
      ChatMessagesState(
        messages: messages ?? this.messages,
        deliveryCounts: deliveryCounts ?? this.deliveryCounts,
        queueAttempts: queueAttempts ?? this.queueAttempts,
        hasMore: hasMore ?? this.hasMore,
        loadingMore: loadingMore ?? this.loadingMore,
      );
}

/// AsyncNotifier that owns the message list, delivery counts and queue
/// attempts for a single conversation.
///
/// On [build] it does the initial DB fetch and subscribes to [AppEventBus]:
///   - [MessageReceivedEvent] / [MessagesDeletedEvent] / [FileTransferProgressEvent]
///     (done=true) → full re-query (new rows must be pulled from DB)
///   - [MessageStatusUpdatedEvent] → in-place patch of the matching message
///   - [MessageRetryUpdatedEvent] → in-place patch of [queueAttempts]
///
/// [loadMore] prepends the next page of older messages.
class ChatMessagesNotifier
    extends AutoDisposeFamilyAsyncNotifier<ChatMessagesState, String> {
  static const _kPageSize = 50;

  @override
  Future<ChatMessagesState> build(String convId) async {
    final initial = await _fetch(convId);

    final bus = ref.read(eventBusProvider);
    final subs = <StreamSubscription>[];

    subs.add(bus
        .on<MessageReceivedEvent>()
        .where((e) => e.conversationId == convId)
        .listen((_) => _refresh(convId)));

    subs.add(bus
        .on<MessagesDeletedEvent>()
        .where((e) => e.conversationIds.contains(convId))
        .listen((_) => _refresh(convId)));

    subs.add(bus
        .on<FileTransferProgressEvent>()
        .where((e) => e.done)
        .listen((_) => _refresh(convId)));

    subs.add(bus
        .on<MessageStatusUpdatedEvent>()
        .listen((e) => _patchStatus(convId, e)));

    subs.add(bus
        .on<MessageRetryUpdatedEvent>()
        .listen(_patchRetry));

    ref.onDispose(() {
      for (final s in subs) {
        s.cancel();
      }
    });

    return initial;
  }

  Future<ChatMessagesState> _fetch(String convId) async {
    final storage = ref.read(storageProvider);
    if (!storage.isOpen) return const ChatMessagesState();

    final identity = ref.read(identityNotifierProvider);
    final myPub58 = identity != null
        ? PubkeyCodec.encode(identity.masterPublicKey)
        : '';

    final raw = await storage.messages
        .forConversation(convId, limit: _kPageSize);

    final counts = <String, (int, int)>{};
    for (final m in raw) {
      if (m.senderPub == myPub58 && m.messageId != null) {
        final c = await storage.messageReceipts.deliveryCount(m.messageId!);
        if (c.$2 > 0) counts[m.messageId!] = c;
      }
    }

    final queueEntries = await storage.sendQueue.allPending();
    final queueMap = <String, (int, int)>{};
    for (final e in queueEntries) {
      if (e.ackPending == 1 || e.attempts > 0) {
        queueMap[e.messageId] = (e.attempts, e.maxAttempts);
      }
    }

    return ChatMessagesState(
      messages: raw.reversed.toList(),
      deliveryCounts: counts,
      queueAttempts: queueMap,
      hasMore: raw.length >= _kPageSize,
    );
  }

  Future<void> _refresh(String convId) async {
    final fresh = await _fetch(convId);
    final current = state.value;
    state = AsyncData(fresh.copyWith(
      loadingMore: current?.loadingMore ?? false,
    ));
  }

  void _patchStatus(String convId, MessageStatusUpdatedEvent e) {
    final current = state.value;
    if (current == null) return;
    final idx = current.messages.indexWhere((m) => m.id == e.messageDbId);
    if (idx < 0) return;
    final old = current.messages[idx];
    final patched = [...current.messages];
    patched[idx] = Message(
      id: old.id,
      conversationId: old.conversationId,
      isGroup: old.isGroup,
      senderPub: old.senderPub,
      body: old.body,
      contentType: old.contentType,
      sentAt: old.sentAt,
      receivedAt: old.receivedAt,
      status: e.status,
      expiresAt: old.expiresAt,
      messageId: old.messageId,
      replyToId: old.replyToId,
    );
    state = AsyncData(current.copyWith(messages: patched));
    // Queue counter usually disappears on delivered — pull a fresh snapshot
    // so the retry chip vanishes without an extra round-trip from the user.
    _refresh(convId);
  }

  void _patchRetry(MessageRetryUpdatedEvent e) {
    final current = state.value;
    if (current == null) return;
    final next = {...current.queueAttempts};
    if (e.attempts < 0) {
      next.remove(e.messageId);
    } else {
      next[e.messageId] = (e.attempts, e.maxAttempts);
    }
    state = AsyncData(current.copyWith(queueAttempts: next));
  }

  /// Page-up: fetch older messages and prepend.
  Future<void> loadMore(String convId) async {
    final current = state.value;
    if (current == null || current.loadingMore || !current.hasMore) return;
    final oldestId =
        current.messages.isNotEmpty ? current.messages.first.id : null;
    if (oldestId == null) return;

    state = AsyncData(current.copyWith(loadingMore: true));

    final storage = ref.read(storageProvider);
    if (!storage.isOpen) {
      state = AsyncData(current.copyWith(loadingMore: false));
      return;
    }

    final older = await storage.messages.forConversation(
      convId,
      limit: _kPageSize,
      beforeId: oldestId,
    );
    final fresh = state.value;
    if (fresh == null) return;
    state = AsyncData(fresh.copyWith(
      messages: [...older.reversed, ...fresh.messages],
      hasMore: older.length >= _kPageSize,
      loadingMore: false,
    ));
  }

  /// Public reload trigger (e.g. RefreshIndicator).
  Future<void> reload(String convId) => _refresh(convId);
}

final chatMessagesProvider = AsyncNotifierProvider.autoDispose
    .family<ChatMessagesNotifier, ChatMessagesState, String>(
  ChatMessagesNotifier.new,
);
