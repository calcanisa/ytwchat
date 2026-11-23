import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/chat_controller.dart';
import '../../core/api/api_client.dart';
import '../../core/api/models.dart';
import '../../utils/theme.dart';
import '../../widgets/avatar.dart';
import '../chat/chat_screen.dart';

class UserSearch extends StatefulWidget {
  final void Function(PublicUser user) onPick;
  final Set<String> selected;
  final Set<String> exclude;
  final bool autofocus;

  const UserSearch({
    super.key,
    required this.onPick,
    this.selected = const {},
    this.exclude = const {},
    this.autofocus = true,
  });

  @override
  State<UserSearch> createState() => _UserSearchState();
}

class _UserSearchState extends State<UserSearch> {
  final _query = TextEditingController();
  Timer? _debounce;
  List<PublicUser> _results = [];
  bool _searching = false;
  String? _error;
  int _seq = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _changed(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(q));
  }

  Future<void> _search(String q) async {
    final term = q.trim().replaceFirst('@', '');
    final seq = ++_seq;
    if (term.length < 3) {
      setState(() {
        _results = [];
        _searching = false;
        _error = null;
      });
      return;
    }
    setState(() => _searching = true);
    try {
      final users = await context.read<ChatController>().engine.api.searchUsers(term);
      if (!mounted || seq != _seq) return;
      setState(() {
        _results = users;
        _searching = false;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _searching = false;
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatController>();
    final showContacts = _query.text.trim().length < 3;
    final users = showContacts ? chat.contacts.map((c) => c.user).toList() : _results;
    final visible = users.where((u) => !widget.exclude.contains(u.id)).toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: _query,
            autofocus: widget.autofocus,
            autocorrect: false,
            decoration: const InputDecoration(
              hintText: 'Search by username',
              prefixIcon: Icon(Icons.search, color: AppTheme.onSurfaceMuted),
            ),
            onChanged: _changed,
          ),
        ),
        if (_searching) const LinearProgressIndicator(minHeight: 2),
        if (_error != null)
          Padding(padding: const EdgeInsets.all(16), child: Text(_error!, style: const TextStyle(color: AppTheme.error))),
        if (showContacts && visible.isNotEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Contacts', style: TextStyle(color: AppTheme.onSurfaceMuted, fontSize: 12, fontWeight: FontWeight.w600)),
            ),
          ),
        if (!showContacts && !_searching && visible.isEmpty && _error == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('Nobody found with that username', style: TextStyle(color: AppTheme.onSurfaceMuted)),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: visible.length,
            itemBuilder: (context, i) {
              final user = visible[i];
              final picked = widget.selected.contains(user.id);
              return ListTile(
                leading: InitialAvatar(name: user.displayName, radius: 22, online: chat.isOnline(user.id)),
                title: Text(user.displayName),
                subtitle: Text('@${user.username}', style: const TextStyle(color: AppTheme.onSurfaceMuted)),
                trailing: picked ? const Icon(Icons.check_circle, color: AppTheme.primary) : null,
                onTap: () => widget.onPick(user),
              );
            },
          ),
        ),
      ],
    );
  }
}

class NewConversationScreen extends StatefulWidget {
  const NewConversationScreen({super.key});

  @override
  State<NewConversationScreen> createState() => _NewConversationScreenState();
}

class _NewConversationScreenState extends State<NewConversationScreen> {
  bool _opening = false;

  Future<void> _start(PublicUser user) async {
    if (_opening) return;
    setState(() => _opening = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final id = await context.read<ChatController>().engine.openDirect(user.id);
      navigator.pushReplacement(MaterialPageRoute(builder: (_) => ChatScreen(conversationId: id)));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message), backgroundColor: AppTheme.error));
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = context.read<ChatController>().me;
    return Scaffold(
      appBar: AppBar(title: const Text('New chat')),
      body: AbsorbPointer(
        absorbing: _opening,
        child: UserSearch(onPick: _start, exclude: {me}),
      ),
    );
  }
}
