import 'dart:io';
import 'package:dio/dio.dart';
import '../models/conversation_model.dart';
import '../models/message_model.dart';
import '../models/user_model.dart';
import '../utils/constants.dart';

class ApiService {
  final Dio _dio;

  ApiService(this._dio);

  Future<List<ConversationModel>> getConversations() async {
    final res = await _dio.get('${AppConstants.baseUrl}/conversations');
    return (res.data as List)
        .map((c) => ConversationModel.fromJson(c))
        .toList();
  }

  Future<ConversationModel> createDirectConversation(String otherUserId) async {
    final res = await _dio.post('${AppConstants.baseUrl}/conversations', data: {
      'kind': 'direct',
      'member_ids': [otherUserId],
    });
    return ConversationModel.fromJson(res.data);
  }

  Future<ConversationModel> createGroupConversation({
    required String name,
    required List<String> memberIds,
  }) async {
    final res = await _dio.post('${AppConstants.baseUrl}/conversations', data: {
      'kind': 'group',
      'name': name,
      'member_ids': memberIds,
    });
    return ConversationModel.fromJson(res.data);
  }

  Future<List<MessageModel>> getMessages(String conversationId,
      {String? before}) async {
    final res = await _dio.get(
      '${AppConstants.baseUrl}/conversations/$conversationId/messages',
      queryParameters: {
        'limit': AppConstants.messagesPageSize,
        if (before != null) 'before': before,
      },
    );
    return (res.data as List).map((m) => MessageModel.fromJson(m)).toList();
  }

  Future<MessageModel> sendTextMessage(String conversationId, String content,
      {String? replyToId}) async {
    final res = await _dio.post(
      '${AppConstants.baseUrl}/conversations/$conversationId/messages',
      data: {
        'kind': 'text',
        'content': content,
        if (replyToId != null) 'reply_to_id': replyToId,
      },
    );
    return MessageModel.fromJson(res.data);
  }

  Future<MessageModel> sendVoiceNote(String conversationId, File file) async {
    final uploadRes = await uploadFile(file);
    final res = await _dio.post(
      '${AppConstants.baseUrl}/conversations/$conversationId/messages',
      data: {
        'kind': 'voice_note',
        'media_url': uploadRes['url'],
      },
    );
    return MessageModel.fromJson(res.data);
  }

  Future<MessageModel> sendImageMessage(
      String conversationId, File file) async {
    final uploadRes = await uploadFile(file);
    final res = await _dio.post(
      '${AppConstants.baseUrl}/conversations/$conversationId/messages',
      data: {
        'kind': 'image',
        'media_url': uploadRes['url'],
      },
    );
    return MessageModel.fromJson(res.data);
  }

  Future<Map<String, dynamic>> uploadFile(File file) async {
    final formData = FormData.fromMap({
      'file': await MultipartFile.fromFile(file.path),
    });
    final res =
        await _dio.post('${AppConstants.baseUrl}/media/upload', data: formData);
    return res.data as Map<String, dynamic>;
  }

  Future<void> markRead(String conversationId) async {
    await _dio
        .post('${AppConstants.baseUrl}/conversations/$conversationId/read');
  }

  Future<List<UserModel>> searchUsers(String query) async {
    final res = await _dio.get(
      '${AppConstants.baseUrl}/users/search',
      queryParameters: {'q': query},
    );
    return (res.data as List).map((u) => UserModel.fromJson(u)).toList();
  }

  Future<UserModel> getMe() async {
    final res = await _dio.get('${AppConstants.baseUrl}/users/me');
    return UserModel.fromJson(res.data);
  }

  Future<List<UserModel>> getContacts() async {
    final res = await _dio.get('${AppConstants.baseUrl}/contacts');
    return (res.data as List).map((u) => UserModel.fromJson(u)).toList();
  }

  Future<UserModel> addContact(String userId) async {
    final res = await _dio.post('${AppConstants.baseUrl}/contacts', data: {
      'contact_user_id': userId,
    });
    return UserModel.fromJson(res.data);
  }

  Future<void> removeContact(String userId) async {
    await _dio.delete('${AppConstants.baseUrl}/contacts/$userId');
  }

  Future<List<Map<String, dynamic>>> lookupByPhones(
      List<String> phoneNumbers) async {
    final res =
        await _dio.post('${AppConstants.baseUrl}/contacts/lookup', data: {
      'phone_numbers': phoneNumbers,
    });
    return (res.data as List).cast<Map<String, dynamic>>();
  }
}
