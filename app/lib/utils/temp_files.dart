import 'dart:io';

import 'package:path_provider/path_provider.dart';

Future<Directory> voicePlaybackDir() async {
  final base = await getTemporaryDirectory();
  return Directory('${base.path}/playback');
}

Future<void> clearTempFiles() async {
  final base = await getTemporaryDirectory();
  for (final name in ['playback']) {
    final dir = Directory('${base.path}/$name');
    if (await dir.exists()) await dir.delete(recursive: true);
  }
  await for (final entry in base.list()) {
    if (entry is File && entry.uri.pathSegments.last.startsWith('voice_')) {
      await entry.delete();
    }
  }
}
