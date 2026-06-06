import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'weather_data.dart';

/// Thin wrapper around [FlutterLocalNotificationsPlugin] for posting a local
/// notification whenever the storm-alert level changes.
///
/// This is a *local* notification: the OS shows it while the app is running and
/// connected over BLE. Background delivery would require a background BLE
/// service, which is out of scope for the MVP.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  static const String _channelId = 'storm_alerts';
  static const String _channelName = 'Storm alerts';
  static const String _channelDescription =
      'Notifies when the storm-alert level changes.';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  /// Initializes the plugin and creates the Android channel. Safe to call once
  /// at startup. Also requests the Android 13+ notification permission.
  Future<void> init() async {
    if (_initialized) return;

    const androidInit =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: androidInit);
    await _plugin.initialize(settings: settings);

    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      await android.createNotificationChannel(
        const AndroidNotificationChannel(
          _channelId,
          _channelName,
          description: _channelDescription,
          importance: Importance.high,
        ),
      );
      // Android 13+ runtime permission; no-op on older versions.
      await android.requestNotificationsPermission();
    }

    _initialized = true;
  }

  /// Posts a notification describing the transition from [from] to [to].
  Future<void> showAlertChange(AlertLevel from, AlertLevel to) async {
    if (!_initialized) await init();

    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDescription,
        importance: Importance.high,
        priority: Priority.high,
        color: to.color,
        ticker: 'Alert: ${to.label}',
      ),
    );

    await _plugin.show(
      id: 0, // reuse the same id so each change replaces the previous notification
      title: '${_emoji(to)} Storm alert: ${to.label}',
      body: _body(from, to),
      notificationDetails: details,
    );
  }

  /// Emoji that signals the severity of an alert level at a glance.
  String _emoji(AlertLevel level) {
    switch (level) {
      case AlertLevel.clear:
        return '✅';
      case AlertLevel.watch:
        return '👀';
      case AlertLevel.warning:
        return '⚠️';
      case AlertLevel.severe:
        return '⛈️';
      case AlertLevel.unknown:
        return '❓';
    }
  }

  String _body(AlertLevel from, AlertLevel to) {
    // First real verdict after warmup: the device was UNKNOWN, now it knows.
    if (from == AlertLevel.unknown) {
      return 'Conditions have been established: ${to.label}.';
    }
    if (to == AlertLevel.clear) {
      return '✅ Conditions have cleared (was ${from.label}).';
    }
    if (to.code > from.code) {
      return '🔺 Alert escalated from ${from.label} to ${to.label}.';
    }
    return '🔽 Alert eased from ${from.label} to ${to.label}.';
  }
}
