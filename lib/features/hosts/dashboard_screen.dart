import 'package:flutter/material.dart';

import '../../core/app_cache.dart';
import '../../core/utils.dart';
import '../../core/zbx_theme.dart';
import '../../presentation/widgets/dashboard_components.dart';

const _rxBlue = ZbxPalette.rxBlue;
const _txGreen = ZbxPalette.txGreen;
const _upGreen = ZbxPalette.upGreen;
const _downRed = ZbxPalette.downRed;
const _warnAmb = ZbxPalette.warnAmb;

typedef GroupTapCallback = void Function(String id, String name);

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
    if (!AppCache.instance.isLoaded) {
      AppCache.instance.load();
    }
    _captureTrendSnapshot();
  }

  @override
  void dispose() {
    AppCache.instance.removeListener(_onCacheUpdate);
    super.dispose();
  }

  void _onCacheUpdate() {
    _captureTrendSnapshot();
    if (mounted) {
      setState(() {});
    }
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

  int get _totalHosts => AppCache.instance.hosts.length;
  int get _totalGroups => AppCache.instance.hostGroups.length;
  int get _totalProblems => AppCache.instance.problems.length;

  int get _disasterCount => AppCache.instance.problems
      .where((problem) => severityValue(problem['priority']?.toString() ?? '0') >= 5)
      .length;

  int get _highCount => AppCache.instance.problems.where((problem) {
    final severity = severityValue(problem['priority']?.toString() ?? '0');
    return severity == 4;
  }).length;

  int get _warnCount => AppCache.instance.problems.where((problem) {
    final severity = severityValue(problem['priority']?.toString() ?? '0');
    return severity >= 2 && severity < 4;
  }).length;

  Map<String, ({int count, int maxSev, String groupId})> _problemsByGroup() {
    final hostMap = <String, dynamic>{};
    for (final host in AppCache.instance.hosts) {
      final id = host['hostid']?.toString();
      if (id != null) hostMap[id] = host;
    }

    final groupIdMap = <String, String>{};
    for (final group in AppCache.instance.hostGroups) {
      final name = (group['name'] ?? '').toString();
      final id = (group['groupid'] ?? '').toString();
      if (name.isNotEmpty && id.isNotEmpty) {
        groupIdMap[name] = id;
      }
    }

    final grouped = <String, ({int count, int maxSev, String groupId})>{};
    for (final problem in AppCache.instance.problems) {
      final severity = severityValue(problem['priority']?.toString() ?? '0');
      final triggerHosts = problem['hosts'];
      if (triggerHosts is! List) continue;

      final seen = <String>{};
      for (final triggerHost in triggerHosts) {
        final hostId = triggerHost['hostid']?.toString();
        final host = hostId != null ? hostMap[hostId] : null;
        if (host == null) continue;

        final rawGroups = host['groups'] ?? host['hostgroups'];
        if (rawGroups is! List) continue;

        for (final group in rawGroups) {
          final groupName = (group['name'] ?? '').toString().trim();
          if (groupName.isEmpty || seen.contains(groupName)) continue;
          seen.add(groupName);

          final previous = grouped[groupName];
          final groupId = groupIdMap[groupName] ?? '';
          grouped[groupName] = (
            count: (previous?.count ?? 0) + 1,
            maxSev: previous == null
                ? severity
                : (severity > previous.maxSev ? severity : previous.maxSev),
            groupId: previous?.groupId.isEmpty == true
                ? groupId
                : (previous?.groupId ?? groupId),
          );
        }
      }
    }

    return grouped;
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
              'Loading dashboard...',
              style: TextStyle(fontSize: 12, color: ZbxT.textSec(context)),
            ),
          ],
        ),
      );
    }

    final groupsSorted = _problemsByGroup().entries.toList()
      ..sort((a, b) => b.value.count.compareTo(a.value.count));

    return RefreshIndicator(
      onRefresh: cache.refresh,
      color: _rxBlue,
      backgroundColor: ZbxT.card(context),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(0, 0, 0, 40),
        children: [
          if (cache.loadError.isNotEmpty)
            buildDashboardErrorBanner(
              context,
              cache.loadError,
              style: DashboardVisualStyle.metro,
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
            child: buildDashboardSectionHeader(
              context,
              'OVERVIEW',
              Icons.dashboard_outlined,
              style: DashboardVisualStyle.metro,
            ),
          ),
          Row(
            children: [
              Expanded(
                child: DashboardStatTile(
                  label: 'Hosts',
                  value: '$_totalHosts',
                  icon: Icons.router,
                  color: _rxBlue,
                  onTap: widget.onHostsTap,
                  style: DashboardVisualStyle.metro,
                ),
              ),
              const SizedBox(width: 2),
              Expanded(
                child: DashboardStatTile(
                  label: 'Groups',
                  value: '$_totalGroups',
                  icon: Icons.folder_outlined,
                  color: _txGreen,
                  onTap: widget.onGroupsTap,
                  style: DashboardVisualStyle.metro,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Expanded(
                child: DashboardStatTile(
                  label: 'Active Alerts',
                  value: '$_totalProblems',
                  icon: Icons.warning_amber_rounded,
                  color: _warnAmb,
                  onTap: widget.onProblemsTap,
                  style: DashboardVisualStyle.metro,
                ),
              ),
              const SizedBox(width: 2),
              Expanded(
                child: DashboardStatTile(
                  label: 'Disaster',
                  value: '$_disasterCount',
                  icon: Icons.crisis_alert_outlined,
                  color: _disasterCount > 0
                      ? const Color(0xFF7B1FA2)
                      : _upGreen,
                  trendValues: _disasterTrend,
                  trendDelta: _trendDelta(_disasterTrend),
                  onTap: () => widget.onSeverityTap?.call(5),
                  style: DashboardVisualStyle.metro,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Expanded(
                child: DashboardStatTile(
                  label: 'High',
                  value: '$_highCount',
                  icon: Icons.error_outline,
                  color: _highCount > 0 ? _downRed : _upGreen,
                  trendValues: _highTrend,
                  trendDelta: _trendDelta(_highTrend),
                  onTap: () => widget.onSeverityTap?.call(4),
                  style: DashboardVisualStyle.metro,
                ),
              ),
              const SizedBox(width: 2),
              Expanded(
                child: DashboardStatTile(
                  label: 'Warning',
                  value: '$_warnCount',
                  icon: Icons.info_outline,
                  color: _warnCount > 0 ? _warnAmb : _upGreen,
                  trendValues: _warnTrend,
                  trendDelta: _trendDelta(_warnTrend),
                  onTap: () => widget.onSeverityTap?.call(3),
                  style: DashboardVisualStyle.metro,
                ),
              ),
            ],
          ),
          if (_totalProblems > 0) ...[
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              child: buildDashboardSectionHeader(
                context,
                'SEVERITY BREAKDOWN',
                Icons.bar_chart,
                style: DashboardVisualStyle.metro,
              ),
            ),
            GestureDetector(
              onTap: widget.onProblemsTap,
              child: DashboardSeverityBar(
                problems: cache.problems,
                style: DashboardVisualStyle.metro,
              ),
            ),
          ],
          if (groupsSorted.isNotEmpty) ...[
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
              child: buildDashboardSectionHeader(
                context,
                'ALERTS BY GROUP',
                Icons.folder_open_outlined,
                style: DashboardVisualStyle.metro,
              ),
            ),
            const SizedBox(height: 2),
            ...groupsSorted.take(12).map(
              (entry) => DashboardGroupAlertRow(
                group: entry.key,
                count: entry.value.count,
                maxSeverity: entry.value.maxSev,
                onTap: () => widget.onGroupTap?.call(
                  entry.value.groupId,
                  entry.key,
                ),
                style: DashboardVisualStyle.metro,
              ),
            ),
          ],
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Center(
              child: Text(
                'Auto-refresh every 30 s  .  Pull to refresh',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 10,
                  color: ZbxT.textSec(context).withValues(alpha: 0.6),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
