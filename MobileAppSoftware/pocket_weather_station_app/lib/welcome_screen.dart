import 'dart:async';

import 'package:flutter/material.dart';

import 'app_chrome.dart';
import 'ble_service.dart';
import 'data_screen.dart';

/// The home screen. Unlike the old auto-connecting flow, the user connects
/// manually with a button. Connecting happens inline in the header (the rest of
/// the screen stays put) so future "saved session/trip" tiles can live below it.
///
/// Ports the connection logic from the former ConnectionScreen: the 5 s hint and
/// 10 s timeout timers and the [_attemptId] race guard that stops a stale
/// [findAndConnect] future from acting on the UI. There is no auto-connect at
/// launch and no auto-reconnect — reconnection is always a manual Connect press.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  static const Duration _hintAfter = Duration(seconds: 5);
  static const Duration _failAfter = Duration(seconds: 10);

  /// The service for the in-flight / active connection; null while idle.
  WeatherBleService? _service;

  bool _isConnecting = false;
  bool _showHint = false;
  bool _timedOut = false;
  Timer? _hintTimer;
  Timer? _failTimer;

  /// Identifies the current connection attempt so a stale [findAndConnect]
  /// future (e.g. one that resolved after the timeout) can't act on the UI.
  int _attemptId = 0;

  @override
  void dispose() {
    _cancelTimers();
    _service?.dispose();
    super.dispose();
  }

  void _cancelTimers() {
    _hintTimer?.cancel();
    _failTimer?.cancel();
  }

  Future<void> _connect() async {
    final service = WeatherBleService();
    final id = ++_attemptId;
    _cancelTimers();
    setState(() {
      _service = service;
      _isConnecting = true;
      _showHint = false;
      _timedOut = false;
    });

    _hintTimer = Timer(_hintAfter, () {
      if (mounted && id == _attemptId) setState(() => _showHint = true);
    });
    _failTimer = Timer(_failAfter, () {
      if (id != _attemptId) return;
      _timedOut = true;
      service.cancel(); // abort the in-progress scan so findAndConnect returns
    });

    final ok = await service.findAndConnect();

    // Attempt superseded (widget gone or a newer attempt started): drop any late
    // connection and bail without touching the UI.
    if (!mounted || id != _attemptId) {
      if (ok) await service.dispose();
      return;
    }

    _cancelTimers();

    if (ok && !_timedOut) {
      // Connected. Show the data screen; when it returns the device has been
      // disconnected, so tear down and reset the header to the idle button.
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => DataScreen(service: service)),
      );
      await service.dispose();
      if (mounted && id == _attemptId) _reset();
    } else {
      // Either the attempt failed, or the timeout already declared failure while
      // the connection raced to complete — drop any late connection.
      if (ok) await service.disconnect();
      await service.dispose();
      if (mounted && id == _attemptId) {
        _reset();
        _showFailSnackBar();
      }
    }
  }

  void _reset() {
    setState(() {
      _service = null;
      _isConnecting = false;
      _showHint = false;
      _timedOut = false;
    });
  }

  void _showFailSnackBar() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Connection Failed — Could not find the Pocket Weather Station. '
          'Make sure it is turned on and nearby.',
        ),
        duration: Duration(seconds: 5),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: buildAppBar(context),
      endDrawer: const WatcherMenuDrawer(), // no Disconnect on the welcome screen
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 32),
        children: [
          _connectHeader(),
          const SizedBox(height: 48),
          // Reserved space for future "saved session/trip" tiles.
          Center(
            child: const Text(
              'Saved trips will appear here',
              style: TextStyle(fontSize: 13, color: Colors.black26),
            ),
          ),
        ],
      ),
    );
  }

  Widget _connectHeader() {
    return Column(
      children: [
        const Icon(Icons.cloud_sync, size: 72, color: Colors.blueGrey),
        const SizedBox(height: 24),
        if (_isConnecting) ...[
          const CircularProgressIndicator(),
          const SizedBox(height: 20),
          const _AnimatedDots(text: 'Connecting'),
          const SizedBox(height: 12),
          AnimatedOpacity(
            opacity: _showHint ? 1 : 0,
            duration: const Duration(milliseconds: 400),
            child: const Text(
              'Check if the device is turned on.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.black54),
            ),
          ),
        ] else ...[
          FilledButton(
            onPressed: _connect,
            child: const Text('Connect'),
          ),
          const SizedBox(height: 12),
          const Text(
            'Connect to your Pocket Weather Station',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: Colors.black54),
          ),
        ],
      ],
    );
  }
}

/// Shows [text] followed by an animated suffix that cycles ".", "..", "...".
class _AnimatedDots extends StatefulWidget {
  const _AnimatedDots({required this.text});

  final String text;

  @override
  State<_AnimatedDots> createState() => _AnimatedDotsState();
}

class _AnimatedDotsState extends State<_AnimatedDots> {
  Timer? _timer;
  int _dots = 1;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 450), (_) {
      if (mounted) setState(() => _dots = (_dots % 3) + 1);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      '${widget.text}${'.' * _dots}',
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
    );
  }
}
