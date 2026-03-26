import 'dart:async';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/api_client.dart';
import '../../core/app_cache.dart';
import '../../core/utils.dart';
import '../../core/zbx_theme.dart';
import '../hosts/interface_dashboard_screen.dart';

// ─────────────────────────────────────────────
// Shared interface-extraction helper
// ─────────────────────────────────────────────
// ── Theme helper via ZbxT (see zbx_theme.dart) ────────────────────────────────

class _IfExtractor {
  static List<String> fromProblem(dynamic problem) {
    final out = <String>{};

    // 1. From attached item names / keys (bracket content)
    final items = (problem['items'] is List)
        ? (problem['items'] as List)
        : const [];
    final bracketRe = RegExp(r'\[([^\]]*)\]');
    for (final it in items) {
      for (final src in [
        (it['name'] ?? '').toString(),
        (it['key_'] ?? '').toString(),
      ]) {
        final m = bracketRe.firstMatch(src);
        if (m != null) {
          final s = _normalize(m.group(1) ?? '');
          if (s.isNotEmpty) out.add(s);
        }
      }
    }

    // 2. From tags whose key implies an interface
    final tags = (problem['tags'] is List)
        ? (problem['tags'] as List)
        : const [];
    for (final t in tags) {
      final tagName = (t['tag'] ?? '').toString().toLowerCase();
      final tagValue = (t['value'] ?? '').toString();
      if (tagValue.isEmpty) continue;
      if (tagName.contains('if') ||
          tagName.contains('interface') ||
          tagName.contains('port') ||
          tagName.contains('sap')) {
        for (final found in _fromText(tagValue)) {
          out.add(found);
        }
      }
    }

    // 3. From the trigger description text
    final desc = (problem['description'] ?? '').toString();
    for (final found in _fromText(desc)) {
      out.add(found);
    }

    return out.toList()..sort();
  }

  static Iterable<String> _fromText(String text) sync* {
    final patterns = <RegExp>[
      RegExp(
        r'\b\d+/\d+/c\d+/\d+(?:\.\d{1,4})?(?::\d+)?\b',
        caseSensitive: false,
      ),
      RegExp(
        r'\b(?:gigabitethernet|ethernet|loopback|port-channel|po)\S*',
        caseSensitive: false,
      ),
      RegExp(r'\b(?:xe|ge|et)-\d+/\d+/\d+\b', caseSensitive: false),
    ];
    for (final p in patterns) {
      for (final m in p.allMatches(text)) {
        final s = _normalize(m.group(0) ?? '');
        if (s.isNotEmpty) yield s;
      }
    }
  }

  static String _normalize(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return '';
    s = s.replaceAll(RegExp(r'^\[|\]$'), '');
    s = s.replaceAll(RegExp(r'^[\s:;,\-]+|[\s:;,\-]+$'), '');
    final lower = s.toLowerCase();
    if (lower == 'interface' || lower == 'ifname' || lower == 'port') return '';
    if (!s.contains('/') &&
        !s.contains('.') &&
        !lower.startsWith('ethernet') &&
        !lower.startsWith('gigabitethernet') &&
        !lower.startsWith('loopback') &&
        !lower.startsWith('port-channel') &&
        !lower.startsWith('po') &&
        !RegExp(
          r'^(xe|ge|et)-\d+/\d+/\d+$',
          caseSensitive: false,
        ).hasMatch(s)) {
      return '';
    }
    return s;
  }
}

// ─────────────────────────────────────────────
// Data model
// ─────────────────────────────────────────────
class _ProblemHostEntry {
  final dynamic host;
  int problemCount;
  int maxSeverity;
  final List<dynamic> problemList;

  _ProblemHostEntry({
    required this.host,
    required this.problemCount,
    required this.maxSeverity,
    required this.problemList,
  });
}

// ─────────────────────────────────────────────
// Shared severity badge
// ─────────────────────────────────────────────
// ─── Design tokens ────────────────────────────────────────────────────────────
const _pBlue = ZbxPalette.rxBlue;
const _pGreen = ZbxPalette.txGreen;
const _pRed = ZbxPalette.downRed;
const _pAmb = ZbxPalette.warnAmb;
const _pDim = ZbxPalette.textMonoDark;

