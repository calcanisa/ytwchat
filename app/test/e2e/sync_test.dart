import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ytwchat/core/api/api_client.dart';
import 'package:ytwchat/core/api/models.dart';
import 'package:ytwchat/core/config.dart';
import 'package:ytwchat/core/crypto/envelope.dart';
import 'package:ytwchat/core/session/session_store.dart';
import 'package:ytwchat/core/store/local_db.dart';
import 'package:ytwchat/core/sync/sync_engine.dart';
import 'package:ytwchat/src/rust/api/chat.dart';
import 'package:ytwchat/src/rust/frb_generated.dart';

const server = String.fromEnvironment('YTWCHAT_E2E_SERVER');
const library = String.fromEnvironment('YTWCHAT_E2E_LIB');

class Client {
  final String name;
  final ApiClient api;
  final SyncEngine engine;
  final LocalDb db;
  final List<SyncEvent> seen = [];

  Client(this.name, this.api, this.engine, this.db) {
    engine.events.listen(seen.add);
  }

  String get userId => engine.userId;
  String get deviceId => engine.deviceId;

  Future<void> close() async {
    await engine.stop();
    await db.close();
  }
}

late Directory root;
final storageKey = Uint8List.fromList(List.generate(64, (i) => (i * 31 + 7) % 256));
final clients = <Client>[];

Future<Client> connect(String username, {bool register = true}) async {
  final dir = await Directory('${root.path}/$username-${clients.length}').create(recursive: true);
  final sessions = SessionStore(MemorySecretStore());
  final api = ApiClient(baseUrl: AppConfig.apiBase(server), sessions: sessions);
  const device = DeviceDescriptor(name: 'Test device', platform: 'android');
  final result = register
      ? await api.register(
          username: username,
          displayName: username[0].toUpperCase() + username.substring(1),
          email: '$username@example.com',
          password: 'correct horse battery',
          device: device,
        )
      : await api.login(email: '$username@example.com', password: 'correct horse battery', device: device);
  final session = Session(
    userId: result.me.id,
    deviceId: result.tokens.deviceId,
    accessToken: result.tokens.accessToken,
    refreshToken: result.tokens.refreshToken,
    accessExpiresAt: DateTime.now().toUtc().add(Duration(seconds: result.tokens.expiresIn)),
  );
  await sessions.save(session);
  api.attach(session);
  final core = ChatCore.open(
    dbPath: '${dir.path}/mls.db',
    userId: session.userId,
    deviceId: session.deviceId,
    storageKey: storageKey,
  );
  final database = await databaseFactoryFfi.openDatabase(
    '${dir.path}/local.db',
    options: OpenDatabaseOptions(version: LocalDb.version, onCreate: LocalDb.onCreate, onConfigure: LocalDb.onConfigure),
  );
  final db = LocalDb(database);
  final engine = SyncEngine(
    api: api,
    core: core,
    db: db,
    userId: session.userId,
    deviceId: session.deviceId,
    wsUri: AppConfig.wsUri(server),
    mediaDir: '${dir.path}/media',
  );
  await engine.start();
  await engine.ready;
  final client = Client(username, api, engine, db);
  clients.add(client);
  await until('$username connected', () async => engine.connected);
  return client;
}

