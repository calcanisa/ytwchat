import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';

import '../../app/call_controller.dart';
import '../../utils/theme.dart';
import '../../widgets/avatar.dart';

class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  late final CallController _call;
  Timer? _clock;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _call = context.read<CallController>();
    _call.addListener(_onChange);
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _call.phase == CallPhase.active) setState(() {});
    });
  }

  @override
  void dispose() {
    _call.removeListener(_onChange);
    _clock?.cancel();
    super.dispose();
  }

  void _onChange() {
    if (_call.phase == CallPhase.idle && !_closing && mounted) {
      _closing = true;
      Navigator.of(context).maybePop();
    }
  }

  String _status(CallController c) {
    switch (c.phase) {
      case CallPhase.outgoing:
        return 'Calling...';
      case CallPhase.incoming:
        return c.video ? 'Incoming video call' : 'Incoming voice call';
      case CallPhase.connecting:
        return 'Connecting...';
      case CallPhase.active:
        final since = c.connectedAt;
        if (since == null) return 'Connected';
        final d = DateTime.now().difference(since);
        return '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
      case CallPhase.ended:
        return c.endReason ?? 'Call ended';
      case CallPhase.idle:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<CallController>();
    final name = c.peerName ?? '';
    final showVideo = c.video && c.hasRemoteVideo && c.phase == CallPhase.active;
    return PopScope(
      canPop: c.phase == CallPhase.idle || c.phase == CallPhase.ended,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            if (showVideo)
              Positioned.fill(
                child: RTCVideoView(c.remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
              )
            else
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    InitialAvatar(name: name, radius: 48),
                    const SizedBox(height: 16),
                    Text(name, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Text(_status(c), style: const TextStyle(color: AppTheme.onSurfaceMuted)),
                    const SizedBox(height: 8),
                    const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.lock_outline, size: 12, color: AppTheme.onSurfaceMuted),
                        SizedBox(width: 4),
                        Text('End to end encrypted', style: TextStyle(color: AppTheme.onSurfaceMuted, fontSize: 12)),
                      ],
                    ),
                  ],
                ),
              ),
            if (c.video && !c.cameraOff && c.phase != CallPhase.incoming && c.phase != CallPhase.ended)
              Positioned(
                top: 48,
                right: 16,
                width: 100,
                height: 140,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: RTCVideoView(c.localRenderer, mirror: true, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
                ),
              ),
            if (showVideo)
              Positioned(
                top: 56,
                left: 16,
                child: Text(_status(c), style: const TextStyle(color: Colors.white, fontSize: 14)),
              ),
            Positioned(
              bottom: 48,
              left: 0,
              right: 0,
              child: c.phase == CallPhase.incoming ? _incoming(c) : _controls(c),
            ),
          ],
        ),
      ),
    );
  }

  Widget _incoming(CallController c) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _RoundButton(icon: Icons.call_end, color: AppTheme.error, size: 64, label: 'Decline', onTap: c.decline),
        _RoundButton(icon: c.video ? Icons.videocam : Icons.call, color: AppTheme.online, size: 64, label: 'Answer', onTap: c.accept),
      ],
    );
  }

  Widget _controls(CallController c) {
    final ended = c.phase == CallPhase.ended;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _RoundButton(
          icon: c.muted ? Icons.mic_off : Icons.mic,
          color: c.muted ? AppTheme.error : AppTheme.surfaceVariant,
          label: c.muted ? 'Unmute' : 'Mute',
          onTap: ended ? null : c.toggleMute,
        ),
        const SizedBox(width: 20),
        _RoundButton(icon: Icons.call_end, color: AppTheme.error, size: 64, label: 'End', onTap: ended ? null : () => c.hangup()),
        const SizedBox(width: 20),
        if (c.video) ...[
          _RoundButton(
            icon: c.cameraOff ? Icons.videocam_off : Icons.videocam,
            color: c.cameraOff ? AppTheme.error : AppTheme.surfaceVariant,
            label: 'Camera',
            onTap: ended ? null : c.toggleCamera,
          ),
          const SizedBox(width: 20),
          _RoundButton(icon: Icons.cameraswitch_outlined, color: AppTheme.surfaceVariant, label: 'Flip', onTap: ended ? null : c.switchCamera),
        ] else
          _RoundButton(
            icon: c.speaker ? Icons.volume_up : Icons.volume_down,
            color: c.speaker ? AppTheme.primary : AppTheme.surfaceVariant,
            label: 'Speaker',
            onTap: ended ? null : c.toggleSpeaker,
          ),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback? onTap;
  final double size;

  const _RoundButton({required this.icon, required this.color, required this.label, required this.onTap, this.size = 52});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        child: Opacity(
          opacity: onTap == null ? 0.5 : 1,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: size * 0.45),
          ),
        ),
      ),
    );
  }
}
