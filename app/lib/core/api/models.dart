import 'dart:convert';
import 'dart:typed_data';

DateTime _time(Object? v) =>
    v is String ? DateTime.parse(v).toUtc() : DateTime.now().toUtc();

class PublicUser {
  final String id;
  final String username;
  final String displayName;
  final String? avatarMediaId;

  const PublicUser({
    required this.id,
    required this.username,
    required this.displayName,
    this.avatarMediaId,
  });

  factory PublicUser.fromJson(Map<String, dynamic> j) => PublicUser(
        id: j['id'] as String,
        username: j['username'] as String,
        displayName: j['display_name'] as String,
        avatarMediaId: j['avatar_media_id'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'display_name': displayName,
        'avatar_media_id': avatarMediaId,
      };

  String get initial => initialOf(displayName);
}

String initialOf(String name) {
  final runes = name.trim().runes;
  return runes.isEmpty ? '?' : String.fromCharCode(runes.first).toUpperCase();
}

class Me {
  final String id;
  final String username;
  final String displayName;
  final String email;
  final bool emailVerified;
  final String? phone;
  final bool phoneVerified;
  final bool hasPassword;
  final bool ytwLinked;

  const Me({
    required this.id,
    required this.username,
    required this.displayName,
    required this.email,
    required this.emailVerified,
    this.phone,
    required this.phoneVerified,
    required this.hasPassword,
    required this.ytwLinked,
  });

  factory Me.fromJson(Map<String, dynamic> j) => Me(
        id: j['id'] as String,
        username: j['username'] as String,
        displayName: j['display_name'] as String,
        email: j['email'] as String,
        emailVerified: j['email_verified'] as bool? ?? false,
        phone: j['phone_e164'] as String?,
        phoneVerified: j['phone_verified'] as bool? ?? false,
        hasPassword: j['has_password'] as bool? ?? true,
        ytwLinked: j['ytw_linked'] as bool? ?? false,
      );

  PublicUser get asPublic =>
      PublicUser(id: id, username: username, displayName: displayName);
}

class Contact {
  final PublicUser user;
  final bool online;

  const Contact({required this.user, required this.online});

  factory Contact.fromJson(Map<String, dynamic> j) => Contact(
        user: PublicUser.fromJson(j),
        online: j['online'] as bool? ?? false,
      );
}

class PhoneMatch {
  final String phoneNumber;
  final PublicUser user;

  const PhoneMatch({required this.phoneNumber, required this.user});

  factory PhoneMatch.fromJson(Map<String, dynamic> j) => PhoneMatch(
        phoneNumber: j['phone_number'] as String,
        user: PublicUser.fromJson(j),
      );
}

class Member {
  final PublicUser user;
  final String role;

  const Member({required this.user, required this.role});

  bool get isAdmin => role == 'admin';

  factory Member.fromJson(Map<String, dynamic> j) =>
      Member(user: PublicUser.fromJson(j), role: j['role'] as String);

  Map<String, dynamic> toJson() => {...user.toJson(), 'role': role};
}

class Conversation {
  final String id;
  final String kind;
  final int epoch;
  final DateTime createdAt;
  final DateTime lastActivityAt;
  final List<Member> members;

  const Conversation({
    required this.id,
    required this.kind,
    required this.epoch,
    required this.createdAt,
    required this.lastActivityAt,
    required this.members,
  });

  bool get isGroup => kind == 'group';

  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
        id: j['id'] as String,
        kind: j['kind'] as String,
        epoch: (j['epoch'] as num).toInt(),
        createdAt: _time(j['created_at']),
        lastActivityAt: _time(j['last_activity_at']),
        members: (j['members'] as List)
            .map((m) => Member.fromJson(m as Map<String, dynamic>))
            .toList(),
      );
}

class ServerMessage {
  final String id;
  final String conversationId;
  final String senderUserId;
  final String senderDeviceId;
  final String kind;
  final int? epoch;
  final Uint8List payload;
  final DateTime createdAt;

  const ServerMessage({
    required this.id,
    required this.conversationId,
    required this.senderUserId,
    required this.senderDeviceId,
    required this.kind,
    required this.epoch,
    required this.payload,
    required this.createdAt,
  });

  factory ServerMessage.fromJson(Map<String, dynamic> j) => ServerMessage(
        id: j['id'] as String,
        conversationId: j['conversation_id'] as String,
        senderUserId: j['sender_user_id'] as String,
        senderDeviceId: j['sender_device_id'] as String,
        kind: j['kind'] as String,
        epoch: (j['epoch'] as num?)?.toInt(),
        payload: base64.decode(j['payload'] as String),
        createdAt: _time(j['created_at']),
      );
}

class MemberDevice {
  final String userId;
  final String deviceId;

  const MemberDevice({required this.userId, required this.deviceId});

  factory MemberDevice.fromJson(Map<String, dynamic> j) => MemberDevice(
        userId: j['user_id'] as String,
        deviceId: j['device_id'] as String,
      );

  String get key => '$userId:$deviceId';
}

class ClaimedKeyPackage {
  final String deviceId;
  final Uint8List keyPackage;

  const ClaimedKeyPackage({required this.deviceId, required this.keyPackage});

  factory ClaimedKeyPackage.fromJson(Map<String, dynamic> j) =>
      ClaimedKeyPackage(
        deviceId: j['device_id'] as String,
        keyPackage: base64.decode(j['key_package'] as String),
      );
}

class KeyPackageCount {
  final int available;
  final bool hasLastResort;

  const KeyPackageCount({required this.available, required this.hasLastResort});

  factory KeyPackageCount.fromJson(Map<String, dynamic> j) => KeyPackageCount(
        available: (j['available'] as num).toInt(),
        hasLastResort: j['has_last_resort'] as bool? ?? false,
      );
}

class DeviceInfo {
  final String id;
  final String name;
  final String platform;
  final DateTime createdAt;
  final DateTime lastSeenAt;
  final bool current;

  const DeviceInfo({
    required this.id,
    required this.name,
    required this.platform,
    required this.createdAt,
    required this.lastSeenAt,
    required this.current,
  });

  factory DeviceInfo.fromJson(Map<String, dynamic> j) => DeviceInfo(
        id: j['id'] as String,
        name: j['name'] as String,
        platform: j['platform'] as String,
        createdAt: _time(j['created_at']),
        lastSeenAt: _time(j['last_seen_at']),
        current: j['current'] as bool? ?? false,
      );
}

class AuthTokens {
  final String accessToken;
  final String refreshToken;
  final int expiresIn;
  final String deviceId;

  const AuthTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
    required this.deviceId,
  });

  factory AuthTokens.fromJson(Map<String, dynamic> j) => AuthTokens(
        accessToken: j['access_token'] as String,
        refreshToken: j['refresh_token'] as String,
        expiresIn: (j['expires_in'] as num).toInt(),
        deviceId: j['device_id'] as String,
      );
}

class AuthResult {
  final AuthTokens tokens;
  final Me me;

  const AuthResult({required this.tokens, required this.me});

  factory AuthResult.fromJson(Map<String, dynamic> j) => AuthResult(
        tokens: AuthTokens.fromJson(j),
        me: Me.fromJson(j['user'] as Map<String, dynamic>),
      );
}

class DeviceDescriptor {
  final String name;
  final String platform;

  const DeviceDescriptor({required this.name, required this.platform});

  Map<String, dynamic> toJson() => {'name': name, 'platform': platform};
}
