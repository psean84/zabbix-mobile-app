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
  static bool _allowSelfSignedCertificates = true;
  static bool _metaCacheEnabled = true;

  // ── Auth-error event bus ──────────────────────────────────────────────────────
  // Fires with a human-readable reason whenever a 401 is received.
  // main.dart subscribes so it can route the user back to the login screen.
  static final StreamController<String> _authErrorCtrl =
      StreamController<String>.broadcast();
  static Stream<String> get authErrorStream => _authErrorCtrl.stream;

  // ── Dynamic base URL (set at login, persisted) ────────────────────────────────
  static String _baseUrl = 'https://192.168.10.100:8443';
  static String _manualBaseUrl = _baseUrl;
  static bool _lockBaseUrlForSession = false;
  static bool _autoSelectBaseUrl = true;
  static bool _preferIntranet = true;
  static String _intranetUrl = 'https://192.168.10.100:8443';
  static String _internetUrl = 'https://zabbix-mobile-backend.duckdns.org:8443';
  static String _tunnelUrl = 'https://tunnel.zabbix-ngp-mobile.net.eu.org:443';
  static Duration _reachTimeout = const Duration(seconds: 2);
  static Duration _reachInterval = const Duration(minutes: 5);
  static DateTime _lastReachCheck = DateTime.fromMillisecondsSinceEpoch(0);
  static Future<void>? _reachInFlight;
  static String get baseUrl => _baseUrl;
  static String get intranetUrl => _intranetUrl;
  static String get internetUrl => _internetUrl;
  static String get tunnelUrl => _tunnelUrl;
  static bool get allowSelfSignedCertificates => _allowSelfSignedCertificates;

  static void setAllowSelfSignedCertificates(bool enabled) {
    _allowSelfSignedCertificates = enabled;
  }

  static void setMetaCacheEnabled(bool enabled) {
    _metaCacheEnabled = enabled;
  }

  static Future<void> setBaseUrl(String url) async {
    final clean = url.trim().replaceAll(RegExp(r'/$'), '');
    if (clean.isEmpty) {
      throw Exception('Server URL is required.');
    }
    final parsed = Uri.tryParse(clean);
    if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) {
      throw Exception('Invalid server URL.');
    }
    if (parsed.scheme.toLowerCase() != 'https') {
      throw Exception('Only HTTPS URLs are allowed.');
    }
    _manualBaseUrl = clean;
    _baseUrl = clean;
    await LocalStore.writeMap('config:server', {'url': clean});
  }

  static String _cleanUrl(String url) {
    var clean = url.trim();
    if (clean.isEmpty) return '';
    if (!clean.startsWith('http://') && !clean.startsWith('https://')) {
      clean = 'https://$clean';
    }
    clean = clean.replaceAll(RegExp(r'/$'), '');
    return clean;
  }

  static Future<void> configureNetwork({
    required String intranetUrl,
    required String internetUrl,
    String? tunnelUrl,
    required bool preferIntranet,
    required bool autoSelect,
    int timeoutSec = 2,
    int intervalMin = 5,
  }) async {
    // Endpoints are policy-fixed (not user-editable in UI).
    _intranetUrl = 'https://192.168.10.100:8443';
    _internetUrl = 'https://zabbix-mobile-backend.duckdns.org:8443';
    _tunnelUrl = 'https://tunnel.zabbix-ngp-mobile.net.eu.org:443';
    _preferIntranet = preferIntranet;
    _autoSelectBaseUrl = autoSelect;
    // Short cap: dead intranet must fail fast so internet relays can be chosen quickly.
    _reachTimeout = Duration(seconds: timeoutSec.clamp(1, 2));
    _reachInterval = Duration(minutes: intervalMin.clamp(1, 60));
    if (_autoSelectBaseUrl) {
      await selectBestBaseUrl(force: true);
    } else {
      _baseUrl = _manualBaseUrl;
    }
  }

  static Future<void> selectBestBaseUrl({bool force = false}) async {
    await _ensureActiveBaseUrl(force: force);
  }

  static void lockBaseUrlForSession() {
    _lockBaseUrlForSession = true;
  }

  static void unlockBaseUrlForSession() {
    _lockBaseUrlForSession = false;
  }

  static Future<List<Map<String, dynamic>>> probeRelayReachability({
    bool updateBaseSelection = true,
  }) async {
    final endpoints = [
      {'name': 'Intranet', 'url': _intranetUrl},
      {'name': 'DuckDNS', 'url': _internetUrl},
      {'name': 'Tunnel', 'url': _tunnelUrl},
    ];
    final out = <Map<String, dynamic>>[];
    String? selected;
    for (final e in endpoints) {
      final url = (e['url'] ?? '').toString();
      final ok = await _isReachable(url);
      out.add({
        'name': e['name'],
        'url': url,
        'reachable': ok,
      });
      if (selected == null && ok) selected = url;
    }
    if (updateBaseSelection && selected != null && selected.isNotEmpty) {
      _baseUrl = selected;
      _lastReachCheck = DateTime.now();
    }
    return out;
  }

  /// Restore saved URL (called before session restore)
  static Future<void> restoreBaseUrl() async {
    // Fixed relay policy; ignore legacy manual server config.
    _manualBaseUrl = _intranetUrl;
    _baseUrl = _intranetUrl;
  }

  // ── Auth token ────────────────────────────────────────────────────────────────
  static String? _authToken;
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
      if (_authToken!.isEmpty) {
        throw Exception('Login succeeded but no token returned.');
      }
      await SecureStore.write(_sessionTokenKey, _authToken!);
      await LocalStore.writeMap('auth:session', {
        'username': username,
        'saved_at': DateTime.now().toIso8601String(),
      });
      return;
    }

    String msg = 'Login failed (${resp.statusCode})';
    try {
      final b = jsonDecode(resp.body) as Map<String, dynamic>;
      msg = (b['error'] ?? b['message'] ?? msg).toString();
    } catch (_) {}
    throw Exception(msg);
  }

  static Future<bool> restoreSession() async {
    await restoreBaseUrl();
    try {
      final saved = await LocalStore.readMap('auth:session');
      if (saved == null) return false;
      var token = await SecureStore.read(_sessionTokenKey);
      // One-time migration from old plain-file token storage.
      if (token == null || token.isEmpty) {
        final legacy = (saved['token'] ?? '').toString();
        if (legacy.isNotEmpty) {
          token = legacy;
          await SecureStore.write(_sessionTokenKey, legacy);
        }
      }
      if (token == null || token.isEmpty) return false;

      final savedAtRaw = (saved['saved_at'] ?? '').toString();
      final savedAt = DateTime.tryParse(savedAtRaw);
      if (savedAt == null) {
        await logout();
        return false;
      }
      if (DateTime.now().difference(savedAt) > _maxSessionAge) {
        await logout();
        return false;
      }
      _authToken = token;
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> logout() async {
    _authToken = null;
    _lockBaseUrlForSession = false;
    await SecureStore.delete(_sessionTokenKey);
    await LocalStore.writeMap('auth:session', {});
  }

  // ── Headers ───────────────────────────────────────────────────────────────────
  static Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    if (_authToken != null && _authToken!.isNotEmpty)
      'Authorization': 'Bearer $_authToken',
  };

  // ── Data endpoints ────────────────────────────────────────────────────────────
  static Future<List<dynamic>> fetchHostGroups() async => _fetchMetaList(
    endpoint: '/api/hostgroups',
    storeKey: 'meta:hostgroups',
    timeoutSec: 30,
  );

  static Future<List<dynamic>> fetchHosts({String? groupId}) async {
    final suffix = groupId == null
        ? '/api/hosts'
        : '/api/hosts?groupid=$groupId';
    return _fetchMetaList(
      endpoint: suffix,
      storeKey: 'meta:hosts:${groupId ?? 'all'}',
      timeoutSec: 30,
    );
  }

  static Future<List<dynamic>> fetchItems(
    String hostId, {
    int pageSize = 50,
    void Function(List<dynamic> mergedItems)? onProgress,
  }) async {
    final storeKey = 'meta:items:$hostId';
    final cached = _metaCacheEnabled ? await LocalStore.readMap(storeKey) : null;
    List<dynamic> metadata = (cached?['data'] is List)
        ? List<dynamic>.from(cached!['data'] as List)
        : <dynamic>[];

    try {
      if (metadata.isEmpty) {
        if (_metaCacheEnabled) {
          final seed = await _fetchMetaList(
            endpoint: '/api/items?hostid=$hostId',
            storeKey: storeKey,
            timeoutSec: 300,
          );
          metadata = _stripItemValues(seed);
        } else {
          final seed = await _getJson(
            '/api/items?hostid=$hostId',
            timeoutSec: 300,
            retries: 1,
          );
          metadata = _stripItemValues(_coerceItemsList(seed));
        }
      }

      var metadataOnly = _stripItemValues(metadata);
      // Metadata-first (no lastvalue) — must run *before* live fetch. A post-fetch
      // emit with empty live would wipe all values in listeners.
      if (onProgress != null) {
        onProgress(_mergeMetaAndValues(metadataOnly, const <dynamic>[]));
      }

      // Fetch live values in pages so large hosts can load progressively.
      final liveList = await _fetchLiveItemValues(
        hostId,
        pageSize: pageSize,
        onProgress: (chunkedLive) {
          if (onProgress == null) return;
          final base = metadata.isEmpty ? _stripItemValues(chunkedLive) : metadata;
          onProgress(_mergeMetaAndValues(_stripItemValues(base), chunkedLive));
        },
      );
      if (metadata.isEmpty && liveList.isNotEmpty) {
        metadata = _stripItemValues(liveList);
      }

      metadataOnly = _stripItemValues(metadata);
      final checksum = _checksumForList(metadataOnly);

      if (_metaCacheEnabled) {
        await LocalStore.writeMap(storeKey, <String, dynamic>{
          'checksum': checksum,
          'cached_at': DateTime.now().toIso8601String(),
          'data': metadataOnly,
        });
      }

      return _mergeMetaAndValues(metadataOnly, liveList);
    } catch (e) {
      if (metadata.isNotEmpty) return metadata;
      throw Exception('Failed to fetch items for host $hostId: $e');
    }
  }

  /// Metadata-only item list for a host.
  /// Reads from local cache first; can optionally avoid network calls.
  static Future<List<dynamic>> fetchItemsMetadata(
    String hostId, {
    bool cacheOnly = false,
    bool forceRefresh = false,
  }) async {
    final storeKey = 'meta:items:$hostId';
    if (!_metaCacheEnabled) {
      if (cacheOnly) return const <dynamic>[];
      final data = await _getJson(
        '/api/items?hostid=$hostId&meta=1',
        timeoutSec: 180,
        retries: 1,
      );
      final list = (data is Map) ? _coerceItemsList(data['data']) : _coerceItemsList(data);
      return _stripItemValues(list);
    }
    final cached = await LocalStore.readMap(storeKey);
    final cachedData = (cached?['data'] is List)
        ? List<dynamic>.from(cached!['data'] as List)
        : <dynamic>[];
    if (!forceRefresh && (cachedData.isNotEmpty || cacheOnly)) return cachedData;
    if (cacheOnly) return cachedData;

    if (forceRefresh) {
      final refreshed = await _fetchMetaList(
        endpoint: '/api/items?hostid=$hostId',
        storeKey: storeKey,
        timeoutSec: 180,
      );
      final metadata = _stripItemValues(refreshed);
      await LocalStore.writeMap(storeKey, <String, dynamic>{
        'checksum': _checksumForList(metadata),
        'cached_at': DateTime.now().toIso8601String(),
        'data': metadata,
      });
      return metadata;
    }

    final list = await _fetchMetaList(
      endpoint: '/api/items?hostid=$hostId',
      storeKey: storeKey,
      timeoutSec: 180,
    );
    return _stripItemValues(list);
  }

  static Future<List<dynamic>> fetchLldRules(String hostId) async {
    if (!_metaCacheEnabled) {
      final data = await _getJson(
        '/api/lld-rules?hostid=$hostId',
        timeoutSec: 120,
        retries: 2,
      );
      return _coerceItemsList(data);
    }
    return _fetchMetaList(
      endpoint: '/api/lld-rules?hostid=$hostId',
      storeKey: 'meta:lld:$hostId',
      timeoutSec: 120,
    );
  }

  static Future<List<dynamic>> fetchItemPrototypes(
    String hostId, {
    bool cacheOnly = false,
  }) async {
    final storeKey = 'meta:itemprototypes:$hostId';
    if (!_metaCacheEnabled) {
      if (cacheOnly) return const <dynamic>[];
      final data = await _getJson(
        '/api/itemprototypes?hostid=$hostId',
        timeoutSec: 120,
        retries: 1,
      );
      return _coerceItemsList((data is Map) ? data['data'] : data);
    }
    final cached = await LocalStore.readMap(storeKey);
    final cachedData = (cached?['data'] is List)
        ? List<dynamic>.from(cached!['data'] as List)
        : <dynamic>[];
    if (cachedData.isNotEmpty || cacheOnly) return cachedData;

    final data = await _getJson(
      '/api/itemprototypes?hostid=$hostId',
      timeoutSec: 120,
      retries: 1,
    );
    List<dynamic> list = <dynamic>[];
    if (data is Map<String, dynamic>) {
      final raw = data['data'];
      if (raw is List) list = raw;
    } else if (data is List) {
      list = data;
    }
    await LocalStore.writeMap(storeKey, <String, dynamic>{
      'cached_at': DateTime.now().toIso8601String(),
      'data': list,
    });
    return list;
  }

  static Future<List<dynamic>> fetchTriggers() async => _fetchMetaList(
    endpoint: '/api/triggers',
    storeKey: 'meta:triggers',
    timeoutSec: 30,
  );

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

  static Future<void> registerDeviceToken(
    String token, {
    Map<String, dynamic>? filter,
  }) async {
    final resp = await _postRaw(
      '/devices/register',
      headers: _headers,
      body: jsonEncode({
        'platform': 'android',
        'token': token,
        ...?(filter == null ? null : {'filter': filter}),
      }),
      timeoutSec: 15,
    );
    _ensureOk(resp);
  }

  /// Push updated notification filter to the relay server.
  static Future<void> updateDeviceFilter(
    String token,
    Map<String, dynamic> filter,
  ) async {
    final resp = await _postRaw(
      '/devices/filter',
      headers: _headers,
      body: jsonEncode({'token': token, 'filter': filter}),
      timeoutSec: 10,
    );
    _ensureOk(resp);
  }

  // ── Internals ─────────────────────────────────────────────────────────────────
  static void _ensureOk(http.Response response) {
    if (response.statusCode == 401) {
      _authToken = null;
      _authErrorCtrl.add('Session expired — please log in again.');
      throw Exception('Session expired — please log in again.');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('HTTP ${response.statusCode}: ${response.body}');
    }
  }

  static Future<dynamic> _getJson(
    String path, {
    int timeoutSec = 20,
    int retries = 1,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt <= retries; attempt++) {
      try {
        final resp = await _getRawSingle(
          path,
          headers: _headers,
          timeoutSec: timeoutSec,
        );
        _ensureOk(resp);
        return jsonDecode(resp.body);
      } catch (e) {
        lastError = e;
        if (e.toString().contains('Session expired')) rethrow;
        if (attempt < retries) {
          await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
          continue;
        }
      }
    }
    throw Exception('Request failed for $path: $lastError');
  }

  static Future<List<dynamic>> _fetchMetaList({
    required String endpoint,
    required String storeKey,
    required int timeoutSec,
  }) async {
    if (!_metaCacheEnabled) {
      final join = endpoint.contains('?') ? '&' : '?';
      final withMeta = '$endpoint${join}meta=1';
      final resp = await _getRaw(withMeta, timeoutSec: timeoutSec, retries: 2);
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final body = jsonDecode(resp.body);
        if (body is Map<String, dynamic>) {
          final list = body['data'];
          if (list is List) return list;
        }
      }
      throw Exception('HTTP ${resp.statusCode}');
    }
    final cached = await LocalStore.readMap(storeKey);
    final cachedCheck = (cached?['checksum'] ?? '').toString();
    final cachedData = cached?['data'];
    final join = endpoint.contains('?') ? '&' : '?';
    final withMeta =
        '$endpoint${join}meta=1${cachedCheck.isEmpty ? '' : '&if_checksum=$cachedCheck'}';

    try {
      final resp = await _getRaw(withMeta, timeoutSec: timeoutSec, retries: 2);
      if (resp.statusCode == 304 && cachedData is List) return cachedData;
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final body = jsonDecode(resp.body);
        if (body is Map<String, dynamic>) {
          final list = body['data'];
          if (list is List) {
            final checksum =
                (body['checksum'] ?? resp.headers['x-checksum'] ?? '')
                    .toString();
            await LocalStore.writeMap(storeKey, <String, dynamic>{
              'checksum': checksum,
              'cached_at':
                  body['cached_at'] ?? DateTime.now().toIso8601String(),
              'data': list,
            });
            return list;
          }
        }
      }
      throw Exception('HTTP ${resp.statusCode}');
    } catch (_) {
      if (cachedData is List) return cachedData;
      rethrow;
    }
  }

  static Future<http.Response> _getRaw(
    String path, {
    int timeoutSec = 20,
    int retries = 1,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt <= retries; attempt++) {
      try {
        final resp = await _getRawSingle(
          path,
          headers: _headers,
          timeoutSec: timeoutSec,
        );
        if (resp.statusCode == 304) return resp;
        _ensureOk(resp);
        return resp;
      } catch (e) {
        lastError = e;
        if (e.toString().contains('Session expired')) rethrow;
        if (attempt < retries) {
          await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
          continue;
        }
      }
    }
    throw Exception('Request failed for $path: $lastError');
  }

  static Future<http.Response> _postRaw(
    String path, {
    required Map<String, String> headers,
    required Object body,
    int timeoutSec = 20,
  }) async {
    Future<http.Response> sendOnce() async {
      final client = _buildClient();
      try {
        return await client
            .post(Uri.parse('$_baseUrl$path'), headers: headers, body: body)
            .timeout(Duration(seconds: timeoutSec));
      } finally {
        client.close();
      }
    }

    await _ensureActiveBaseUrl();
    try {
      return await sendOnce();
    } catch (_) {
      // Network path may have changed (e.g., intranet -> internet). Force
      // relay re-selection and retry once on the new active base URL.
      await _ensureActiveBaseUrl(force: true);
      return sendOnce();
    }
  }

  static Future<http.Response> _getRawSingle(
    String path, {
    required Map<String, String> headers,
    int timeoutSec = 20,
  }) async {
    Future<http.Response> sendOnce() async {
      final client = _buildClient();
      try {
        return await client
            .get(Uri.parse('$_baseUrl$path'), headers: headers)
            .timeout(Duration(seconds: timeoutSec));
      } finally {
        client.close();
      }
    }

    await _ensureActiveBaseUrl();
    try {
      return await sendOnce();
    } catch (_) {
      await _ensureActiveBaseUrl(force: true);
      return sendOnce();
    }
  }

  static http.Client _buildClient() {
    if (!_allowSelfSignedCertificates) return http.Client();
    final expectedHost = Uri.tryParse(_baseUrl)?.host.toLowerCase();
    final ioHttpClient = HttpClient()
      ..badCertificateCallback = (X509Certificate cert, String host, int port) {
        if (expectedHost == null || expectedHost.isEmpty) return false;
        // Restrict trust bypass to the configured API host only.
        return host.toLowerCase() == expectedHost;
      };
    return IOClient(ioHttpClient);
  }

  static Future<void> _ensureActiveBaseUrl({bool force = false}) async {
    if (_lockBaseUrlForSession && !force) return;
    if (!_autoSelectBaseUrl) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastReachCheck) < _reachInterval) return;
    if (_reachInFlight != null) return _reachInFlight!;
    _reachInFlight = _selectBaseUrl().whenComplete(() => _reachInFlight = null);
    return _reachInFlight!;
  }

  static Future<void> _selectBaseUrl() async {
    final first = _intranetUrl;
    final second = _internetUrl;
    final third = _tunnelUrl;
    final checks = await Future.wait<bool>([
      _isReachable(first),
      _isReachable(second),
      _isReachable(third),
    ]);
    String? selected;
    if (checks[0]) {
      selected = first;
    } else if (checks[1]) {
      selected = second;
    } else if (checks[2]) {
      selected = third;
    }
    if (selected != null && selected.isNotEmpty) {
      _baseUrl = selected;
    } else {
      _baseUrl = _manualBaseUrl;
    }
    _lastReachCheck = DateTime.now();
  }

  static Future<bool> _isReachable(String baseUrl) async {
    if (baseUrl.trim().isEmpty) return false;
    final uri = Uri.tryParse(baseUrl);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return false;
    final port = uri.hasPort
        ? uri.port
        : (uri.scheme.toLowerCase() == 'https' ? 443 : 80);
    // Parallel probes: wall time ≈ this cap per relay (settings 1–2s, capped at 1.2s).
    final hardProbeTimeout = Duration(
      milliseconds: _reachTimeout.inMilliseconds.clamp(600, 1200).toInt(),
    );

    // Attempt 1: fast TCP connect probe (works even if "/" route is blocked).
    try {
      final sock = await Socket.connect(
        uri.host,
        port,
        timeout: hardProbeTimeout,
      ).timeout(hardProbeTimeout);
      sock.destroy();
      return true;
    } catch (_) {}

    return false;
  }

  static List<dynamic> _stripItemValues(List<dynamic> items) {
    return items.map((i) {
      final src = (i is Map) ? i : <String, dynamic>{};
      final m = <String, dynamic>{};
      m['itemid'] = src['itemid'];
      m['name'] = src['name'];
      m['key_'] = src['key_'];
      m['units'] = src['units'];
      m['value_type'] = src['value_type'];
      m['tags'] = src['tags'];
      return m;
    }).toList();
  }

  static String _checksumForList(List<dynamic> list) {
    try {
      final s = jsonEncode(list);
      var hash = 5381;
      for (final c in s.codeUnits) {
        hash = ((hash << 5) + hash) ^ c;
      }
      return '${list.length}:${hash.toUnsigned(32)}';
    } catch (_) {
      return DateTime.now().millisecondsSinceEpoch.toString();
    }
  }

  static String _normItemId(dynamic v) => (v ?? '').toString().trim();

  /// Backend may return a raw list or `{ "data": [ ... ] }`.
  static List<dynamic> _coerceItemsList(dynamic json) {
    if (json is List) return json;
    if (json is Map) {
      final d = json['data'];
      if (d is List) return d;
    }
    return const <dynamic>[];
  }

  static List<dynamic> _mergeMetaAndValues(
    List<dynamic> metadata,
    List<dynamic> live,
  ) {
    final liveById = <String, dynamic>{};
    for (final i in live) {
      if (i is! Map) continue;
      final id = _normItemId(i['itemid'] ?? i['id']);
      if (id.isNotEmpty) liveById[id] = i;
    }
    return metadata.map((m) {
      final out = <String, dynamic>{
        ...(m is Map ? Map<String, dynamic>.from(m) : <String, dynamic>{}),
      };
      final id = _normItemId(out['itemid'] ?? out['id']);
      final v = liveById[id];
      if (v != null) {
        out['lastvalue'] = (v['lastvalue'] ?? v['value'] ?? '').toString();
        out['lastclock'] = v['lastclock'] ?? v['clock'];
      } else {
        out['lastvalue'] = '';
        out['lastclock'] = '';
      }
      return out;
    }).toList();
  }

  static Future<List<dynamic>> _fetchLiveItemValues(
    String hostId, {
    int pageSize = 50,
    void Function(List<dynamic> liveItems)? onProgress,
  }) async {
    // One-shot values (single RTT). Always try first — avoids many paginated
    // round trips on high-latency links. Progressive UI used to skip this path.
    try {
      final valuesOnly = await _getJson(
        '/api/item-values?hostid=$hostId',
        timeoutSec: 120,
        retries: 1,
      );
      final asList = _coerceItemsList(valuesOnly);
      if (asList.isNotEmpty) {
        return asList;
      }
    } catch (_) {
      // Paginated fallback below.
    }

    final all = <dynamic>[];
    const maxPages = 500;
    var fetchedPages = 0;
    final seenIds = <String>{};
    DateTime? lastProgressEmit;
    var offset = 1;

    // Single steady page size — no 5/10-item staging (that multiplied WAN RTTs).
    while (fetchedPages < maxPages) {
      final full = await _getJson(
        '/api/items?hostid=$hostId&limit=$pageSize&offset=$offset',
        timeoutSec: 300,
        retries: 1,
      );
      final chunk = _coerceItemsList(full);
      if (chunk.isEmpty) break;

      var added = 0;
      for (final item in chunk) {
        final id = item is Map
            ? _normItemId(item['itemid'] ?? item['id'])
            : '';
        if (id.isEmpty) {
          all.add(item);
          added++;
          continue;
        }
        if (seenIds.add(id)) {
          all.add(item);
          added++;
        }
      }

      if (onProgress != null) {
        final now = DateTime.now();
        const throttle = Duration(milliseconds: 320);
        final firstPage = fetchedPages == 0;
        final prevEmit = lastProgressEmit;
        final cooled =
            prevEmit == null || now.difference(prevEmit) >= throttle;
        if (firstPage || cooled) {
          lastProgressEmit = now;
          onProgress(List<dynamic>.from(all));
        }
      }

      fetchedPages++;

      if (chunk.length < pageSize) break;
      if (added == 0) break;
      offset += 1;
      await Future<void>.delayed(Duration.zero);
    }
    return all;
  }
}
