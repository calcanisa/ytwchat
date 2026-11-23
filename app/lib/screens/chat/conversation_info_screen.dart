import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/chat_controller.dart';
import '../../core/api/api_client.dart';
import '../../core/api/models.dart';
import '../../core/store/local_db.dart';
import '../../core/sync/sync_engine.dart';
import '../../utils/theme.dart';
import '../../widgets/avatar.dart';
import '../home/new_conversation_screen.dart';

class ConversationInfoScreen extends StatefulWidget {
  final String conversationId;

  const ConversationInfoScreen({super.key, required this.conversationId});

  @override
  State<ConversationInfoScreen> createState() => _ConversationInfoScreenState();
}

class _ConversationInfoScreenState extends State<ConversationInfoScreen> {
  bool _busy = false;
  Set<String> _blocked = {};

  @override
  void initState() {
    super.initState();
    _loadBlocks();
  }

  Future<void> _loadBlocks() async {
    try {
      final list = await context.read<ChatController>().engine.api.blocks();
      if (mounted) setState(() => _blocked = list.map((u) => u.id).toSet());
    } on ApiException {
      return;
    }
  }

  Future<void> _run(Future<void> Function() task, {String? done}) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await task();
      if (done != null) messenger.showSnackBar(SnackBar(content: Text(done)));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message), backgroundColor: AppTheme.error));
    } on SendException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message), backgroundColor: AppTheme.error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String body, String action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(d, true), child: Text(action, style: const TextStyle(color: AppTheme.error))),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _rename(LocalConversation conv, SyncEngine engine) async {
    final field = TextEditingController(text: conv.title ?? '');
    final title = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Group name'),
        content: TextField(controller: field, autofocus: true, maxLength: 60),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(d, field.text), child: const Text('Save')),
        ],
      ),
    );
    field.dispose();
    if (title == null) return;
    await _run(() => engine.renameGroup(conv.id, title));
  }

  Future<void> _addPeople(LocalConversation conv, SyncEngine engine) async {
    final picked = await Navigator.push<PublicUser>(
      context,
      MaterialPageRoute(
        builder: (page) => Scaffold(
          appBar: AppBar(title: const Text('Add people')),
          body: UserSearch(
            onPick: (u) => Navigator.pop(page, u),
            exclude: conv.members.map((m) => m.user.id).toSet(),
          ),
        ),
      ),
    );
    if (picked == null) return;
    await _run(() => engine.addToGroup(conv.id, [picked.id]), done: '${picked.displayName} added');
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatController>();
    final engine = chat.engine;
    final conv = chat.byId(widget.conversationId);
    if (conv == null) return Scaffold(appBar: AppBar());
    final me = chat.me;
    final admin = conv.isAdmin(me);
    final other = conv.isGroup ? null : conv.others(me).firstOrNull;
    final active = conv.state != GroupState.left;

    return Scaffold(
      appBar: AppBar(title: Text(conv.isGroup ? 'Group info' : 'Contact info')),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          children: [
            if (_busy) const LinearProgressIndicator(minHeight: 2),
            const SizedBox(height: 24),
            Center(child: InitialAvatar(name: conv.displayName(me), radius: 40, group: conv.isGroup)),
            const SizedBox(height: 12),
            Center(child: Text(conv.displayName(me), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600))),
            if (other != null)
              Center(child: Text('@${other.user.username}', style: const TextStyle(color: AppTheme.onSurfaceMuted))),
            const SizedBox(height: 16),
            if (conv.isGroup && admin && active)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Change group name'),
                onTap: () => _rename(conv, engine),
              ),
            ListTile(
              leading: const Icon(Icons.verified_user_outlined),
              title: const Text('Verify security codes'),
              subtitle: const Text('Compare codes in person to confirm nobody is listening in'),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => SecurityCodesScreen(conversationId: conv.id)),
              ),
            ),
            if (conv.isGroup) ...[
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text('${conv.members.length} members', style: const TextStyle(color: AppTheme.onSurfaceMuted, fontSize: 12, fontWeight: FontWeight.w600)),
              ),
              if (admin && active)
                ListTile(
                  leading: const Icon(Icons.person_add_alt_1_outlined, color: AppTheme.primary),
                  title: const Text('Add people', style: TextStyle(color: AppTheme.primary)),
                  onTap: () => _addPeople(conv, engine),
                ),
              ...conv.members.map((m) => ListTile(
                    leading: InitialAvatar(name: m.user.displayName, radius: 20, online: chat.isOnline(m.user.id)),
                    title: Text(m.user.id == me ? '${m.user.displayName} (you)' : m.user.displayName),
                    subtitle: Text('@${m.user.username}', style: const TextStyle(color: AppTheme.onSurfaceMuted)),
                    trailing: m.isAdmin
                        ? const Text('Admin', style: TextStyle(color: AppTheme.primary, fontSize: 12))
                        : admin && active && m.user.id != me
                            ? IconButton(
                                tooltip: 'Remove',
                                icon: const Icon(Icons.remove_circle_outline, color: AppTheme.error),
                                onPressed: () async {
                                  if (await _confirm('Remove ${m.user.displayName}?', 'They will no longer get new messages in this group.', 'Remove')) {
                                    await _run(() => engine.removeFromGroup(conv.id, m.user.id));
                                  }
                                },
                              )
                            : null,
                  )),
              const Divider(),
              if (active)
                ListTile(
                  leading: const Icon(Icons.logout, color: AppTheme.error),
                  title: const Text('Leave group', style: TextStyle(color: AppTheme.error)),
                  onTap: () async {
                    if (await _confirm('Leave this group?', 'You will stop getting messages from this group.', 'Leave')) {
                      await _run(() => engine.leaveGroup(conv.id));
                    }
                  },
                ),
            ],
            if (other != null) ...[
              const Divider(),
              if (!chat.isContact(other.user.id))
                ListTile(
                  leading: const Icon(Icons.person_add_alt_1_outlined),
                  title: const Text('Add to contacts'),
                  onTap: () => _run(() => chat.addContact(other.user), done: 'Added to contacts'),
                ),
              _blocked.contains(other.user.id)
                  ? ListTile(
                      leading: const Icon(Icons.block),
                      title: Text('Unblock ${other.user.displayName}'),
                      onTap: () => _run(() async {
                        await engine.api.unblock(other.user.id);
                        await _loadBlocks();
                      }, done: 'Unblocked'),
                    )
                  : ListTile(
                      leading: const Icon(Icons.block, color: AppTheme.error),
                      title: Text('Block ${other.user.displayName}', style: const TextStyle(color: AppTheme.error)),
                      onTap: () async {
                        if (await _confirm('Block ${other.user.displayName}?', 'They will not be able to message or call you.', 'Block')) {
                          await _run(() async {
                            await engine.api.block(other.user.id);
                            await chat.loadContacts();
                            await _loadBlocks();
                          }, done: 'Blocked');
                        }
                      },
                    ),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

class SecurityCodesScreen extends StatelessWidget {
  final String conversationId;

  const SecurityCodesScreen({super.key, required this.conversationId});

  static String format(String fingerprint) {
    final clean = fingerprint.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
    final groups = <String>[];
    for (var i = 0; i < clean.length; i += 4) {
      groups.add(clean.substring(i, i + 4 > clean.length ? clean.length : i + 4));
    }
    return groups.join(' ');
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.read<ChatController>();
    final engine = chat.engine;
    final conv = chat.byId(conversationId);
    final members = engine.securityMembers(conversationId);
    final byUser = <String, List<String>>{};
    for (final m in members) {
      if (m.userId == chat.me && m.deviceId == engine.deviceId) continue;
      (byUser[m.userId] ??= []).add(m.fingerprint);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Security codes')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Each device in this chat has its own code. Meet or call the person and check that the codes on their phone match what you see here. If they match, nobody can read your messages but the people in this chat.',
            style: TextStyle(color: AppTheme.onSurfaceMuted),
          ),
          const SizedBox(height: 24),
          const Text('This phone', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          SelectableText(format(engine.ownFingerprint()), style: const TextStyle(fontFamily: 'monospace', fontSize: 15, letterSpacing: 1)),
          const SizedBox(height: 24),
          if (members.isEmpty)
            const Text('Encryption is still being set up for this chat.', style: TextStyle(color: AppTheme.onSurfaceMuted)),
          ...byUser.entries.map((e) {
            final name = e.key == chat.me
                ? 'Your other devices'
                : conv?.member(e.key)?.user.displayName ?? 'Former member';
            return Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  ...e.value.map((f) => Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: SelectableText(format(f), style: const TextStyle(fontFamily: 'monospace', fontSize: 15, letterSpacing: 1)),
                      )),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}
