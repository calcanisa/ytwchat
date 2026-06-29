import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../utils/constants.dart';
import '../models/user_model.dart';

class AuthService {
  final Dio _dio;
  final FlutterSecureStorage _storage;

  AuthService(this._dio, this._storage);

  Future<String?> getToken() => _storage.read(key: AppConstants.tokenKey);
  Future<String?> getUserId() => _storage.read(key: AppConstants.userIdKey);

  Future<bool> isLoggedIn() async {
    final token = await getToken();
    return token != null;
  }

  Future<UserModel> register({
    required String username,
    required String displayName,
    required String email,
    required String password,
    String? phoneNumber,
  }) async {
    final res = await _dio.post('${AppConstants.baseUrl}/auth/register', data: {
      'username': username,
      'display_name': displayName,
      'email': email,
      'password': password,
      if (phoneNumber != null) 'phone_number': phoneNumber,
    });
    await _saveAuth(res.data);
    return UserModel.fromJson(res.data['user']);
  }

  Future<UserModel> login({
    required String email,
    required String password,
  }) async {
    final res = await _dio.post('${AppConstants.baseUrl}/auth/login', data: {
      'email': email,
      'password': password,
    });
    await _saveAuth(res.data);
    return UserModel.fromJson(res.data['user']);
  }

  Future<void> logout() async {
    await _storage.delete(key: AppConstants.tokenKey);
    await _storage.delete(key: AppConstants.userIdKey);
  }

  Future<void> _saveAuth(Map<String, dynamic> data) async {
    await _storage.write(key: AppConstants.tokenKey, value: data['token'] as String);
    await _storage.write(key: AppConstants.userIdKey, value: data['user']['id'] as String);
  }
}
