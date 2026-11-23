import 'dart:typed_data';

String? imageMime(Uint8List b) {
  bool at(int offset, List<int> sig) {
    if (b.length < offset + sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (b[offset + i] != sig[i]) return false;
    }
    return true;
  }

  if (at(0, [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (at(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) return 'image/png';
  if (at(0, [0x47, 0x49, 0x46, 0x38])) return 'image/gif';
  if (at(0, [0x52, 0x49, 0x46, 0x46]) && at(8, [0x57, 0x45, 0x42, 0x50])) return 'image/webp';
  if (at(4, [0x66, 0x74, 0x79, 0x70])) {
    final brand = String.fromCharCodes(b.sublist(8, 12));
    if (brand.startsWith('hei') || brand.startsWith('mif') || brand == 'heix') return 'image/heic';
    if (brand == 'avif') return 'image/avif';
  }
  return null;
}

const _byExtension = {
  'pdf': 'application/pdf',
  'txt': 'text/plain',
  'csv': 'text/csv',
  'doc': 'application/msword',
  'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xls': 'application/vnd.ms-excel',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'ppt': 'application/vnd.ms-powerpoint',
  'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'zip': 'application/zip',
  'mp3': 'audio/mpeg',
  'm4a': 'audio/mp4',
  'mp4': 'video/mp4',
  'mov': 'video/quicktime',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
};

String fileMime(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return 'application/octet-stream';
  return _byExtension[name.substring(dot + 1).toLowerCase()] ?? 'application/octet-stream';
}
