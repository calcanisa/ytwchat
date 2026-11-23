import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../utils/constants.dart';

enum WsEvent {
  newMessage,
  messageDeleted,
  userOnline,
  userOffline,
  typingStart,
  typingStop,
  messageRead,
  callOffer,
  callAnswer,
  callIceCandidate,
  callHangup,
  callRejected,
}

WsEvent? wsEventFromString(String s) {
  switch (s) {
    case 'new_message': return WsEvent.newMessage;
    case 'message_deleted': return WsEvent.messageDeleted;
    case 'user_online': return WsEvent.userOnline;
    case 'user_offline': return WsEvent.userOffline;
    case 'typing_start': return WsEvent.typingStart;
    case 'typing_stop': return WsEvent.typingStop;
    case 'message_read': return WsEvent.messageRead;
    case 'call_offer': return WsEvent.callOffer;
    case 'call_answer': return WsEvent.callAnswer;
    case 'call_ice_candidate': return WsEvent.callIceCandidate;
    case 'call_hangup': return WsEvent.callHangup;
    case 'call_rejected': return WsEvent.callRejected;
    default: return null;
  }
}

class WsMessage {
  final WsEvent event;
  final Map<String, dynamic> data;
  const WsMessage({required this.event, required this.data});
}

class WebSocketService {
  WebSocketChannel? _channel;
  StreamController<WsMessage>? _controller;
  String? _token;
  bool _intentionalClose = false;
  Timer? _reconnectTimer;

  Stream<WsMessage>? get stream => _controller?.stream;

  Future<void> connect(String token) async {
    _token = token;
    _intentionalClose = false;
    _controller ??= StreamController<WsMessage>.broadcast();
    _doConnect();
  }

  void _doConnect() {
    try {
      _channel = WebSocketChannel.connect(
        Uri.parse('${AppConstants.wsUrl}?token=$_token'),
      );

      _channel!.stream.listen(
        (data) {
          final json = jsonDecode(data as String) as Map<String, dynamic>;
          final event = wsEventFromString(json['event'] as String);
          if (event != null) {
            _controller?.add(WsMessage(
              event: event,
              data: json['data'] as Map<String, dynamic>,
            ));
          }
        },
        onDone: _onDisconnect,
        onError: (_) => _onDisconnect(),
      );
    } catch (_) {
      _onDisconnect();
    }
  }

  void _onDisconnect() {
    if (_intentionalClose) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(
      const Duration(milliseconds: AppConstants.wsReconnectDelayMs),
      _doConnect,
    );
  }

  void send(Map<String, dynamic> payload) {
    _channel?.sink.add(jsonEncode(payload));
  }

  void sendTypingStart(String conversationId) {
    send({'event': 'typing_start', 'data': {'conversation_id': conversationId}});
  }

  void sendTypingStop(String conversationId) {
    send({'event': 'typing_stop', 'data': {'conversation_id': conversationId}});
  }

  void sendCallOffer(String toUserId, String conversationId, String sdp) {
    send({'event': 'call_offer', 'data': {
      'to_user_id': toUserId,
      'conversation_id': conversationId,
      'sdp': sdp,
    }});
  }

  void sendCallAnswer(String toUserId, String conversationId, String sdp) {
    send({'event': 'call_answer', 'data': {
      'to_user_id': toUserId,
      'conversation_id': conversationId,
      'sdp': sdp,
    }});
  }

  void sendIceCandidate(String toUserId, String conversationId, String candidate) {
    send({'event': 'call_ice_candidate', 'data': {
      'to_user_id': toUserId,
      'conversation_id': conversationId,
      'candidate': candidate,
    }});
  }

  void sendCallHangup(String toUserId, String conversationId) {
    send({'event': 'call_hangup', 'data': {
      'to_user_id': toUserId,
      'conversation_id': conversationId,
    }});
  }

  void sendCallReject(String toUserId, String conversationId) {
    send({'event': 'call_reject', 'data': {
      'to_user_id': toUserId,
      'conversation_id': conversationId,
    }});
  }

  void disconnect() {
    _intentionalClose = true;
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _channel = null;
  }

  void dispose() {
    disconnect();
    _controller?.close();
    _controller = null;
  }
}
