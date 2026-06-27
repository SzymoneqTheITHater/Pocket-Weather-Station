import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Entry point for the foreground-service isolate. flutter_foreground_task
/// requires a top-level (vm:entry-point) callback that installs a [TaskHandler];
/// ours does nothing but hold the service. The actual BLE work keeps running in
/// the main isolate — the service exists only to keep the process alive.
@pragma('vm:entry-point')
void startMonitoringCallback() {
  FlutterForegroundTask.setTaskHandler(_MonitoringTaskHandler());
}

class _MonitoringTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

/// Thin wrapper around [FlutterForegroundTask] for the "monitoring" foreground
/// service. Started once a BLE connection is established and stopped on an
/// intentional disconnect; it keeps the app's process (and thus the main-isolate
/// BLE listener and the alert notification/SMS path) alive while backgrounded.
class MonitoringService {
  MonitoringService._();

  static const String _channelId = 'pws_monitoring';

  /// Configures the notification channel + task options. Call once at startup.
  static void init() {
    // Registers the port used to talk to the task isolate (harmless even though
    // we don't exchange data — BLE stays in the main isolate).
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: _channelId,
        channelName: 'Monitoring',
        channelDescription:
            'Keeps the connection to the Pocket Weather Station alive.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      // We don't use the repeat callback — BLE stays in the main isolate.
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

  /// Starts the foreground service (no-op if already running).
  static Future<void> start() async {
    if (await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.startService(
      serviceTypes: [ForegroundServiceTypes.connectedDevice],
      notificationTitle: 'Pocket Weather Station',
      notificationText: 'Monitoring',
      callback: startMonitoringCallback,
    );
  }

  /// Updates the persistent notification's body (e.g. "Reconnecting…").
  static Future<void> updateText(String text) async {
    if (!await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.updateService(notificationText: text);
  }

  /// Stops the foreground service (no-op if not running).
  static Future<void> stop() async {
    if (!await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.stopService();
  }
}
