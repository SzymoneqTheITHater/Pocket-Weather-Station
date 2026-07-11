import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'monitoring_service.dart';
import 'notification_service.dart';
import 'sms_service.dart';
import 'weather_data.dart';

/// High-level connection status surfaced to the UI. Distinct from the raw BLE
/// connection state: a `disconnected` BLE event that wasn't user-initiated maps
/// to [reconnecting] (the OS keeps auto-reconnecting), not to a teardown.
enum WatchStatus { connecting, connected, reconnecting, disconnected }

/// Owns the BLE lifecycle for the Pocket Weather Station: discover the device by
/// name, connect, find the DATA characteristic, read the first value, and stream
/// every notification as a parsed [WeatherData].
///
/// Connection uses flutter_blue_plus' native `autoConnect`: after the first
/// connection the Android stack transparently reconnects whenever the device is
/// back in range (low power, no scanning), until [disconnect] is called. So an
/// involuntary drop (out of range, device power loss) recovers on its own, while
/// a user-initiated [disconnect] is final. A foreground service started on the
/// first connection keeps the process — and this listener + [_emit] — alive in
/// the background.
///
/// The firmware advertises only its name (not the service UUID), so the initial
/// discovery filters on the advertised name rather than `withServices`.
class WeatherBleService {
  static const String deviceName = 'Pocket-Weather-Station';
  static final Guid serviceUuid = Guid('5b3e1f00-1c2d-4e3a-9b6f-0a1b2c3d4e5f');
  static final Guid dataCharUuid = Guid('5b3e1f01-1c2d-4e3a-9b6f-0a1b2c3d4e5f');

  final StreamController<WeatherData> _dataController =
      StreamController<WeatherData>.broadcast();
  final StreamController<WatchStatus> _statusController =
      StreamController<WatchStatus>.broadcast();

  BluetoothDevice? _device;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<List<int>>? _valueSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  Completer<BluetoothDevice?>? _scanCompleter;

  /// Completes when the first connection finishes discovering + subscribing (or
  /// is aborted), giving [findAndConnect] its bool result for the welcome screen.
  Completer<bool>? _firstConnected;

  WeatherData? _lastData;
  WatchStatus _status = WatchStatus.disconnected;

  /// Set when the user disconnects, so the connection-state listener doesn't
  /// treat the resulting `disconnected` event as an involuntary drop to recover.
  bool _userDisconnected = false;

  /// Whether the foreground service has been started for this session.
  bool _fgsStarted = false;

  /// Wall-clock of the most recent reading that reported a GPS fix. Lets an
  /// alert-change SMS describe how long ago the location was valid when the
  /// current reading has none. Null until the first fix this session.
  DateTime? _lastFixAt;

  /// Live stream of parsed readings (notifications + the initial read).
  Stream<WeatherData> get dataStream => _dataController.stream;

  /// The most recent reading, for seeding a fresh [StreamBuilder].
  WeatherData? get lastData => _lastData;

  /// High-level connection status (connecting / connected / reconnecting / …).
  Stream<WatchStatus> get status => _statusController.stream;
  WatchStatus get statusNow => _status;

  void _setStatus(WatchStatus s) {
    _status = s;
    if (!_statusController.isClosed) _statusController.add(s);
  }

  /// Discovers the device by name and starts an auto-reconnecting connection.
  ///
  /// Returns `true` once the first connection has subscribed to the DATA
  /// characteristic. Returns `false` if the device isn't found (e.g. powered
  /// off), if [cancel] is called / it times out, or on any BLE error. After a
  /// `true` result the connection self-heals via `autoConnect` until [disconnect].
  Future<bool> findAndConnect() async {
    try {
      _userDisconnected = false;
      // Drop any reading cached from a previous session so a reconnect to a
      // device that's still GPS-waiting (its DATA value is the "{}" placeholder)
      // shows the "Waiting for GPS fix" screen until the first real reading.
      _lastData = null;
      _lastFixAt = null;
      _setStatus(WatchStatus.connecting);

      if (await FlutterBluePlus.isSupported == false) {
        _setStatus(WatchStatus.disconnected);
        return false;
      }

      // On Android this pops the system "turn Bluetooth on" dialog if it's off.
      try {
        await FlutterBluePlus.turnOn();
      } catch (_) {}
      await FlutterBluePlus.adapterState
          .where((s) => s == BluetoothAdapterState.on)
          .first;

      final device = await _scanForDevice();
      if (device == null) {
        _setStatus(WatchStatus.disconnected);
        return false;
      }
      _device = device;

      // Listen before connecting so we don't miss the first `connected` event.
      _firstConnected = Completer<bool>();
      await _connSub?.cancel();
      _connSub = device.connectionState.listen(_onConnectionStateChanged);

      // `autoConnect` returns immediately and lets the OS (re)connect whenever
      // the device is in range until `disconnect()`. `mtu` must be null with it;
      // we request the MTU ourselves in [_onConnected]. `License.nonprofit`
      // covers personal / educational use (engineering thesis).
      await device.connect(
        license: License.nonprofit,
        mtu: null,
        autoConnect: true,
      );

      return await _firstConnected!.future;
    } catch (_) {
      _setStatus(WatchStatus.disconnected);
      return false;
    }
  }

