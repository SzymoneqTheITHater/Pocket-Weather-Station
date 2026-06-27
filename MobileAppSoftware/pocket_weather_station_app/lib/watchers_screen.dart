import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';

import 'sms_service.dart';

/// Manages the list of "watcher" entries (name + phone number) that will be
/// texted when the storm-alert level changes. Reads/writes through [SmsService],
/// which persists the list across restarts.
class WatchersScreen extends StatefulWidget {
  const WatchersScreen({super.key});

  @override
  State<WatchersScreen> createState() => _WatchersScreenState();
}

class _WatchersScreenState extends State<WatchersScreen> {
  List<Watcher> get _watchers => SmsService.instance.watchers;

  /// Opens the add/edit dialog. When [index] is null the result is added;
  /// otherwise the existing watcher at [index] is replaced.
  Future<void> _editDialog({int? index}) async {
    final existing = index == null ? null : _watchers[index];
    final result = await showDialog<Watcher>(
      context: context,
      builder: (_) => _WatcherDialog(
        isEdit: index != null,
        initialNumber: existing?.number ?? '',
        initialName: existing?.name,
      ),
    );

    if (result == null || result.number.isEmpty) return;
    if (index == null) {
      await SmsService.instance.add(result);
    } else {
      await SmsService.instance.update(index, result);
    }
    if (mounted) setState(() {});
  }

