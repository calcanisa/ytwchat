class AppConstants {
  static const String baseUrl = 'http://10.0.2.2:8001';
  static const String wsUrl = 'ws://192.168.10.215:8001/ws';

  static const String tokenKey = 'converse_token';
  static const String userIdKey = 'converse_user_id';

  static const int wsReconnectDelayMs = 3000;
  static const int typingDebounceMs = 1000;
  static const int messagesPageSize = 50;
}
