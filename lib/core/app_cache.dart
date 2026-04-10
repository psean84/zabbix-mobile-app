import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../data/repositories/monitoring_repository.dart';
import '../domain/models/app_snapshot.dart';

/// Loaded once at app startup and reused everywhere.
/// Call [AppCache.instance.load()] from main() before runApp.
class AppCache extends ChangeNotifier {
  AppCache._({MonitoringRepository? repository})
    : _repository = repository ?? const MonitoringRepository();

  static final AppCache instance = AppCache._();

  final MonitoringRepository _repository;
  AppSnapshot _snapshot = const AppSnapshot.empty();

  AppSnapshot get snapshot => _snapshot;
  List<dynamic> get hostGroups => _snapshot.hostGroups;
  List<dynamic> get hosts => _snapshot.hosts;
  List<dynamic> get problems => _snapshot.problems;
  Map<String, String> get vrfToCustomer => _snapshot.vrfToCustomer;
  List<String> get allVrfs => _snapshot.allVrfs;
  List<String> get allCustomers => _snapshot.allCustomers;

  bool isLoaded = false;
  bool isLoading = false;
  String loadError = '';

  bool _isOffline = false;
  bool get isOffline => _isOffline;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  Timer? _autoRefreshTimer;

  void startConnectivityMonitor() {
    _connectivitySub?.cancel();

    Connectivity().checkConnectivity().then((results) {
      _isOffline =
          results.contains(ConnectivityResult.none) && results.length == 1;
      notifyListeners();
    });

    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final wasOffline = _isOffline;
      _isOffline =
          results.contains(ConnectivityResult.none) && results.length == 1;
      notifyListeners();

      if (wasOffline && !_isOffline && isLoaded) {
        refresh();
      }
    });
  }

  void stopConnectivityMonitor() {
    _connectivitySub?.cancel();
    _connectivitySub = null;
  }

  /// Start a single app-wide refresh timer. Call from main.dart after login.
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

  Future<void> load({bool force = false}) async {
    if (isLoading) return;
    if (isLoaded && !force) return;

    isLoading = true;
    loadError = '';
    notifyListeners();

    try {
      _snapshot = await _repository.fetchAppSnapshot();
      isLoaded = true;
      loadError = '';
    } catch (e) {
      loadError = e.toString();
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> refresh() => load(force: true);

  void reset() {
    stopAutoRefresh();
    stopConnectivityMonitor();
    _snapshot = const AppSnapshot.empty();
    isLoaded = false;
    isLoading = false;
    loadError = '';
    notifyListeners();
  }

  String customerForVrf(String vrf) => _snapshot.customerForVrf(vrf);

  String? vrfForCustomer(String customer) => _snapshot.vrfForCustomer(customer);

  Map<String, dynamic>? hostById(String id) => _snapshot.hostById(id);
}
