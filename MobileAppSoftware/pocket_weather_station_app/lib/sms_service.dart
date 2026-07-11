import 'dart:convert';

import 'package:another_telephony/telephony.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'weather_data.dart';

/// A watcher to be texted when the storm-alert level changes: a phone [number]
/// plus an optional contact [name] captured when the number was picked from the
/// device's address book.
class Watcher {
  const Watcher({required this.number, this.name});

  final String number;
  final String? name;

  /// True when a (non-blank) contact name is attached.
  bool get hasName => name != null && name!.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {
        'number': number,
        if (hasName) 'name': name,
      };

  /// Decodes a stored entry. Falls back to treating the whole string as a bare
  /// number, which migrates entries saved before names were supported.
  factory Watcher.fromStored(String stored) {
    try {
      final decoded = jsonDecode(stored);
      if (decoded is Map && decoded['number'] is String) {
        final name = decoded['name'];
        return Watcher(
          number: decoded['number'] as String,
          name: name is String ? name : null,
        );
      }
    } catch (_) {}
    return Watcher(number: stored);
  }
}

/// Stores the user-defined "watcher" entries that should be texted when the
/// storm-alert level changes, and provides the silent-send primitive used to
/// reach them.
///
/// Mirrors [NotificationService]: a lazily-initialized singleton. The watcher
/// list is persisted with shared_preferences so it survives restarts. The actual
/// alert-change trigger that builds and sends the message lives elsewhere and is
/// added later — this service only owns the list and the [sendToAll] primitive.
class SmsService {
  SmsService._();
  static final SmsService instance = SmsService._();

  static const String _prefsKey = 'sms_watchers';

  final Telephony _telephony = Telephony.instance;

  List<Watcher> _watchers = [];
  bool _initialized = false;

  /// The current watchers (unmodifiable; mutate via [add]/[update]/[remove]).
  List<Watcher> get watchers => List.unmodifiable(_watchers);

  /// Loads the saved watcher list and requests the runtime SMS permission. Safe
  /// to call once at startup; subsequent calls are no-ops.
  Future<void> init() async {
    if (_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_prefsKey) ?? [];
    _watchers = stored.map(Watcher.fromStored).toList();
    // Android-only runtime SEND_SMS permission; harmless if already granted.
    try {
      await _telephony.requestSmsPermissions;
    } catch (_) {}
    _initialized = true;
  }

  /// Appends [watcher] and persists.
  Future<void> add(Watcher watcher) async {
    _watchers.add(watcher);
    await _persist();
  }

  /// Replaces the watcher at [index] with [watcher] and persists.
  Future<void> update(int index, Watcher watcher) async {
    _watchers[index] = watcher;
    await _persist();
  }

  /// Removes the watcher at [index] and persists.
  Future<void> remove(int index) async {
    _watchers.removeAt(index);
    await _persist();
  }

  /// Silently texts [message] to every watcher. No-op when the list is empty.
  /// Failures sending to one number don't abort the rest. Messages longer than a
  /// single 160-char GSM-7 segment are sent multipart so they aren't truncated.
  Future<void> sendToAll(String message) async {
    if (_watchers.isEmpty) return;
    final multipart = message.length > 160;
    for (final watcher in _watchers) {
      try {
        await _telephony.sendSms(
          to: watcher.number,
          message: message,
          isMultipart: multipart,
        );
      } catch (_) {}
    }
  }

  /// Texts every watcher a one-line summary of an alert-level change. Builds the
  /// message from the latest [data] and the time of the last GPS fix ([lastFixAt],
  /// used to describe a stale location), then hands it to [sendToAll].
  Future<void> sendAlertChange(
    AlertLevel from,
    AlertLevel to,
    WeatherData data,
    DateTime? lastFixAt,
  ) async {
    await sendToAll(_buildMessage(from, to, data, lastFixAt));
  }

  /// Plain-ASCII alert summary, e.g.
  /// "Storm alert: WATCH->WARNING 14:32. 3h drop 4.2hPa, 30m drop 1.8hPa,
  ///  10m rise 0.8hPa. Loc: https://maps.google.com/?q=49.17912,20.08812".
  /// Kept within a single 160-char GSM-7 segment in the typical (live-fix)
  /// case so it sends reliably on weak signal.
  String _buildMessage(
    AlertLevel from,
    AlertLevel to,
    WeatherData data,
    DateTime? lastFixAt,
  ) {
    final now = DateTime.now();
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    final drop3h = data.corrDrop3h.toStringAsFixed(1);
    final drop30m = data.corrDrop30m.toStringAsFixed(1);
    final rise10m = data.corrRise10m.toStringAsFixed(1);
    return 'Storm alert: ${from.label}->${to.label} $hh:$mm. '
        '3h drop ${drop3h}hPa, 30m drop ${drop30m}hPa, 10m rise ${rise10m}hPa. '
        '${_location(data, lastFixAt, now)}';
  }

  /// Location clause for the alert message. Uses the current coordinates while a
  /// fix is live, the last-known coordinates (with how long ago the fix was lost)
  /// during an outage, or "unavailable" if no fix has ever been seen.
  String _location(WeatherData data, DateTime? lastFixAt, DateTime now) {
    final coords =
        '${data.latitude.toStringAsFixed(5)},${data.longitude.toStringAsFixed(5)}';
    final url = 'https://maps.google.com/?q=$coords';
    if (data.hasFix) return 'Loc: $url';
    if (lastFixAt != null) {
      final n = (now.difference(lastFixAt).inSeconds / 60).round();
      final minutes = n < 1 ? 1 : n;
      return 'Loc (last known, fix lost ~${minutes}min): $url';
    }
    return 'Loc: unavailable';
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _prefsKey,
      _watchers.map((w) => jsonEncode(w.toJson())).toList(),
    );
  }
}
