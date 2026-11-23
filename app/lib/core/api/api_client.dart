import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../session/session_store.dart';
import 'models.dart';

class ApiException implements Exception {
  final int? status;
  final String code;
  final String message;

  const ApiException(this.status, this.code, this.message);

  bool get isNetwork => code == 'network';
  bool get isConflict => status == 409;
  bool get isNotFound => status == 404;
  bool get isUnauthorized => status == 401;

  @override
  String toString() => message;

  static ApiException from(Object error) {
    if (error is ApiException) return error;
    if (error is DioException) {
      final res = error.response;
      if (res == null) {
        return const ApiException(
          null,
          'network',
          "Can't reach ytwchat. Check your connection and try again.",
        );
      }
      final data = res.data;
      if (data is Map && data['error'] is Map) {
        final e = data['error'] as Map;
        return ApiException(
          res.statusCode,
          (e['code'] as String?) ?? 'error',
          (e['message'] as String?) ?? 'Something went wrong. Try again.',
        );
      }
      if (res.statusCode == 401) {
        return const ApiException(401, 'unauthorized', 'Sign in again to continue.');
      }
      if (res.statusCode == 413) {
        return const ApiException(413, 'too_large', 'That file is too large.');
      }
      return ApiException(
        res.statusCode,
        'error',
        'Something went wrong on our side. Try again.',
      );
    }
    return const ApiException(null, 'error', 'Something went wrong. Try again.');
  }
}

class ApiClient {
  final Dio _dio;
  final SessionStore _sessions;
  Session? _session;
  Future<bool>? _refreshing;
  void Function()? onSessionExpired;