Future<void> until(String what, Future<bool> Function() check, {Duration timeout = const Duration(seconds: 20)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (await check()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('Timed out waiting for $what');
}

Future<List<String>> texts(Client c, String cid) async =>
    (await c.engine.messages(cid)).where((m) => m.type == EnvelopeType.text).map((m) => m.text!).toList();

Future<void> expectText(Client c, String cid, String text) =>
    until('${c.name} to get "$text"', () async => (await texts(c, cid)).contains(text));

void main() {
  final enabled = server.isNotEmpty && library.isNotEmpty;

  setUpAll(() async {
    if (!enabled) return;
    sqfliteFfiInit();
    await RustLib.init(externalLibrary: ExternalLibrary.open(library));
    root = await Directory.systemTemp.createTemp('ytwchat-e2e');
  });

  tearDownAll(() async {
    if (!enabled) return;
    for (final c in clients) {
      await c.close();
    }
    await root.delete(recursive: true);
  });

  test('encrypted chat across users, devices, groups and media', () async {
    final alice = await connect('alice');
    final bob = await connect('bobby');
    final bobLaptop = await connect('bobby', register: false);
    final carol = await connect('carol');

    final direct = await alice.engine.openDirect(bob.userId);
    await alice.engine.sendText(direct, 'Hi Bob, this is encrypted');
    await expectText(bob, direct, 'Hi Bob, this is encrypted');
    await expectText(bobLaptop, direct, 'Hi Bob, this is encrypted');
    await until('alice message marked sent', () async =>
        (await alice.engine.messages(direct)).every((m) => m.status == MessageStatus.sent));

    await bob.engine.sendText(direct, 'Got it, Alice');
    await expectText(alice, direct, 'Got it, Alice');
    await expectText(bobLaptop, direct, 'Got it, Alice');
    final ownCopy = (await bobLaptop.engine.messages(direct)).firstWhere((m) => m.text == 'Got it, Alice');
    expect(ownCopy.senderUserId, bob.userId);
    expect(ownCopy.status, MessageStatus.sent);
    final bobConv = await bob.engine.conversation(direct);
    expect(bobConv!.unread, 1);
    expect(bobConv.state, GroupState.ready);

    final photo = Uint8List.fromList(List.generate(300000, (i) => (i * 7) % 256));
    await alice.engine.sendMedia(direct, type: EnvelopeType.image, bytes: photo, mime: 'image/jpeg');
    LocalMessage? received;
    await until('bob to get the photo', () async {
      received = (await bob.engine.messages(direct)).where((m) => m.type == EnvelopeType.image).firstOrNull;
      return received != null;
    });
    expect(await bob.engine.mediaBytes(received!.media!), photo);
    final stored = File('${bob.engine.mediaDir}/${received!.media!.id}').readAsBytesSync();
    expect(stored, isNot(equals(photo)), reason: 'media is stored encrypted on the device');

    final typingSeen = bob.seen.length;
    await alice.engine.typing(direct);
    await until('bob to see typing', () async =>
        bob.seen.skip(typingSeen).any((e) => e is TypingSignal && e.userId == alice.userId));

    final group = await alice.engine.createGroup('Weekend plans', [bob.userId, carol.userId]);
    await until('carol joined the group', () async => (await carol.engine.conversation(group))?.state == GroupState.ready);
    await until('carol has the group name', () async => (await carol.engine.conversation(group))?.title == 'Weekend plans');
    await carol.engine.sendText(group, 'Count me in');
    await expectText(alice, group, 'Count me in');
    await expectText(bob, group, 'Count me in');
    await expectText(bobLaptop, group, 'Count me in');

    final carolTablet = await connect('carol', register: false);
    await until('carol tablet added to the group', () async =>
        (await carolTablet.engine.conversation(group))?.state == GroupState.ready);
    await alice.engine.sendText(group, 'Tablet welcome');
    await expectText(carolTablet, group, 'Tablet welcome');
    expect(alice.engine.securityMembers(group).length, 5);

    await alice.engine.removeFromGroup(group, bob.userId);
    await until('bob removed', () async => (await bob.engine.conversation(group))?.state == GroupState.left);
    await until('bob devices removed from encryption', () async => alice.engine.securityMembers(group).length == 3);
    await alice.engine.sendText(group, 'Secret after Bob left');
    await expectText(carol, group, 'Secret after Bob left');
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(await texts(bob, group), isNot(contains('Secret after Bob left')));
    expect(await texts(bobLaptop, group), isNot(contains('Secret after Bob left')));

    final race = await carol.engine.openDirect(bob.userId);
    await Future.wait([
      carol.engine.sendText(race, 'first from carol'),
      bob.engine.sendText(race, 'first from bob'),
    ]);
    await expectText(bob, race, 'first from carol');
    await expectText(carol, race, 'first from bob');
    await expectText(carolTablet, race, 'first from bob');
    await expectText(bobLaptop, race, 'first from carol');
  }, skip: enabled ? false : 'set YTWCHAT_E2E_SERVER and YTWCHAT_E2E_LIB', timeout: const Timeout(Duration(minutes: 3)));
}
