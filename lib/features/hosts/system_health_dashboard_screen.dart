import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/zbx_theme.dart';

class SystemHealthDashboardScreen extends StatefulWidget {
  final String hostId;
  final String hostName;
  final String hostIp;
  final Map<String, String> ruleByKeyBase;
  final List<dynamic>? preloadedItems;
  final Color accentColor;

  const SystemHealthDashboardScreen({
    super.key,
    required this.hostId,
    required this.hostName,
    required this.hostIp,
    this.ruleByKeyBase = const <String, String>{},
    this.preloadedItems,
    this.accentColor = const Color(0xFF00ABA9),
  });

  @override
  State<SystemHealthDashboardScreen> createState() =>
      _SystemHealthDashboardScreenState();
}

class _SystemHealthDashboardScreenState
    extends State<SystemHealthDashboardScreen> {
  static const _systemRules = {
    'BNG Chassis Component Discovery',
    'BNG CPU Process Discovery',
    'BNG Health Discovery',
    'BNG Subscriber Management',
    'BNG Memory Pool Discovery',
  };

  static const _cpuMemRules = {
    'BNG CPU Process Discovery',
    'BNG Memory Pool Discovery',
  };

  static const _sectionByBaseKey = {
    'bng.chassis.fan_speed': 'BNG Chassis Component Discovery',
    'bng.chassis.fan_state': 'BNG Chassis Component Discovery',
    'bng.chassis.psu_v1': 'BNG Chassis Component Discovery',
    'bng.chassis.psu_v2': 'BNG Chassis Component Discovery',
    'bng.mem.in_use': 'BNG Health Discovery',
    'bng.mem.total': 'BNG Health Discovery',
    'bng.mem.available': 'BNG Health Discovery',
    'bng.mem.total_utilization': 'BNG Health Discovery',
    'bng.cpu.usage': 'BNG Health Discovery',
    'bng.cpu.busiest_core': 'BNG Health Discovery',
    'bng.cpu.idle': 'BNG Health Discovery',
    'bng.chassis.ccm_temp': 'BNG Health Discovery',
    'bng.chassis.over_temp': 'BNG Health Discovery',
    'bng.sub.current': 'BNG Subscriber Management',
    'bng.sub.peak': 'BNG Subscriber Management',
    'bng.cpu.proc': 'CPU & Memory',
    'bng.cpu.proc_capacity': 'CPU & Memory',
    'bng.mem.pool.in_use': 'CPU & Memory',
  };

  final Map<String, bool> _sectionExpanded = {};

  List<dynamic> _items = const <dynamic>[];
  bool _loading = true;
  String _error = '';

  Color get _accent => widget.accentColor;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = '';
      });
    }

    try {
      final items = widget.preloadedItems ?? await ApiClient.fetchItems(widget.hostId);
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
        _error = '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Load failed: $e';
      });
    }
  }

  String _baseKey(String key) {
    final lower = key.toLowerCase().trim();
    final idx = lower.indexOf('[');
    return idx > 0 ? lower.substring(0, idx) : lower;
  }

  String _ruleLabelForBase(String base) {
    final mapped = widget.ruleByKeyBase[base]?.trim();
    if (mapped != null && mapped.isNotEmpty) {
      return _cpuMemRules.contains(mapped) ? 'CPU & Memory' : mapped;
    }
    return _sectionByBaseKey[base] ?? '';
  }

  Map<String, List<dynamic>> get _sections {
    final sections = <String, List<dynamic>>{};
    for (final item in _items) {
      final key = (item['key_'] ?? item['key'] ?? '').toString();
      final base = _baseKey(key);
      final ruleName = _ruleLabelForBase(base);
      if (ruleName.isEmpty) continue;
      if (!_systemRules.contains(ruleName) &&
          ruleName != 'CPU & Memory' &&
          ruleName != 'BNG Subscriber Management') {
        continue;
      }
      sections.putIfAbsent(ruleName, () => <dynamic>[]).add(item);
    }
    return sections;
  }

  List<String> get _sectionNames => _sections.keys
      .where((s) => s != 'CPU & Memory' && s != 'BNG Subscriber Management')
      .toList();

  String _displayVal(dynamic item) {
    final val = (item['lastvalue'] ?? '-').toString();
    final units = (item['units'] ?? '').toString();
    return units.isNotEmpty ? '$val $units' : val;
  }

  String _fmtBytes(num v) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var d = v.toDouble();
    var i = 0;
    while (d >= 1024 && i < units.length - 1) {
      d /= 1024;
      i++;
    }
    final fixed = d >= 100 ? 0 : d >= 10 ? 1 : 2;
    return '${d.toStringAsFixed(fixed)} ${units[i]}';
  }

  String _bytesDisplay(dynamic item) {
    final raw = (item['lastvalue'] ?? '').toString().replaceAll(',', '').trim();
    final n = double.tryParse(raw);
    if (n == null) return _displayVal(item);
    return _fmtBytes(n);
  }

  String _secondArg(String key) {
    final l = key.indexOf('[');
    if (l < 0) return '';
    final r = key.indexOf(']', l + 1);
    if (r <= l + 1) return '';
    final inside = key.substring(l + 1, r);
    final parts = inside.split(',');
    if (parts.length >= 2) return parts[1].trim();
    return parts[0].trim();
  }

  String _fmtSubKey(String raw) => raw.replaceAll('_', ' ').toUpperCase();

  Widget _buildLoader() {
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: _accent,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'Loading system health...',
            style: TextStyle(color: _accent, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildError() {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          _error,
          style: TextStyle(color: ZbxPalette.downRed),
        ),
      ],
    );
  }

  Widget _cpuMemTable(List<dynamic> itemsIn) {
    final rows = <String, Map<String, String>>{};
    for (final item in itemsIn) {
      final key = (item['key_'] ?? item['key'] ?? '').toString();
      final base = _baseKey(key);
      final row = _secondArg(key);
      if (row.isEmpty) continue;
      rows.putIfAbsent(row, () => <String, String>{});
      if (base == 'bng.cpu.proc') {
        rows[row]!['cpu'] = _displayVal(item);
      } else if (base == 'bng.cpu.proc_capacity') {
        rows[row]!['cap'] = _displayVal(item);
      } else if (base == 'bng.mem.pool.in_use') {
        rows[row]!['mem'] = _bytesDisplay(item);
      }
    }

    final keys = rows.keys.toList()..sort();
    if (keys.isEmpty) {
      return Text(
        'No CPU/Memory items',
        style: TextStyle(fontSize: 10, color: ZbxT.textSec(context)),
      );
    }

    return Container(
      padding: const EdgeInsets.all(8),
      color: ZbxT.card(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                flex: 3,
                child: Text(
                  'Process',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: _accent),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  'CPU Utilization',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: _accent),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  'Capacity Utilization',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: _accent),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  'Memory In-Use',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: _accent),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ...keys.map((k) {
            final row = rows[k]!;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Text(
                      k,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10, color: ZbxT.textPri(context)),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      row['cpu'] ?? '-',
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: _accent),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      row['cap'] ?? '-',
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: _accent),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      row['mem'] ?? '-',
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: _accent),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _twoColGrid(List<Widget> cards) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 2.0;
        final width = (constraints.maxWidth - gap) / 2;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: cards.map((card) => SizedBox(width: width, child: card)).toList(),
        );
      },
    );
  }

  Widget _subscriberTable(List<dynamic> itemsIn) {
    final current = <String, String>{};
    final peak = <String, String>{};
    final rows = <String, Map<String, String>>{};

    for (final item in itemsIn) {
      final key = (item['key_'] ?? item['key'] ?? '').toString();
      final base = _baseKey(key);
      if (base != 'bng.sub.current' && base != 'bng.sub.peak') continue;
      final rowRaw = _secondArg(key);
      if (rowRaw.isEmpty) continue;
      rows.putIfAbsent(rowRaw, () => <String, String>{});
      if (base == 'bng.sub.current') {
        final row = _fmtSubKey(rowRaw);
        if (row.isNotEmpty) current[row] = _displayVal(item);
        rows[rowRaw]!['current'] = _displayVal(item);
      } else {
        final row = _fmtSubKey(rowRaw);
        if (row.isNotEmpty) peak[row] = _displayVal(item);
        rows[rowRaw]!['peak'] = _displayVal(item);
      }
    }

    final keys = rows.keys.toList()..sort();
    final setupKey = 'PFCP SESSIONS IN SETUP';
    final totalKey = 'TOTAL PFCP SESSIONS PPP';
    final setupVal = current[setupKey] ?? peak[setupKey] ?? '-';
    final totalVal = current[totalKey] ?? peak[totalKey] ?? '-';

    Widget metricCard(String label, String value, String desc) {
      return Container(
        padding: const EdgeInsets.all(12),
        color: _accent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(fontSize: 9, color: Colors.white.withValues(alpha: 0.8), letterSpacing: 0.4),
            ),
            const SizedBox(height: 6),
            Text(
              value,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Colors.white, height: 1),
            ),
            const SizedBox(height: 4),
            Text(
              desc,
              style: TextStyle(fontSize: 9, color: Colors.white.withValues(alpha: 0.7)),
            ),
          ],
        ),
      );
    }

    if (keys.isEmpty) {
      return Text(
        'No Subscriber items',
        style: TextStyle(fontSize: 10, color: ZbxT.textSec(context)),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _twoColGrid([
          metricCard('PFCP SESSIONS IN SETUP', setupVal, 'Indicating connecting subscribers'),
          metricCard('TOTAL PFCP SESSIONS PPP', totalVal, 'Indicating connected subscribers'),
        ]),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(8),
          color: ZbxT.card(context),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Text(
                      'Name',
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: _accent),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      'Current',
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: _accent),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      'Peak',
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: _accent),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ...keys.map((k) {
                final row = rows[k]!;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: Text(
                          _fmtSubKey(k),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 10, color: ZbxT.textPri(context)),
                        ),
                      ),
                      Expanded(
                        flex: 2,
                        child: Text(
                          row['current'] ?? '-',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: _accent),
                        ),
                      ),
                      Expanded(
                        flex: 2,
                        child: Text(
                          row['peak'] ?? '-',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: _accent),
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
      ],
    );
  }

  String _sectionKey(String section) => 'bng:${widget.hostId}:$section';

  Widget _collapseSection({
    required String title,
    required Widget child,
    Widget? headerChild,
  }) {
    final key = _sectionKey(title);
    final expanded = _sectionExpanded[key] == true;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      color: ZbxT.card(context),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _sectionExpanded[key] = !expanded),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: _accent, width: 3)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: headerChild ??
                        Text(
                          title,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            color: ZbxT.textPri(context),
                            letterSpacing: 0.2,
                          ),
                        ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(2),
                    color: _accent,
                    child: Icon(expanded ? Icons.remove : Icons.add, size: 14, color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: child,
            ),
        ],
      ),
    );
  }

  Widget _buildSimpleSection(String title, List<dynamic> items) {
    return Container(
      color: ZbxT.card(context),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: _accent,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 8),
          ...items.map((item) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        (item['name'] ?? item['key_'] ?? 'Item').toString(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: ZbxT.textPri(context),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _displayVal(item),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: _accent,
                      ),
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final sections = _sections;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 40),
      children: [
        Container(
          color: ZbxT.card(context),
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(width: 4, height: 42, color: _accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.hostName,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: ZbxT.textPri(context),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.hostIp.isEmpty ? 'System Health Dashboard' : widget.hostIp,
                      style: TextStyle(
                        fontSize: 10,
                        color: ZbxT.textSec(context),
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.monitor_heart_outlined, color: _accent),
            ],
          ),
        ),
        const SizedBox(height: 10),
        if (_sectionNames.isEmpty &&
            !sections.containsKey('BNG Subscriber Management') &&
            !sections.containsKey('CPU & Memory'))
          Text(
            'No System Health items',
            style: TextStyle(fontSize: 10, color: ZbxT.textSec(context)),
          )
        else ...[
          ..._sectionNames.map((section) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _buildSimpleSection(
                  section,
                  sections[section] ?? const <dynamic>[],
                ),
              )),
          if (sections.containsKey('BNG Subscriber Management'))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _collapseSection(
                title: 'Subscriber Management',
                child: _subscriberTable(
                  sections['BNG Subscriber Management'] ?? const <dynamic>[],
                ),
              ),
            ),
          if (sections.containsKey('CPU & Memory'))
            _collapseSection(
              title: 'CPU & Memory',
              child: _cpuMemTable(
                sections['CPU & Memory'] ?? const <dynamic>[],
              ),
            ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: ZbxT.card(context),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back_ios_new_rounded,
            size: 18,
            color: _accent,
          ),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'System Health',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: ZbxT.textPri(context),
              ),
            ),
            Text(
              widget.hostName,
              style: TextStyle(
                fontSize: 10,
                color: ZbxT.textSec(context),
              ),
            ),
          ],
        ),
      ),
      body: _loading
          ? _buildLoader()
          : RefreshIndicator(
              onRefresh: _load,
              color: _accent,
              backgroundColor: ZbxT.card(context),
              child: _error.isNotEmpty ? _buildError() : _buildBody(),
            ),
    );
  }
}
