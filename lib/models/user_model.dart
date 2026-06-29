class UserModel {
  final String id;
  final String username;
  final String displayName;
  final String? avatarUrl;
  final String? phoneNumber;
  final bool isOnline;
  final DateTime lastSeen;

  const UserModel({
    required this.id,
    required this.username,
    required this.displayName,
    this.avatarUrl,
    this.phoneNumber,
    required this.isOnline,
    required this.lastSeen,
  });

  factory UserModel.fromJson(Map<String, dynamic> json) {
    return UserModel(
      id: json['id'] as String,
      username: json['username'] as String,
      displayName: json['display_name'] as String,
      avatarUrl: json['avatar_url'] as String?,
      phoneNumber: json['phone_number'] as String?,
      isOnline: json['is_online'] as bool,
      lastSeen: DateTime.parse(json['last_seen'] as String),
    );
  }

  UserModel copyWith({bool? isOnline, DateTime? lastSeen}) {
    return UserModel(
      id: id,
      username: username,
      displayName: displayName,
      avatarUrl: avatarUrl,
      phoneNumber: phoneNumber,
      isOnline: isOnline ?? this.isOnline,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }
}
