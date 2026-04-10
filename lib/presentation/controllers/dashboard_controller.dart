import 'package:flutter/foundation.dart';

import '../../core/app_cache.dart';
import '../../domain/models/dashboard_summary.dart';
import '../../domain/services/dashboard_summary_builder.dart';

class DashboardController extends ChangeNotifier {
  DashboardController({
    AppCache? cache,
    DashboardSummaryBuilder? summaryBuilder,
  }) : _cache = cache ?? AppCache.instance,
       _summaryBuilder = summaryBuilder ?? const DashboardSummaryBuilder() {
    _cache.addListener(_handleCacheChanged);
    _rebuildState();
  }

  final AppCache _cache;
  final DashboardSummaryBuilder _summaryBuilder;

  DashboardSummary _summary = const DashboardSummary.empty();
  final List<int> _disasterTrend = <int>[];
  final List<int> _highTrend = <int>[];
  final List<int> _warningTrend = <int>[];

  DashboardSummary get summary => _summary;
  bool get isLoading => _cache.isLoading;
  bool get isLoaded => _cache.isLoaded;
  String get loadError => _cache.loadError;
  List<dynamic> get problems => _cache.problems;
  List<int> get disasterTrend => List<int>.unmodifiable(_disasterTrend);
  List<int> get highTrend => List<int>.unmodifiable(_highTrend);
  List<int> get warningTrend => List<int>.unmodifiable(_warningTrend);

  Future<void> refresh() => _cache.refresh();

  int trendDelta(List<int> values) =>
      values.length >= 2 ? values.last - values[values.length - 2] : 0;

  void _handleCacheChanged() {
    _rebuildState();
    notifyListeners();
  }

  void _rebuildState() {
    _summary = _summaryBuilder.build(_cache.snapshot);
    _captureTrendSnapshots();
  }

  void _captureTrendSnapshots() {
    if (!_cache.isLoaded || _cache.isLoading) return;

    _pushTrend(_disasterTrend, _summary.disasterCount);
    _pushTrend(_highTrend, _summary.highCount);
    _pushTrend(_warningTrend, _summary.warningCount);
  }

  void _pushTrend(List<int> values, int nextValue) {
    if (values.isNotEmpty && values.last == nextValue) return;
    values.add(nextValue);
    if (values.length > 30) {
      values.removeAt(0);
    }
  }

  @override
  void dispose() {
    _cache.removeListener(_handleCacheChanged);
    super.dispose();
  }
}
