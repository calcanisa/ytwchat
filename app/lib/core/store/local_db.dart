import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';

import '../api/models.dart';
import '../crypto/envelope.dart';

enum MessageStatus { pending, sent, failed, received }

enum GroupState { ready, waiting, left }

class LocalMessage {
  final String id;
  final String conversationId;
  final String senderUserId;
  final String senderDeviceId;
  final EnvelopeType type;
  final String? text;
  final MediaRef? media;
  final DateTime sentAt;
  final MessageStatus status;

  const LocalMessage({
    required this.id,
    required this.conversationId,
    required this.senderUserId,
    required this.senderDeviceId,
    required this.type,
    required this.text,
    required this.media,
    required this.sentAt,
    required this.status,
  });

  static LocalMessage fromRow(Map<String, Object?> r) => LocalMessage(
        id: r['id'] as String,
        conversationId: r['conversation_id'] as String,
        senderUserId: r['sender_user_id'] as String,
        senderDeviceId: r['sender_device_id'] as String,
        type: EnvelopeType.values.byName(r['type'] as String),
        text: r['body'] as String?,
        media: r['media'] == null ? null : MediaRef.parse(jsonDecode(r['media'] as String)),
        sentAt: DateTime.fromMillisecondsSinceEpoch(r['sent_at'] as int, isUtc: true),
        status: MessageStatus.values.byName(r['status'] as String),
      );

  String get preview {
    switch (type) {
      case EnvelopeType.image:
        return 'Photo';
      case EnvelopeType.voice:
        return 'Voice note';
      case EnvelopeType.file:
        return media?.name ?? 'File';
      default:
        return text ?? '';
    }
  }
}

class LocalConversation {
  final String id;
  final String kind;
  final String? title;
  final int serverEpoch;
  final DateTime lastActivityAt;
  final int unread;
  final String? lastPreview;
  final String? lastSenderId;
  final DateTime? lastAt;
  final List<Member> members;
  final GroupState state;

  const LocalConversation({
    required this.id,
    required this.kind,
    required this.title,
    required this.serverEpoch,
    required this.lastActivityAt,
    required this.unread,
    required this.lastPreview,
    required this.lastSenderId,
    required this.lastAt,
    required this.members,
    required this.state,
  });

  bool get isGroup => kind == 'group';

  static LocalConversation fromRow(Map<String, Object?> r) => LocalConversation(
        id: r['id'] as String,
        kind: r['kind'] as String,
        title: r['title'] as String?,
        serverEpoch: r['server_epoch'] as int,
        lastActivityAt: DateTime.fromMillisecondsSinceEpoch(r['last_activity_at'] as int, isUtc: true),
        unread: r['unread'] as int,
        lastPreview: r['last_preview'] as String?,
        lastSenderId: r['last_sender'] as String?,
        lastAt: r['last_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(r['last_at'] as int, isUtc: true),
        members: (jsonDecode(r['members'] as String) as List)
            .map((m) => Member.fromJson(m as Map<String, dynamic>))
            .toList(),
        state: GroupState.values.byName(r['state'] as String),
      );

  List<Member> others(String me) => members.where((m) => m.user.id != me).toList();

  Member? member(String userId) =>
      members.where((m) => m.user.id == userId).firstOrNull;

  String displayName(String me) {
    if (isGroup) {
      if (title != null && title!.isNotEmpty) return title!;
      final names = others(me).map((m) => m.user.displayName).toList();
      return names.isEmpty ? 'Group' : names.take(3).join(', ');
    }
    return others(me).firstOrNull?.user.displayName ?? 'Just you';
  }

  bool isAdmin(String me) => member(me)?.isAdmin ?? false;
}

class LocalDb {
  final Database db;

  LocalDb(this.db);

  static const version = 1;

  static Future<void> onCreate(Database db, int version) async {
    final batch = db.batch();
    batch.execute('''
      CREATE TABLE conversations (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        title TEXT,
        server_epoch INTEGER NOT NULL DEFAULT 0,
        last_activity_at INTEGER NOT NULL,
        unread INTEGER NOT NULL DEFAULT 0,
        last_preview TEXT,
        last_sender TEXT,
        last_at INTEGER,
        members TEXT NOT NULL,
        state TEXT NOT NULL DEFAULT 'waiting'
      )''');
    batch.execute('''
      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL,
        sender_user_id TEXT NOT NULL,
        sender_device_id TEXT NOT NULL,
        type TEXT NOT NULL,
        body TEXT,
        media TEXT,
        sent_at INTEGER NOT NULL,
        status TEXT NOT NULL,
        envelope TEXT,
        created_local INTEGER NOT NULL
      )''');
    batch.execute('CREATE INDEX messages_conversation ON messages (conversation_id, sent_at)');
    batch.execute("CREATE INDEX messages_outbox ON messages (status) WHERE status = 'pending'");
    await batch.commit(noResult: true);
  }

  static Future<void> onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
  }

