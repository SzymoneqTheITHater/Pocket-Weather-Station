import 'dart:async';

import 'package:flutter/material.dart';

import 'app_chrome.dart';
import 'ble_service.dart';
import 'weather_data.dart';

/// Live "glorified OLED" view of the device's current readings. Subscribes to
/// the DATA characteristic via [WeatherBleService] and renders everything the
/// firmware sends, with a color-coded alert banner and a locally live-ticking
/// uptime. An involuntary disconnect shows a "Reconnecting…" banner (the service
/// auto-reconnects); leaving is user-driven (Disconnect / back).
class DataScreen extends StatefulWidget {
  const DataScreen({super.key, required this.service});

  final WeatherBleService service;

  @override
  State<DataScreen> createState() => _DataScreenState();
}

/// Dark red used to mark stale GPS-derived values once the fix is lost: the GPS
/// and Altitude tile values, plus the corrected-trends "no fix" subtitle.
const Color _kStaleRed = Color(0xFFB71C1C);

class _DataScreenState extends State<DataScreen> {
  WeatherData? _data;

  /// Monitoring-time anchor: the last received `mon_s` and the wall-clock instant
  /// it arrived. Displayed time = anchor + (now − anchorWall), ticked every 1 s.
  int _anchorMonSec = 0;
  DateTime _anchorWall = DateTime.now();

  /// Wall-clock of the most recent frame that reported a GPS fix, used to show
  /// "last known ~N min ago" while the fix is lost. Null until the first fix is
  /// seen this session (e.g. the app connected during an outage), in which case
  /// the minutes are omitted from the subtitle.
  DateTime? _lastFixWall;

  Timer? _ticker;
  StreamSubscription<WeatherData>? _dataSub;
  StreamSubscription<WatchStatus>? _statusSub;

  /// True while the link is down but the service is auto-reconnecting; drives the
  /// "Reconnecting…" banner. The last readings stay on screen meanwhile.
  bool _isReconnecting = false;

