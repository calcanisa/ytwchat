import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import '../../models/conversation_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../services/api_service.dart';
import '../../services/websocket_service.dart';
import '../../utils/theme.dart';
import '../../widgets/avatar.dart';
import '../../widgets/message_bubble.dart';
import '../call/call_screen.dart';

class ChatScreen extends StatefulWidget {
  final ConversationModel conversation;
  const ChatScreen({super.key, required this.conversation});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final _recorder = FlutterSoundRecorder();

  bool _recording = false;
  bool _sending = false;
  String? _recordingPath;
  Timer? _typingTimer;
  bool _isTyping = false;
  bool _recorderReady = false;

  @override
  void initState() {
    super.initState();
    _initRecorder();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await context.read<ChatProvider>().loadMessages(widget.conversation.id);
      await context.read<ChatProvider>().markRead(widget.conversation.id);
      _scrollToBottom();
    });
  }

  Future<void> _initRecorder() async {
    await _recorder.openRecorder();
    setState(() => _recorderReady = true);
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    _recorder.closeRecorder();
    _typingTimer?.cancel();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _onTextChanged(String value) {
    final ws = context.read<WebSocketService>();
    if (value.isNotEmpty && !_isTyping) {
      _isTyping = true;
      ws.sendTypingStart(widget.conversation.id);
    }
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(milliseconds: 1500), () {
      if (_isTyping) {
        _isTyping = false;
        ws.sendTypingStop(widget.conversation.id);
      }
    });
  }

  Future<void> _sendText() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _sending) return;
    _textController.clear();
    _isTyping = false;
    context.read<WebSocketService>().sendTypingStop(widget.conversation.id);
    setState(() => _sending = true);
    try {
      await context
          .read<ApiService>()
          .sendTextMessage(widget.conversation.id, text);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Failed to send message'),
              backgroundColor: AppTheme.error),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
      _scrollToBottom();
    }
  }

  Future<void> _startRecording() async {
    if (!_recorderReady) return;
    final status = await Permission.microphone.request();
    if (!status.isGranted) return;
    final dir = await getTemporaryDirectory();
    _recordingPath =
        '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.aac';
    await _recorder.startRecorder(toFile: _recordingPath, codec: Codec.aacADTS);
    setState(() => _recording = true);
  }

  Future<void> _stopAndSendRecording() async {
    await _recorder.stopRecorder();
    setState(() => _recording = false);
    if (_recordingPath == null) return;
    final file = File(_recordingPath!);
    if (!file.existsSync()) return;
    setState(() => _sending = true);
    try {
      await context
          .read<ApiService>()
          .sendVoiceNote(widget.conversation.id, file);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Failed to send voice note'),
              backgroundColor: AppTheme.error),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
      _scrollToBottom();
    }
  }

  Future<void> _cancelRecording() async {
    await _recorder.stopRecorder();
    setState(() => _recording = false);
  }

  void _startCall(bool isVideo) {
    final auth = context.read<AuthProvider>();
    final otherUser = widget.conversation.members
        .where((m) => m.id != auth.user?.id)
        .firstOrNull;
    if (otherUser == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CallScreen(
          conversation: widget.conversation,
          remoteUserId: otherUser.id,
          remoteDisplayName: otherUser.displayName,
          isVideo: isVideo,
          isOutgoing: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.read<AuthProvider>();
    final chat = context.watch<ChatProvider>();
    final messages = chat.getMessages(widget.conversation.id);
    final convName = widget.conversation.displayName(auth.user?.id ?? '');
    final isOnline = widget.conversation.isOnline(auth.user?.id ?? '');

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            ConversationAvatar(
              conversation: widget.conversation,
              currentUserId: auth.user?.id ?? '',
              radius: 18,
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(convName,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600)),
                Text(
                  isOnline ? 'online' : 'offline',
                  style: TextStyle(
                      fontSize: 12,
                      color:
                          isOnline ? AppTheme.online : AppTheme.onSurfaceMuted),
                ),
              ],
            ),
          ],
        ),
        actions: [
          if (widget.conversation.kind == ConversationKind.direct) ...[
            IconButton(
                icon: const Icon(Icons.call),
                onPressed: () => _startCall(false)),
            IconButton(
                icon: const Icon(Icons.videocam),
                onPressed: () => _startCall(true)),
          ],
          IconButton(icon: const Icon(Icons.more_vert), onPressed: () {}),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? const Center(
                    child: Text('No messages yet',
                        style: TextStyle(color: AppTheme.onSurfaceMuted)))
                : ListView.builder(
                    controller: _scrollController,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final message = messages[index];
                      final isOwn = message.senderId == auth.user?.id;
                      final showAvatar = !isOwn &&
                          (index == 0 ||
                              messages[index - 1].senderId != message.senderId);
                      return MessageBubble(
                        message: message,
                        isOwn: isOwn,
                        showAvatar: showAvatar,
                      );
                    },
                  ),
          ),
          _buildInputBar(),
        ],
      ),
    );
  }

  Widget _buildInputBar() {
    if (_recording) {
      return Container(
        color: AppTheme.surface,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            const Icon(Icons.circle, color: AppTheme.error, size: 12),
            const SizedBox(width: 8),
            const Expanded(
                child: Text('Recording...',
                    style: TextStyle(color: AppTheme.onSurfaceMuted))),
            IconButton(
              icon: const Icon(Icons.delete, color: AppTheme.onSurfaceMuted),
              onPressed: _cancelRecording,
            ),
            IconButton(
              icon: const Icon(Icons.send, color: AppTheme.primary),
              onPressed: _stopAndSendRecording,
            ),
          ],
        ),
      );
    }

    return Container(
      color: AppTheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _textController,
              onChanged: _onTextChanged,
              maxLines: null,
              decoration: const InputDecoration(
                hintText: 'Message',
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
            ),
          ),
          const SizedBox(width: 8),
          ValueListenableBuilder(
            valueListenable: _textController,
            builder: (_, value, __) {
              if (value.text.isEmpty) {
                return GestureDetector(
                  onLongPressStart: (_) => _startRecording(),
                  onLongPressEnd: (_) => _stopAndSendRecording(),
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: const BoxDecoration(
                        color: AppTheme.primary, shape: BoxShape.circle),
                    child: const Icon(Icons.mic, color: Colors.white, size: 20),
                  ),
                );
              }
              return GestureDetector(
                onTap: _sending ? null : _sendText,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: const BoxDecoration(
                      color: AppTheme.primary, shape: BoxShape.circle),
                  child: _sending
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.send, color: Colors.white, size: 20),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
