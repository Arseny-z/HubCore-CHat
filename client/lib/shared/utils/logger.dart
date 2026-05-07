import 'dart:developer' as dev;
import 'package:flutter/foundation.dart';

import 'file_logger.dart';

/// Centralized logger for HubCore Chat.
///
/// All output goes to:
///   - dart:developer (visible in IDE / logcat as flutter)
///   - FileLogger → /data/data/com.hubcore.chat/files/hubcore.log
///
/// Levels: d=DEBUG, i=INFO, w=WARN, e=ERROR
abstract final class AppLogger {

  static void d(String tag, String message) {
    if (kDebugMode) {
      dev.log(message, name: tag, level: 500);
    }
    FileLogger.write('D', tag, message);
  }

  static void i(String tag, String message) {
    if (kDebugMode) {
      dev.log(message, name: tag, level: 800);
    }
    FileLogger.write('I', tag, message);
  }

  static void w(String tag, String message, {Object? error}) {
    if (kDebugMode) {
      dev.log(message, name: tag, level: 900, error: error);
    }
    FileLogger.write('W', tag, message, error: error);
  }

  static void e(String tag, String message, {Object? error, StackTrace? stack}) {
    dev.log(message, name: tag, level: 1000, error: error, stackTrace: stack);
    FileLogger.write('E', tag, message, error: error);
    if (stack != null) FileLogger.write('E', tag, stack.toString());
  }
}
