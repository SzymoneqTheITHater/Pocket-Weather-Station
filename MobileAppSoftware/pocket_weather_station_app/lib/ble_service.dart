import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'notification_service.dart';
import 'weather_data.dart';

/// Owns the BLE lifecycle for the Pocket Weather Station: discover the device by
/// name, connect, find the DATA characteristic, read the first value, and stream
/// every notification as a parsed [WeatherData].
///
/// The firmware advertises only its name (not the service UUID), so discovery
/// filters on the advertised name rather than `withServices`.
class WeatherBleService {
  static const String deviceName = 'MountainGuide_Weather';
  static final Guid serviceUuid = Guid('5b3e1f00-1c2d-4e3a-9b6f-0a1b2c3d4e5f');
  static final Guid dataCharUuid = Guid('5b3e1f01-1c2d-4e3a-9b6f-0a1b2c3d4e5f');

  final StreamController<WeatherData> _dataController =
      StreamController<WeatherData>.broadcast();

  BluetoothDevice? _device;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<List<int>>? _valueSub;
  Completer<BluetoothDevice?>? _scanCompleter;
  WeatherData? _lastData;

  /// Live stream of parsed readings (notifications + the initial read).
  Stream<WeatherData> get dataStream => _dataController.stream;

  /// The most recent reading, for seeding a fresh [StreamBuilder].
  WeatherData? get lastData => _lastData;

  /// The connected device's connection-state stream (null before connecting).
  Stream<BluetoothConnectionState>? get connectionState =>
      _device?.connectionState;

  /// Runs the full discover → connect → subscribe flow.
  ///
  /// Returns `true` once subscribed to the DATA characteristic. Returns `false`
  /// if the device isn't found (e.g. powered off), if [cancel] is called, or on
  /// any BLE error. Safe to call again after a failure (used by Retry).
  Future<bool> findAndConnect() async {
    try {
      // Drop any reading cached from a previous session so a reconnect to a
      // device that's still GPS-waiting (its DATA value is the "{}" placeholder)
      // doesn't seed the data screen with stale tiles — it should show the
      // "Waiting for GPS fix" screen until the first real reading arrives.
      _lastData = null;

      if (await FlutterBluePlus.isSupported == false) return false;

      // On Android this pops the system "turn Bluetooth on" dialog if it's off.
      try {
        await FlutterBluePlus.turnOn();
      } catch (_) {}
      await FlutterBluePlus.adapterState
          .where((s) => s == BluetoothAdapterState.on)
          .first;

      final device = await _scanForDevice();
      if (device == null) return false;
      _device = device;

      // `License.nonprofit` covers personal / educational use (engineering thesis).
      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 8),
      );

      final services = await device.discoverServices();
      BluetoothCharacteristic? dataChar;
      for (final service in services) {
        for (final c in service.characteristics) {
          if (c.uuid == dataCharUuid) {
            dataChar = c;
            break;
          }
        }
        if (dataChar != null) break;
      }
      if (dataChar == null) {
        await device.disconnect();
        return false;
      }

      // Immediate value so the data screen isn't blank waiting for the next notify.
      try {
        _emit(WeatherData.tryParse(await dataChar.read()));
      } catch (_) {}

      await dataChar.setNotifyValue(true);
      _valueSub = dataChar.onValueReceived.listen((raw) {
        _emit(WeatherData.tryParse(raw));
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  void _emit(WeatherData? data) {
    if (data == null) return;

    // Notify on any change of alert level (but not on the very first reading,
    // when there's nothing to compare against).
    final previous = _lastData;
    if (previous != null && previous.alert != data.alert) {
      NotificationService.instance.showAlertChange(previous.alert, data.alert);
    }

    _lastData = data;
    if (!_dataController.isClosed) _dataController.add(data);
  }

  /// Scans (filtered by name) and completes with the first matching device, or
  /// `null` if [cancel] stops the scan first.
  Future<BluetoothDevice?> _scanForDevice() async {
    final completer = Completer<BluetoothDevice?>();
    _scanCompleter = completer;

    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        if (r.device.platformName == deviceName ||
            r.advertisementData.advName == deviceName) {
          if (!completer.isCompleted) completer.complete(r.device);
          return;
        }
      }
    });

    await FlutterBluePlus.startScan(
      withNames: [deviceName],
      timeout: const Duration(seconds: 12),
    );

    final device = await completer.future;
    await _stopScan();
    return device;
  }

  Future<void> _stopScan() async {
    await _scanSub?.cancel();
    _scanSub = null;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
  }

  /// Aborts an in-progress [findAndConnect] (used by the connection timeout).
  Future<void> cancel() async {
    if (_scanCompleter != null && !_scanCompleter!.isCompleted) {
      _scanCompleter!.complete(null);
    }
    await _stopScan();
  }

  /// Disconnects and tears down subscriptions (keeps the data stream open so the
  /// UI can react; call [dispose] to release everything).
  Future<void> disconnect() async {
    await _stopScan();
    await _valueSub?.cancel();
    _valueSub = null;
    // Forget the last reading so the next session starts clean (see findAndConnect).
    _lastData = null;
    try {
      await _device?.disconnect();
    } catch (_) {}
  }

  Future<void> dispose() async {
    await disconnect();
    await _dataController.close();
  }
}
