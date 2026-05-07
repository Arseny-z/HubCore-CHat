import 'dart:io';
import 'dart:async';

import 'package:path_provider/path_provider.dart';

/// Writes all log lines to /data/data/com.hubcore.chat/files/hubcore.log
/// File is cleared on [init] (app start). Thread-safe via queue.
class FileLogger {
  static IOSink? _sink;
  static final _queue = StreamController<String>(sync: false);
  static bool _ready = false;

  /// Call once at app startup (before any logging).
  /// Clears the file and opens it for appending.
  static Future<void> init() async {
    try {
      final dir  = await getApplicationSupportDirectory();
      final file = File('${dir.path}/hubcore.log');
      // Overwrite on each launch
      _sink = file.openWrite(mode: FileMode.writeOnly);
      _sink!.writeln('=== HubCore Chat log started ${DateTime.now().toIso8601String()} ===');
      _ready = true;
      // Drain queue on single isolate — no concurrent writes
      _queue.stream.listen((line) {
        try { _sink?.writeln(line); } catch (_) {}
      });
    } catch (e) {
      // Logging not critical — continue without file
    }
  }

  static Future<void> close() async {
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
    _ready = false;
  }

  static void write(String level, String tag, String message, {Object? error}) {
    if (!_ready) return;
    final ts  = _ts();
    final err = error != null ? ' | $error' : '';
    _queue.add('$ts [$level/$tag] $message$err');
  }

  static String _ts() {
    final n = DateTime.now();
    final h  = n.hour.toString().padLeft(2, '0');
    final m  = n.minute.toString().padLeft(2, '0');
    final s  = n.second.toString().padLeft(2, '0');
    final ms = n.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }
}
