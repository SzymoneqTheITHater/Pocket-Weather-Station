// Smoke test: the app should boot into the connection screen and show the
// "Connecting…" prompt while it scans for the device.

import 'package:flutter_test/flutter_test.dart';

import 'package:pocket_weather_station_app/main.dart';

void main() {
  testWidgets('App opens on the connecting screen', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump();

    expect(
      find.textContaining('Connecting to the Pocket Weather Station'),
      findsOneWidget,
    );
  });
}
