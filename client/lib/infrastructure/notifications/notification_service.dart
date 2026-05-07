import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Thin wrapper around flutter_local_notifications.
///
/// Call [init] once at app startup (after unlock).
/// Call [showMessage] when a new message arrives via WS or polling.
class NotificationService {
  static final NotificationService _instance = NotificationService._();
  factory NotificationService() => _instance;
  NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  static const _channelId       = 'hubcore_messages';
  static const _channelName     = 'Messages';
  static const _channelSilentId   = 'hubcore_strangers';
  static const _channelSilentName = 'New conversations';

  Future<void> init() async {
    if (_initialized) return;

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: android);

    await _plugin.initialize(settings);

    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    await androidPlugin?.requestNotificationsPermission();

    // Regular channel — contacts
    const channel = AndroidNotificationChannel(
      _channelId,
      _channelName,
      importance: Importance.high,
      enableVibration: true,
    );
    await androidPlugin?.createNotificationChannel(channel);

    // Silent channel — strangers (no sound, no vibration)
    const silentChannel = AndroidNotificationChannel(
      _channelSilentId,
      _channelSilentName,
      importance: Importance.low,
      enableVibration: false,
      playSound: false,
    );
    await androidPlugin?.createNotificationChannel(silentChannel);

    _initialized = true;
  }

  /// Show a notification for a new message.
  ///
  /// Set [silent] = true for strangers — uses a low-importance channel
  /// with no sound or vibration.
  Future<void> showMessage({
    required String senderLabel,
    String body = 'New message',
    bool silent = false,
  }) async {
    if (!_initialized) return;

    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        silent ? _channelSilentId : _channelId,
        silent ? _channelSilentName : _channelName,
        importance: silent ? Importance.low : Importance.high,
        priority: silent ? Priority.low : Priority.high,
        playSound: !silent,
        enableVibration: !silent,
      ),
    );

    await _plugin.show(
      senderLabel.hashCode & 0x7FFFFFFF,
      senderLabel,
      body,
      details,
    );
  }
}
