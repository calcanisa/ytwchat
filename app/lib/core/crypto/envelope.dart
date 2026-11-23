import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../config.dart';

class EnvelopeException implements Exception {
  final String reason;
  const EnvelopeException(this.reason);
  @override
  String toString() => reason;
}

final _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

bool isUuid(String? v) => v != null && _uuidPattern.hasMatch(v);

class MediaRef {
  final String id;
  final Uint8List key;
  final Uint8List nonce;
  final Uint8List sha256;
  final String mime;
  final int size;
  final String? name;
  final int? durationMs;

  const MediaRef({
    required this.id,
    required this.key,
    required this.nonce,
    required this.sha256,
    required this.mime,
    required this.size,
    this.name,
    this.durationMs,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'key': base64.encode(key),
        'nonce': base64.encode(nonce),
        'sha256': base64.encode(sha256),
        'mime': mime,
        'size': size,
        'name': ?name,
        'duration_ms': ?durationMs,
      };

  static MediaRef parse(Object? raw) {
    if (raw is! Map) throw const EnvelopeException('media must be an object');
    final id = raw['id'];
    if (id is! String || !isUuid(id)) {
      throw const EnvelopeException('media id is not valid');
    }
    Uint8List bytes(String field, int length) {
      final v = raw[field];
      if (v is! String || v.length > 64) {
        throw EnvelopeException('media $field is not valid');
      }
      final out = base64.decode(v);
      if (out.length != length) throw EnvelopeException('media $field is not valid');
      return out;
    }

    final mime = raw['mime'];
    final size = raw['size'];
    final name = raw['name'];
    final duration = raw['duration_ms'];
    if (mime is! String || mime.isEmpty || mime.length > 100 || !RegExp(r'^[\w.+-]+/[\w.+-]+$').hasMatch(mime)) {
      throw const EnvelopeException('media type is not valid');
    }
    if (size is! int || size < 1 || size > AppConfig.maxMediaBytes) {
      throw const EnvelopeException('media size is not valid');
    }
    if (name != null && (name is! String || name.length > 200)) {
      throw const EnvelopeException('file name is not valid');
    }
    if (duration != null && (duration is! int || duration < 0 || duration > 4 * 3600 * 1000)) {
      throw const EnvelopeException('duration is not valid');
    }
    return MediaRef(
      id: id,
      key: bytes('key', 32),
      nonce: bytes('nonce', 12),
      sha256: bytes('sha256', 32),
      mime: mime,
      size: size,
      name: name == null ? null : sanitizeFileName(name as String),
      durationMs: duration as int?,
    );
  }
}

String sanitizeFileName(String name) {
  final cleaned = name
      .replaceAll(RegExp(r'[\x00-\x1f\x7f/\\:*?"<>|]'), '_')
      .replaceAll(RegExp(r'^\.+'), '')
      .trim();
  if (cleaned.isEmpty) return 'file';
  return cleaned.length > 120 ? cleaned.substring(cleaned.length - 120) : cleaned;
}

enum EnvelopeType { text, image, voice, file, meta, typing, call }

const storedTypes = {
  EnvelopeType.text,
  EnvelopeType.image,
  EnvelopeType.voice,
  EnvelopeType.file,
};

class Envelope {
  static const _uuid = Uuid();

  final String id;
  final EnvelopeType type;
  final int sentAt;
  final String? text;
  final MediaRef? media;
  final String? title;
  final Map<String, dynamic>? call;

  const Envelope({
    required this.id,
    required this.type,
    required this.sentAt,
    this.text,
    this.media,
    this.title,
    this.call,
  });

  static int _now() => DateTime.now().toUtc().millisecondsSinceEpoch;

  factory Envelope.text(String text) => Envelope(
        id: _uuid.v4(),
        type: EnvelopeType.text,
        sentAt: _now(),
        text: text,
      );

  factory Envelope.media(EnvelopeType type, MediaRef media, {String? caption}) =>
      Envelope(
        id: _uuid.v4(),
        type: type,
        sentAt: _now(),
        media: media,
        text: caption,
      );

  factory Envelope.meta(String title) => Envelope(
        id: _uuid.v4(),
        type: EnvelopeType.meta,
        sentAt: _now(),
        title: title,
      );

  factory Envelope.typing() =>
      Envelope(id: _uuid.v4(), type: EnvelopeType.typing, sentAt: _now());

  factory Envelope.call(Map<String, dynamic> data) => Envelope(
        id: _uuid.v4(),
        type: EnvelopeType.call,
        sentAt: _now(),
        call: data,
      );

  Map<String, dynamic> toJson() => {
        'v': 1,
        'id': id,
        't': type.name,
        'ts': sentAt,
        'text': ?text,
        'media': ?media?.toJson(),
        'title': ?title,
        'call': ?call,
      };

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  static Envelope decode(List<int> bytes) {
    if (bytes.length > 200 * 1024) throw const EnvelopeException('message is too large');
    final Object? raw;
    try {
      raw = jsonDecode(utf8.decode(bytes));
    } catch (_) {
      throw const EnvelopeException('message is not readable');
    }
    if (raw is! Map<String, dynamic>) throw const EnvelopeException('message is not readable');
    if (raw['v'] != 1) throw const EnvelopeException('message version is not supported');
    final id = raw['id'];
    if (id is! String || !isUuid(id)) throw const EnvelopeException('message id is not valid');
    final typeName = raw['t'];
    final type = EnvelopeType.values.where((t) => t.name == typeName).firstOrNull;
    if (type == null) throw const EnvelopeException('message type is not supported');
    final ts = raw['ts'];
    if (ts is! int) throw const EnvelopeException('message time is not valid');
    final text = raw['text'];
    if (text != null && (text is! String || text.length > AppConfig.maxTextLength)) {
      throw const EnvelopeException('message text is not valid');
    }
    final title = raw['title'];
    if (title != null && (title is! String || title.trim().isEmpty || title.length > 60)) {
      throw const EnvelopeException('group name is not valid');
    }
    final call = raw['call'];
    if (call != null && call is! Map<String, dynamic>) {
      throw const EnvelopeException('call data is not valid');
    }
    MediaRef? media;
    if (raw['media'] != null) media = MediaRef.parse(raw['media']);

    switch (type) {
      case EnvelopeType.text:
        if (text == null || (text as String).trim().isEmpty) {
          throw const EnvelopeException('message is empty');
        }
      case EnvelopeType.image:
      case EnvelopeType.voice:
      case EnvelopeType.file:
        if (media == null) throw const EnvelopeException('media is missing');
      case EnvelopeType.meta:
        if (title == null) throw const EnvelopeException('group name is missing');
      case EnvelopeType.call:
        if (call == null) throw const EnvelopeException('call data is missing');
      case EnvelopeType.typing:
        break;
    }
    return Envelope(
      id: id,
      type: type,
      sentAt: ts,
      text: text as String?,
      media: media,
      title: (title as String?)?.trim(),
      call: call as Map<String, dynamic>?,
    );
  }
}
