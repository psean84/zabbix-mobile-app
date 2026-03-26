import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'api_client.dart';

/// Loaded once at app startup and reused everywhere.
/// Call [AppCache.instance.load()] from main() before runApp.
class AppCache extends ChangeNotifier {
  AppCache._();
  static final AppCache instance = AppCache._();

  // ── Raw data ─────────────────────────────────────────────────────────────────
  List<dynamic> hostGroups = [];
  List<dynamic> hosts      = [];
  List<dynamic> problems   = [];

  /// VRF → Customer name (from PE item tags)
  Map<String, String> vrfToCustomer = {};

  /// All known VRFs (sorted)
  List<String> get allVrfs {
    final s = <String>{...vrfToCustomer.keys};
    return s.toList()..sort();
  }

  /// All known customer names (sorted)
  List<String> get allCustomers {
    final s = <String>{...vrfToCustomer.values.where((v) => v.isNotEmpty)};
    return s.toList()..sort();
  }

  bool  isLoaded  = false;
  bool  isLoading = false;
  String loadError = '';

  // ── Connectivity ──────────────────────────────────────────────────────────────
  bool _isOffline = false;
  bool get isOffline => _isOffline;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  void startConnectivityMonitor() {
    _connectivitySub?.cancel();
    // Check current state immediately
    Connectivity().checkConnectivity().then((results) {
      _isOffline = results.contains(ConnectivityResult.none) && results.length == 1;
      notifyListeners();
    });
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final wasOffline = _isOffline;
      _isOffline = results.contains(ConnectivityResult.none) && results.length == 1;
      notifyListeners();
      // Auto-refresh when coming back online
      if (wasOffline && !_isOffline && isLoaded) refresh();
    });
  }

  void stopConnectivityMonitor() {
    _connectivitySub?.cancel();
    _connectivitySub = null;
  }

  // ── Centralized auto-refresh timer ────────────────────────────────────────────
  Timer? _autoRefreshTimer;

  /// Start a single app-wide refresh timer.  Call from main.dart after login;
  /// this replaces the individual timers that were scattered across screens.
  void startAutoRefresh({Duration interval = const Duration(seconds: 30)}) {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = Timer.periodic(interval, (_) {
      if (!_isOffline) refresh();
    });
  }

  void stopAutoRefresh() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = null;
  }

  // ── Load at startup ───────────────────────────────────────────────────────────
  Future<void> load({bool force = false}) async {
    if (isLoading) return;
    if (isLoaded && !force) return;

    isLoading = true;
    loadError = '';
    notifyListeners();

    try {
      // Parallel fetch of groups + hosts + problems
      final results = await Future.wait([
        ApiClient.fetchHostGroups(),
        ApiClient.fetchHosts(),
        ApiClient.fetchTriggers(),
      ]);

      hostGroups = results[0] as List;
      hosts      = results[1] as List;
      problems   = results[2] as List;

      // ── Build VRF→Customer map from trigger tags ──────────────────────────
      // Triggers in PE group have tags: Customer={val}, VRF={val}
      final map = <String, String>{};
      for (final p in problems) {
        final tags = (p['tags'] is List) ? (p['tags'] as List) : const [];
        String? vrf;
        String? customer;
        for (final t in tags) {
          final k = (t['tag'] ?? '').toString().toLowerCase();
          final v = (t['value'] ?? '').toString().trim();
          if (v.isEmpty) continue;
          if (k == 'vrf' || k == 'vrfname' || k == 'vrf_name') vrf = v;
          if (k == 'customer' || k == 'cust' || k == 'customer_name') customer = v;
        }
        if (vrf != null && vrf.isNotEmpty) {
          map[vrf] = customer ?? map[vrf] ?? '';
        }
      }
      vrfToCustomer = map;

      isLoaded  = true;
      loadError = '';
    } catch (e) {
      loadError = e.toString();
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  // ── Refresh (called from pull-to-refresh) ─────────────────────────────────────
  Future<void> refresh() => load(force: true);

  // ── Reset (called on logout) ──────────────────────────────────────────────────
  void reset() {
    stopAutoRefresh();
    stopConnectivityMonitor();
    hostGroups = [];
    hosts = [];
    problems = [];
    vrfToCustomer = {};
    isLoaded = false;
    isLoading = false;
    loadError = '';
    notifyListeners();
  }

  // ── Quick lookups ─────────────────────────────────────────────────────────────
  String customerForVrf(String vrf) => vrfToCustomer[vrf] ?? '';

  String? vrfForCustomer(String customer) {
    for (final e in vrfToCustomer.entries) {
      if (e.value == customer) return e.key;
    }
    return null;
  }

  Map<String, dynamic>? hostById(String id) {
    for (final h in hosts) {
      if (h['hostid']?.toString() == id) return h as Map<String, dynamic>?;
    }
    return null;
  }
}