  Future<void> _delete(int index) async {
    await SmsService.instance.remove(index);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Watchers')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _editDialog(),
        child: const Icon(Icons.add),
      ),
      body: _watchers.isEmpty ? _empty() : _list(),
    );
  }

  Widget _empty() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sms_outlined, size: 56, color: Colors.blueGrey),
            SizedBox(height: 16),
            Text(
              'No watchers yet',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            SizedBox(height: 8),
            Text(
              'Add a phone number to be alerted by SMS when the storm-alert '
              'level changes.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }

  Widget _list() {
    return ListView.builder(
      itemCount: _watchers.length,
      itemBuilder: (context, i) {
        final w = _watchers[i];
        return ListTile(
          leading: Icon(
            w.hasName ? Icons.person : Icons.phone,
            color: Colors.blueGrey,
          ),
          title: Text(w.hasName ? w.name! : w.number),
          subtitle: w.hasName ? Text(w.number) : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.edit),
                tooltip: 'Edit',
                onPressed: () => _editDialog(index: i),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Delete',
                onPressed: () => _delete(i),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// One selectable contact phone number (a contact with several numbers yields
/// one option per number).
class _ContactOption {
  const _ContactOption({required this.name, required this.number});

  final String name;
  final String number;
}

/// Add/edit dialog for a single watcher. Owns its own [TextEditingController]
/// (disposed only after the route fully pops, avoiding the framework's
/// `_dependents.isEmpty` assertion) and offers IKO-style contact suggestions:
/// as the user types a number, matching contacts appear and tapping one captures
/// both the name and the number.
class _WatcherDialog extends StatefulWidget {
  const _WatcherDialog({
    required this.isEdit,
    required this.initialNumber,
    this.initialName,
  });

  final bool isEdit;
  final String initialNumber;
  final String? initialName;

  @override
  State<_WatcherDialog> createState() => _WatcherDialogState();
}

class _WatcherDialogState extends State<_WatcherDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialNumber);

  List<_ContactOption> _contacts = [];
  bool _loadingContacts = true;
  bool _contactsDenied = false;

  /// The contact whose number is currently in the field; its name is saved with
  /// the watcher. Cleared when the user edits the number away from it.
  _ContactOption? _picked;

  @override
  void initState() {
    super.initState();
    if (widget.initialName != null && widget.initialName!.isNotEmpty) {
      _picked = _ContactOption(
        name: widget.initialName!,
        number: widget.initialNumber,
      );
    }
    _controller.addListener(_onTextChanged);
    _loadContacts();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadContacts() async {
    try {
      // Include contacts in non-visible groups/labels; otherwise Android's
      // IN_VISIBLE_GROUP filter hides anyone the user has put in a custom group.
      FlutterContacts.config.includeNonVisibleOnAndroid = true;

      final granted = await FlutterContacts.requestPermission(readonly: true);
      if (!granted) {
        if (mounted) {
          setState(() {
            _loadingContacts = false;
            _contactsDenied = true;
          });
        }
        return;
      }
      final contacts = await FlutterContacts.getContacts(withProperties: true);
      final options = <_ContactOption>[];
      for (final c in contacts) {
        final name = c.displayName.trim();
        for (final phone in c.phones) {
          final number = phone.number.trim();
          if (number.isEmpty) continue;
          options.add(_ContactOption(name: name, number: number));
        }
      }
      if (mounted) {
        setState(() {
          _contacts = options;
          _loadingContacts = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingContacts = false);
    }
  }

  void _onTextChanged() {
    // Editing away from the picked contact's number drops the attached name.
    if (_picked != null && _controller.text.trim() != _picked!.number) {
      _picked = null;
    }
    setState(() {});
  }

  void _pick(_ContactOption option) {
    _picked = option; // set before changing text so _onTextChanged keeps it
    _controller.value = TextEditingValue(
      text: option.number,
      selection: TextSelection.collapsed(offset: option.number.length),
    );
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {});
  }

  void _submit() {
    final number = _controller.text.trim();
    if (number.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    Navigator.of(context).pop(Watcher(number: number, name: _picked?.name));
  }

  static String _digitsOnly(String s) => s.replaceAll(RegExp(r'[^0-9]'), '');

  /// Up to 8 contacts matching the current input, ranked so the most relevant
  /// appear first: numbers that *start* with the typed digits, then numbers that
  /// merely contain them (e.g. behind a country code), then name-only matches.
  /// Empty while a contact is picked or the field is empty.
  List<_ContactOption> get _suggestions {
    if (_picked != null) return const [];
    final query = _controller.text.trim();
    if (query.isEmpty) return const [];
    final queryDigits = _digitsOnly(query);
    final queryLower = query.toLowerCase();

    final matches = <({_ContactOption option, int rank, int order})>[];
    final seen = <String>{};
    for (final c in _contacts) {
      final numberDigits = _digitsOnly(c.number);
      int rank;
      if (queryDigits.isNotEmpty && numberDigits.startsWith(queryDigits)) {
        rank = 0;
      } else if (queryDigits.isNotEmpty && numberDigits.contains(queryDigits)) {
        rank = 1;
      } else if (c.name.isNotEmpty && c.name.toLowerCase().contains(queryLower)) {
        rank = 2;
      } else {
        continue;
      }
      if (seen.add('${c.name}|${c.number}')) {
        matches.add((option: c, rank: rank, order: matches.length));
      }
    }
    // Stable sort by rank (ties keep contact order via [order]).
    matches.sort((a, b) {
      final byRank = a.rank.compareTo(b.rank);
      return byRank != 0 ? byRank : a.order.compareTo(b.order);
    });
    return matches.take(8).map((m) => m.option).toList();
  }

  @override
  Widget build(BuildContext context) {
    final suggestions = _suggestions;
    return AlertDialog(
      title: Text(widget.isEdit ? 'Edit watcher' : 'Add watcher'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Phone number',
                hintText: '+48 123 456 789',
                prefixIcon: Icon(Icons.phone),
              ),
              onSubmitted: (_) => _submit(),
            ),
            if (_picked != null) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  const Icon(Icons.person, size: 18, color: Colors.blueGrey),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _picked!.name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: 'Remove contact name',
                    onPressed: () => setState(() => _picked = null),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            _suggestionsArea(suggestions),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Save'),
        ),
      ],
    );
  }

  Widget _suggestionsArea(List<_ContactOption> suggestions) {
    if (_loadingContacts) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Text(
              'Loading contacts…',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ],
        ),
      );
    }
    if (_contactsDenied) {
      return const Text(
        'Contacts permission denied — you can still type a number manually.',
        style: TextStyle(fontSize: 12, color: Colors.black54),
      );
    }
    if (suggestions.isEmpty) return const SizedBox.shrink();
    // Flexible (not a fixed height) so the list shrinks to whatever vertical
    // space the dialog has left once the keyboard is up, scrolling instead of
    // overflowing.
    return Flexible(
      child: ListView.builder(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: suggestions.length,
        itemBuilder: (_, i) {
          final c = suggestions[i];
          return ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.person_outline),
            title: Text(c.name.isEmpty ? c.number : c.name),
            subtitle: c.name.isEmpty ? null : Text(c.number),
            onTap: () => _pick(c),
          );
        },
      ),
    );
  }
}
