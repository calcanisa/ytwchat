import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:uuid/uuid.dart';

import '../core/crypto/envelope.dart';
import '../core/store/local_db.dart';
import '../core/sync/sync_engine.dart';
import '../utils/temp_files.dart';
import '../utils/theme.dart';
import 'avatar.dart';

class MessageBubble extends StatelessWidget {
  final LocalMessage message;
  final SyncEngine engine;
  final bool isOwn;
  final String? senderName;
  final bool showSender;
  final VoidCallback? onRetry;

  const MessageBubble({
    super.key,
    required this.message,
    required this.engine,
    required this.isOwn,
    required this.senderName,
    required this.showSender,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final maxWidth = MediaQuery.of(context).size.width * 0.74;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisAlignment: isOwn ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isOwn && showSender)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: InitialAvatar(name: senderName ?? '?', radius: 14),
            )
          else if (!isOwn && senderName != null)
            const SizedBox(width: 36),
          Flexible(
            child: GestureDetector(
              onTap: message.status == MessageStatus.failed ? onRetry : null,
              child: Container(
                constraints: BoxConstraints(maxWidth: maxWidth),
                decoration: BoxDecoration(
                  color: isOwn ? AppTheme.messageBubbleOwn : AppTheme.messageBubbleOther,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(16),
                    topRight: const Radius.circular(16),
                    bottomLeft: Radius.circular(isOwn ? 16 : 4),
                    bottomRight: Radius.circular(isOwn ? 4 : 16),
                  ),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!isOwn && showSender && senderName != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          senderName!,
                          style: const TextStyle(color: AppTheme.primary, fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ),
                    _content(context),
                    const SizedBox(height: 2),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          DateFormat('HH:mm').format(message.sentAt.toLocal()),
                          style: TextStyle(fontSize: 10, color: isOwn ? Colors.white70 : AppTheme.onSurfaceMuted),
                        ),
                        if (isOwn) ...[
                          const SizedBox(width: 4),
                          _statusIcon(),
                        ],
                      ],
                    ),
                    if (message.status == MessageStatus.failed)
                      const Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: Text('Not sent. Tap to try again.', style: TextStyle(fontSize: 11, color: Colors.white)),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusIcon() {
    switch (message.status) {
      case MessageStatus.pending:
        return const Icon(Icons.schedule, size: 12, color: Colors.white70);
      case MessageStatus.failed:
        return const Icon(Icons.error_outline, size: 12, color: Colors.white);
      case MessageStatus.sent:
      case MessageStatus.received:
        return const Icon(Icons.done, size: 12, color: Colors.white70);
    }
  }

  Widget _content(BuildContext context) {
    final media = message.media;
    switch (message.type) {
      case EnvelopeType.text:
        return SelectableText(message.text ?? '', style: const TextStyle(fontSize: 15));
      case EnvelopeType.image:
        if (media == null) return const SizedBox.shrink();
        return _EncryptedImage(engine: engine, media: media);
      case EnvelopeType.voice:
        if (media == null) return const SizedBox.shrink();
        return VoiceNotePlayer(engine: engine, media: media);
      case EnvelopeType.file:
        if (media == null) return const SizedBox.shrink();
        return _FileAttachment(engine: engine, media: media);
      default:
        return const SizedBox.shrink();
    }
  }
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

class _EncryptedImage extends StatefulWidget {
  final SyncEngine engine;
  final MediaRef media;

  const _EncryptedImage({required this.engine, required this.media});

