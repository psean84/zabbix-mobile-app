import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/app_cache.dart';
import '../../core/utils.dart';
import '../../core/zbx_theme.dart';

const _rxBlue = ZbxPalette.rxBlue;
const _txGreen = ZbxPalette.txGreen;
const _upGreen = ZbxPalette.upGreen;
const _downRed = ZbxPalette.downRed;
const _warnAmb = ZbxPalette.warnAmb;

typedef GroupTapCallback = void Function(String id, String name);

// â”€â”€ Theme-aware color helper â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
class _T {
  static Color card(BuildContext ctx) => ZbxTheme.of(ctx).bgCard;
  static Color rim(BuildContext ctx) => ZbxTheme.of(ctx).rim;
  static Color textPri(BuildContext ctx) => ZbxTheme.of(ctx).textPri;
  static Color textSec(BuildContext ctx) => ZbxTheme.of(ctx).textSec;
}

class DashboardScreen extends StatefulWidget {
  final GroupTapCallback? onGroupTap;
  final VoidCallback? onProblemsTap;
  final VoidCallback? onHostsTap;
  final VoidCallback? onGroupsTap;
  final void Function(int severity)? onSeverityTap;

  const DashboardScreen({
    super.key,
    this.onGroupTap,
    this.onProblemsTap,
    this.onHostsTap,
    this.onGroupsTap,
    this.onSeverityTap,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final List<int> _disasterTrend = <int>[];
  final List<int> _highTrend = <int>[];
  final List<int> _warnTrend = <int>[];

  @override
  void initState() {
    super.initState();
    AppCache.instance.addListener(_onCacheUpdate);
    // Load if not yet loaded
    if (!AppCache.instance.isLoaded) {
      AppCache.instance.load();
    }
    // Refresh driven by AppCache.startAutoRefresh() in main.dart
    _captureTrendSnapshot();
  }

  @override
  void dispose() {
    AppCache.instance.removeListener(_onCacheUpdate);
    super.dispose();
  }

  void _onCacheUpdate() {
    _captureTrendSnapshot();
    if (mounted) setState(() {});
  }

  void _captureTrendSnapshot() {
    if (!AppCache.instance.isLoaded || AppCache.instance.isLoading) return;
    void push(List<int> list, int value) {
      if (list.isNotEmpty && list.last == value) return;
      list.add(value);
      if (list.length > 30) list.removeAt(0);
    }

    push(_disasterTrend, _disasterCount);
    push(_highTrend, _highCount);
    push(_warnTrend, _warnCount);
  }

  int _trendDelta(List<int> values) =>
      values.length >= 2 ? values.last - values[values.length - 2] : 0;

  // â”€â”€ Summary computations â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  int get _totalHosts => AppCache.instance.hosts.length;
  int get _totalGroups => AppCache.instance.hostGroups.length;
  int get _totalProblems => AppCache.instance.problems.length;

  int get _disasterCount => AppCache.instance.problems
      .where((p) => severityValue(p['priority']?.toString() ?? '0') >= 5)
      .length;
  int get _highCount => AppCache.instance.problems.where((p) {
    final s = severityValue(p['priority']?.toString() ?? '0');
    return s == 4;
  }).length;
  int get _warnCount => AppCache.instance.problems.where((p) {
    final s = severityValue(p['priority']?.toString() ?? '0');
    return s >= 2 && s < 4;
  }).length;

  Map<String, ({int count, int maxSev, String groupId})> _problemsByGroup() {
    final hostMap = <String, dynamic>{};
    for (final h in AppCache.instance.hosts) {
      final id = h['hostid']?.toString();
      if (id != null) hostMap[id] = h;
    }

    // Build groupId lookup from hostGroups list
    final groupIdMap = <String, String>{};
    for (final g in AppCache.instance.hostGroups) {
      final name = (g['name'] ?? '').toString();
      final id = (g['groupid'] ?? '').toString();
      if (name.isNotEmpty && id.isNotEmpty) groupIdMap[name] = id;
    }

    final out = <String, ({int count, int maxSev, String groupId})>{};
    for (final p in AppCache.instance.problems) {
      final sev = severityValue(p['priority']?.toString() ?? '0');
      final trigHosts = p['hosts'];
      if (trigHosts is! List) continue;
      final seen = <String>{};
      for (final th in trigHosts) {
        final hid = th['hostid']?.toString();
        final host = hid != null ? hostMap[hid] : null;
        if (host == null) continue;
        final rawGrps = host['groups'] ?? host['hostgroups'];
        if (rawGrps is! List) continue;
        for (final g in rawGrps) {
          final name = (g['name'] ?? '').toString().trim();
          if (name.isEmpty || seen.contains(name)) continue;
          seen.add(name);
          final prev = out[name];
          final gid = groupIdMap[name] ?? '';
          out[name] = (
            count: (prev?.count ?? 0) + 1,
            maxSev: prev == null
                ? sev
                : (sev > prev.maxSev ? sev : prev.maxSev),
            groupId: prev?.groupId.isEmpty == true
                ? gid
                : (prev?.groupId ?? gid),
          );
        }
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final cache = AppCache.instance;

    if (cache.isLoading && !cache.isLoaded) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: _rxBlue, strokeWidth: 2),
            const SizedBox(height: 14),
            Text(
              'Loading dashboardâ€¦',
              style: TextStyle(fontSize: 12, color: ZbxT.textSec(context)),
            ),
          ],
        ),
      );
    }

