import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../app/call_controller.dart';
import '../../app/chat_controller.dart';
import '../../core/config.dart';
import '../../core/crypto/envelope.dart';
import '../../core/store/local_db.dart';
import '../../core/sync/sync_engine.dart';
import '../../utils/mime.dart';
import '../../utils/theme.dart';
import '../../widgets/avatar.dart';
import '../../widgets/message_bubble.dart';
import 'conversation_info_screen.dart';

class ChatScreen extends StatefulWidget {
  final String conversationId;

  const ChatScreen({super.key, required this.conversationId});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _text = TextEditingController();
  final _scroll = ScrollController();
  final _recorder = FlutterSoundRecorder();
  late final ChatController _chat;
  StreamSubscription<String>? _updates;

  List<LocalMessage> _messages = [];
  bool _loadingOlder = false;
  bool _hasOlder = true;
  bool _recorderReady = false;
  bool _recording = false;
  DateTime? _recordStarted;
  String? _recordPath;
  int _uploads = 0;

  String get _cid => widget.conversationId;
  SyncEngine get _engine => _chat.engine;

  @override
  void initState() {
    super.initState();
    _chat = context.read<ChatController>();
    _engine.activeConversationId = _cid;
    _updates = _chat.messageUpdates.where((id) => id == _cid).listen((_) => _reload());
    _scroll.addListener(_onScroll);
    _text.addListener(() => setState(() {}));
    unawaited(_reload());
    unawaited(_engine.markRead(_cid));
  }

  @override
  void dispose() {
    if (_engine.activeConversationId == _cid) _engine.activeConversationId = null;
    _updates?.cancel();
    _text.dispose();
    _scroll.dispose();
    if (_recorderReady) _recorder.closeRecorder();
    final path = _recordPath;
    if (path != null) File(path).delete().ignore();
    super.dispose();
  }

  Future<void> _reload() async {
    final latest = await _engine.messages(_cid, limit: _messages.length < 100 ? 100 : _messages.length + 20);
    if (!mounted) return;
    setState(() => _messages = latest);
    unawaited(_engine.markRead(_cid));
  }