  @override
  void initState() {
    super.initState();

    _applyData(widget.service.lastData);

    _dataSub = widget.service.dataStream.listen((data) {
      if (mounted) setState(() => _applyData(data));
    });

    _statusSub = widget.service.status.listen((status) {
      if (!mounted) return;
      setState(() => _isReconnecting = status == WatchStatus.reconnecting);
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
    _anchorMonSec = data.monitoringSeconds;
    _anchorWall = DateTime.now();
    // Remember when we last had a fix so the "no fix" subtitle can say how long
    // ago the shown coordinates/altitude were last valid.
    if (data.hasFix) _lastFixWall = DateTime.now();
  }

  /// Live monitoring time in seconds, extrapolated from the anchor.
  int get _liveMonitoringSec =>
      _anchorMonSec + DateTime.now().difference(_anchorWall).inSeconds;

  /// Subtitle for the altitude-corrected trends card when the GPS fix is lost.
  /// Shows how long ago the displayed values were last valid; if no fix has been
  /// seen this session yet, the minutes are omitted.
  String _noFixSubtitle() {
    final lastFix = _lastFixWall;
    if (lastFix == null) {
      return 'No GPS fix — using last known values';
    }
    final n = (DateTime.now().difference(lastFix).inSeconds / 60).round();
    final minutes = n < 1 ? 1 : n;
    return 'No GPS fix — last known ~$minutes min ago — using last known values';
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _dataSub?.cancel();
    _statusSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Leaving this screen is an intentional disconnect: tear down the
      // connection (and its foreground service) so it won't auto-reconnect.
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) widget.service.disconnect();
      },
      child: Scaffold(
        appBar: buildAppBar(context),
        // Popping runs the PopScope above (service.disconnect()); WelcomeScreen
        // disposes the service after its push returns. So Disconnect only needs
        // to pop.
        endDrawer: WatcherMenuDrawer(
          onDisconnect: () => Navigator.of(context).pop(),
        ),
        body: Column(
          children: [
            if (_isReconnecting) _reconnectingBanner(),
            Expanded(child: _data == null ? _waiting() : _content(_data!)),
          ],
        ),
      ),
    );
  }

  /// Slim banner shown while the link dropped and the service is auto-reconnecting.
  /// The last readings stay visible below it (tinted stale by the GPS logic).
  Widget _reconnectingBanner() {
    return Material(
      color: const Color(0xFFFFF3E0), // soft amber, matches the warning palette
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Reconnecting…',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFFE65100),
                ),
              ),
            ),
          ],
        ),
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
            // Every tile is fixed to _kTileHeight so all reading rows match,
            // regardless of value width (the pressure tile's FittedBox no longer
            // inflates the row via intrinsic height).
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
            // GPS (under Humidity) + Altitude (under Battery). Both derive from
            // the firmware's GPS fields; show placeholders when there's no fix.
            Row(
              children: [
                Expanded(child: _GpsCard(data: d)),
                const SizedBox(width: 12),
                Expanded(
                  // Always show the last-known altitude; tint it dark red once the
                  // fix is lost so it reads as stale rather than live.
                  child: _ReadingCard(
                    icon: Icons.terrain,
                    label: 'Altitude',
                    value: d.altitude.toStringAsFixed(1),
                    unit: 'm',
                    valueColor: d.hasFix ? null : _kStaleRed,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Altitude-corrected trends first (the values the alert algorithm
            // actually uses), then the raw trends below for comparison.
            _DropsCard(
              title: 'Altitude-corrected Pressure trends',
              subtitle: d.hasFix
                  ? 'Altitude correction active (GPS fix)'
                  : _noFixSubtitle(),
              subtitleColor: d.hasFix
                  ? const Color(0xFF0D47A1) // dark blue: correction active
                  : _kStaleRed, // dark red: no fix, using last-known values
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
            _UptimeCard(monitoringSeconds: _liveMonitoringSec),
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

/// Fixed height of the value area (the region below the label) shared by every
/// tile. One-line tiles render their value here; the GPS tile fits its two
/// coordinate lines in the same box — so all tiles end up equal height with no
/// overflow. Sized to hold the GPS tile's two coordinate lines near full size.
const double _kTileValueAreaHeight = 46;

/// Builds the label row (icon + caption) shared by [_ReadingCard]/[_GpsCard].
Widget _tileLabel(IconData icon, String label) {
  return Row(
    children: [
      Icon(icon, size: 20, color: Colors.blueGrey),
      const SizedBox(width: 6),
      Text(
        label,
        style: const TextStyle(fontSize: 13, color: Colors.black54),
      ),
    ],
  );
}

/// A single labelled reading tile (temperature, pressure, …).
class _ReadingCard extends StatelessWidget {
  const _ReadingCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.unit,
    this.valueColor,
  });

  final IconData icon;
  final String label;
  final String value;
  final String unit;

  /// Overrides the value text colour (null keeps the default). Used to tint a
  /// stale last-known reading (e.g. altitude after the GPS fix is lost).
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _tileLabel(icon, label),
            const SizedBox(height: 6),
            // scaleDown keeps value+unit on one line; 4-digit pressures shrink
            // instead of wrapping "hPa" below. The fixed-height box keeps every
            // tile the same height as the GPS tile.
            SizedBox(
              height: _kTileValueAreaHeight,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: RichText(
                  text: TextSpan(
                    style: DefaultTextStyle.of(context).style,
                    children: [
                      TextSpan(
                        text: value,
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: valueColor,
                        ),
                      ),
                      TextSpan(
                        text: ' $unit',
                        style: const TextStyle(
                            fontSize: 15, color: Colors.black54),
                      ),
                    ],
                  ),
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
/// Always shows the last-known coordinates; tints them dark red once the fix is
/// lost so they read as stale rather than live.
class _GpsCard extends StatelessWidget {
  const _GpsCard({required this.data});

  final WeatherData data;

  @override
  Widget build(BuildContext context) {
    // Default colour while the fix is live; dark red once it is lost.
    final color = data.hasFix ? null : _kStaleRed;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _tileLabel(Icons.location_on, 'GPS'),
            const SizedBox(height: 6),
            // The two coordinate lines are taller than a single value line, so
            // scaleDown shrinks them to fit the shared value-area height — the
            // GPS tile then matches the compact one-line tiles exactly.
            //
            // Always show the last-known coordinates; once the fix is lost they
            // are tinted dark red so they read as stale rather than live.
            SizedBox(
              height: _kTileValueAreaHeight,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Fixed-width "Lat:"/"Lon:" labels so both numbers
                    // start at the same x — first digits align.
                    _coordRow('Lat:', data.latitude, color),
                    const SizedBox(height: 2),
                    _coordRow('Lon:', data.longitude, color),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// One coordinate line: a fixed-width label cell + the value, so the values
  /// of consecutive rows line up at the same starting column. [color] tints the
  /// whole line (null keeps the default) so a stale last-known fix reads as red.
  Widget _coordRow(String label, double value, Color? color) {
    final style =
        TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color);
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

/// Card showing the live-ticking monitoring time (since the first measurement).
class _UptimeCard extends StatelessWidget {
  const _UptimeCard({required this.monitoringSeconds});

  final int monitoringSeconds;

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
                    'Device has been monitoring for',
                    style: TextStyle(fontSize: 13, color: Colors.black54),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    formatUptime(monitoringSeconds),
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
