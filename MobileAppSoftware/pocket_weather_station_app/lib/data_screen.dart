import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'ble_service.dart';
import 'weather_data.dart';

/// Live "glorified OLED" view of the device's current readings. Subscribes to
/// the DATA characteristic via [WeatherBleService] and renders everything the
/// firmware sends, with a color-coded alert banner and a locally live-ticking
/// uptime. Pops back to the connection screen if the device disconnects.
class DataScreen extends StatefulWidget {
  const DataScreen({super.key, required this.service});

  final WeatherBleService service;

  @override
  State<DataScreen> createState() => _DataScreenState();
}

class _DataScreenState extends State<DataScreen> {
  WeatherData? _data;

  /// Uptime anchor: the last received `up_s` and the wall-clock instant it
  /// arrived. Displayed uptime = anchor + (now − anchorWall), ticked every 1 s.
  int _anchorUpS = 0;
  DateTime _anchorWall = DateTime.now();

  Timer? _ticker;
  StreamSubscription<WeatherData>? _dataSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  bool _popped = false;

  @override
  void initState() {
    super.initState();

    _applyData(widget.service.lastData);

    _dataSub = widget.service.dataStream.listen((data) {
      if (mounted) setState(() => _applyData(data));
    });

    _connSub = widget.service.connectionState?.listen((state) {
      if (state == BluetoothConnectionState.disconnected) _leave();
    });

    // Re-render once per second so the uptime display keeps ticking between
    // the device's 5-minute updates.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void _applyData(WeatherData? data) {
    if (data == null) return;
    _data = data;
    _anchorUpS = data.uptimeSeconds;
    _anchorWall = DateTime.now();
  }

  /// Live uptime in seconds, extrapolated from the anchor.
  int get _liveUptimeSec =>
      _anchorUpS + DateTime.now().difference(_anchorWall).inSeconds;

  void _leave() {
    if (_popped || !mounted) return;
    _popped = true;
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _dataSub?.cancel();
    _connSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Leaving this screen means we're done with this connection; drop it so
      // the connection screen starts a fresh scan. Mark _popped first so the
      // connection-state listener's _leave() can't pop a second time.
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          _popped = true;
          widget.service.disconnect();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: const Text('Pocket Weather Station'),
        ),
        body: _data == null ? _waiting() : _content(_data!),
      ),
    );
  }

  Widget _waiting() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Waiting for the first reading…'),
        ],
      ),
    );
  }

  Widget _content(WeatherData d) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            _AlertBanner(alert: d.alert),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _ReadingCard(
                    icon: Icons.thermostat,
                    label: 'Temperature',
                    value: d.temperature.toStringAsFixed(1),
                    unit: '°C',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _ReadingCard(
                    icon: Icons.speed,
                    label: 'Pressure',
                    value: d.pressure.toStringAsFixed(2),
                    unit: 'hPa',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _ReadingCard(
                    icon: Icons.water_drop,
                    label: 'Humidity',
                    value: d.humidity.toStringAsFixed(1),
                    unit: '%',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _ReadingCard(
                    icon: _batteryIcon(d.battery),
                    label: 'Battery',
                    value: '${d.battery}',
                    unit: '%',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _DropsCard(data: d),
            const SizedBox(height: 12),
            _UptimeCard(uptimeSeconds: _liveUptimeSec),
          ],
        ),
      ),
    );
  }

  IconData _batteryIcon(int pct) {
    if (pct >= 80) return Icons.battery_full;
    if (pct >= 50) return Icons.battery_5_bar;
    if (pct >= 20) return Icons.battery_3_bar;
    return Icons.battery_alert;
  }
}

/// Full-width color-coded alert banner driven by the firmware's alert level.
class _AlertBanner extends StatelessWidget {
  const _AlertBanner({required this.alert});

  final AlertLevel alert;

  String get _description {
    switch (alert) {
      case AlertLevel.clear:
        return 'No storm indicators.';
      case AlertLevel.watch:
        return 'Conditions worth watching.';
      case AlertLevel.warning:
        return 'Storm developing — stay alert.';
      case AlertLevel.severe:
        return 'Severe storm risk — take shelter.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
      decoration: BoxDecoration(
        color: alert.background,
        border: Border.all(color: alert.color, width: 2),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Icon(alert.icon, size: 40, color: alert.color),
          const SizedBox(height: 8),
          Text(
            alert.label,
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              letterSpacing: 2,
              color: alert.color,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _description,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: alert.color),
          ),
        ],
      ),
    );
  }
}

/// A single labelled reading tile (temperature, pressure, …).
class _ReadingCard extends StatelessWidget {
  const _ReadingCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.unit,
  });

  final IconData icon;
  final String label;
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: Colors.blueGrey),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: const TextStyle(fontSize: 13, color: Colors.black54),
                ),
              ],
            ),
            const SizedBox(height: 10),
            RichText(
              text: TextSpan(
                style: DefaultTextStyle.of(context).style,
                children: [
                  TextSpan(
                    text: value,
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  TextSpan(
                    text: ' $unit',
                    style: const TextStyle(fontSize: 15, color: Colors.black54),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Card showing the two pressure-drop trends, or a "ready in ~X min" countdown
/// while the device's history buffer is still warming up.
class _DropsCard extends StatelessWidget {
  const _DropsCard({required this.data});

  final WeatherData data;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Pressure trends',
              style: TextStyle(fontSize: 13, color: Colors.black54),
            ),
            const SizedBox(height: 12),
            _dropRow('3-hour drop', data.drop3hReady, data.drop3h,
                data.drop3hReadyInMin),
            const Divider(height: 24),
            _dropRow('30-minute drop', data.drop30mReady, data.drop30m,
                data.drop30mReadyInMin),
          ],
        ),
      ),
    );
  }

  Widget _dropRow(String label, bool ready, double drop, int readyInMin) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontSize: 15)),
        ready
            ? Text(
                '${drop.toStringAsFixed(2)} hPa',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              )
            : Row(
                children: [
                  const Icon(Icons.hourglass_bottom,
                      size: 16, color: Colors.orange),
                  const SizedBox(width: 4),
                  Text(
                    'Trend ready in ~$readyInMin min',
                    style: const TextStyle(fontSize: 13, color: Colors.orange),
                  ),
                ],
              ),
      ],
    );
  }
}

/// Card showing the live-ticking device uptime.
class _UptimeCard extends StatelessWidget {
  const _UptimeCard({required this.uptimeSeconds});

  final int uptimeSeconds;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.timer_outlined, color: Colors.blueGrey),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Device has been working for',
                    style: TextStyle(fontSize: 13, color: Colors.black54),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    formatUptime(uptimeSeconds),
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
