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
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.satellite_alt, size: 48, color: Colors.blueGrey),
            const SizedBox(height: 16),
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            const Text(
              'Waiting for the GPS fix to take first measurement*',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 8),
            const Text(
              'GPS fix is necessary for the proper work of storm prediction algorithm',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }

  Widget _content(WeatherData d) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            _AlertBanner(alert: d.alert, readyInMin: d.drop30mReadyInMin),
            const SizedBox(height: 12),
            // stretch + IntrinsicHeight: both tiles in the row grow to the
            // taller one's height so single-line tiles match the 2-line GPS tile.
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
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
            ),
            const SizedBox(height: 12),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
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
            ),
            const SizedBox(height: 12),
            // GPS (under Humidity) + Altitude (under Battery). Both derive from
            // the firmware's GPS fields; show placeholders when there's no fix.
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _GpsCard(data: d)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _ReadingCard(
                      icon: Icons.terrain,
                      label: 'Altitude',
                      value: d.hasFix ? d.altitude.toStringAsFixed(0) : '—',
                      unit: d.hasFix ? 'm' : '',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // Altitude-corrected trends first (the values the alert algorithm
            // actually uses), then the raw trends below for comparison.
            _DropsCard(
              title: 'Altitude-corrected Pressure trends',
              subtitle: d.hasFix
                  ? 'Altitude correction active (GPS fix)'
                  : 'No GPS fix — showing raw fallback',
              subtitleColor: d.hasFix
                  ? const Color(0xFF0D47A1) // dark blue: correction active
                  : const Color(0xFFB71C1C), // dark red: no fix, raw fallback
              data: d,
              drop3h: d.corrDrop3h,
              drop30m: d.corrDrop30m,
            ),
            const SizedBox(height: 12),
            _DropsCard(
              title: 'Pressure trends',
              data: d,
              drop3h: d.drop3h,
              drop30m: d.drop30m,
            ),
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
/// While the level is UNKNOWN (device warming up) it shows a "?" banner with a
/// countdown to when the first real verdict becomes available.
class _AlertBanner extends StatelessWidget {
  const _AlertBanner({required this.alert, required this.readyInMin});

  final AlertLevel alert;

  /// Minutes until the 30-min window becomes valid; only used for UNKNOWN.
  final int readyInMin;

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
      case AlertLevel.unknown:
        return readyInMin > 0
            ? 'Establishing conditions… known in ~$readyInMin min.'
            : 'Establishing conditions…';
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
            // UNKNOWN's countdown line matches the Drops "ready in ~X min" orange.
            style: TextStyle(
              fontSize: 14,
              color: alert == AlertLevel.unknown ? Colors.orange : alert.color,
            ),
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
            // scaleDown keeps value+unit on one line; 4-digit pressures shrink
            // slightly instead of wrapping "hPa" below (which enlarged the tile).
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: RichText(
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
                      style:
                          const TextStyle(fontSize: 15, color: Colors.black54),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tile showing the current GPS latitude/longitude, styled like [_ReadingCard].
/// Shows a "No fix" placeholder until the firmware reports a fix.
class _GpsCard extends StatelessWidget {
  const _GpsCard({required this.data});

  final WeatherData data;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: const [
                Icon(Icons.location_on, size: 20, color: Colors.blueGrey),
                SizedBox(width: 6),
                Text(
                  'GPS',
                  style: TextStyle(fontSize: 13, color: Colors.black54),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (data.hasFix) ...[
              // Fixed-width "Lat:"/"Lon:" labels so both numbers start at the
              // same x — the first digits line up in one column.
              _coordRow('Lat:', data.latitude),
              const SizedBox(height: 2),
              _coordRow('Lon:', data.longitude),
            ] else
              const Text(
                'No fix',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.black38,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// One coordinate line: a fixed-width label cell + the value, so the values
  /// of consecutive rows line up at the same starting column.
  Widget _coordRow(String label, double value) {
    const style = TextStyle(fontSize: 16, fontWeight: FontWeight.bold);
    return Row(
      children: [
        SizedBox(width: 38, child: Text(label, style: style)),
        Text(value.toStringAsFixed(5), style: style),
      ],
    );
  }
}

/// Card showing two pressure-drop trends (raw or altitude-corrected), or a
/// "ready in ~X min" countdown while the device's history buffer is still
/// warming up. The warmup window is shared by both raw and corrected drops, so
/// the ready flags come from [data] while the displayed values are passed in.
class _DropsCard extends StatelessWidget {
  const _DropsCard({
    required this.title,
    required this.data,
    required this.drop3h,
    required this.drop30m,
    this.subtitle,
    this.subtitleColor = Colors.black54,
  });

  final String title;
  final WeatherData data;
  final double drop3h;
  final double drop30m;
  final String? subtitle;
  final Color subtitleColor;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 13,
                color: Colors.black54,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(
                subtitle!,
                style: TextStyle(fontSize: 12, color: subtitleColor),
              ),
            ],
            const SizedBox(height: 12),
            _dropRow('3-hour drop', data.drop3hReady, drop3h,
                data.drop3hReadyInMin),
            const Divider(height: 24),
            _dropRow('30-minute drop', data.drop30mReady, drop30m,
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