  static Future<void> _upsert(DatabaseExecutor ex, Conversation c) async {
    final members = jsonEncode(c.members.map((m) => m.toJson()).toList());
    final updated = await ex.rawUpdate(
      'UPDATE conversations SET kind = ?, server_epoch = ?, last_activity_at = MAX(last_activity_at, ?), members = ?, '
      "state = CASE WHEN state = 'left' THEN 'waiting' ELSE state END WHERE id = ?",
      [c.kind, c.epoch, c.lastActivityAt.millisecondsSinceEpoch, members, c.id],
    );
    if (updated == 0) {
      await ex.insert(
        'conversations',
        {
          'id': c.id,
          'kind': c.kind,
          'server_epoch': c.epoch,
          'last_activity_at': c.lastActivityAt.millisecondsSinceEpoch,
          'members': members,
          'state': GroupState.waiting.name,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }

  Future<void> upsertConversation(Conversation c) => _upsert(db, c);

  Future<void> syncConversations(List<Conversation> list) async {
    await db.transaction((txn) async {
      for (final c in list) {
        await _upsert(txn, c);
      }
      final ids = list.map((c) => c.id).toSet();
      final rows = await txn.query('conversations', columns: ['id'], where: 'state != ?', whereArgs: [GroupState.left.name]);
      for (final r in rows) {
        final id = r['id'] as String;
        if (!ids.contains(id)) {
          await txn.update('conversations', {'state': GroupState.left.name}, where: 'id = ?', whereArgs: [id]);
        }
      }
    });
  }

  Future<List<LocalConversation>> conversations() async => (await db.query(
        'conversations',
        orderBy: 'COALESCE(last_at, last_activity_at) DESC',
      ))
          .map(LocalConversation.fromRow)
          .toList();

  Future<LocalConversation?> conversation(String id) async {
    final rows = await db.query('conversations', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : LocalConversation.fromRow(rows.first);
  }

  Future<void> setState(String id, GroupState state) =>
      db.update('conversations', {'state': state.name}, where: 'id = ?', whereArgs: [id]);

  Future<void> setTitle(String id, String title) =>
      db.update('conversations', {'title': title}, where: 'id = ?', whereArgs: [id]);

  Future<void> markRead(String id) =>
      db.update('conversations', {'unread': 0}, where: 'id = ?', whereArgs: [id]);

  Future<void> deleteConversation(String id) async {
    await db.transaction((txn) async {
      await txn.delete('messages', where: 'conversation_id = ?', whereArgs: [id]);
      await txn.delete('conversations', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<bool> insertMessage({
    required Envelope envelope,
    required String conversationId,
    required String senderUserId,
    required String senderDeviceId,
    required MessageStatus status,
    required bool countUnread,
  }) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final sentAt = envelope.sentAt > now + 300000 ? now : envelope.sentAt;
    var inserted = false;
    await db.transaction((txn) async {
      final id = await txn.insert(
        'messages',
        {
          'id': envelope.id,
          'conversation_id': conversationId,
          'sender_user_id': senderUserId,
          'sender_device_id': senderDeviceId,
          'type': envelope.type.name,
          'body': envelope.text,
          'media': envelope.media == null ? null : jsonEncode(envelope.media!.toJson()),
          'sent_at': sentAt,
          'status': status.name,
          'envelope': status == MessageStatus.pending ? utf8.decode(envelope.encode()) : null,
          'created_local': now,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      inserted = id != 0;
      if (!inserted) return;
      final preview = LocalMessage(
        id: envelope.id,
        conversationId: conversationId,
        senderUserId: senderUserId,
        senderDeviceId: senderDeviceId,
        type: envelope.type,
        text: envelope.text,
        media: envelope.media,
        sentAt: DateTime.fromMillisecondsSinceEpoch(sentAt, isUtc: true),
        status: status,
      ).preview;
      await txn.rawUpdate(
        'UPDATE conversations SET last_preview = ?, last_sender = ?, last_at = ? '
        'WHERE id = ? AND (last_at IS NULL OR last_at <= ?)',
        [preview, senderUserId, sentAt, conversationId, sentAt],
      );
      if (countUnread) {
        await txn.rawUpdate('UPDATE conversations SET unread = unread + 1 WHERE id = ?', [conversationId]);
      }
    });
    return inserted;
  }

  Future<List<LocalMessage>> messages(String conversationId, {int limit = 200, int? beforeSentAt}) async {
    final rows = await db.query(
      'messages',
      where: beforeSentAt == null ? 'conversation_id = ?' : 'conversation_id = ? AND sent_at < ?',
      whereArgs: beforeSentAt == null ? [conversationId] : [conversationId, beforeSentAt],
      orderBy: 'sent_at DESC, created_local DESC',
      limit: limit,
    );
    return rows.map(LocalMessage.fromRow).toList().reversed.toList();
  }

  Future<LocalMessage?> message(String id) async {
    final rows = await db.query('messages', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : LocalMessage.fromRow(rows.first);
  }

  Future<List<(String, Envelope)>> outbox(String conversationId) async {
    final rows = await db.query(
      'messages',
      columns: ['id', 'envelope'],
      where: "conversation_id = ? AND status = 'pending' AND envelope IS NOT NULL",
      whereArgs: [conversationId],
      orderBy: 'created_local ASC',
    );
    return rows
        .map((r) => (r['id'] as String, Envelope.decode(utf8.encode(r['envelope'] as String))))
        .toList();
  }

  Future<Set<String>> conversationsWithOutbox() async {
    final rows = await db.rawQuery(
      "SELECT DISTINCT conversation_id FROM messages WHERE status = 'pending'",
    );
    return rows.map((r) => r['conversation_id'] as String).toSet();
  }

  Future<void> setStatus(String id, MessageStatus status) => db.update(
        'messages',
        {
          'status': status.name,
          if (status == MessageStatus.sent || status == MessageStatus.received) 'envelope': null,
        },
        where: 'id = ?',
        whereArgs: [id],
      );

  Future<void> close() => db.close();
}