  ApiClient({required String baseUrl, required SessionStore sessions, Dio? dio})
      : _sessions = sessions,
        _dio = dio ??
            Dio(BaseOptions(
              baseUrl: baseUrl,
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 60),
              sendTimeout: const Duration(seconds: 120),
              contentType: Headers.jsonContentType,
              responseType: ResponseType.json,
            )) {
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: _onRequest,
      onError: _onError,
    ));
  }

  Session? get session => _session;

  void attach(Session session) => _session = session;

  void detach() {
    _session = null;
    _refreshing = null;
  }

  Future<void> _onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (options.extra['public'] == true) return handler.next(options);
    var current = _session;
    if (current == null) {
      return handler.reject(DioException(
        requestOptions: options,
        response: Response(requestOptions: options, statusCode: 401),
      ));
    }
    if (current.accessExpiringSoon) {
      await refresh();
      current = _session;
      if (current == null) {
        return handler.reject(DioException(
          requestOptions: options,
          response: Response(requestOptions: options, statusCode: 401),
        ));
      }
    }
    options.headers['Authorization'] = 'Bearer ${current.accessToken}';
    handler.next(options);
  }

  Future<void> _onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final options = err.requestOptions;
    final unauthorized = err.response?.statusCode == 401;
    if (!unauthorized ||
        options.extra['public'] == true ||
        options.extra['retried'] == true ||
        _session == null) {
      return handler.next(err);
    }
    final used = options.headers['Authorization'];
    final current = _session;
    final alreadyRotated =
        current != null && used != 'Bearer ${current.accessToken}';
    final ok = alreadyRotated || await refresh();
    final fresh = _session;
    if (!ok || fresh == null) return handler.next(err);
    options.extra['retried'] = true;
    options.headers['Authorization'] = 'Bearer ${fresh.accessToken}';
    try {
      handler.resolve(await _dio.fetch(options));
    } on DioException catch (e) {
      handler.next(e);
    }
  }

  Future<bool> refresh() {
    final inflight = _refreshing;
    if (inflight != null) return inflight;
    final future = _doRefresh();
    _refreshing = future;
    return future.whenComplete(() => _refreshing = null);
  }

  Future<bool> _doRefresh() async {
    final current = _session;
    if (current == null) return false;
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        '/auth/refresh',
        data: {'refresh_token': current.refreshToken},
        options: Options(extra: {'public': true}),
      );
      final t = AuthTokens.fromJson(res.data!);
      if (_session?.refreshToken != current.refreshToken) return _session != null;
      final next = current.withTokens(t.accessToken, t.refreshToken, t.expiresIn);
      _session = next;
      await _sessions.save(next);
      return true;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 401) {
        _session = null;
        onSessionExpired?.call();
      }
      return false;
    }
  }

  Future<String?> accessToken() async {
    final current = _session;
    if (current == null) return null;
    if (current.accessExpiringSoon) await refresh();
    return _session?.accessToken;
  }

  Future<T> _call<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } catch (e) {
      throw ApiException.from(e);
    }
  }

  Future<Map<String, dynamic>> _get(String path, {Map<String, dynamic>? query}) =>
      _call(() async =>
          (await _dio.get<Map<String, dynamic>>(path, queryParameters: query))
              .data!);

  Future<List<dynamic>> _getList(String path, {Map<String, dynamic>? query}) =>
      _call(() async =>
          (await _dio.get<List<dynamic>>(path, queryParameters: query)).data!);

  Future<dynamic> _post(String path, Object? body) =>
      _call(() async => (await _dio.post<dynamic>(path, data: body)).data);

  Future<void> _delete(String path, {Object? body}) =>
      _call(() async => await _dio.delete<dynamic>(path, data: body));

  Future<AuthResult> register({
    required String username,
    required String displayName,
    required String email,
    required String password,
    required DeviceDescriptor device,
  }) =>
      _call(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/auth/register',
          data: {
            'username': username,
            'display_name': displayName,
            'email': email,
            'password': password,
            'device': device.toJson(),
          },
          options: Options(extra: {'public': true}),
        );
        return AuthResult.fromJson(res.data!);
      });

  Future<AuthResult> login({
    required String email,
    required String password,
    required DeviceDescriptor device,
  }) =>
      _call(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/auth/login',
          data: {'email': email, 'password': password, 'device': device.toJson()},
          options: Options(extra: {'public': true}),
        );
        return AuthResult.fromJson(res.data!);
      });

  Future<void> logout() => _post('/auth/logout', null);

  Future<Me> me() async => Me.fromJson(await _get('/users/me'));

  Future<Me> updateMe({String? displayName}) async => Me.fromJson(
        await _call(() async => (await _dio.patch<Map<String, dynamic>>(
              '/users/me',
              data: {'display_name': ?displayName},
            ))
                .data!),
      );

  Future<void> deleteAccount(String? password) =>
      _delete('/users/me', body: {'password': password});

  Future<List<PublicUser>> searchUsers(String q) async =>
      (await _getList('/users/search', query: {'q': q}))
          .map((e) => PublicUser.fromJson(e as Map<String, dynamic>))
          .toList();

  Future<PublicUser> user(String id) async =>
      PublicUser.fromJson(await _get('/users/$id'));

  Future<List<Contact>> contacts() async => (await _getList('/contacts'))
      .map((e) => Contact.fromJson(e as Map<String, dynamic>))
      .toList();

  Future<PublicUser> addContact(String userId) async => PublicUser.fromJson(
      await _post('/contacts', {'contact_user_id': userId})
          as Map<String, dynamic>);

  Future<void> removeContact(String userId) => _delete('/contacts/$userId');

  Future<List<PhoneMatch>> lookupPhones(List<String> numbers) async =>
      ((await _post('/contacts/lookup', {'phone_numbers': numbers})) as List)
          .map((e) => PhoneMatch.fromJson(e as Map<String, dynamic>))
          .toList();

  Future<List<PublicUser>> blocks() async => (await _getList('/blocks'))
      .map((e) => PublicUser.fromJson(e as Map<String, dynamic>))
      .toList();

  Future<void> block(String userId) => _post('/blocks', {'user_id': userId});

  Future<void> unblock(String userId) => _delete('/blocks/$userId');

  Future<List<DeviceInfo>> devices() async => (await _getList('/devices'))
      .map((e) => DeviceInfo.fromJson(e as Map<String, dynamic>))
      .toList();

  Future<void> revokeDevice(String id) => _delete('/devices/$id');

  Future<KeyPackageCount> keyPackageCount() async =>
      KeyPackageCount.fromJson(await _get('/devices/current/key-packages'));

  Future<KeyPackageCount> uploadKeyPackages(
    List<Uint8List> packages, {
    Uint8List? lastResort,
  }) async =>
      KeyPackageCount.fromJson(await _post('/devices/current/key-packages', {
        'key_packages': packages.map(base64.encode).toList(),
        'last_resort': lastResort == null ? null : base64.encode(lastResort),
      }) as Map<String, dynamic>);

  Future<List<ClaimedKeyPackage>> claimKeyPackages(
    String userId, {
    List<String>? deviceIds,
  }) async =>
      ((await _post('/key-packages/$userId/claim', {'device_ids': deviceIds}))
              as List)
          .map((e) => ClaimedKeyPackage.fromJson(e as Map<String, dynamic>))
          .toList();

  Future<List<Conversation>> conversations() async =>
      (await _getList('/conversations'))
          .map((e) => Conversation.fromJson(e as Map<String, dynamic>))
          .toList();

  Future<Conversation> conversation(String id) async =>
      Conversation.fromJson(await _get('/conversations/$id'));

  Future<List<MemberDevice>> conversationDevices(String id) async =>
      (await _getList('/conversations/$id/devices'))
          .map((e) => MemberDevice.fromJson(e as Map<String, dynamic>))
          .toList();

  Future<Conversation> createConversation(String kind, List<String> memberIds) async =>
      Conversation.fromJson(await _post(
        '/conversations',
        {'kind': kind, 'member_ids': memberIds},
      ) as Map<String, dynamic>);

  Future<Conversation> addMembers(String id, List<String> userIds) async =>
      Conversation.fromJson(await _post(
        '/conversations/$id/members',
        {'user_ids': userIds},
      ) as Map<String, dynamic>);

  Future<void> removeMember(String id, String userId) =>
      _delete('/conversations/$id/members/$userId');

  Future<ServerMessage> sendMessage(
    String conversationId, {
    required String kind,
    required Uint8List payload,
    int? epoch,
    List<String>? recipientDeviceIds,
  }) async =>
      ServerMessage.fromJson(await _post('/conversations/$conversationId/messages', {
        'kind': kind,
        'payload': base64.encode(payload),
        'epoch': ?epoch,
        'recipient_device_ids': ?recipientDeviceIds,
      }) as Map<String, dynamic>);

  Future<List<ServerMessage>> pending({int limit = 100}) async =>
      (await _getList('/messages/pending', query: {'limit': limit}))
          .map((e) => ServerMessage.fromJson(e as Map<String, dynamic>))
          .toList();

  Future<void> ack(List<String> ids) async {
    if (ids.isEmpty) return;
    await _post('/messages/ack', {'message_ids': ids});
  }

  Future<String> uploadMedia(Uint8List bytes) => _call(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/media',
          data: Stream<List<int>>.value(bytes),
          options: Options(
            contentType: 'application/octet-stream',
            headers: {Headers.contentLengthHeader: bytes.length},
          ),
        );
        return res.data!['id'] as String;
      });

  Future<Uint8List> downloadMedia(String id) => _call(() async {
        final res = await _dio.get<List<int>>(
          '/media/$id',
          options: Options(responseType: ResponseType.bytes),
        );
        return Uint8List.fromList(res.data!);
      });

  Future<void> setPushToken(String? token) => _call(() async =>
      await _dio.put<dynamic>('/devices/current/push-token', data: {'push_token': token}));
}
