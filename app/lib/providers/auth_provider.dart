import 'package:flutter/material.dart';
import '../models/user_model.dart';
import '../services/auth_service.dart';
import '../services/websocket_service.dart';

enum AuthState { unknown, unauthenticated, authenticated }

class AuthProvider extends ChangeNotifier {
  final AuthService _authService;
  final WebSocketService _wsService;

  AuthState _state = AuthState.unknown;
  UserModel? _user;
  String? _error;

  AuthState get state => _state;
  UserModel? get user => _user;
  String? get error => _error;
  bool get isAuthenticated => _state == AuthState.authenticated;

  AuthProvider(this._authService, this._wsService);

  Future<void> init() async {
    final loggedIn = await _authService.isLoggedIn();
    if (loggedIn) {
      final token = await _authService.getToken();
      await _wsService.connect(token!);
      _state = AuthState.authenticated;
    } else {
      _state = AuthState.unauthenticated;
    }
    notifyListeners();
  }

  Future<bool> login(String email, String password) async {
    _error = null;
    try {
      _user = await _authService.login(email: email, password: password);
      final token = await _authService.getToken();
      await _wsService.connect(token!);
      _state = AuthState.authenticated;
      notifyListeners();
      return true;
    } on Exception catch (e) {
      _error = _parseError(e);
      notifyListeners();
      return false;
    }
  }

  Future<bool> register(String username, String displayName, String email, String password, {String? phoneNumber}) async {
    _error = null;
    try {
      _user = await _authService.register(
        username: username,
        displayName: displayName,
        email: email,
        password: password,
        phoneNumber: phoneNumber,
      );
      final token = await _authService.getToken();
      await _wsService.connect(token!);
      _state = AuthState.authenticated;
      notifyListeners();
      return true;
    } on Exception catch (e) {
      _error = _parseError(e);
      notifyListeners();
      return false;
    }
  }

  Future<void> logout() async {
    _wsService.disconnect();
    await _authService.logout();
    _user = null;
    _state = AuthState.unauthenticated;
    notifyListeners();
  }

  String _parseError(Exception e) {
    if (e is DioException) {
      return e.response?.data?['error'] as String? ?? 'Something went wrong';
    }
    return 'Something went wrong';
  }
}

class DioException implements Exception {
  final dynamic response;
  const DioException({this.response});
}
