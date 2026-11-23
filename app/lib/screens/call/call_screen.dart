import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';
import '../../models/conversation_model.dart';
import '../../services/websocket_service.dart';
import '../../utils/theme.dart';

class CallScreen extends StatefulWidget {
  final ConversationModel conversation;
  final String remoteUserId;
  final String remoteDisplayName;
  final bool isVideo;
  final bool isOutgoing;
  final Map<String, dynamic>? incomingOffer;

  const CallScreen({
    super.key,
    required this.conversation,
    required this.remoteUserId,
    required this.remoteDisplayName,
    required this.isVideo,
    required this.isOutgoing,
    this.incomingOffer,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  MediaStream? _remoteStream;

  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();

  bool _muted = false;
  bool _cameraOff = false;
  bool _connected = false;
  bool _ringing = true;

  StreamSubscription? _wsSub;

  static const _iceServers = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
    ]
  };

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    await _setupPeerConnection();
    _listenWsEvents();
    if (widget.isOutgoing) {
      await _startCall();
    } else if (widget.incomingOffer != null) {
      await _answerCall(widget.incomingOffer!['sdp'] as String);
    }
  }

  Future<void> _setupPeerConnection() async {
    _pc = await createPeerConnection(_iceServers);

    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': widget.isVideo ? {'facingMode': 'user'} : false,
    });

    _localRenderer.srcObject = _localStream;

    for (final track in _localStream!.getTracks()) {
      _pc!.addTrack(track, _localStream!);
    }

    _pc!.onIceCandidate = (candidate) {
      context.read<WebSocketService>().sendIceCandidate(
        widget.remoteUserId,
        widget.conversation.id,
        candidate.toMap().toString(),
      );
    };

    _pc!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        setState(() {
          _remoteStream = event.streams[0];
          _remoteRenderer.srcObject = _remoteStream;
          _connected = true;
          _ringing = false;
        });
      }
    };
  }

  void _listenWsEvents() {
    final ws = context.read<WebSocketService>();
    _wsSub = ws.stream?.listen((msg) async {
      switch (msg.event) {
        case WsEvent.callAnswer:
          final sdp = msg.data['sdp'] as String;
          await _pc?.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
          setState(() { _connected = true; _ringing = false; });
          break;

        case WsEvent.callIceCandidate:
          final candidateMap = msg.data['candidate'] as Map<String, dynamic>;
          await _pc?.addCandidate(RTCIceCandidate(
            candidateMap['candidate'] as String,
            candidateMap['sdpMid'] as String?,
            candidateMap['sdpMLineIndex'] as int?,
          ));
          break;

        case WsEvent.callHangup:
        case WsEvent.callRejected:
          _hangup(remote: true);
          break;

        default:
          break;
      }
    });
  }

  Future<void> _startCall() async {
    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);
    context.read<WebSocketService>().sendCallOffer(
      widget.remoteUserId,
      widget.conversation.id,
      offer.sdp!,
    );
  }

  Future<void> _answerCall(String offerSdp) async {
    await _pc!.setRemoteDescription(RTCSessionDescription(offerSdp, 'offer'));
    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer);
    context.read<WebSocketService>().sendCallAnswer(
      widget.remoteUserId,
      widget.conversation.id,
      answer.sdp!,
    );
    setState(() { _connected = true; _ringing = false; });
  }

  void _hangup({bool remote = false}) {
    if (!remote) {
      context.read<WebSocketService>().sendCallHangup(
        widget.remoteUserId,
        widget.conversation.id,
      );
    }
    _cleanup();
    if (mounted) Navigator.pop(context);
  }

  void _cleanup() {
    _wsSub?.cancel();
    _localStream?.dispose();
    _remoteStream?.dispose();
    _pc?.close();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
  }

  void _toggleMute() {
    final audioTracks = _localStream?.getAudioTracks();
    if (audioTracks != null) {
      for (final track in audioTracks) {
        track.enabled = _muted;
      }
    }
    setState(() => _muted = !_muted);
  }

  void _toggleCamera() {
    final videoTracks = _localStream?.getVideoTracks();
    if (videoTracks != null) {
      for (final track in videoTracks) {
        track.enabled = _cameraOff;
      }
    }
    setState(() => _cameraOff = !_cameraOff);
  }

  @override
  void dispose() {
    _cleanup();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (widget.isVideo && _connected)
            RTCVideoView(_remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
          else
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleAvatar(
                    radius: 48,
                    backgroundColor: AppTheme.surfaceVariant,
                    child: Text(
                      widget.remoteDisplayName[0].toUpperCase(),
                      style: const TextStyle(fontSize: 36, color: AppTheme.onSurface),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(widget.remoteDisplayName, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Text(
                    _ringing
                        ? (widget.isOutgoing ? 'Calling...' : 'Incoming call...')
                        : _connected ? (widget.isVideo ? 'Video call' : 'Voice call') : 'Connecting...',
                    style: const TextStyle(color: AppTheme.onSurfaceMuted),
                  ),
                ],
              ),
            ),

          if (widget.isVideo && _connected)
            Positioned(
              top: 48,
              right: 16,
              width: 100,
              height: 140,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: RTCVideoView(_localRenderer, mirror: true),
              ),
            ),

          Positioned(
            bottom: 48,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _CallButton(
                  icon: _muted ? Icons.mic_off : Icons.mic,
                  color: _muted ? AppTheme.error : AppTheme.surfaceVariant,
                  onTap: _toggleMute,
                ),
                const SizedBox(width: 24),
                _CallButton(
                  icon: Icons.call_end,
                  color: AppTheme.error,
                  size: 64,
                  onTap: _hangup,
                ),
                const SizedBox(width: 24),
                if (widget.isVideo)
                  _CallButton(
                    icon: _cameraOff ? Icons.videocam_off : Icons.videocam,
                    color: _cameraOff ? AppTheme.error : AppTheme.surfaceVariant,
                    onTap: _toggleCamera,
                  )
                else
                  _CallButton(
                    icon: Icons.volume_up,
                    color: AppTheme.surfaceVariant,
                    onTap: () {},
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CallButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final double size;

  const _CallButton({
    required this.icon,
    required this.color,
    required this.onTap,
    this.size = 52,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Icon(icon, color: Colors.white, size: size * 0.45),
      ),
    );
  }
}
