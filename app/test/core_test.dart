import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ytwchat/core/api/models.dart';
import 'package:ytwchat/core/crypto/envelope.dart';
import 'package:ytwchat/core/store/local_db.dart';
import 'package:ytwchat/utils/mime.dart';

Uint8List raw(Map<String, dynamic> m) => Uint8List.fromList(utf8.encode(jsonEncode(m)));

MediaRef media() => MediaRef(
      id: '0b9f3c1e-8d2a-4b6f-9e1d-2c3b4a5d6e7f',
      key: Uint8List(32),
      nonce: Uint8List(12),
      sha256: Uint8List(32),
      mime: 'image/jpeg',
      size: 1000,
      name: '../../etc/passwd',
    );

void main() {
  group('envelope', () {
    test('round trips every stored type', () {
      for (final env in [
        Envelope.text('hello'),
        Envelope.media(EnvelopeType.image, media()),
        Envelope.meta('Team'),
        Envelope.call({'k': 'end', 'id': '0b9f3c1e-8d2a-4b6f-9e1d-2c3b4a5d6e7f'}),
        Envelope.typing(),
      ]) {
        final back = Envelope.decode(env.encode());
        expect(back.id, env.id);
        expect(back.type, env.type);
        expect(back.text, env.text);
        expect(back.title, env.title);
      }
    });

    test('file names cannot escape a folder', () {
      final back = Envelope.decode(Envelope.media(EnvelopeType.file, media()).encode());
      expect(back.media!.name, isNot(contains('/')));
      expect(back.media!.name!.startsWith('.'), isFalse);
    });

    test('rejects malformed or hostile input', () {
      final good = Envelope.text('hi').toJson();
      final cases = <Map<String, dynamic>>[
        {...good, 'v': 2},
        {...good, 'id': 'not-a-uuid'},
        {...good, 't': 'script'},
        {...good, 'ts': 'yesterday'},
        {...good, 'text': '   '},
        {...good, 'text': 'x' * 20001},
        {...good, 't': 'image'},
        {...good, 't': 'meta'},
        {...good, 't': 'meta', 'title': 'x' * 61},
        {
          ...good,
          't': 'image',
          'media': {...media().toJson(), 'key': base64.encode(Uint8List(16))},
        },
        {
          ...good,
          't': 'image',
          'media': {...media().toJson(), 'id': '../../secret'},
        },
        {
          ...good,
          't': 'image',
          'media': {...media().toJson(), 'mime': 'text/html; charset=utf-8'},
        },
        {
          ...good,
          't': 'image',
          'media': {...media().toJson(), 'size': 999999999999},
        },
      ];
      for (final c in cases) {
        expect(() => Envelope.decode(raw(c)), throwsA(isA<EnvelopeException>()), reason: jsonEncode(c).substring(0, 60));
      }
      expect(() => Envelope.decode(utf8.encode('not json')), throwsA(isA<EnvelopeException>()));
      expect(() => Envelope.decode(utf8.encode('[1,2]')), throwsA(isA<EnvelopeException>()));
    });
  });

  group('mime', () {
    test('detects images by content, not name', () {
      expect(imageMime(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0])), 'image/jpeg');
      expect(imageMime(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])), 'image/png');
      expect(imageMime(Uint8List.fromList(utf8.encode('<html>'))), isNull);
      expect(fileMime('Report.PDF'), 'application/pdf');
      expect(fileMime('noext'), 'application/octet-stream');
    });
  });

  group('local store', () {
    late LocalDb db;
    const me = 'me-id';
    const cid = '0b9f3c1e-8d2a-4b6f-9e1d-000000000001';

    setUp(() async {
      sqfliteFfiInit();
      final database = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(version: LocalDb.version, onCreate: LocalDb.onCreate, singleInstance: false),
      );
      db = LocalDb(database);
      await db.upsertConversation(Conversation(
        id: cid,
        kind: 'direct',
        epoch: 0,
        createdAt: DateTime.utc(2026),
        lastActivityAt: DateTime.utc(2026),
        members: const [
          Member(user: PublicUser(id: me, username: 'me', displayName: 'Me'), role: 'member'),
          Member(user: PublicUser(id: 'them', username: 'them', displayName: 'Them'), role: 'member'),
        ],
      ));
    });

    tearDown(() => db.close());

    Future<bool> put(Envelope e, {String sender = 'them', bool unread = true}) => db.insertMessage(
          envelope: e,
          conversationId: cid,
          senderUserId: sender,
          senderDeviceId: 'device',
          status: sender == me ? MessageStatus.pending : MessageStatus.received,
          countUnread: unread,
        );

    test('deduplicates, counts unread and keeps the newest preview', () async {
      final first = Envelope.text('first');
      expect(await put(first), isTrue);
      expect(await put(first), isFalse);
      final older = Envelope(id: '0b9f3c1e-8d2a-4b6f-9e1d-000000000009', type: EnvelopeType.text, sentAt: first.sentAt - 60000, text: 'older');
      await put(older);
      final conv = (await db.conversation(cid))!;
      expect(conv.unread, 2);
      expect(conv.lastPreview, 'first');
      final list = await db.messages(cid);
      expect(list.map((m) => m.text), ['older', 'first']);
      await db.markRead(cid);
      expect((await db.conversation(cid))!.unread, 0);
    });

    test('outbox holds pending messages until sent', () async {
      final mine = Envelope.text('queued');
      await put(mine, sender: me, unread: false);
      final outbox = await db.outbox(cid);
      expect(outbox.single.$1, mine.id);
      expect(outbox.single.$2.text, 'queued');
      await db.setStatus(mine.id, MessageStatus.sent);
      expect(await db.outbox(cid), isEmpty);
    });

    test('clocks far in the future are clamped', () async {
      final future = Envelope(
        id: '0b9f3c1e-8d2a-4b6f-9e1d-00000000000f',
        type: EnvelopeType.text,
        sentAt: DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch,
        text: 'from the future',
      );
      await put(future);
      final m = (await db.message(future.id))!;
      expect(m.sentAt.isBefore(DateTime.now().add(const Duration(minutes: 1))), isTrue);
    });

    test('conversations missing from the server are marked left and can return', () async {
      await db.syncConversations([]);
      expect((await db.conversation(cid))!.state, GroupState.left);
      await db.syncConversations([
        Conversation(id: cid, kind: 'direct', epoch: 3, createdAt: DateTime.utc(2026), lastActivityAt: DateTime.utc(2026), members: const []),
      ]);
      expect((await db.conversation(cid))!.state, GroupState.waiting);
    });
  });
}