// ─── Severity helpers ─────────────────────────────────────────────────────────
Color _sevColor(int s) {
  switch (s) {
    case 5:
      return const Color(0xFFAB47BC);
    case 4:
      return _pRed;
    case 3:
      return _pAmb;
    case 2:
      return const Color(0xFFFFD54F);
    case 1:
      return _pBlue;
    default:
      return const Color(0xFF7A90B4);
  }
}

String _sevLabel(int s) {
  switch (s) {
    case 5:
      return 'DISASTER';
    case 4:
      return 'HIGH';
    case 3:
      return 'AVERAGE';
    case 2:
      return 'WARNING';
    case 1:
      return 'INFO';
    default:
      return 'N/C';
  }
}

String _timeAgo(dynamic problem) {
  final ts = int.tryParse((problem['lastchange'] ?? '').toString());
  if (ts == null || ts == 0) return '';
  final dur = DateTime.now().difference(
    DateTime.fromMillisecondsSinceEpoch(ts * 1000),
  );
  if (dur.inDays > 0) return '${dur.inDays}d ago';
  if (dur.inHours > 0) return '${dur.inHours}h ago';
  if (dur.inMinutes > 0) return '${dur.inMinutes}m ago';
  return 'just now';
}

class _SeverityBadge extends StatelessWidget {
  final int severity;
  final bool compact;
  const _SeverityBadge({required this.severity, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final color = _sevColor(severity);
    final label = _sevLabel(severity);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 7 : 10,
        vertical: compact ? 3 : 5,
      ),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        border: Border.all(color: color.withOpacity(0.45), width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: compact ? 5 : 6,
            height: compact ? 5 : 6,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(color: color.withOpacity(0.6), blurRadius: 4),
              ],
            ),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w800,
              fontSize: compact ? 9 : 10,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _InterfaceChip extends StatelessWidget {
  final String name;
  final VoidCallback onTap;
  const _InterfaceChip({required this.name, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: _pBlue.withOpacity(0.08),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: _pBlue.withOpacity(0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cable, size: 11, color: _pBlue),
            const SizedBox(width: 5),
            Text(
              name,
              style: const TextStyle(
                fontSize: 12,
                color: _pBlue,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// LEVEL 1 – Group summary cards
// ─────────────────────────────────────────────
class ProblemsScreen extends StatefulWidget {
  final String searchQuery;
  const ProblemsScreen({super.key, required this.searchQuery});

  @override
  State<ProblemsScreen> createState() => ProblemsScreenState();
}

class ProblemsScreenState extends State<ProblemsScreen> {
  List<dynamic> _problems = [];
  List<dynamic> _hosts = [];
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    // Data comes from the shared AppCache; subscribe for updates
    AppCache.instance.addListener(_onCacheUpdate);
    if (!AppCache.instance.isLoaded) AppCache.instance.load();
  }

  @override
  void dispose() {
    AppCache.instance.removeListener(_onCacheUpdate);
    super.dispose();
  }

  void _onCacheUpdate() {
    if (!mounted) return;
    setState(() {
      _problems = AppCache.instance.problems;
      _hosts    = AppCache.instance.hosts;
      _loading  = AppCache.instance.isLoading && _problems.isEmpty;
      _error    = AppCache.instance.loadError;
    });
  }

  void shareProblems() {
    if (_problems.isEmpty) {
      Share.share('No active problems — all monitored systems operating normally.');
      return;
    }
    final now = DateTime.now();
    final stamp =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final lines = _problems.map((p) {
      final sev = severityText(p['priority']?.toString() ?? '0');
      final desc = (p['description'] ?? '').toString().trim();
      return '[$sev] $desc';
    }).join('\n');
    Share.share('Active Problems — $stamp\n\n$lines\n\nTotal: ${_problems.length} alert${_problems.length == 1 ? '' : 's'}');
  }

  Map<String, dynamic> _hostById() {
    final out = <String, dynamic>{};
    for (final h in _hosts) {
      final id = h['hostid']?.toString();
      if (id != null && id.isNotEmpty) out[id] = h;
    }
    return out;
  }

  List<String> _hostGroups(dynamic host) {
    final raw = host['groups'] ?? host['hostgroups'];
    if (raw is List && raw.isNotEmpty) {
      final names = raw
          .map((g) => (g['name'] ?? '').toString().trim())
          .where((g) => g.isNotEmpty)
          .toList();
      if (names.isNotEmpty) return names;
    }
    return const [];
  }

  Map<String, List<dynamic>> _groupedProblems() {
    final hostMap = _hostById();
    final grouped = <String, List<dynamic>>{};
    final tokens = widget.searchQuery
        .toLowerCase()
        .trim()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();

    bool matches(String text) {
      if (tokens.isEmpty) return true;
      final hay = text.toLowerCase();
      for (final t in tokens) {
        if (!hay.contains(t)) return false;
      }
      return true;
    }

    for (final problem in _problems) {
      final triggerHosts = problem['hosts'];
      final groupsForProblem = <String>{};
      final sb = StringBuffer();
      sb.write((problem['description'] ?? '').toString());
      final tags = (problem['tags'] is List)
          ? (problem['tags'] as List)
          : const [];
      for (final t in tags) {
        sb.write(' ');
        sb.write((t['tag'] ?? '').toString());
        sb.write(' ');
        sb.write((t['value'] ?? '').toString());
      }
      final items = (problem['items'] is List)
          ? (problem['items'] as List)
          : const [];
      for (final it in items) {
        sb.write(' ');
        sb.write((it['name'] ?? '').toString());
        sb.write(' ');
        sb.write((it['key_'] ?? '').toString());
      }
      if (triggerHosts is List) {
        for (final h in triggerHosts) {
          final hostId = h['hostid']?.toString();
          final host = hostId != null ? hostMap[hostId] : null;
          if (host != null) {
            groupsForProblem.addAll(_hostGroups(host));
            sb.write(' ');
            sb.write((host['name'] ?? host['host'] ?? '').toString());
          }
        }
      }
      if (!matches(sb.toString())) continue;
      for (final group in groupsForProblem) {
        if (!matches(group)) continue;
        grouped.putIfAbsent(group, () => <dynamic>[]).add(problem);
      }
    }
    return grouped;
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: _pGreen.withOpacity(0.10),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: _pGreen.withOpacity(0.25)),
            ),
            child: Icon(Icons.check_circle_outline, size: 44, color: _pGreen),
          ),
          SizedBox(height: 18),
          Text(
            'No Active Problems',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: ZbxT.textPri(context),
            ),
          ),
          SizedBox(height: 6),
          Text(
            'All monitored systems operating normally.',
            style: TextStyle(fontSize: 13, color: ZbxT.textSec(context)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: _pBlue, strokeWidth: 2),
      );
    }

    final grouped = _groupedProblems();
    final groups = grouped.keys.toList()..sort();
    final groupCards = groups.map((group) {
      final groupProblems = grouped[group] ?? const <dynamic>[];
      final affectedHostIds = <String>{};
      var highest = 0;
      for (final p in groupProblems) {
        final sev = severityValue(p['priority']?.toString() ?? '0');
        if (sev > highest) highest = sev;
        final th = p['hosts'];
        if (th is List) {
          for (final h in th) {
            final id = h['hostid']?.toString();
            if (id != null && id.isNotEmpty) affectedHostIds.add(id);
          }
        }
      }
      return (
        group: group,
        problemCount: groupProblems.length,
        hostCount: affectedHostIds.length,
        highestSeverity: highest,
      );
    }).toList();

    return RefreshIndicator(
      onRefresh: AppCache.instance.refresh,
      color: _pBlue,
      backgroundColor: ZbxT.card(context),
      child: Column(
        children: [
          // Error banner
          if (_error.isNotEmpty)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: _pRed.withOpacity(0.10),
                border: Border.all(color: _pRed.withOpacity(0.35)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _error,
                style: const TextStyle(fontSize: 11, color: _pRed),
              ),
            ),
          Expanded(
            child: groups.isEmpty
                ? _buildEmptyState()
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final isWide = constraints.maxWidth >= 900;
                      final cardWidth = isWide
                          ? (constraints.maxWidth - 8) / 2
                          : constraints.maxWidth;
                      return ListView(
                        padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: Row(
                              children: [
                                Text(
                                  'ACTIVE ALERTS',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                    color: ZbxT.textSec(context),
                                    letterSpacing: 1.2,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Container(
                                    height: 1,
                                    color: ZbxT.rim(context),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: _pRed.withOpacity(0.12),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: _pRed.withOpacity(0.35),
                                    ),
                                  ),
                                  child: Text(
                                    '${_problems.length} alert${_problems.length == 1 ? '' : 's'}',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: _pRed,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (isWide)
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: groupCards
                                  .map(
                                    (item) => SizedBox(
                                      width: cardWidth,
                                      child: _GroupCard(
                                        groupName: item.group,
                                        problemCount: item.problemCount,
                                        hostCount: item.hostCount,
                                        highestSeverity: item.highestSeverity,
                                        onTap: () => Navigator.of(context).push(
                                          MaterialPageRoute(
                                            builder: (_) => GroupHostsScreen(
                                              groupName: item.group,
                                              allProblems: _problems,
                                              allHosts: _hosts,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  )
                                  .toList(),
                            )
                          else
                            ...groupCards.map(
                              (item) => _GroupCard(
                                groupName: item.group,
                                problemCount: item.problemCount,
                                hostCount: item.hostCount,
                                highestSeverity: item.highestSeverity,
                                onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => GroupHostsScreen(
                                      groupName: item.group,
                                      allProblems: _problems,
                                      allHosts: _hosts,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ─── Level 1 : Group card ──────────────────────────────────────────────────────
class _GroupCard extends StatelessWidget {
  final String groupName;
  final int problemCount;
  final int hostCount;
  final int highestSeverity;
  final VoidCallback onTap;

  const _GroupCard({
    required this.groupName,
    required this.problemCount,
    required this.hostCount,
    required this.highestSeverity,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = _sevColor(highestSeverity);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: ZbxT.card(context),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withOpacity(0.22)),
        ),
        child: Row(
          children: [
            // Severity strip
            Container(
              width: 4,
              height: 72,
              decoration: BoxDecoration(
                color: color,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(14),
                  bottomLeft: Radius.circular(14),
                ),
                boxShadow: [
                  BoxShadow(
                    color: color.withOpacity(0.4),
                    blurRadius: 8,
                    offset: const Offset(0, 0),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            // Icon
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: color.withOpacity(0.10),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(Icons.folder_outlined, size: 18, color: color),
            ),
            const SizedBox(width: 12),
            // Text
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      groupName,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        color: ZbxT.textPri(context),
                      ),
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          size: 11,
                          color: color.withOpacity(0.8),
                        ),
                        SizedBox(width: 4),
                        Text(
                          '$problemCount alert${problemCount == 1 ? '' : 's'}',
                          style: TextStyle(
                            fontSize: 11,
                            color: color,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        SizedBox(width: 8),
                        Icon(
                          Icons.router_outlined,
                          size: 11,
                          color: ZbxT.textSec(context),
                        ),
                        SizedBox(width: 4),
                        Text(
                          '$hostCount host${hostCount == 1 ? '' : 's'}',
                          style: TextStyle(
                            fontSize: 11,
                            color: ZbxT.textSec(context),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            _SeverityBadge(severity: highestSeverity),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, color: _pDim, size: 18),
            const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// LEVEL 2 – Host cards for a group (replaces ExpansionTile)
// ─────────────────────────────────────────────
class GroupHostsScreen extends StatefulWidget {
  final String groupName;
  final List<dynamic> allProblems;
  final List<dynamic> allHosts;

  const GroupHostsScreen({
    super.key,
    required this.groupName,
    required this.allProblems,
    required this.allHosts,
  });

  @override
  State<GroupHostsScreen> createState() => _GroupHostsScreenState();
}

class _ProblemsSessionFilters {
  static String severity = 'All';
  static String host = 'All';
  static bool showFilters = false;
}

class _GroupHostsScreenState extends State<GroupHostsScreen> {
  String _severityFilter = _ProblemsSessionFilters.severity;
  String _hostFilter = _ProblemsSessionFilters.host;
  bool _showFilters = _ProblemsSessionFilters.showFilters;

  static const _severities = [
    'All',
    'Disaster',
    'High',
    'Average',
    'Warning',
    'Information',
    'Not classified',
  ];

  @override
  void initState() {
    super.initState();
    // Ensure selected host filter is valid for this group; otherwise fallback.
    final hostNames = _hostNames();
    if (!hostNames.contains(_hostFilter)) {
      _hostFilter = 'All';
      _ProblemsSessionFilters.host = 'All';
    }
  }

  Map<String, dynamic> _hostById() {
    final out = <String, dynamic>{};
    for (final h in widget.allHosts) {
      final id = h['hostid']?.toString();
      if (id != null && id.isNotEmpty) out[id] = h;
    }
    return out;
  }

  List<String> _hostGroups(dynamic host) {
    final raw = host['groups'] ?? host['hostgroups'];
    if (raw is List) {
      return raw
          .map((g) => (g['name'] ?? '').toString().trim())
          .where((g) => g.isNotEmpty)
          .toList();
    }
    return const [];
  }

  List<_ProblemHostEntry> _computeEntries() {
    final hostMap = _hostById();
    final byHost = <String, _ProblemHostEntry>{};

    for (final problem in widget.allProblems) {
      final sev = severityValue(problem['priority']?.toString() ?? '0');
      final triggerHosts = problem['hosts'];
      if (triggerHosts is! List) continue;
      for (final h in triggerHosts) {
        final hostId = h['hostid']?.toString();
        if (hostId == null || hostId.isEmpty) continue;
        final host = hostMap[hostId];
        if (host == null) continue;
        if (!_hostGroups(host).contains(widget.groupName)) continue;
        final hostName = (host['name'] ?? host['host'] ?? '').toString();
        if (_hostFilter != 'All' && _hostFilter != hostName) continue;

        final entry = byHost[hostId];
        if (entry == null) {
          byHost[hostId] = _ProblemHostEntry(
            host: host,
            problemCount: 1,
            maxSeverity: sev,
            problemList: [problem],
          );
        } else {
          entry.problemCount++;
          if (sev > entry.maxSeverity) entry.maxSeverity = sev;
          entry.problemList.add(problem);
        }
      }
    }

    var list = byHost.values.toList();
    if (_severityFilter != 'All') {
      final req = severityValue(severityCodeFromLabel(_severityFilter));
      list = list.where((e) => e.maxSeverity == req).toList();
    }
    list.sort((a, b) => b.maxSeverity.compareTo(a.maxSeverity));
    return list;
  }

  Set<String> _hostNames() {
    final hostMap = _hostById();
    final out = <String>{'All'};
    for (final problem in widget.allProblems) {
      final th = problem['hosts'];
      if (th is! List) continue;
      for (final h in th) {
        final hostId = h['hostid']?.toString();
        if (hostId == null) continue;
        final host = hostMap[hostId];
        if (host == null) continue;
        if (!_hostGroups(host).contains(widget.groupName)) continue;
        final n = (host['name'] ?? host['host'] ?? '').toString().trim();
        if (n.isNotEmpty) out.add(n);
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final entries = _computeEntries();

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.groupName,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        actions: [
          IconButton(
            icon: Icon(
              _showFilters ? Icons.filter_list_off : Icons.filter_list,
            ),
            onPressed: () => setState(() {
              _showFilters = !_showFilters;
              _ProblemsSessionFilters.showFilters = _showFilters;
            }),
            tooltip: 'Filters',
          ),
        ],
      ),
      body: Column(
        children: [
          if (_showFilters) _buildFilterBar(),
          Expanded(
            child: entries.isEmpty
                ? Center(
                    child: Text(
                      _severityFilter != 'All' || _hostFilter != 'All'
                          ? 'No hosts match current filters'
                          : 'No affected hosts',
                      style: TextStyle(color: ZbxT.textSec(context)),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
                    itemCount: entries.length + 1,
                    itemBuilder: (ctx, i) {
                      if (i == 0) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Text(
                            '${entries.length} affected host${entries.length == 1 ? '' : 's'}',
                            style: TextStyle(
                              fontSize: 13,
                              color: ZbxT.textSec(context),
                            ),
                          ),
                        );
                      }
                      final entry = entries[i - 1];
                      final name =
                          (entry.host['name'] ??
                                  entry.host['host'] ??
                                  'Unknown')
                              .toString();
                      final ip = extractIp(entry.host);
                      return _HostProblemCard(
                        hostName: name,
                        hostIp: ip,
                        problemCount: entry.problemCount,
                        maxSeverity: entry.maxSeverity,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => HostProblemsScreen(
                              host: entry.host,
                              problems: entry.problemList,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    final hostNames = _hostNames().toList()..sort();
    return Container(
      color: const Color(0xFF0A1B3A),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        children: [
          Row(
            children: [
              SizedBox(
                width: 80,
                child: Text(
                  'SEVERITY',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: ZbxT.textSec(context),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _severityFilter,
                  isDense: true,
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    border: OutlineInputBorder(),
                  ),
                  items: _severities
                      .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                      .toList(),
                  onChanged: (v) => setState(() {
                    _severityFilter = v ?? 'All';
                    _ProblemsSessionFilters.severity = _severityFilter;
                  }),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              SizedBox(
                width: 80,
                child: Text(
                  'HOST',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: ZbxT.textSec(context),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _hostFilter,
                  isDense: true,
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    border: OutlineInputBorder(),
                  ),
                  items: hostNames
                      .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                      .toList(),
                  onChanged: (v) => setState(() {
                    _hostFilter = v ?? 'All';
                    _ProblemsSessionFilters.host = _hostFilter;
                  }),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Level 2 : Host card ───────────────────────────────────────────────────────
class _HostProblemCard extends StatelessWidget {
  final String hostName;
  final String hostIp;
  final int problemCount;
  final int maxSeverity;
  final VoidCallback onTap;

  const _HostProblemCard({
    required this.hostName,
    required this.hostIp,
    required this.problemCount,
    required this.maxSeverity,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = _sevColor(maxSeverity);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: ZbxT.card(context),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withOpacity(0.20)),
        ),
        child: Row(
          children: [
            // Severity strip
            Container(
              width: 4,
              height: 84,
              decoration: BoxDecoration(
                color: color,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(14),
                  bottomLeft: Radius.circular(14),
                ),
                boxShadow: [
                  BoxShadow(color: color.withOpacity(0.35), blurRadius: 8),
                ],
              ),
            ),
            const SizedBox(width: 14),
            // Router icon
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: _pBlue.withOpacity(0.08),
                borderRadius: BorderRadius.circular(9),
              ),
              child: const Icon(Icons.dns_outlined, size: 17, color: _pBlue),
            ),
            const SizedBox(width: 12),
            // Text
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 13),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hostName,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        color: ZbxT.textPri(context),
                      ),
                    ),
                    SizedBox(height: 3),
                    Text(
                      hostIp,
                      style: TextStyle(
                        fontSize: 11,
                        color: ZbxT.textSec(context),
                        fontFamily: 'monospace',
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Container(
                          width: 5,
                          height: 5,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: color.withOpacity(0.6),
                                blurRadius: 4,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '$problemCount active alert${problemCount == 1 ? '' : 's'}',
                          style: TextStyle(
                            fontSize: 11,
                            color: color,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _SeverityBadge(severity: maxSeverity),
                const SizedBox(height: 6),
                const Icon(Icons.chevron_right, color: _pDim, size: 18),
              ],
            ),
            const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// LEVEL 3 – Problem cards for a host  (NEW)
// ─────────────────────────────────────────────
class HostProblemsScreen extends StatelessWidget {
  final dynamic host;
  final List<dynamic> problems;

  const HostProblemsScreen({
    super.key,
    required this.host,
    required this.problems,
  });

  @override
  Widget build(BuildContext context) {
    final hostName = (host['name'] ?? host['host'] ?? 'Unknown').toString();
    final hostId = (host['hostid'] ?? '').toString();
    final hostIp = extractIp(host);

    final sorted = [...problems]
      ..sort(
        (a, b) => severityValue(
          b['priority']?.toString() ?? '0',
        ).compareTo(severityValue(a['priority']?.toString() ?? '0')),
      );

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              hostName,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            Text(
              hostIp,
              style: TextStyle(fontSize: 12, color: ZbxT.textSec(context)),
            ),
          ],
        ),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
        itemCount: sorted.length + 1,
        itemBuilder: (ctx, i) {
          if (i == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                '${sorted.length} active problem${sorted.length == 1 ? '' : 's'}',
                style: TextStyle(fontSize: 13, color: ZbxT.textSec(context)),
              ),
            );
          }
          final problem = sorted[i - 1];
          // Interfaces specifically mentioned by THIS problem
          final interfaces = _IfExtractor.fromProblem(problem);
          return _ProblemCard(
            problem: problem,
            interfaces: interfaces,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ProblemDetailScreen(
                  hostId: hostId,
                  hostIp: hostIp,
                  hostName: hostName,
                  problems: sorted,
                  initialIndex: i - 1,
                ),
              ),
            ),
            onInterfaceTap: (ifName) => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => InterfaceDashboardScreen(
                  hostId: hostId,
                  hostName: hostName,
                  hostIp: hostIp,
                  // Pass the exact interface extracted from this problem
                  interfaceName: ifName,
                  // interfaceOrder = only the interfaces for this problem,
                  // so left/right swipe stays within this problem's scope
                  interfaceOrder: interfaces,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ─── Level 3 : Problem card ────────────────────────────────────────────────────
class _ProblemCard extends StatelessWidget {
  final dynamic problem;
  final List<String> interfaces;
  final VoidCallback onTap;
  final ValueChanged<String> onInterfaceTap;

  const _ProblemCard({
    required this.problem,
    required this.interfaces,
    required this.onTap,
    required this.onInterfaceTap,
  });

  @override
  Widget build(BuildContext context) {
    final desc = (problem['description'] ?? 'No description').toString();
    final sev = (problem['priority'] ?? '0').toString();
    final sevInt = severityValue(sev);
    final color = _sevColor(sevInt);
    final ago = _timeAgo(problem);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: ZbxT.card(context),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withOpacity(0.18)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 4,
              decoration: BoxDecoration(
                color: color,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(14),
                  bottomLeft: Radius.circular(14),
                ),
                boxShadow: [
                  BoxShadow(color: color.withOpacity(0.4), blurRadius: 8),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _SeverityBadge(severity: sevInt, compact: true),
                        const Spacer(),
                        if (ago.isNotEmpty) ...[
                          const Icon(Icons.access_time, size: 10, color: _pDim),
                          const SizedBox(width: 3),
                          Text(
                            ago,
                            style: const TextStyle(fontSize: 10, color: _pDim),
                          ),
                        ],
                        SizedBox(width: 6),
                        Icon(Icons.chevron_right, size: 15, color: _pDim),
                      ],
                    ),
                    SizedBox(height: 8),
                    Text(
                      desc,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: ZbxT.textPri(context),
                        height: 1.4,
                      ),
                    ),
                    if (interfaces.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Container(
                            width: 2,
                            height: 10,
                            margin: const EdgeInsets.only(right: 6),
                            decoration: BoxDecoration(
                              color: _pBlue.withOpacity(0.5),
                              borderRadius: BorderRadius.circular(1),
                            ),
                          ),
                          Text(
                            'INTERFACES',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              color: ZbxT.textSec(context),
                              letterSpacing: 1.0,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: interfaces
                            .map(
                              (ifName) => _InterfaceChip(
                                name: ifName,
                                onTap: () => onInterfaceTap(ifName),
                              ),
                            )
                            .toList(),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// LEVEL 4 – Problem detail (page-view swipe)
// ─────────────────────────────────────────────
class ProblemDetailScreen extends StatefulWidget {
  final String hostId;
  final String hostIp;
  final String hostName;
  final List<dynamic> problems;
  final int initialIndex;

  const ProblemDetailScreen({
    super.key,
    required this.hostId,
    required this.hostIp,
    required this.hostName,
    required this.problems,
    required this.initialIndex,
  });

  @override
  State<ProblemDetailScreen> createState() => _ProblemDetailScreenState();
}

class _ProblemDetailScreenState extends State<ProblemDetailScreen> {
  late final PageController _controller;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _controller = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.hostName,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            Text(
              'Problem ${_index + 1} of ${widget.problems.length}',
              style: const TextStyle(fontSize: 12, color: Colors.white60),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          // Page indicator dots
          if (widget.problems.length > 1)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(widget.problems.length, (i) {
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: i == _index ? 18 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(3),
                      color: i == _index
                          ? severityColor(
                              (widget.problems[_index]['priority'] ?? '0')
                                  .toString(),
                            )
                          : Colors.white24,
                    ),
                  );
                }),
              ),
            ),
          Expanded(
            child: PageView.builder(
              controller: _controller,
              itemCount: widget.problems.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (_, i) => _buildProblemPage(i),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProblemPage(int i) {
    final problem = widget.problems[i];
    final desc = (problem['description'] ?? 'No description').toString();
    final sev = (problem['priority'] ?? '0').toString();
    final interfaces = _IfExtractor.fromProblem(problem);
    final tags = (problem['tags'] is List)
        ? (problem['tags'] as List)
        : const [];
    final opItems = (problem['items'] is List)
        ? (problem['items'] as List)
        : const [];
    final lastChange = problem['lastchange']?.toString() ?? '';
    final ts = int.tryParse(lastChange);
    final timeStr = ts != null && ts > 0
        ? DateTime.fromMillisecondsSinceEpoch(
            ts * 1000,
          ).toLocal().toString().substring(0, 16)
        : '';

    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        Row(
          children: [
            _SeverityBadge(severity: severityValue(sev)),
            const Spacer(),
            if (timeStr.isNotEmpty)
              Text(
                timeStr,
                style: TextStyle(fontSize: 11, color: ZbxT.textSec(context)),
              ),
          ],
        ),
        SizedBox(height: 12),
        Text(desc, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        SizedBox(height: 8),
        Text(
          'Host: ${widget.hostName}',
          style: TextStyle(fontSize: 13, color: Colors.white70),
        ),
        Text(
          'IP: ${widget.hostIp}',
          style: TextStyle(fontSize: 13, color: ZbxT.textSec(context)),
        ),

        // Interfaces as chips — pass ONLY this problem's interfaces
        // so the InterfaceDashboard filters items for exactly that interface
        if (interfaces.isNotEmpty) ...[
          SizedBox(height: 18),
          Text(
            'INTERFACES',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: ZbxT.textSec(context),
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: interfaces
                .map(
                  (ifName) => _InterfaceChip(
                    name: ifName,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => InterfaceDashboardScreen(
                          hostId: widget.hostId,
                          hostName: widget.hostName,
                          hostIp: widget.hostIp,
                          interfaceName: ifName,
                          // Only this problem's interfaces for swipe
                          interfaceOrder: interfaces,
                        ),
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ],

        // Tags
        if (tags.isNotEmpty) ...[
          SizedBox(height: 18),
          Divider(color: ZbxT.rim(context)),
          SizedBox(height: 8),
          Text(
            'TAGS',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: ZbxT.textSec(context),
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: tags.map<Widget>((t) {
              final k = (t['tag'] ?? '').toString().trim();
              final v = (t['value'] ?? '').toString().trim();
              if (k.isEmpty && v.isEmpty) return const SizedBox.shrink();
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: ZbxT.lift(context),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: ZbxT.rim(context), width: 1),
                ),
                child: RichText(
                  text: TextSpan(
                    style: DefaultTextStyle.of(context).style,
                    children: [
                      TextSpan(
                        text: k.isNotEmpty ? '$k: ' : '',
                        style: TextStyle(
                          fontSize: 12,
                          color: ZbxT.textSec(context),
                        ),
                      ),
                      TextSpan(
                        text: v,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: ZbxT.textPri(context),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ],

        // Attached item values from the trigger
        if (opItems.isNotEmpty) ...[
          SizedBox(height: 18),
          Divider(color: ZbxT.rim(context)),
          SizedBox(height: 8),
          Text(
            'ITEM VALUES',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: ZbxT.textSec(context),
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 8),
          ...opItems.map<Widget>((it) {
            final n = (it['name'] ?? '').toString().trim();
            final v = (it['lastvalue'] ?? '').toString();
            final u = (it['units'] ?? '').toString();
            if (n.isEmpty || v.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      n,
                      style: TextStyle(fontSize: 13, color: Colors.white60),
                    ),
                  ),
                  Text(
                    u.isEmpty ? v : '$v $u',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: ZbxT.textPri(context),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ],
    );
  }
}
