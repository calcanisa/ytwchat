import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../models/user_model.dart';
import '../../providers/chat_provider.dart';
import '../../services/api_service.dart';
import '../../utils/theme.dart';
import '../../widgets/avatar.dart';
import '../chat/chat_screen.dart';

class _PhoneContact {
  final String displayName;
  final String phoneNumber;
  final UserModel? converseUser;
  bool adding = false;

  _PhoneContact({
    required this.displayName,
    required this.phoneNumber,
    this.converseUser,
  });
}

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  List<_PhoneContact> _contacts = [];
  List<UserModel> _converseContacts = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final api = context.read<ApiService>();
      _converseContacts = await api.getContacts();

      final status = await Permission.contacts.request();
      if (!status.isGranted) {
        setState(() { _loading = false; _error = 'Contacts permission denied'; });
        return;
      }

      final phoneContacts = await FlutterContacts.getAll(
        properties: {ContactProperty.phone},
      );

      final phones = phoneContacts
          .expand((c) => c.phones.map((p) => MapEntry(c.displayName, _normalizePhone(p.number))))
          .where((e) => e.value.isNotEmpty)
          .toList();

      final phoneNumbers = phones.map((e) => e.value).toSet().toList();
      final matched = phoneNumbers.isEmpty ? [] : await api.lookupByPhones(phoneNumbers);
      final matchMap = { for (final r in matched) r['phone_number'] as String: UserModel.fromJson(r['user']) };

      setState(() {
        _contacts = phones.map((e) => _PhoneContact(
          displayName: e.key ?? "Unknown",
          phoneNumber: e.value,
          converseUser: matchMap[e.value],
        )).toList();
        _contacts.sort((a, b) {
          if (a.converseUser != null && b.converseUser == null) return -1;
          if (a.converseUser == null && b.converseUser != null) return 1;
          return a.displayName.compareTo(b.displayName);
        });
        _loading = false;
      });
    } catch (e) {
      setState(() { _loading = false; _error = 'Failed to load contacts: $e'; });
    }
  }

  String _normalizePhone(String phone) {
    return phone.replaceAll(RegExp(r'[\s\-\(\)]'), '');
  }

  Future<void> _addContact(_PhoneContact contact) async {
    if (contact.converseUser == null) return;
    setState(() => contact.adding = true);
    try {
      final api = context.read<ApiService>();
      await api.addContact(contact.converseUser!.id);
      setState(() {
        _converseContacts.add(contact.converseUser!);
        contact.adding = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${contact.converseUser!.displayName} added to Converse')),
        );
      }
    } catch (_) {
      setState(() => contact.adding = false);
    }
  }

  Future<void> _sendSmsInvite(_PhoneContact contact) async {
    final uri = Uri.parse(
      'sms:${contact.phoneNumber}?body=Hey! I\'m using Converse to chat. Join me: https://converse.app/download',
    );
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  Future<void> _startChat(UserModel user) async {
    final chat = context.read<ChatProvider>();
    final conv = await chat.startDirectConversation(user.id);
    if (conv != null && mounted) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(conversation: conv)));
    }
  }

  bool _isAdded(UserModel user) => _converseContacts.any((c) => c.id == user.id);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline, size: 48, color: AppTheme.error),
                      const SizedBox(height: 12),
                      Text(_error!, style: const TextStyle(color: AppTheme.onSurfaceMuted), textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      ElevatedButton(onPressed: _load, child: const Text('Retry')),
                    ],
                  ),
                )
              : _buildList(),
    );
  }

  Widget _buildList() {
    if (_contacts.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.contacts_outlined, size: 64, color: AppTheme.onSurfaceMuted),
            SizedBox(height: 16),
            Text('No contacts found', style: TextStyle(color: AppTheme.onSurfaceMuted)),
          ],
        ),
      );
    }

    final onConverse = _contacts.where((c) => c.converseUser != null).toList();
    final notOnConverse = _contacts.where((c) => c.converseUser == null).toList();

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        children: [
          if (onConverse.isNotEmpty) ...[
            _sectionHeader('On Converse'),
            ...onConverse.map((c) => _converseContactTile(c)),
          ],
          if (notOnConverse.isNotEmpty) ...[
            _sectionHeader('Invite to Converse'),
            ...notOnConverse.map((c) => _inviteTile(c)),
          ],
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(title, style: const TextStyle(color: AppTheme.onSurfaceMuted, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }

  Widget _converseContactTile(_PhoneContact contact) {
    final user = contact.converseUser!;
    final added = _isAdded(user);

    return ListTile(
      leading: UserAvatar(user: user, radius: 22),
      title: Text(contact.displayName),
      subtitle: Text('@${user.username}', style: const TextStyle(color: AppTheme.onSurfaceMuted, fontSize: 12)),
      trailing: added
          ? TextButton(onPressed: () => _startChat(user), child: const Text('Message'))
          : contact.adding
              ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
              : ElevatedButton(
                  onPressed: () => _addContact(contact),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(80, 34),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    textStyle: const TextStyle(fontSize: 13),
                  ),
                  child: const Text('Add'),
                ),
    );
  }

  Widget _inviteTile(_PhoneContact contact) {
    return ListTile(
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: AppTheme.surfaceVariant,
        child: Text(contact.displayName[0].toUpperCase(), style: const TextStyle(color: AppTheme.onSurfaceMuted)),
      ),
      title: Text(contact.displayName),
      subtitle: Text(contact.phoneNumber, style: const TextStyle(color: AppTheme.onSurfaceMuted, fontSize: 12)),
      trailing: TextButton.icon(
        onPressed: () => _sendSmsInvite(contact),
        icon: const Icon(Icons.sms_outlined, size: 16),
        label: const Text('Invite'),
        style: TextButton.styleFrom(foregroundColor: AppTheme.onSurfaceMuted),
      ),
    );
  }
}
