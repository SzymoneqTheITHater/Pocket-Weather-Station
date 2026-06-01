import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLE Scan Test',
      home: const ScanScreen(),
    );
  }
}

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});
  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  List<ScanResult> _results = [];
  bool _isScanning = false;

  @override
  void initState() {
    super.initState();
    // Refresh the list whenever new scan results arrive.
    FlutterBluePlus.scanResults.listen((results) {
      setState(() => _results = results);
    });
    // Track scan state so the button can show "Scanning…".
    FlutterBluePlus.isScanning.listen((scanning) {
      setState(() => _isScanning = scanning);
    });
  }

  Future<void> _startScan() async {
    if (await FlutterBluePlus.isSupported == false) return;

    // On Android this pops a system dialog to turn Bluetooth on if it's off.
    try {
      await FlutterBluePlus.turnOn();
    } catch (_) {}

    // Wait until the adapter is actually on, then scan.
    await FlutterBluePlus.adapterState
        .where((s) => s == BluetoothAdapterState.on)
        .first;

    setState(() => _results = []);
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('BLE Scan Test')),
      body: ListView.builder(
        itemCount: _results.length,
        itemBuilder: (context, i) {
          final r = _results[i];
          final name = r.device.platformName.isNotEmpty
              ? r.device.platformName
              : (r.advertisementData.advName.isNotEmpty
                  ? r.advertisementData.advName
                  : '(unnamed)');
          return ListTile(
            title: Text(name),
            subtitle: Text('${r.device.remoteId}'),
            trailing: Text('${r.rssi} dBm'),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isScanning ? null : _startScan,
        icon: const Icon(Icons.search),
        label: Text(_isScanning ? 'Scanning…' : 'Scan'),
      ),
    );
  }
}