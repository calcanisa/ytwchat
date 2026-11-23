import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

import '../core/crypto/envelope.dart';
import '../core/sync/sync_engine.dart';
import '../screens/call/call_screen.dart';

enum CallPhase { idle, outgoing, incoming, connecting, active, ended }

class CallController extends ChangeNotifier {
  static const _iceServers = [
    {'urls': 'stun:stun.l.google.com:19302'},
    {'urls': 'stun:stun1.l.google.com:19302'},
  ];

  final SyncEngine engine;
  final GlobalKey<NavigatorState> navigatorKey;
  StreamSubscription<SyncEvent>? _sub;

  CallPhase phase = CallPhase.idle;
  String? callId;
  String? conversationId;
  String? peerUserId;
  String? peerDeviceId;
  String? peerName;
  bool video = false;
  bool muted = false;
  bool cameraOff = false;
  bool speaker = false;
  String? endReason;
  DateTime? connectedAt;

  RTCPeerConnection? _pc;
  MediaStream? _local;
  final localRenderer = RTCVideoRenderer();
  final remoteRenderer = RTCVideoRenderer();
  bool _renderersReady = false;
  bool hasRemoteVideo = false;

  Map<String, dynamic>? _offer;
  final List<RTCIceCandidate> _remoteQueue = [];
  bool _remoteSet = false;
  final List<Map<String, dynamic>> _outIce = [];
  Timer? _iceTimer;
  Timer? _ringTimer;
  Timer? _resetTimer;

  CallController(this.engine, this.navigatorKey) {
    _sub = engine.events.listen((e) {
      if (e is CallSignal) unawaited(_onSignal(e));
    });
  }

  bool get busy => phase != CallPhase.idle;

  Future<void> _onSignal(CallSignal s) async {
    final d = s.data;
    final kind = d['k'];
    final id = d['id'];
    if (kind is! String || id is! String || !isUuid(id)) return;

    if (s.userId == engine.userId) {
      if ((kind == 'answer' || kind == 'end') && phase == CallPhase.incoming && id == callId) {
        await _finish(kind == 'answer' ? 'Answered on another device' : null);
      }
      return;
    }

    switch (kind) {
      case 'offer':
        final sdp = d['sdp'];
        if (sdp is! String || sdp.length > 100000) return;
        if (busy) {
          await engine.sendCallSignal(s.conversationId, {'k': 'end', 'id': id, 'reason': 'busy'}, toDeviceIds: [s.deviceId]);
          return;
        }
        final conv = await engine.conversation(s.conversationId);
        if (conv == null || conv.isGroup || conv.member(s.userId) == null) return;
        _reset();
        callId = id;
        conversationId = s.conversationId;
        peerUserId = s.userId;
        peerDeviceId = s.deviceId;
        peerName = conv.member(s.userId)?.user.displayName ?? 'Someone';
        video = d['video'] == true;
        _offer = d;
        phase = CallPhase.incoming;
        notifyListeners();
        _ringTimer = Timer(const Duration(seconds: 45), () => _finish('Missed call'));
        _showScreen();
      case 'answer':
        final sdp = d['sdp'];
        if (phase != CallPhase.outgoing || id != callId || sdp is! String || sdp.length > 100000) return;
        _ringTimer?.cancel();
        peerDeviceId = s.deviceId;
        phase = CallPhase.connecting;
        notifyListeners();
        await _pc?.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
        await _remoteReady();
        _flushIce();
      case 'ice':
        if (id != callId || (peerDeviceId != null && s.deviceId != peerDeviceId)) return;
        final list = d['c'];
        if (list is! List || list.length > 50) return;
        for (final c in list) {
          if (c is! Map) continue;
          final candidate = c['candidate'];
          if (candidate is! String || candidate.length > 2000) continue;
          final ice = RTCIceCandidate(candidate, c['sdpMid'] as String?, (c['sdpMLineIndex'] as num?)?.toInt());
          if (_remoteSet) {
            await _pc?.addCandidate(ice);
          } else {
            _remoteQueue.add(ice);
          }
        }
      case 'end':
        if (id != callId || (peerDeviceId != null && s.deviceId != peerDeviceId)) return;
        final reason = d['reason'];
        await _finish(switch (reason) {
          'busy' => 'They are on another call',
          'declined' => 'Call declined',
          'no_answer' => 'No answer',
          _ => phase == CallPhase.incoming ? 'Missed call' : 'Call ended',
        });
    }
  }

  void _showScreen() {
    navigatorKey.currentState?.push(MaterialPageRoute(builder: (_) => const CallScreen()));
  }

  Future<String?> startCall({
    required String conversationId,
    required String peerUserId,
    required String peerName,
    required bool video,
  }) async {
    if (busy) return 'You are already on a call.';
    if (!await _permissions(video)) {
      return video ? 'Allow microphone and camera access to make video calls.' : 'Allow microphone access to make calls.';
    }
    _reset();
    callId = const Uuid().v4();
    this.conversationId = conversationId;
    this.peerUserId = peerUserId;
    this.peerName = peerName;
    this.video = video;
    phase = CallPhase.outgoing;
    notifyListeners();
    _showScreen();
    try {
      await _setup();
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      final sent = await engine.sendCallSignal(conversationId, {
        'k': 'offer',
        'id': callId,
        'video': video,
        'sdp': offer.sdp,
      });
      if (!sent) {
        await _finish('Could not reach ytwchat. Check your connection.');
        return null;
      }
      _ringTimer = Timer(const Duration(seconds: 45), () => hangup(reason: 'no_answer'));
    } catch (_) {
      await _finish('The call could not start.');
    }
    return null;
  }

