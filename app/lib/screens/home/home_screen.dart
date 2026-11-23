import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_session.dart';
import '../../app/chat_controller.dart';
import '../../utils/theme.dart';
import '../../widgets/conversation_tile.dart';
import '../chat/chat_screen.dart';
import '../contacts/contacts_screen.dart';
import '../settings/settings_screen.dart';
import 'new_conversation_screen.dart';
import 'new_group_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  void _open(Widget page) => Navigator.push(context, MaterialPageRoute(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatController>();
    final session = context.read<AppSession>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('ytwchat'),
        actions: [
          if (_tab == 0)
            IconButton(
              tooltip: 'New chat',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => _open(const NewConversationScreen()),
            ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (v) {
              switch (v) {
                case 'group':
                  _open(const NewGroupScreen());
                case 'settings':
                  _open(const SettingsScreen());
                case 'signout':
                  session.logout();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'group', child: Text('New group')),
              PopupMenuItem(value: 'settings', child: Text('Settings')),
              PopupMenuItem(value: 'signout', child: Text('Sign out')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (!chat.connected)
            Container(
              width: double.infinity,
              color: AppTheme.surfaceVariant,
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: const Text(
                'Connecting...',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.onSurfaceMuted, fontSize: 12),
              ),
            ),
          Expanded(
            child: IndexedStack(
              index: _tab,
              children: [
                _ChatsTab(onNewChat: () => _open(const NewConversationScreen())),
                const ContactsScreen(),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        backgroundColor: AppTheme.surface,
        indicatorColor: AppTheme.primary.withValues(alpha: 0.2),
        destinations: [
          NavigationDestination(
            icon: Badge(
              isLabelVisible: chat.unreadTotal > 0,
              label: Text(chat.unreadTotal > 99 ? '99+' : '${chat.unreadTotal}'),
              child: const Icon(Icons.chat_bubble_outline),
            ),
            selectedIcon: const Icon(Icons.chat_bubble),
            label: 'Chats',
          ),
          const NavigationDestination(
            icon: Icon(Icons.people_outline),
            selectedIcon: Icon(Icons.people),
            label: 'Contacts',
          ),
        ],
      ),
    );
  }
}

class _ChatsTab extends StatelessWidget {
  final VoidCallback onNewChat;

  const _ChatsTab({required this.onNewChat});

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatController>();
    if (!chat.loaded) return const Center(child: CircularProgressIndicator());
    if (chat.conversations.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, size: 56, color: AppTheme.onSurfaceMuted),
              const SizedBox(height: 16),
              const Text('No chats yet', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              const Text(
                'Find someone by their username to start an encrypted chat.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.onSurfaceMuted),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: 200,
                child: ElevatedButton(onPressed: onNewChat, child: const Text('Start a chat')),
              ),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () async => chat.engine.resume(),
      child: ListView.builder(
        itemCount: chat.conversations.length,
        itemBuilder: (context, i) {
          final conv = chat.conversations[i];
          final other = conv.isGroup ? null : conv.others(chat.me).firstOrNull;
          return ConversationTile(
            conversation: conv,
            me: chat.me,
            online: other != null && chat.isOnline(other.user.id),
            typing: chat.typingIn(conv.id).isNotEmpty,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => ChatScreen(conversationId: conv.id)),
            ),
          );
        },
      ),
    );
  }
}
