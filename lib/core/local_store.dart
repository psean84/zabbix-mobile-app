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
}

