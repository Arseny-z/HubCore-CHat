import 'dart:async';

import 'app_events.dart';

export 'app_events.dart';

/// Application-wide event bus.
///
/// Use Cases emit events here; UI and other Use Cases subscribe to them.
/// Replaces the fragmented callback fields and multiple streams that
/// previously lived on [MessagingService], [TtlService], and [MessageRouter].
///
/// Usage:
/// ```dart
/// // Emit (from a Use Case):
/// _bus.emit(MessageReceivedEvent(conversationId: pub, ...));
///
/// // Subscribe (from UI):
/// _bus.on<MessageReceivedEvent>()
///     .where((e) => e.conversationId == _contact.masterPub)
///     .listen((_) => _loadMessages());
/// ```
class AppEventBus {
  final _ctrl = StreamController<AppEvent>.broadcast();

  /// All events as a single stream.
  Stream<AppEvent> get stream => _ctrl.stream;

  /// Filtered stream of events of type [T].
  Stream<T> on<T extends AppEvent>() =>
      stream.where((e) => e is T).cast<T>();

  /// Emit [event] to all current listeners.
  void emit(AppEvent event) {
    if (!_ctrl.isClosed) _ctrl.add(event);
  }

  /// Release resources. After [dispose] no further events can be emitted.
  void dispose() => _ctrl.close();
}
