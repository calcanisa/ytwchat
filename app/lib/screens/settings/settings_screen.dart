import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../app/app_session.dart';
import '../../app/chat_controller.dart';
import '../../core/api/api_client.dart';
import '../../core/api/models.dart';
import '../../utils/theme.dart';
import '../../widgets/avatar.dart';
import '../chat/conversation_info_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  void _toast(String text, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), backgroundColor: error ? AppTheme.error : null),
    );
  }

  Future<void> _editName(AppSession session) async {
    final field = TextEditingController(text: session.me?.displayName ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Your name'),
        content: TextField(controller: field, autofocus: true, maxLength: 60, textCapitalization: TextCapitalization.words),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(d, field.text), child: const Text('Save')),
        ],
      ),
    );
    field.dispose();
    if (name == null || name.trim().isEmpty) return;
    try {
      final me = await session.api.updateMe(displayName: name.trim());
      session.me = me;
      await session.store.saveProfile(me);
      await session.refreshProfile();
    } on ApiException catch (e) {
      _toast(e.message, error: true);
    }
  }

  Future<void> _deleteAccount(AppSession session) async {
    final navigator = Navigator.of(context);
    final field = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Delete your account?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('This removes your account, your contacts and every device. Messages on other people\'s phones stay with them. This cannot be undone.'),
            const SizedBox(height: 12),
            if (session.me?.hasPassword ?? true)
              TextField(controller: field, obscureText: true, decoration: const InputDecoration(hintText: 'Your password')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(d, field.text),
            child: const Text('Delete account', style: TextStyle(color: AppTheme.error)),
          ),
        ],
      ),
    );
    field.dispose();
    if (password == null) return;
    final error = await session.deleteAccount(password.isEmpty ? null : password);
    if (error != null) {
      _toast(error, error: true);
      return;
    }
    navigator.popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AppSession>();
    final me = session.me;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          if (me != null)
            ListTile(
              contentPadding: const EdgeInsets.all(16),
              leading: InitialAvatar(name: me.displayName, radius: 28),
              title: Text(me.displayName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              subtitle: Text('@${me.username}\n${me.email}', style: const TextStyle(color: AppTheme.onSurfaceMuted)),
              isThreeLine: true,
              trailing: IconButton(tooltip: 'Change name', icon: const Icon(Icons.edit_outlined), onPressed: () => _editName(session)),
            ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.devices_outlined),
            title: const Text('Linked devices'),
            subtitle: const Text('See and sign out devices that use your account'),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DevicesScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.fingerprint),
            title: const Text('This phone\'s security code'),
            subtitle: Text(
              SecurityCodesScreen.format(context.read<ChatController>().engine.ownFingerprint()),
              style: const TextStyle(fontFamily: 'monospace', color: AppTheme.onSurfaceMuted),
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Sign out'),
            subtitle: const Text('Messages on this phone are deleted when you sign out'),
            onTap: () {
              Navigator.of(context).popUntil((r) => r.isFirst);
              session.logout();
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_forever_outlined, color: AppTheme.error),
            title: const Text('Delete account', style: TextStyle(color: AppTheme.error)),
            onTap: () => _deleteAccount(session),
          ),
        ],
      ),
    );
  }
}

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  List<DeviceInfo>? _devices;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await context.read<AppSession>().api.devices();
      if (mounted) setState(() => _devices = list);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _revoke(DeviceInfo d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('Sign out ${d.name}?'),
        content: const Text('That device will be signed out and removed from all your chats.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('Sign out', style: TextStyle(color: AppTheme.error))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<AppSession>().api.revokeDevice(d.id);
      await _load();
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message), backgroundColor: AppTheme.error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final devices = _devices;
    final fmt = DateFormat('d MMM yyyy, HH:mm');
    return Scaffold(
      appBar: AppBar(title: const Text('Linked devices')),
      body: devices == null
          ? Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!, style: const TextStyle(color: AppTheme.error)))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                children: devices
                    .map((d) => ListTile(
                          leading: Icon(d.platform == 'ios' || d.platform == 'android' ? Icons.smartphone : Icons.computer),
                          title: Text(d.current ? '${d.name} (this phone)' : d.name),
                          subtitle: Text(
                            'Last active ${fmt.format(d.lastSeenAt.toLocal())}',
                            style: const TextStyle(color: AppTheme.onSurfaceMuted, fontSize: 12),
                          ),
                          trailing: d.current
                              ? null
                              : TextButton(onPressed: () => _revoke(d), child: const Text('Sign out', style: TextStyle(color: AppTheme.error))),
                        ))
                    .toList(),
              ),
            ),
    );
  }
}