  @override
  State<_EncryptedImage> createState() => _EncryptedImageState();
}

class _EncryptedImageState extends State<_EncryptedImage> {
  late Future<Uint8List> _bytes = widget.engine.mediaBytes(widget.media);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _bytes,
      builder: (context, snap) {
        if (snap.hasError) {
          return SizedBox(
            width: 200,
            height: 120,
            child: Center(
              child: TextButton.icon(
                onPressed: () => setState(() => _bytes = widget.engine.mediaBytes(widget.media)),
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Photo unavailable. Retry'),
              ),
            ),
          );
        }
        if (!snap.hasData) {
          return const SizedBox(width: 200, height: 200, child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
        }
        return GestureDetector(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => _PhotoViewer(bytes: snap.data!)),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(
              snap.data!,
              fit: BoxFit.cover,
              width: 220,
              height: 220,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => const SizedBox(
                width: 200,
                height: 120,
                child: Center(child: Text('This photo could not be shown')),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PhotoViewer extends StatelessWidget {
  final Uint8List bytes;

  const _PhotoViewer({required this.bytes});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black),
      body: Center(child: InteractiveViewer(maxScale: 5, child: Image.memory(bytes))),
    );
  }
}

class _FileAttachment extends StatefulWidget {
  final SyncEngine engine;
  final MediaRef media;

  const _FileAttachment({required this.engine, required this.media});

  @override
  State<_FileAttachment> createState() => _FileAttachmentState();
}

class _FileAttachmentState extends State<_FileAttachment> {
  bool _busy = false;

  Future<void> _save() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes = await widget.engine.mediaBytes(widget.media);
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save file',
        fileName: widget.media.name ?? 'file',
        bytes: bytes,
      );
      if (path != null) messenger.showSnackBar(const SnackBar(content: Text('File saved')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e'), backgroundColor: AppTheme.error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: _busy ? null : _save,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _busy
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.insert_drive_file_outlined, size: 22),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.media.name ?? 'File', overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
                Text('${formatBytes(widget.media.size)}  Tap to save', style: const TextStyle(fontSize: 11, color: Colors.white70)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class VoiceNotePlayer extends StatefulWidget {
  final SyncEngine engine;
  final MediaRef media;

  const VoiceNotePlayer({super.key, required this.engine, required this.media});

  @override
  State<VoiceNotePlayer> createState() => _VoiceNotePlayerState();
}

class _VoiceNotePlayerState extends State<VoiceNotePlayer> {

  final _player = AudioPlayer();
  final List<StreamSubscription<dynamic>> _subs = [];
  bool _loading = false;
  bool _loaded = false;
  bool _playing = false;
  File? _temp;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _subs.add(_player.positionStream.listen((p) {
      if (mounted) setState(() => _position = p);
    }));
    _subs.add(_player.durationStream.listen((d) {
      if (mounted && d != null) setState(() => _duration = d);
    }));
    _subs.add(_player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed) {
        _player.pause();
        _player.seek(Duration.zero);
        if (mounted) setState(() => _playing = false);
      }
    }));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    _temp?.delete().ignore();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _player.pause();
      setState(() => _playing = false);
      return;
    }
    if (!_loaded) {
      setState(() => _loading = true);
      try {
        final bytes = await widget.engine.mediaBytes(widget.media);
        final dir = await voicePlaybackDir();
        await dir.create(recursive: true);
        final file = File('${dir.path}/${const Uuid().v4()}.aac');
        await file.writeAsBytes(bytes, flush: true);
        _temp = file;
        await _player.setFilePath(file.path);
        _loaded = true;
      } catch (_) {
        if (mounted) {
          setState(() => _loading = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('This voice note could not be played'), backgroundColor: AppTheme.error),
          );
        }
        return;
      }
      if (mounted) setState(() => _loading = false);
    }
    setState(() => _playing = true);
    unawaited(_player.play());
  }

  String _fmt(Duration d) =>
      '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final total = _duration > Duration.zero ? _duration : Duration(milliseconds: widget.media.durationMs ?? 0);
    final progress = total.inMilliseconds > 0 ? (_position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0) : 0.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: _loading ? null : _toggle,
          child: Container(
            width: 36,
            height: 36,
            decoration: const BoxDecoration(color: Colors.white24, shape: BoxShape.circle),
            child: _loading
                ? const Padding(padding: EdgeInsets.all(9), child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : Icon(_playing ? Icons.pause : Icons.play_arrow, size: 20, color: Colors.white),
          ),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 120,
              child: SliderTheme(
                data: const SliderThemeData(trackHeight: 2, thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6)),
                child: Slider(
                  value: progress,
                  onChanged: _loaded
                      ? (v) => _player.seek(Duration(milliseconds: (v * total.inMilliseconds).toInt()))
                      : null,
                  activeColor: Colors.white,
                  inactiveColor: Colors.white30,
                ),
              ),
            ),
            Text('${_fmt(_position)} / ${_fmt(total)}', style: const TextStyle(fontSize: 10, color: Colors.white70)),
          ],
        ),
      ],
    );
  }
}