    final probByGroup = _problemsByGroup();
    final groupsSorted = probByGroup.entries.toList()
      ..sort((a, b) => b.value.count.compareTo(a.value.count));

    return RefreshIndicator(
      onRefresh: cache.refresh,
      color: _rxBlue,
      backgroundColor: ZbxT.card(context),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 40),
        children: [
          // â”€â”€ Error â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
          if (cache.loadError.isNotEmpty) _errorBanner(cache.loadError),

          // â”€â”€ Overview â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
          _sectionHeader('OVERVIEW', Icons.dashboard_outlined),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _StatTile(
                  label: 'Hosts',
                  value: '$_totalHosts',
                  icon: Icons.router,
                  color: _rxBlue,
                  onTap: widget.onHostsTap,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _StatTile(
                  label: 'Groups',
                  value: '$_totalGroups',
                  icon: Icons.folder_outlined,
                  color: _txGreen,
                  onTap: widget.onGroupsTap,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _StatTile(
                  label: 'Active Alerts',
                  value: '$_totalProblems',
                  icon: Icons.warning_amber_rounded,
                  color: _warnAmb,
                  onTap: widget.onProblemsTap,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _StatTile(
                  label: 'Disaster',
                  value: '$_disasterCount',
                  icon: Icons.crisis_alert_outlined,
                  color: _disasterCount > 0
                      ? const Color(0xFF7B1FA2)
                      : _upGreen,
                  trendValues: _disasterTrend,
                  trendDelta: _trendDelta(_disasterTrend),
                  onTap: () => widget.onSeverityTap?.call(5),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _StatTile(
                  label: 'High',
                  value: '$_highCount',
                  icon: Icons.error_outline,
                  color: _highCount > 0 ? _downRed : _upGreen,
                  trendValues: _highTrend,
                  trendDelta: _trendDelta(_highTrend),
                  onTap: () => widget.onSeverityTap?.call(4),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _StatTile(
                  label: 'Warning',
                  value: '$_warnCount',
                  icon: Icons.info_outline,
                  color: _warnCount > 0 ? _warnAmb : _upGreen,
                  trendValues: _warnTrend,
                  trendDelta: _trendDelta(_warnTrend),
                  onTap: () => widget.onSeverityTap?.call(3),
                ),
              ),
            ],
          ),

          // â”€â”€ Severity bar â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
          if (_totalProblems > 0) ...[
            const SizedBox(height: 20),
            _sectionHeader('SEVERITY BREAKDOWN', Icons.bar_chart),
            const SizedBox(height: 10),
            GestureDetector(
              onTap: widget.onProblemsTap,
              child: _SeverityBar(problems: cache.problems),
            ),
          ],

          // â”€â”€ Alerts by group â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
          if (groupsSorted.isNotEmpty) ...[
            const SizedBox(height: 20),
            _sectionHeader('ALERTS BY GROUP', Icons.folder_open_outlined),
            const SizedBox(height: 4),
            Text(
              'Tap a group to open the Problems screen.',
              style: TextStyle(fontSize: 10, color: ZbxT.textSec(context)),
            ),
            const SizedBox(height: 10),
            ...groupsSorted
                .take(12)
                .map(
                  (e) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _GroupAlertRow(
                      group: e.key,
                      count: e.value.count,
                      maxSev: e.value.maxSev,
                      onTap: () =>
                          widget.onGroupTap?.call(e.value.groupId, e.key),
                    ),
                  ),
                ),
          ],

          // â”€â”€ Last updated â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
          const SizedBox(height: 20),
          Center(
            child: Text(
              'Auto-refresh every 30 s  â€¢  Pull to refresh',
              style: TextStyle(
                fontSize: 10,
                color: ZbxT.textSec(context).withValues(alpha: 0.6),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorBanner(String msg) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: _downRed.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: _downRed.withValues(alpha: 0.3)),
    ),
    child: Row(
      children: [
        const Icon(Icons.error_outline, color: _downRed, size: 15),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            msg,
            style: const TextStyle(fontSize: 11, color: _downRed),
          ),
        ),
      ],
    ),
  );

  Widget _sectionHeader(String title, IconData icon) => Row(
    children: [
      Icon(icon, size: 13, color: ZbxT.textSec(context)),
      const SizedBox(width: 6),
      Text(
        title,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: ZbxT.textSec(context),
          letterSpacing: 0.9,
        ),
      ),
      SizedBox(width: 8),
      Expanded(child: Container(height: 1, color: ZbxT.rim(context))),
    ],
  );
}