  void _onConnectionStateChanged(BluetoothConnectionState state) {
    if (state == BluetoothConnectionState.connected) {
      _onConnected();
    } else if (state == BluetoothConnectionState.disconnected) {
      if (_userDisconnected) return;
      // Involuntary drop — the native autoConnect will reconnect when the device
      // returns. Keep the foreground service up and show "reconnecting".
      _valueSub?.cancel();
      _valueSub = null;
      _setStatus(WatchStatus.reconnecting);
      MonitoringService.updateText('Reconnecting…');
    }
  }

  /// Per-connection setup, run on every (re)connection: request a larger MTU,
  /// (re-)discover services, and (re-)subscribe to the DATA characteristic.
  Future<void> _onConnected() async {
    final device = _device;
    if (device == null) return;
    try {
      // autoConnect skips the automatic MTU request, but the DATA JSON is larger
      // than the 23-byte default; request a bigger one (harmless if unsupported).
      try {
        await device.requestMtu(512);
      } catch (_) {}

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
        _completeFirst(false);
        return;
      }

      // Immediate value so the data screen isn't blank waiting for the next notify.
      try {
        _emit(WeatherData.tryParse(await dataChar.read()));
      } catch (_) {}

      await dataChar.setNotifyValue(true);
      await _valueSub?.cancel();
      _valueSub = dataChar.onValueReceived.listen((raw) {
        _emit(WeatherData.tryParse(raw));
      });

      _setStatus(WatchStatus.connected);

      // Start the foreground service once a connection is established; keep it
      // running through reconnects, stopping only on an intentional disconnect.
      if (!_fgsStarted) {
        _fgsStarted = true;
        await MonitoringService.start();
      }
      await MonitoringService.updateText('Monitoring');

      _completeFirst(true);
    } catch (_) {
      // Setup failed (e.g. dropped mid-discovery). Report failure for the initial
      // attempt; later attempts are retried by the native autoConnect.
      _completeFirst(false);
    }
  }

  void _completeFirst(bool ok) {
    if (_firstConnected != null && !_firstConnected!.isCompleted) {
      _firstConnected!.complete(ok);
    }
  }

  void _emit(WeatherData? data) {
    if (data == null) return;

    // Track when we last had a fix so an alert SMS can say how long ago the
    // location was valid if the current reading has none.
    if (data.hasFix) _lastFixAt = DateTime.now();

    // React to any change of alert level (but not on the very first reading,
    // when there's nothing to compare against).
    final previous = _lastData;
    if (previous != null && previous.alert != data.alert) {
      NotificationService.instance.showAlertChange(previous.alert, data.alert);

      // Text the watchers too, but only for transitions between real verdicts —
      // UNKNOWN is warmup, not a weather verdict.
      if (previous.alert != AlertLevel.unknown &&
          data.alert != AlertLevel.unknown) {
        SmsService.instance
            .sendAlertChange(previous.alert, data.alert, data, _lastFixAt);
      }
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
    _completeFirst(false);
  }

  /// User-initiated disconnect: cancels autoConnect, stops the foreground
  /// service, and tears down subscriptions (keeps the data stream open so the UI
  /// can react; call [dispose] to release everything).
  Future<void> disconnect() async {
    _userDisconnected = true;
    await _stopScan();
    await _connSub?.cancel();
    _connSub = null;
    await _valueSub?.cancel();
    _valueSub = null;
    // Forget the last reading / fix so the next session starts clean.
    _lastData = null;
    _lastFixAt = null;
    try {
      await _device?.disconnect(); // removes the device from the autoConnect set
    } catch (_) {}
    await MonitoringService.stop();
    _fgsStarted = false;
    _setStatus(WatchStatus.disconnected);
  }

  Future<void> dispose() async {
    await disconnect();
    await _statusController.close();
    await _dataController.close();
  }
}
