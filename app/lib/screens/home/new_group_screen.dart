import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/chat_controller.dart';
import '../../core/api/api_client.dart';
import '../../core/api/models.dart';
import '../../core/sync/sync_engine.dart';
import '../../utils/theme.dart';
import '../chat/chat_screen.dart';
import 'new_conversation_screen.dart';

class NewGroupScreen extends StatefulWidget {
  const NewGroupScreen({super.key});

  @override
  State<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends State<NewGroupScreen> {
  final _title = TextEditingController();
  final Map<String, PublicUser> _picked = {};
  bool _creating = false;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _toggle(PublicUser user) {
    setState(() {
      if (_picked.remove(user.id) == null) _picked[user.id] = user;
    });
  }

  Future<void> _create() async {
    final messenger = ScaffoldMessenger.of(context);
    final problem = SyncEngine.validateTitle(_title.text);
    if (problem != null) {
      messenger.showSnackBar(SnackBar(content: Text(problem), backgroundColor: AppTheme.error));
      return;
    }
    if (_picked.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('Add at least one person.'), backgroundColor: AppTheme.error));
      return;
    }
    setState(() => _creating = true);
    final navigator = Navigator.of(context);
    try {
      final id = await context.read<ChatController>().engine.createGroup(_title.text, _picked.keys.toList());
      navigator.pushReplacement(MaterialPageRoute(builder: (_) => ChatScreen(conversationId: id)));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message), backgroundColor: AppTheme.error));
      if (mounted) setState(() => _creating = false);
    } on SendException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message), backgroundColor: AppTheme.error));
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = context.read<ChatController>().me;
    return Scaffold(
      appBar: AppBar(
        title: const Text('New group'),
        actions: [
          TextButton(
            onPressed: _creating ? null : _create,
            child: _creating
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Create'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: TextField(
              controller: _title,
              maxLength: 60,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(hintText: 'Group name', counterText: ''),
            ),
          ),
          if (_picked.isNotEmpty)
            SizedBox(
              height: 52,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                children: _picked.values
                    .map((u) => Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: InputChip(label: Text(u.displayName), onDeleted: () => _toggle(u)),
                        ))
                    .toList(),
              ),
            ),
          Expanded(child: UserSearch(onPick: _toggle, selected: _picked.keys.toSet(), exclude: {me}, autofocus: false)),
        ],
      ),
    );
  }
}