  Future<void> accept() async {
    final offer = _offer;
    if (phase != CallPhase.incoming || offer == null) return;
    _ringTimer?.cancel();
    if (!await _permissions(video)) {
      await decline();
      return;
    }
    phase = CallPhase.connecting;
    notifyListeners();
    try {
      await _setup();
      await _pc!.setRemoteDescription(RTCSessionDescription(offer['sdp'] as String, 'offer'));
      await _remoteReady();
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      await engine.sendCallSignal(conversationId!, {'k': 'answer', 'id': callId, 'sdp': answer.sdp});
      _flushIce();
    } catch (_) {
      await hangup();
    }
  }

  Future<void> decline() async {
    if (callId != null && conversationId != null) {
      await engine.sendCallSignal(conversationId!, {'k': 'end', 'id': callId, 'reason': 'declined'});
    }
    await _finish(null);
  }

  Future<void> hangup({String? reason}) async {
    if (callId != null && conversationId != null && phase != CallPhase.ended && phase != CallPhase.idle) {
      await engine.sendCallSignal(conversationId!, {'k': 'end', 'id': callId, 'reason': ?reason});
    }
    await _finish(reason == 'no_answer' ? 'No answer' : 'Call ended');
  }

  void toggleMute() {
    muted = !muted;
    for (final t in _local?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = !muted;
    }
    notifyListeners();
  }

  void toggleCamera() {
    cameraOff = !cameraOff;
    for (final t in _local?.getVideoTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = !cameraOff;
    }
    notifyListeners();
  }

  Future<void> switchCamera() async {
    final tracks = _local?.getVideoTracks() ?? <MediaStreamTrack>[];
    if (tracks.isNotEmpty) await Helper.switchCamera(tracks.first);
  }

  Future<void> toggleSpeaker() async {
    speaker = !speaker;
    await Helper.setSpeakerphoneOn(speaker);
    notifyListeners();
  }

  Future<bool> _permissions(bool withVideo) async {
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) return false;
    if (withVideo) {
      final cam = await Permission.camera.request();
      if (!cam.isGranted) return false;
    }
    return true;
  }

  Future<void> _setup() async {
    if (!_renderersReady) {
      await localRenderer.initialize();
      await remoteRenderer.initialize();
      _renderersReady = true;
    }
    final pc = await createPeerConnection({'iceServers': _iceServers, 'sdpSemantics': 'unified-plan'});
    _pc = pc;
    final local = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': video ? {'facingMode': 'user'} : false,
    });
    _local = local;
    localRenderer.srcObject = local;
    for (final t in local.getTracks()) {
      await pc.addTrack(t, local);
    }
    speaker = video;
    await Helper.setSpeakerphoneOn(speaker);
    pc.onIceCandidate = (c) {
      if (c.candidate == null) return;
      _outIce.add({'candidate': c.candidate, 'sdpMid': c.sdpMid, 'sdpMLineIndex': c.sdpMLineIndex});
      _iceTimer ??= Timer(const Duration(milliseconds: 250), _flushIce);
    };
    pc.onTrack = (event) {
      if (event.streams.isEmpty) return;
      remoteRenderer.srcObject = event.streams.first;
      hasRemoteVideo = event.streams.first.getVideoTracks().isNotEmpty;
      notifyListeners();
    };
    pc.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        phase = CallPhase.active;
        connectedAt ??= DateTime.now();
        notifyListeners();
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        unawaited(hangup());
      }
    };
  }

  Future<void> _remoteReady() async {
    _remoteSet = true;
    for (final c in _remoteQueue) {
      await _pc?.addCandidate(c);
    }
    _remoteQueue.clear();
  }

  void _flushIce() {
    _iceTimer?.cancel();
    _iceTimer = null;
    final device = peerDeviceId;
    final cid = conversationId;
    if (device == null || cid == null || callId == null || _outIce.isEmpty) return;
    if (phase == CallPhase.outgoing || phase == CallPhase.incoming) return;
    while (_outIce.isNotEmpty) {
      final batch = _outIce.take(20).toList();
      _outIce.removeRange(0, batch.length);
      unawaited(engine.sendCallSignal(cid, {'k': 'ice', 'id': callId, 'c': batch}, toDeviceIds: [device]));
    }
  }

  Future<void> _finish(String? reason) async {
    if (phase == CallPhase.idle || phase == CallPhase.ended) return;
    _ringTimer?.cancel();
    _iceTimer?.cancel();
    _iceTimer = null;
    endReason = reason;
    phase = CallPhase.ended;
    notifyListeners();
    try {
      for (final t in _local?.getTracks() ?? <MediaStreamTrack>[]) {
        await t.stop();
      }
      await _local?.dispose();
      await _pc?.close();
    } catch (_) {}
    _local = null;
    _pc = null;
    localRenderer.srcObject = null;
    remoteRenderer.srcObject = null;
    _resetTimer?.cancel();
    _resetTimer = Timer(const Duration(milliseconds: 1500), () {
      _reset();
      notifyListeners();
    });
  }

  void _reset() {
    _resetTimer?.cancel();
    phase = CallPhase.idle;
    callId = null;
    conversationId = null;
    peerUserId = null;
    peerDeviceId = null;
    peerName = null;
    video = false;
    muted = false;
    cameraOff = false;
    speaker = false;
    endReason = null;
    connectedAt = null;
    hasRemoteVideo = false;
    _offer = null;
    _remoteQueue.clear();
    _remoteSet = false;
    _outIce.clear();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ringTimer?.cancel();
    _iceTimer?.cancel();
    _resetTimer?.cancel();
    _local?.dispose();
    _pc?.close();
    if (_renderersReady) {
      localRenderer.dispose();
      remoteRenderer.dispose();
    }
    super.dispose();
  }
}