// â”€â”€â”€ Stat tile â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
class _StatTile extends StatelessWidget {
  final String label, value;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;
  final List<int>? trendValues;
  final int? trendDelta;

  const _StatTile({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.onTap,
    this.trendValues,
    this.trendDelta,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ZbxT.card(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 10,
                    color: ZbxT.textSec(context),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: color,
                    height: 1.1,
                  ),
                ),
              ],
            ),
          ),
          if ((trendValues ?? const <int>[]).length >= 2)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: _TrendMini(
                values: trendValues!,
                accent: color,
                delta: trendDelta ?? 0,
              ),
            ),
          if (onTap != null)
            Icon(
              Icons.chevron_right,
              size: 16,
              color: ZbxT.textSec(context).withValues(alpha: 0.4),
            ),
        ],
      ),
    ),
  );
}

class _TrendMini extends StatelessWidget {
  final List<int> values;
  final Color accent;
  final int delta;

  const _TrendMini({
    required this.values,
    required this.accent,
    required this.delta,
  });

  @override
  Widget build(BuildContext context) {
    final points = values
        .asMap()
        .entries
        .map((e) => FlSpot(e.key.toDouble(), e.value.toDouble()))
        .toList();
    final minY = values.reduce(math.min).toDouble();
    final maxY = values.reduce(math.max).toDouble();
    final arrow = delta > 0
        ? Icons.trending_up
        : (delta < 0 ? Icons.trending_down : Icons.trending_flat);
    final arrowColor = delta > 0
        ? ZbxPalette.downRed
        : (delta < 0 ? ZbxPalette.txGreen : ZbxT.textSec(context));

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 34,
          height: 16,
          child: LineChart(
            LineChartData(
              minX: 0,
              maxX: (values.length - 1).toDouble(),
              minY: minY == maxY ? (minY - 1) : minY,
              maxY: minY == maxY ? (maxY + 1) : maxY,
              lineBarsData: [
                LineChartBarData(
                  spots: points,
                  isCurved: true,
                  color: accent,
                  barWidth: 1.7,
                  dotData: const FlDotData(show: false),
                  belowBarData: BarAreaData(show: false),
                ),
              ],
              gridData: const FlGridData(show: false),
              titlesData: const FlTitlesData(show: false),
              borderData: FlBorderData(show: false),
              lineTouchData: const LineTouchData(enabled: false),
            ),
          ),
        ),
        Icon(arrow, size: 11, color: arrowColor),
      ],
    );
  }
}

// â”€â”€â”€ Severity bar â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
class _SeverityBar extends StatelessWidget {
  final List<dynamic> problems;
  const _SeverityBar({required this.problems});

  static const _colors = {
    5: Color(0xFF7B1FA2),
    4: Color(0xFFEF5350),
    3: Color(0xFFFFAB40),
    2: Color(0xFFFFD54F),
    1: Color(0xFF29B6F6),
    0: Color(0xFF7A90B4),
  };
  static const _labels = {
    5: 'Disaster',
    4: 'High',
    3: 'Average',
    2: 'Warning',
    1: 'Info',
    0: 'Not classified',
  };

  @override
  Widget build(BuildContext context) {
    final counts = <int, int>{};
    for (final p in problems) {
      final s = severityValue(p['priority']?.toString() ?? '0');
      counts[s] = (counts[s] ?? 0) + 1;
    }
    final total = problems.length;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ZbxT.card(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ZbxT.rim(context)),
      ),
      child: Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              height: 10,
              child: Row(
                children: [5, 4, 3, 2, 1, 0].map((s) {
                  final n = counts[s] ?? 0;
                  if (n == 0 || total == 0) return const SizedBox.shrink();
                  return Flexible(
                    flex: n,
                    child: Container(color: _colors[s]),
                  );
                }).toList(),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 6,
            children: [5, 4, 3, 2, 1, 0]
                .where((s) => (counts[s] ?? 0) > 0)
                .map(
                  (s) => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: _colors[s],
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        '${_labels[s]} (${counts[s]})',
                        style: TextStyle(
                          fontSize: 10,
                          color: ZbxT.textSec(context),
                        ),
                      ),
                    ],
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }
}

// â”€â”€â”€ Group alert row â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
class _GroupAlertRow extends StatelessWidget {
  final String group;
  final int count, maxSev;
  final VoidCallback? onTap;

  const _GroupAlertRow({
    required this.group,
    required this.count,
    required this.maxSev,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = severityColor('$maxSev');
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: ZbxT.card(context),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Row(
          children: [
            Container(
              width: 4,
              height: 36,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                group,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: ZbxT.textPri(context),
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: color.withValues(alpha: 0.4)),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: color,
                ),
              ),
            ),
            if (onTap != null) ...[
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right,
                size: 16,
                color: ZbxT.textSec(context).withValues(alpha: 0.5),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
