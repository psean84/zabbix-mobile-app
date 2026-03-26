import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'local_store.dart';
import 'secure_store.dart';

class ApiClient {
  static const Duration _maxSessionAge = Duration(hours: 8);
  static const String _sessionTokenKey = 'auth:token';
  static bool _allowSelfSignedCertificates = false;

  // ── Auth-error event bus ──────────────────────────────────────────────────────
  static final StreamController<String> _authErrorCtrl =
      StreamController<String>.broadcast();
  static Stream<String> get authErrorStream => _authErrorCtrl.stream;

  // ── Dynamic base URL ──────────────────────────────────────────────────────────
  static String _baseUrl = 'https://192.168.10.100:8080';
  static String get baseUrl => _baseUrl;
  static bool get allowSelfSignedCertificates => _allowSelfSignedCertificates;

  static void setAllowSelfSignedCertificates(bool enabled) {
    _allowSelfSignedCertificates = enabled;
  }

  static Future<void> setBaseUrl(String url) async {
    final clean = url.trim().replaceAll(RegExp(r'/$'), '');
    if (clean.isEmpty) throw Exception('Server URL is required.');
    final parsed = Uri.tryParse(clean);
    if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) {
      throw Exception('Invalid server URL.');
    }
    if (parsed.scheme.toLowerCase() != 'https') {
      throw Exception('Only HTTPS URLs are allowed.');
    }
    _baseUrl = clean;
    await LocalStore.writeMap('config:server', {'url': clean});
  }

  static Future<void> restoreBaseUrl() async {
    try {
      final saved = await LocalStore.readMap('config:server');
      final url = (saved?['url'] ?? '').toString().trim();
      if (url.isNotEmpty) _baseUrl = url;
    } catch (_) {}
  }

  // ── Auth ─────────────────────────────────────────────────────────────────────
  static String? _authToken;
  static String? get authToken => _authToken;
  static bool get isLoggedIn => _authToken != null && _authToken!.isNotEmpty;

  static Future<void> login(String username, String password) async {
    final resp = await _postRaw(
      '/auth/login',
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'username': username, 'password': password}),
      timeoutSec: 20,
    );

    if (resp.statusCode == 200) {
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      _authToken = (body['token'] ?? body['auth'] ?? '').toString();
      if (_authToken!.isEmpty) throw Exception('No token returned.');
      await SecureStore.write(_sessionTokenKey, _authToken!);
      await LocalStore.writeMap('auth:session', {
        'username': username,
        'saved_at': DateTime.now().toIso8601String(),
      });
      return;
    }
    throw Exception(_extractMsg(resp));
  }

  static Future<bool> restoreSession() async {
    await restoreBaseUrl();
    try {
      final saved = await LocalStore.readMap('auth:session');
      if (saved == null) return false;
      var token = await SecureStore.read(_sessionTokenKey);
      if (token == null || token.isEmpty) return false;

      final savedAt = DateTime.tryParse((saved['saved_at'] ?? '').toString());
      if (savedAt == null || DateTime.now().difference(savedAt) > _maxSessionAge) {
        await logout();
        return false;
      }
      _authToken = token;
      return true;
    } catch (_) { return false; }
  }

  static Future<void> logout() async {
    _authToken = null;
    await SecureStore.delete(_sessionTokenKey);
    await LocalStore.writeMap('auth:session', {});
  }

  // ── Data ─────────────────────────────────────────────────────────────────────
  static Future<List<dynamic>> fetchHostGroups({bool cacheOnly = false}) =>
      _fetchMetaList(
        endpoint: '/api/hostgroups',
        storeKey: 'meta:hostgroups',
        timeoutSec: 30,
        cacheOnly: cacheOnly,
      );

  static Future<List<dynamic>> fetchHosts({String? groupId, bool cacheOnly = false}) =>
      _fetchMetaList(
        endpoint: groupId == null ? '/api/hosts' : '/api/hosts?groupid=$groupId',
        storeKey: 'meta:hosts:${groupId ?? 'all'}',
        timeoutSec: 30,
        cacheOnly: cacheOnly,
      );

  static Future<List<dynamic>> fetchTriggers({bool cacheOnly = false}) =>
      _fetchMetaList(
        endpoint: '/api/triggers',
        storeKey: 'meta:triggers',
        timeoutSec: 30,
        cacheOnly: cacheOnly,
      );

  static Future<List<dynamic>> fetchItems(String hostId) async {
    final storeKey = 'meta:items:$hostId';
    final cached = await LocalStore.readMap(storeKey);
    List<dynamic> metadata = (cached?['data'] is List)
        ? List<dynamic>.from(cached!['data'] as List)
        : <dynamic>[];

    try {
      final liveList = await _fetchLiveItemValues(hostId);
      if (metadata.isEmpty && liveList.isNotEmpty) {
        metadata = _stripItemValues(liveList);
      }
      final metadataOnly = _stripItemValues(metadata.isEmpty ? await fetchItemsMetadata(hostId) : metadata);
      return _mergeMetaAndValues(metadataOnly, liveList);
    } catch (e) {
      if (metadata.isNotEmpty) return metadata;
      rethrow;
    }
  }

  static Future<List<dynamic>> fetchItemsMetadata(String hostId, {bool cacheOnly = false}) async {
    final storeKey = 'meta:items:$hostId';
    final cached = await LocalStore.readMap(storeKey);
    final cachedData = (cached?['data'] is List) ? cached!['data'] as List : [];
    if (cachedData.isNotEmpty || cacheOnly) return cachedData;

    final data = await _getJson('/api/items?hostid=$hostId&meta=1', timeoutSec: 180);
    List<dynamic> list = (data is Map) ? (data['data'] as List? ?? []) : (data is List ? data : []);
    final meta = _stripItemValues(list);
    await LocalStore.writeMap(storeKey, {
      'checksum': _checksumForList(meta),
      'cached_at': DateTime.now().toIso8601String(),
      'data': meta,
    });
    return meta;
  }

  static Future<List<dynamic>> fetchLldRules(String hostId) async {
    final data = await _getJson('/api/lld-rules?hostid=$hostId', timeoutSec: 120, retries: 2);
    return data is List ? data : <dynamic>[];
  }

  static Future<Map<String, dynamic>> fetchHistory({
    required List<String> itemIds,
    required int from,
    required int to,
  }) async {
    final data = await _getJson(
      '/api/history?itemids=${itemIds.join(',')}&from=$from&to=$to',
      timeoutSec: 40,
      retries: 1,
    );
    return data is Map<String, dynamic> ? data : <String, dynamic>{};
  }

  static Future<Map<String, dynamic>> fetchHistoryChunk({
    required List<String> itemIds,
    required int from,
    required int to,
  }) => fetchHistory(itemIds: itemIds, from: from, to: to);

  static Future<void> registerDeviceToken(String token, {Map<String, dynamic>? filter}) async {
    await _postRaw('/devices/register', headers: {
      'Content-Type': 'application/json',
      if (_authToken != null) 'Authorization': 'Bearer $_authToken',
    }, body: jsonEncode({'platform': 'android', 'token': token, ...?filter != null ? {'filter': filter} : null}));
  }

  static Future<void> updateDeviceFilter(String token, Map<String, dynamic> filter) async {
    try {
      await _postRaw('/devices/filter', headers: {
        'Content-Type': 'application/json',
        if (_authToken != null) 'Authorization': 'Bearer $_authToken',
      }, body: jsonEncode({'token': token, 'filter': filter}), timeoutSec: 10);
    } catch (_) {}
  }

  // ── Internals ────────────────────────────────────────────────────────────────
  static Future<List<dynamic>> _fetchMetaList({
    required String endpoint,
    required String storeKey,
    required int timeoutSec,
    bool cacheOnly = false,
  }) async {
    final cached = await LocalStore.readMap(storeKey);
    final cachedData = cached?['data'];
    if (cacheOnly && cachedData is List) return cachedData;

    final checksum = (cached?['checksum'] ?? '').toString();
    final join = endpoint.contains('?') ? '&' : '?';
    final url = '$endpoint${join}meta=1${checksum.isEmpty ? '' : '&if_checksum=$checksum'}';

    try {
      final resp = await _getRaw(url, timeoutSec: timeoutSec);
      if (resp.statusCode == 304 && cachedData is List) return cachedData;
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final body = jsonDecode(resp.body);
        if (body is Map && body['data'] is List) {
          final list = body['data'] as List;
          await LocalStore.writeMap(storeKey, {
            'checksum': body['checksum'] ?? resp.headers['x-checksum'] ?? '',
            'cached_at': body['cached_at'] ?? DateTime.now().toIso8601String(),
            'data': list,
          });
          return list;
        }
      }
    } catch (_) {}
    if (cachedData is List) return cachedData;
    throw Exception('Failed to fetch $endpoint');
  }

  static Future<http.Response> _getRaw(String path, {int timeoutSec = 20, int retries = 1}) async {
    for (var i = 0; i <= retries; i++) {
      try {
        final client = _buildClient();
        final resp = await client.get(Uri.parse('$_baseUrl$path'), headers: {
          'Content-Type': 'application/json',
          if (_authToken != null) 'Authorization': 'Bearer $_authToken',
        }).timeout(Duration(seconds: timeoutSec));
        if (resp.statusCode == 401) {
          _authToken = null;
          _authErrorCtrl.add('Expired');
          throw Exception('Session expired');
        }
        return resp;
      } catch (e) {
        if (i == retries) rethrow;
        await Future.delayed(Duration(milliseconds: 500 * (i + 1)));
      }
    }
    throw Exception('Request failed');
  }

  static Future<dynamic> _getJson(String path, {int timeoutSec = 20, int retries = 1}) async {
    final resp = await _getRaw(path, timeoutSec: timeoutSec, retries: retries);
    return jsonDecode(resp.body);
  }

  static Future<http.Response> _postRaw(String path, {required Map<String, String> headers, required Object body, int timeoutSec = 20}) async {
    final client = _buildClient();
    return await client.post(Uri.parse('$_baseUrl$path'), headers: headers, body: body).timeout(Duration(seconds: timeoutSec));
  }

  static http.Client _buildClient() {
    if (!_allowSelfSignedCertificates) return http.Client();
    final host = Uri.tryParse(_baseUrl)?.host.toLowerCase();
    final io = HttpClient()..badCertificateCallback = (cert, h, p) => h.toLowerCase() == host;
    return IOClient(io);
  }

  static String _extractMsg(http.Response r) {
    try {
      final b = jsonDecode(r.body);
      return (b['error'] ?? b['message'] ?? 'Error ${r.statusCode}').toString();
    } catch (_) { return 'Error ${r.statusCode}'; }
  }

  static List<dynamic> _stripItemValues(List<dynamic> items) => items.map((i) => {
    'itemid': i['itemid'], 'name': i['name'], 'key_': i['key_'], 'units': i['units'], 'value_type': i['value_type'], 'tags': i['tags']
  }).toList();

  static String _checksumForList(List<dynamic> list) {
    final s = jsonEncode(list);
    var hash = 5381;
    for (final c in s.codeUnits) hash = ((hash << 5) + hash) ^ c;
    return '${list.length}:${hash.toUnsigned(32)}';
  }

  static List<dynamic> _mergeMetaAndValues(List<dynamic> metadata, List<dynamic> live) {
    final liveById = {for (var i in live) (i['itemid'] ?? '').toString(): i};
    return metadata.map((m) {
      final id = (m['itemid'] ?? '').toString();
      final v = liveById[id];
      return {...m, 'lastvalue': v?['lastvalue'] ?? '', 'lastclock': v?['lastclock'] ?? ''};
    }).toList();
  }

  static Future<List<dynamic>> _fetchLiveItemValues(String hostId) async {
    try {
      final v = await _getJson('/api/item-values?hostid=$hostId', timeoutSec: 120);
      if (v is List) return v;
    } catch (_) {}
    final f = await _getJson('/api/items?hostid=$hostId', timeoutSec: 300);
    return f is List ? f : [];
  }
}
