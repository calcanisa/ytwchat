import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../utils/theme.dart';
import '../../widgets/conversation_tile.dart';
import '../chat/chat_screen.dart';
import '../contacts/contacts_screen.dart';
import 'new_conversation_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ChatProvider>().loadConversations();
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.read<AuthProvider>();
    final chat = context.watch<ChatProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Converse'),
        actions: [
          if (_tab == 0)
            IconButton(
              icon: const Icon(Icons.edit),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const NewConversationScreen()),
              ),
            ),
          PopupMenuButton(
            icon: const Icon(Icons.more_vert),
            itemBuilder: (_) => [
              PopupMenuItem(onTap: auth.logout, child: const Text('Sign out')),
            ],
          ),
        ],
      ),
      body: IndexedStack(
        index: _tab,
        children: [
          chat.conversations.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.chat_bubble_outline,
                          size: 64, color: AppTheme.onSurfaceMuted),
                      SizedBox(height: 16),
                      Text('No conversations yet',
                          style: TextStyle(color: AppTheme.onSurfaceMuted)),
                      SizedBox(height: 8),
                      Text('Go to Contacts to start chatting',
                          style: TextStyle(
                              color: AppTheme.onSurfaceMuted, fontSize: 13)),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: chat.conversations.length,
                  itemBuilder: (context, index) {
                    final conv = chat.conversations[index];
                    return ConversationTile(
                      conversation: conv,
                      currentUserId: auth.user?.id ?? '',
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => ChatScreen(conversation: conv)),
                      ),
                    );
                  },
                ),
          const ContactsScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        backgroundColor: AppTheme.surface,
        indicatorColor: AppTheme.primary.withValues(alpha: 0.2),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: 'Chats',
          ),
          NavigationDestination(
            icon: Icon(Icons.people_outline),
            selectedIcon: Icon(Icons.people),
            label: 'Contacts',
          ),
        ],
      ),
    );
  }
}
