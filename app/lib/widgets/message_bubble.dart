import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import '../models/message_model.dart';
import '../utils/theme.dart';
import 'avatar.dart';

class MessageBubble extends StatelessWidget {
  final MessageModel message;
  final bool isOwn;
  final bool showAvatar;

  const MessageBubble({
    super.key,
    required this.message,
    required this.isOwn,
    required this.showAvatar,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisAlignment: isOwn ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isOwn && showAvatar)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: CircleAvatar(
                radius: 14,
                backgroundColor: AppTheme.surfaceVariant,
                child: Text(
                  message.senderDisplayName[0].toUpperCase(),
                  style: const TextStyle(fontSize: 11, color: AppTheme.onSurface),
                ),
              ),
            )
          else if (!isOwn)
            const SizedBox(width: 36),
          Flexible(
            child: Container(
              constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
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
                  if (!isOwn && showAvatar)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        message.senderDisplayName,
                        style: const TextStyle(color: AppTheme.primary, fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ),
                  _buildContent(),
                  const SizedBox(height: 2),
                  Align(
                    alignment: Alignment.bottomRight,
                    child: Text(
                      DateFormat('HH:mm').format(message.createdAt.toLocal()),
                      style: TextStyle(
                        fontSize: 10,
                        color: isOwn ? Colors.white70 : AppTheme.onSurfaceMuted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    if (message.isDeleted) {
      return const Text('This message was deleted', style: TextStyle(color: AppTheme.onSurfaceMuted, fontStyle: FontStyle.italic));
    }
    switch (message.kind) {
      case MessageKind.text:
        return Text(message.content ?? '', style: const TextStyle(fontSize: 15));
      case MessageKind.voiceNote:
        return VoiceNotePlayer(url: message.mediaUrl ?? '', durationSecs: message.mediaDurationSecs);
      case MessageKind.image:
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.network(message.mediaUrl ?? '', fit: BoxFit.cover, width: 200, height: 200),
        );
      case MessageKind.system:
        return Text(message.content ?? '', style: const TextStyle(color: AppTheme.onSurfaceMuted, fontSize: 13));
      default:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.attach_file, size: 16),
            const SizedBox(width: 4),
            Text(message.content ?? 'File', style: const TextStyle(fontSize: 14)),
          ],
        );
    }
  }
}

class VoiceNotePlayer extends StatefulWidget {
  final String url;
  final int? durationSecs;

  const VoiceNotePlayer({super.key, required this.url, this.durationSecs});

  @override
  State<VoiceNotePlayer> createState() => _VoiceNotePlayerState();
}

class _VoiceNotePlayerState extends State<VoiceNotePlayer> {
  final _player = AudioPlayer();
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _player.positionStream.listen((p) => setState(() => _position = p));
    _player.durationStream.listen((d) => setState(() => _duration = d ?? Duration.zero));
    _player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed) {
        setState(() { _playing = false; _position = Duration.zero; });
        _player.seek(Duration.zero);
        _player.pause();
      }
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlay() async {
    if (_playing) {
      await _player.pause();
      setState(() => _playing = false);
    } else {
      if (_player.audioSource == null) {
        await _player.setUrl(widget.url);
      }
      await _player.play();
      setState(() => _playing = true);
    }
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final total = _duration.inSeconds > 0 ? _duration : Duration(seconds: widget.durationSecs ?? 0);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: _togglePlay,
          child: Container(
            width: 36,
            height: 36,
            decoration: const BoxDecoration(color: Colors.white24, shape: BoxShape.circle),
            child: Icon(_playing ? Icons.pause : Icons.play_arrow, size: 20, color: Colors.white),
          ),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 120,
              child: SliderTheme(
                data: const SliderThemeData(
                  trackHeight: 2,
                  thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
                ),
                child: Slider(
                  value: total.inSeconds > 0
                      ? (_position.inSeconds / total.inSeconds).clamp(0.0, 1.0)
                      : 0.0,
                  onChanged: (v) => _player.seek(Duration(seconds: (v * total.inSeconds).toInt())),
                  activeColor: Colors.white,
                  inactiveColor: Colors.white30,
                ),
              ),
            ),
            Text(
              '${_formatDuration(_position)} / ${_formatDuration(total)}',
              style: const TextStyle(fontSize: 10, color: Colors.white70),
            ),
          ],
        ),
      ],
    );
  }
}