  void _onScroll() {
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 300) _loadOlder();
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder || !_hasOlder || _messages.isEmpty) return;
    _loadingOlder = true;
    final older = await _engine.messages(
      _cid,
      limit: 100,
      beforeSentAt: _messages.first.sentAt.millisecondsSinceEpoch,
    );
    if (!mounted) return;
    setState(() {
      _hasOlder = older.length == 100;
      final known = _messages.map((m) => m.id).toSet();
      _messages = [...older.where((m) => !known.contains(m.id)), ..._messages];
    });
    _loadingOlder = false;
  }

  void _error(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'), backgroundColor: AppTheme.error));
  }

  Future<void> _sendText() async {
    final text = _text.text;
    if (text.trim().isEmpty) return;
    try {
      await _engine.sendText(_cid, text);
      _text.clear();
    } on SendException catch (e) {
      _error(e);
    }
  }

  Future<void> _sendMedia(EnvelopeType type, Future<(Uint8List, String, String?)?> Function() pick, {int? durationMs}) async {
    setState(() => _uploads++);
    try {
      final picked = await pick();
      if (picked == null) return;
      final (bytes, mime, name) = picked;
      await _engine.sendMedia(_cid, type: type, bytes: bytes, mime: mime, name: name, durationMs: durationMs);
    } on SendException catch (e) {
      _error(e);
    } catch (_) {
      _error('That could not be sent. Try again.');
    } finally {
      if (mounted) setState(() => _uploads--);
    }
  }

  Future<void> _pickImage(ImageSource source) => _sendMedia(EnvelopeType.image, () async {
        final file = await ImagePicker().pickImage(
          source: source,
          maxWidth: 2560,
          maxHeight: 2560,
          imageQuality: 85,
          requestFullMetadata: false,
        );
        if (file == null) return null;
        final bytes = await file.readAsBytes();
        final mime = imageMime(bytes);
        if (mime == null) throw const SendException('That photo format is not supported.');
        return (bytes, mime, null);
      });

  Future<void> _pickFile() => _sendMedia(EnvelopeType.file, () async {
        final result = await FilePicker.platform.pickFiles(withData: true);
        final file = result?.files.firstOrNull;
        if (file == null) return null;
        if (file.size > AppConfig.maxMediaBytes) throw const SendException('Files can be up to 60 MB.');
        final bytes = file.bytes;
        if (bytes == null) throw const SendException('That file could not be read.');
        return (bytes, fileMime(file.name), file.name);
      });

  void _attach() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.surface,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Photo from gallery'),
              onTap: () {
                Navigator.pop(sheet);
                _pickImage(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () {
                Navigator.pop(sheet);
                _pickImage(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: const Text('File'),
              onTap: () {
                Navigator.pop(sheet);
                _pickFile();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _startRecording() async {
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      _error('Allow microphone access to record voice notes.');
      return;
    }
    if (!_recorderReady) {
      await _recorder.openRecorder();
      _recorderReady = true;
    }
    final dir = await getTemporaryDirectory();
    _recordPath = '${dir.path}/voice_${DateTime.now().microsecondsSinceEpoch}.aac';
    await _recorder.startRecorder(toFile: _recordPath, codec: Codec.aacADTS, bitRate: 32000, sampleRate: 22050);
    setState(() {
      _recording = true;
      _recordStarted = DateTime.now();
    });
  }

  Future<void> _stopRecording({required bool send}) async {
    await _recorder.stopRecorder();
    final path = _recordPath;
    final started = _recordStarted;
    setState(() {
      _recording = false;
      _recordStarted = null;
      _recordPath = null;
    });
    if (path == null) return;
    final file = File(path);
    if (!send || started == null) {
      await file.delete().catchError((_) => file);
      return;
    }
    final duration = DateTime.now().difference(started).inMilliseconds;
    if (duration < 700) {
      await file.delete().catchError((_) => file);
      _error('Hold on a little longer to record a voice note.');
      return;
    }
    await _sendMedia(EnvelopeType.voice, () async {
      try {
        return (await file.readAsBytes(), 'audio/aac', null);
      } finally {
        await file.delete().catchError((_) => file);
      }
    }, durationMs: duration);
  }

  Future<void> _call(LocalConversation conv, bool video) async {
    final other = conv.others(_chat.me).firstOrNull;
    if (other == null) return;
    final error = await context.read<CallController>().startCall(
          conversationId: conv.id,
          peerUserId: other.user.id,
          peerName: other.user.displayName,
          video: video,
        );
    if (error != null) _error(error);
  }

  String _subtitle(LocalConversation conv) {
    final typing = _chat.typingIn(conv.id);
    if (typing.isNotEmpty) {
      if (!conv.isGroup) return 'typing...';
      final names = typing.map((id) => conv.member(id)?.user.displayName ?? 'Someone').toList();
      return '${names.join(', ')} typing...';
    }
    if (conv.state == GroupState.left) return 'You are no longer in this chat';
    if (conv.isGroup) return '${conv.members.length} members';
    final other = conv.others(_chat.me).firstOrNull;
    if (other == null) return '';
    return _chat.isOnline(other.user.id) ? 'online' : 'end to end encrypted';
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatController>();
    final conv = chat.byId(_cid);
    if (conv == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    }
    final name = conv.displayName(chat.me);
    final other = conv.isGroup ? null : conv.others(chat.me).firstOrNull;
    final canCall = !conv.isGroup && other != null && conv.state == GroupState.ready;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ConversationInfoScreen(conversationId: _cid))),
          child: Row(
            children: [
              InitialAvatar(
                name: name,
                radius: 18,
                group: conv.isGroup,
                online: other != null && chat.isOnline(other.user.id),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    Text(
                      _subtitle(conv),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: AppTheme.onSurfaceMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (canCall) ...[
            IconButton(tooltip: 'Voice call', icon: const Icon(Icons.call), onPressed: () => _call(conv, false)),
            IconButton(tooltip: 'Video call', icon: const Icon(Icons.videocam), onPressed: () => _call(conv, true)),
          ],
        ],
      ),
      body: Column(
        children: [
          if (conv.state == GroupState.waiting)
            Container(
              width: double.infinity,
              color: AppTheme.surfaceVariant,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: const Text(
                'Setting up encryption. Messages will send as soon as everyone has a device online.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: AppTheme.onSurfaceMuted),
              ),
            ),
          if (_uploads > 0) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: _messages.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Text(
                        'Messages in this chat are end to end encrypted. Say hello.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppTheme.onSurfaceMuted),
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    reverse: true,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final i = _messages.length - 1 - index;
                      final m = _messages[i];
                      final isOwn = m.senderUserId == chat.me;
                      final firstOfRun = i == 0 || _messages[i - 1].senderUserId != m.senderUserId;
                      return MessageBubble(
                        key: ValueKey(m.id),
                        message: m,
                        engine: _engine,
                        isOwn: isOwn,
                        senderName: conv.isGroup ? (conv.member(m.senderUserId)?.user.displayName ?? 'Former member') : null,
                        showSender: conv.isGroup && firstOfRun,
                        onRetry: () => _engine.retry(m.id),
                      );
                    },
                  ),
          ),
          if (conv.state == GroupState.left)
            Container(
              width: double.infinity,
              color: AppTheme.surface,
              padding: const EdgeInsets.all(16),
              child: const SafeArea(
                top: false,
                child: Text('You can no longer send messages here.', textAlign: TextAlign.center, style: TextStyle(color: AppTheme.onSurfaceMuted)),
              ),
            )
          else
            _inputBar(),
        ],
      ),
    );
  }

  Widget _inputBar() {
    if (_recording) {
      return Container(
        color: AppTheme.surface,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: SafeArea(
          top: false,
          child: Row(
            children: [
              const Icon(Icons.circle, color: AppTheme.error, size: 12),
              const SizedBox(width: 8),
              const Expanded(child: Text('Recording voice note', style: TextStyle(color: AppTheme.onSurfaceMuted))),
              IconButton(
                tooltip: 'Discard',
                icon: const Icon(Icons.delete_outline, color: AppTheme.onSurfaceMuted),
                onPressed: () => _stopRecording(send: false),
              ),
              IconButton(
                tooltip: 'Send voice note',
                icon: const Icon(Icons.send, color: AppTheme.primary),
                onPressed: () => _stopRecording(send: true),
              ),
            ],
          ),
        ),
      );
    }
    final hasText = _text.text.trim().isNotEmpty;
    return Container(
      color: AppTheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            IconButton(tooltip: 'Attach', icon: const Icon(Icons.add, color: AppTheme.onSurfaceMuted), onPressed: _attach),
            Expanded(
              child: TextField(
                controller: _text,
                minLines: 1,
                maxLines: 5,
                maxLength: AppConfig.maxTextLength,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  hintText: 'Message',
                  counterText: '',
                  contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
                onChanged: (v) {
                  if (v.trim().isNotEmpty) unawaited(_engine.typing(_cid));
                },
              ),
            ),
            const SizedBox(width: 4),
            hasText
                ? IconButton(tooltip: 'Send', icon: const Icon(Icons.send, color: AppTheme.primary), onPressed: _sendText)
                : IconButton(tooltip: 'Record voice note', icon: const Icon(Icons.mic, color: AppTheme.onSurfaceMuted), onPressed: _startRecording),
          ],
        ),
      ),
    );
  }
}
