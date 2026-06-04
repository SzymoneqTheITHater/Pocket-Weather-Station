import 'dart:convert';

import 'package:flutter/material.dart';

/// Uptime (seconds) after which each pressure-drop trend becomes meaningful.
/// These mirror the firmware: the 30-min drop needs SAMPLES_30MIN (6) intervals
/// of 5 min, and the 3-h drop needs the full 37-sample history (~180 min).
const int kDrop30mReadyUptimeSec = 30 * 60; // 1800 s
const int kDrop3hReadyUptimeSec = 180 * 60; // 10800 s

/// The four storm-alert levels emitted by the firmware (JSON field `alert`).
enum AlertLevel {
  clear(0, 'CLEAR', Color(0xFF2E7D32), Color(0xFFE8F5E9), Icons.check_circle),
  watch(1, 'WATCH', Color(0xFFF9A825), Color(0xFFFFF8E1), Icons.visibility),
  warning(2, 'WARNING', Color(0xFFEF6C00), Color(0xFFFFF3E0), Icons.warning_amber),
  severe(3, 'SEVERE', Color(0xFFC62828), Color(0xFFFFEBEE), Icons.flash_on);

  const AlertLevel(this.code, this.label, this.color, this.background, this.icon);

  /// Numeric code as sent by the device (0-3).
  final int code;

  /// Human-readable label shown on the banner.
  final String label;

  /// Primary banner / accent color.
  final Color color;

  /// Soft background tint for the banner surface.
  final Color background;

  /// Icon shown alongside the label.
  final IconData icon;

  /// Maps a device `alert` code (0-3) to an [AlertLevel], defaulting to CLEAR
  /// for any unexpected value.
  static AlertLevel fromCode(int code) {
    return AlertLevel.values.firstWhere(
      (a) => a.code == code,
      orElse: () => AlertLevel.clear,
    );
  }
}

/// A single current-reading snapshot parsed from the DATA characteristic JSON:
/// `{"temp","pressure","humidity","alert","p_drop_3h","p_drop_30m","bat","up_s"}`.
class WeatherData {
  const WeatherData({
    required this.temperature,
    required this.pressure,
    required this.humidity,
    required this.alert,
    required this.drop3h,
    required this.drop30m,
    required this.battery,
    required this.uptimeSeconds,
  });

  final double temperature; // °C
  final double pressure; // hPa
  final double humidity; // %
  final AlertLevel alert;
  final double drop3h; // hPa, 0.0 while warming up
  final double drop30m; // hPa, 0.0 while warming up
  final int battery; // %
  final int uptimeSeconds; // device uptime (up_s)

  /// True once the device has been up long enough for the 30-min drop to be valid.
  bool get drop30mReady => uptimeSeconds >= kDrop30mReadyUptimeSec;

  /// True once the device has been up long enough for the 3-h drop to be valid.
  bool get drop3hReady => uptimeSeconds >= kDrop3hReadyUptimeSec;

  /// Remaining minutes until the 30-min drop is valid (0 once ready).
  int get drop30mReadyInMin =>
      ((kDrop30mReadyUptimeSec - uptimeSeconds) / 60).ceil().clamp(0, 9999);

  /// Remaining minutes until the 3-h drop is valid (0 once ready).
  int get drop3hReadyInMin =>
      ((kDrop3hReadyUptimeSec - uptimeSeconds) / 60).ceil().clamp(0, 9999);

  /// Parses a raw UTF-8 JSON payload. Returns `null` for the firmware's `"{}"`
  /// placeholder or any malformed/incomplete frame.
  static WeatherData? tryParse(List<int> raw) {
    try {
      final decoded = jsonDecode(utf8.decode(raw));
      if (decoded is! Map || !decoded.containsKey('temp')) return null;
      return WeatherData(
        temperature: _toDouble(decoded['temp']),
        pressure: _toDouble(decoded['pressure']),
        humidity: _toDouble(decoded['humidity']),
        alert: AlertLevel.fromCode(_toInt(decoded['alert'])),
        drop3h: _toDouble(decoded['p_drop_3h']),
        drop30m: _toDouble(decoded['p_drop_30m']),
        battery: _toInt(decoded['bat']),
        uptimeSeconds: _toInt(decoded['up_s']),
      );
    } catch (_) {
      return null;
    }
  }

  static double _toDouble(dynamic v) => (v is num) ? v.toDouble() : 0.0;
  static int _toInt(dynamic v) => (v is num) ? v.toInt() : 0;
}

/// Formats a duration in seconds as e.g. "4h 25min 12s" / "25min 12s" / "12s".
String formatUptime(int totalSeconds) {
  if (totalSeconds < 0) totalSeconds = 0;
  final h = totalSeconds ~/ 3600;
  final m = (totalSeconds % 3600) ~/ 60;
  final s = totalSeconds % 60;
  final parts = <String>[];
  if (h > 0) parts.add('${h}h');
  if (h > 0 || m > 0) parts.add('${m}min');
  parts.add('${s}s');
  return parts.join(' ');
}
