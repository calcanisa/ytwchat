import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/chat_controller.dart';
import '../../core/api/api_client.dart';
import '../../core/api/models.dart';
import '../../utils/theme.dart';
import '../../widgets/avatar.dart';
import '../chat/chat_screen.dart';
import '../home/new_conversation_screen.dart';

class _PhoneEntry {
  final String name;
  final String number;
  final PublicUser? user;

  const _PhoneEntry({required this.name, required this.number, this.user});
}

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  List<_PhoneEntry> _phone = [];
  bool _scanning = false;
  bool _scanned = false;
  String? _scanError;

  Future<void> _scanPhone() async {
    setState(() {
      _scanning = true;
      _scanError = null;
    });
    final api = context.read<ChatController>().engine.api;
    try {
      final permission = await FlutterContacts.permissions.request(PermissionType.read);
      if (permission != PermissionStatus.granted && permission != PermissionStatus.limited) {
        setState(() {
          _scanning = false;
          _scanError = 'Allow contacts access to find friends who use ytwchat.';
        });
        return;
      }
      final phoneContacts = await FlutterContacts.getAll(properties: {ContactProperty.phone});
      final entries = <String, String>{};
      for (final c in phoneContacts) {
        for (final p in c.phones) {
          final normalized = _normalize(p.normalizedNumber ?? p.number);
          if (normalized != null) entries.putIfAbsent(normalized, () => c.displayName ?? '');
        }
      }
      final numbers = entries.keys.toList();
      final matches = <String, PublicUser>{};
      for (var i = 0; i < numbers.length; i += 1000) {
        final chunk = numbers.sublist(i, i + 1000 > numbers.length ? numbers.length : i + 1000);
        for (final m in await api.lookupPhones(chunk)) {
          matches[m.phoneNumber] = m.user;
        }
      }
      final list = entries.entries
          .map((e) => _PhoneEntry(name: e.value.isEmpty ? e.key : e.value, number: e.key, user: matches[e.key]))
          .toList()
        ..sort((a, b) {
          if ((a.user == null) != (b.user == null)) return a.user == null ? 1 : -1;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
      if (!mounted) return;
      setState(() {
        _phone = list;
        _scanning = false;
        _scanned = true;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _scanError = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _scanError = 'Your contacts could not be read.';
      });
    }
  }

  String? _normalize(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[\s\-().]'), '');
    if (!RegExp(r'^\+[1-9][0-9]{6,14}$').hasMatch(cleaned)) return null;
    return cleaned;
  }

  Future<void> _message(PublicUser user) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final id = await context.read<ChatController>().engine.openDirect(user.id);
      navigator.push(MaterialPageRoute(builder: (_) => ChatScreen(conversationId: id)));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message), backgroundColor: AppTheme.error));
    }
  }

  Future<void> _add(PublicUser user) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<ChatController>().addContact(user);
      messenger.showSnackBar(SnackBar(content: Text('${user.displayName} added to your contacts')));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message), backgroundColor: AppTheme.error));
    }
  }

  Future<void> _invite(_PhoneEntry entry) async {
    final uri = Uri(
      scheme: 'sms',
      path: entry.number,
      queryParameters: {'body': 'I use ytwchat for private, encrypted messages. Join me: https://ytwchat.com'},
    );
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  void _findPeople() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (page) => Scaffold(
          appBar: AppBar(title: const Text('Add contact')),
          body: UserSearch(
            exclude: {context.read<ChatController>().me},
            onPick: (u) {
              Navigator.pop(page);
              _add(u);
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatController>();
    final contacts = chat.contacts;
    return RefreshIndicator(
      onRefresh: chat.loadContacts,
      child: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.person_search_outlined, color: AppTheme.primary),
            title: const Text('Add by username', style: TextStyle(color: AppTheme.primary)),
            onTap: _findPeople,
          ),
          if (contacts.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('People you add will show up here.', textAlign: TextAlign.center, style: TextStyle(color: AppTheme.onSurfaceMuted)),
            ),
          ...contacts.map((c) => ListTile(
                leading: InitialAvatar(name: c.user.displayName, radius: 22, online: chat.isOnline(c.user.id)),
                title: Text(c.user.displayName),
                subtitle: Text('@${c.user.username}', style: const TextStyle(color: AppTheme.onSurfaceMuted, fontSize: 12)),
                onTap: () => _message(c.user),
                trailing: PopupMenuButton<String>(
                  onSelected: (v) async {
                    if (v == 'remove') await chat.removeContact(c.user.id);
                  },
                  itemBuilder: (_) => const [PopupMenuItem(value: 'remove', child: Text('Remove contact'))],
                ),
              )),
          const Divider(),
          if (!_scanned)
            ListTile(
              leading: _scanning
                  ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.contacts_outlined),
              title: const Text('Find friends from your phone contacts'),
              subtitle: const Text(
                'Phone numbers are checked and never stored on our servers',
                style: TextStyle(color: AppTheme.onSurfaceMuted, fontSize: 12),
              ),
              onTap: _scanning ? null : _scanPhone,
            ),
          if (_scanError != null)
            Padding(padding: const EdgeInsets.all(16), child: Text(_scanError!, style: const TextStyle(color: AppTheme.error))),
          ..._phone.map((e) {
            final user = e.user;
            if (user == null) {
              return ListTile(
                leading: InitialAvatar(name: e.name, radius: 22),
                title: Text(e.name),
                subtitle: Text(e.number, style: const TextStyle(color: AppTheme.onSurfaceMuted, fontSize: 12)),
                trailing: TextButton(onPressed: () => _invite(e), child: const Text('Invite')),
              );
            }
            final added = chat.isContact(user.id);
            return ListTile(
              leading: InitialAvatar(name: user.displayName, radius: 22, online: chat.isOnline(user.id)),
              title: Text(e.name),
              subtitle: Text('@${user.username}', style: const TextStyle(color: AppTheme.onSurfaceMuted, fontSize: 12)),
              trailing: added
                  ? TextButton(onPressed: () => _message(user), child: const Text('Message'))
                  : TextButton(onPressed: () => _add(user), child: const Text('Add')),
            );
          }),
        ],
      ),
    );
  }
}
