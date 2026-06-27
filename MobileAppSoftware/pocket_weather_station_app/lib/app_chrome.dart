import 'package:flutter/material.dart';

import 'watchers_screen.dart';

/// The persistent app bar shared by both screens: fixed title, no back button,
/// and a right-side hamburger that opens the enclosing [Scaffold]'s endDrawer.
///
/// Pair this with `endDrawer: const WatcherMenuDrawer(...)` on the same Scaffold.
AppBar buildAppBar(BuildContext context) {
  return AppBar(
    automaticallyImplyLeading: false,
    title: const Text('Pocket Weather Station'),
    actions: [
      // Builder so the IconButton's context can find the enclosing Scaffold
      // (the AppBar itself is built above the Scaffold in the tree).
      Builder(
        builder: (ctx) => IconButton(
          icon: const Icon(Icons.menu),
          tooltip: 'Menu',
          onPressed: () => Scaffold.of(ctx).openEndDrawer(),
        ),
      ),
    ],
  );
}

/// The shared endDrawer menu. "Configure watchers list" is always present;
/// "Disconnect" appears only when [onDisconnect] is non-null (i.e. on the data
/// screen) — pass null on the welcome screen to omit it.
class WatcherMenuDrawer extends StatelessWidget {
  const WatcherMenuDrawer({super.key, this.onDisconnect});

  /// Called when the user taps Disconnect; null hides the tile entirely.
  final VoidCallback? onDisconnect;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            ListTile(
              leading: const Icon(Icons.sms),
              title: const Text('Configure watchers list'),
              onTap: () {
                Navigator.of(context).pop(); // close the drawer first
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const WatchersScreen()),
                );
              },
            ),
            if (onDisconnect != null)
              ListTile(
                leading: const Icon(Icons.bluetooth_disabled),
                title: const Text('Disconnect'),
                onTap: () {
                  Navigator.of(context).pop(); // close the drawer first
                  onDisconnect!();
                },
              ),
          ],
        ),
      ),
    );
  }
}
