import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class LocalStore {
  static Future<Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/zbx_cache');
    if (!await d.exists()) {
      await d.create(recursive: true);
    }
    return d;
  }

  static String _safeName(String key) {
    final raw = utf8.encode(key);
    return base64Url.encode(raw).replaceAll('=', '');
  }

  static String? _unsafeName(String safe) {
    try {
      var s = safe;
      final mod = s.length % 4;
      if (mod != 0) {
        s = s.padRight(s.length + (4 - mod), '=');
      }
      final raw = base64Url.decode(s);
      return utf8.decode(raw);
    } catch (_) {
      return null;
    }
  }

  static Future<File> _fileForKey(String key) async {
    final d = await _dir();
    return File('${d.path}/${_safeName(key)}.json');
  }

  static Future<Map<String, dynamic>?> readMap(String key) async {
    try {
      final f = await _fileForKey(key);
      if (!await f.exists()) return null;
      final raw = await f.readAsString();
      final data = jsonDecode(raw);
      if (data is Map<String, dynamic>) return data;
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> writeMap(String key, Map<String, dynamic> value) async {
    try {
      final f = await _fileForKey(key);
      await f.writeAsString(jsonEncode(value), flush: true);
    } catch (_) {
      // Best-effort local cache.
    }
  }

  static Future<int> clearByPrefix(List<String> prefixes) async {
    var cleared = 0;
    try {
      final d = await _dir();
      if (!await d.exists()) return 0;
      await for (final entity in d.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.endsWith('.json')) continue;
        final safe = name.substring(0, name.length - 5);
        final key = _unsafeName(safe);
        if (key == null) continue;
        if (prefixes.any((p) => key.startsWith(p))) {
          try {
            await entity.delete();
            cleared++;
          } catch (_) {}
        }
      }
    } catch (_) {}
    return cleared;
  }

  /// Best-effort cache stats for the local JSON cache.
  ///
  /// Returns:
  /// - `files`: number of cached JSON files that match the prefixes
  /// - `bytes`: sum of file sizes in bytes
  static Future<Map<String, int>> statsByPrefix(List<String> prefixes) async {
    var files = 0;
    var bytes = 0;
    try {
      final d = await _dir();
      if (!await d.exists()) return const {'files': 0, 'bytes': 0};
      await for (final entity in d.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.endsWith('.json')) continue;
        final safe = name.substring(0, name.length - 5);
        final key = _unsafeName(safe);
        if (key == null) continue;
        if (!prefixes.any((p) => key.startsWith(p))) continue;
        try {
          final len = await entity.length();
          files++;
          bytes += len;
        } catch (_) {}
      }
    } catch (_) {}
    return {'files': files, 'bytes': bytes};
  }
}
