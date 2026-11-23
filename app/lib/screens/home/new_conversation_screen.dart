import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/user_model.dart';
import '../../providers/chat_provider.dart';
import '../../services/api_service.dart';
import '../../utils/theme.dart';
import '../../widgets/avatar.dart';
import '../chat/chat_screen.dart';

class NewConversationScreen extends StatefulWidget {
  const NewConversationScreen({super.key});

  @override
  State<NewConversationScreen> createState() => _NewConversationScreenState();
}

class _NewConversationScreenState extends State<NewConversationScreen> {
  final _searchController = TextEditingController();
  List<UserModel> _results = [];
  bool _searching = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    if (query.trim().length < 2) {
      setState(() => _results = []);
      return;
    }
    setState(() => _searching = true);
    try {
      final api = context.read<ApiService>();
      final users = await api.searchUsers(query.trim());
      setState(() { _results = users; _searching = false; });
    } catch (_) {
      setState(() => _searching = false);
    }
  }

  Future<void> _startConversation(UserModel user) async {
    final chat = context.read<ChatProvider>();
    final conv = await chat.startDirectConversation(user.id);
    if (conv != null && mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => ChatScreen(conversation: conv)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New conversation')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Search by name or username',
                prefixIcon: Icon(Icons.search, color: AppTheme.onSurfaceMuted),
              ),
              onChanged: _search,
            ),
          ),
          if (_searching)
            const Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()),
          Expanded(
            child: ListView.builder(
              itemCount: _results.length,
              itemBuilder: (context, index) {
                final user = _results[index];
                return ListTile(
                  leading: UserAvatar(user: user, radius: 22),
                  title: Text(user.displayName),
                  subtitle: Text('@${user.username}', style: const TextStyle(color: AppTheme.onSurfaceMuted)),
                  trailing: user.isOnline
                      ? const Icon(Icons.circle, color: AppTheme.online, size: 10)
                      : null,
                  onTap: () => _startConversation(user),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
