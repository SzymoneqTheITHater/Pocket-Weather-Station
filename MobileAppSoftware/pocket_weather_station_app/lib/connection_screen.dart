import 'dart:async';

import 'package:flutter/material.dart';

import 'ble_service.dart';
import 'data_screen.dart';

/// The first screen the user sees. Auto-scans for the Pocket Weather Station and
/// connects to it. Surfaces a hint after 5 s and a "Connection Failed" + Retry
/// after 10 s if the device can't be reached (e.g. it's powered off).
class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key});

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

enum _Phase { connecting, failed }

class _ConnectionScreenState extends State<ConnectionScreen> {
  static const Duration _hintAfter = Duration(seconds: 5);
  static const Duration _failAfter = Duration(seconds: 10);

  final WeatherBleService _service = WeatherBleService();

  _Phase _phase = _Phase.connecting;
  bool _showHint = false;
  Timer? _hintTimer;
  Timer? _failTimer;

  /// Identifies the current connection attempt so that a stale [findAndConnect]
  /// future (e.g. one that resolved after a timeout/retry) can't act on the UI.
  int _attemptId = 0;

  @override
  void initState() {
    super.initState();
    _attempt();
  }

  @override
  void dispose() {
    _cancelTimers();
    _service.dispose();
    super.dispose();
  }

  void _cancelTimers() {
    _hintTimer?.cancel();
    _failTimer?.cancel();
  }

  Future<void> _attempt() async {
    final id = ++_attemptId;
    _cancelTimers();
    setState(() {
      _phase = _Phase.connecting;
      _showHint = false;
    });

    _hintTimer = Timer(_hintAfter, () {
      if (mounted && id == _attemptId) setState(() => _showHint = true);
    });
    _failTimer = Timer(_failAfter, () {
      if (id != _attemptId) return;
      _service.cancel(); // abort the in-progress scan
      if (mounted) setState(() => _phase = _Phase.failed);
    });

    final ok = await _service.findAndConnect();
    if (!mounted || id != _attemptId) return;

    if (ok && _phase != _Phase.failed) {
      _cancelTimers();
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => DataScreen(service: _service)),
      );
      // Returned from the data screen (device disconnected) → reconnect.
      if (mounted) _attempt();
    } else {
      // Either the attempt failed, or the timeout already declared failure
      // while the connection raced to complete — drop any late connection.
      if (ok) await _service.disconnect();
      if (mounted) setState(() => _phase = _Phase.failed);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: _phase == _Phase.connecting ? _connectingView() : _failedView(),
        ),
      ),
    );
  }

  Widget _connectingView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.cloud_sync, size: 72, color: Colors.blueGrey),
        const SizedBox(height: 24),
        const CircularProgressIndicator(),
        const SizedBox(height: 28),
        const _AnimatedDots(text: 'Connecting to the Pocket Weather Station'),
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
      ],
    );
  }

  Widget _failedView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.cloud_off, size: 72, color: Colors.redAccent),
        const SizedBox(height: 24),
        const Text(
          'Connection Failed',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        const Text(
          'Could not find the Pocket Weather Station.\n'
          'Make sure it is turned on and nearby.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: Colors.black54),
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: _attempt,
          icon: const Icon(Icons.refresh),
          label: const Text('Retry'),
        ),
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
