import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/app_cache.dart';
import '../../core/utils.dart';
import '../../core/zbx_theme.dart';
import '../graph/interactive_line_graph.dart';
import 'interface_dashboard_screen.dart';

// ── Theme helper via ZbxT (see zbx_theme.dart) ────────────────────────────────

const _rxBlue = ZbxPalette.rxBlue;
const _txGreen = ZbxPalette.txGreen;

class HostsScreen extends StatefulWidget {
  final String pushStatus;
  final String searchQuery;
  final String? initialGroupId;
  final String? initialGroupName;
  final VoidCallback? onExit; // called when user backs out of the top level

  const HostsScreen({
    super.key,
    required this.pushStatus,
    required this.searchQuery,
    this.initialGroupId,
    this.initialGroupName,
    this.onExit,
  });

  @override
  State<HostsScreen> createState() => _HostsScreenState();
}

class _HostsScreenState extends State<HostsScreen> {
  List<dynamic> hostGroups = [];
  List<dynamic> hosts = [];
  List<dynamic> currentItems = [];
  Map<String, List<dynamic>> entityToItems = {};
  final Set<String> selectedItemIds = <String>{};
  final Map<String, List<dynamic>> _hostItemsCache = <String, List<dynamic>>{};
  final Map<String, Map<String, List<dynamic>>> _hostEntityCache =
      <String, Map<String, List<dynamic>>>{};
  final Map<String, String> _hostMetaBlobById = <String, String>{};
  final Map<String, Map<String, Set<String>>> _hostTagMetaById =
      <String, Map<String, Set<String>>>{};
  final Map<String, TextEditingController> _sharedFromCtrls =
      <String, TextEditingController>{};
  final Map<String, TextEditingController> _sharedToCtrls =
      <String, TextEditingController>{};

  String? selectedGroupId;
  String? selectedGroupName;
  dynamic selectedHost;

  bool loading = true;
  bool loadingItems = false;
  String error = '';
  String _ifSearch = '';
  bool _showHostFilters = false;
  final Map<String, String> _hostTagFilters = <String, String>{};
  bool _warmingHostMeta = false;
  int _hostLoadSeq = 0;
  int _hostMetaSeq = 0;

  @override
  void initState() {
    super.initState();
    // Use cached data from AppCache first, refresh in background
    _loadGroupsFromCache();
    // Refresh driven by AppCache.startAutoRefresh() in main.dart
    // If navigated from dashboard with a specific group, jump to it
    if (widget.initialGroupId != null &&
        widget.initialGroupId!.isNotEmpty &&
        widget.initialGroupName != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _loadHostsForGroup(widget.initialGroupId!, widget.initialGroupName!);
        }
      });
    }
  }

  void _loadGroupsFromCache() {
    if (!mounted) return;
    final cache = AppCache.instance;
    if (cache.hostGroups.isNotEmpty) {
      setState(() {
        hostGroups = cache.hostGroups;
        loading = false;
        error = cache.loadError;
      });
      unawaited(_warmLocalMetadataForKnownHosts());
    }
    // Refresh cache in background
    if (!cache.isLoading) {
      cache
          .refresh()
          .then((_) {
            if (!mounted) return;
            setState(() {
              hostGroups = AppCache.instance.hostGroups;
              loading = false;
              error = AppCache.instance.loadError;
            });
            unawaited(_warmLocalMetadataForKnownHosts());
          })
          .catchError((_) {});
    }
  }

  Future<void> _loadGroups() async {
    try {
      final g = await ApiClient.fetchHostGroups();
      if (!mounted) return;
      setState(() {
        hostGroups = g;
        loading = false;
        error = '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = 'Failed: $e';
      });
    }
  }

  @override
  void dispose() {
    for (final c in _sharedFromCtrls.values) {
      c.dispose();
    }
    for (final c in _sharedToCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> _searchTokens() {
    final q = widget.searchQuery.toLowerCase().trim();
    if (q.isEmpty) return const <String>[];
    return q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
  }

  bool _matchesSearch(String text) {
    final tokens = _searchTokens();
    if (tokens.isEmpty) return true;
    final hay = text.toLowerCase();
    for (final t in tokens) {
      if (!hay.contains(t)) return false;
    }
    return true;
  }

  List<String> _hostGroupsOf(dynamic host) {
    final raw = host['hostgroups'] ?? host['groups'];
    if (raw is! List) return const <String>[];
    return raw
        .map((g) => (g['name'] ?? '').toString().trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  String _itemTagsText(dynamic item) {
    final tags = (item['tags'] is List) ? (item['tags'] as List) : const [];
    if (tags.isEmpty) return '';
    return tags
        .map(
          (t) =>
              '${(t['tag'] ?? '').toString()} ${(t['value'] ?? '').toString()}',
        )
        .join(' ');
  }

  void _indexHostMetadata(String hostId, List<dynamic> items) {
    final normalized = <String, Set<String>>{};
    final sb = StringBuffer();
    for (final i in items) {
      final name = (i['name'] ?? '').toString();
      final key = (i['key_'] ?? '').toString();
      final tags = (i['tags'] is List) ? (i['tags'] as List) : const [];
      if (name.isNotEmpty) {
        sb.write(' ');
        sb.write(name);
      }
      if (key.isNotEmpty) {
        sb.write(' ');
        sb.write(key);
      }
      for (final t in tags) {
        final tagName = (t['tag'] ?? '').toString().trim();
        final tagValue = (t['value'] ?? '').toString().trim();
        if (tagName.isEmpty || tagValue.isEmpty) continue;
        sb.write(' ');
        sb.write(tagName);
        sb.write(' ');
        sb.write(tagValue);
        normalized.putIfAbsent(tagName, () => <String>{}).add(tagValue);
      }
    }
    _hostMetaBlobById[hostId] = sb.toString();
    _hostTagMetaById[hostId] = normalized;
  }

  Future<void> _warmHostMetadataForList(List<dynamic> hostList) async {
    if (hostList.isEmpty) return;
    final seq = ++_hostMetaSeq;
    var networkFetchBudget = 8;
    if (mounted) setState(() => _warmingHostMeta = true);
    try {
      for (final h in hostList) {
        if (!mounted || seq != _hostMetaSeq) return;
        final hostId = (h['hostid'] ?? '').toString();
        if (hostId.isEmpty) continue;
        if (_hostMetaBlobById.containsKey(hostId)) continue;

        List<dynamic> items = _hostItemsCache[hostId] ?? const <dynamic>[];
        if (items.isEmpty) {
          try {
            items = await ApiClient.fetchItemsMetadata(hostId, cacheOnly: true);
          } catch (_) {
            items = const <dynamic>[];
          }
        }
        if (items.isEmpty) {
          // Fallback to backend metadata (no history calls).
          if (networkFetchBudget > 0) {
            networkFetchBudget--;
            try {
              items = await ApiClient.fetchItemsMetadata(hostId);
            } catch (_) {
              items = const <dynamic>[];
            }
          }
        }
        if (items.isEmpty) continue;
        _hostItemsCache[hostId] = items;
        _indexHostMetadata(hostId, items);
        if (mounted && seq == _hostMetaSeq) {
          setState(() {});
        }
      }
    } finally {
      if (mounted && seq == _hostMetaSeq) {
        setState(() => _warmingHostMeta = false);
      }
    }
  }

  Future<void> _warmLocalMetadataForKnownHosts() async {
    final knownHosts = AppCache.instance.hosts;
    if (knownHosts.isEmpty) return;
    var networkFetchBudget = 4;
    try {
      for (final h in knownHosts) {
        if (!mounted) return;
        final hostId = (h['hostid'] ?? '').toString();
        if (hostId.isEmpty || _hostMetaBlobById.containsKey(hostId)) continue;
        List<dynamic> items = const <dynamic>[];
        try {
          items = await ApiClient.fetchItemsMetadata(hostId, cacheOnly: true);
        } catch (_) {
          items = const <dynamic>[];
        }
        if (items.isEmpty && networkFetchBudget > 0) {
          networkFetchBudget--;
          try {
            items = await ApiClient.fetchItemsMetadata(hostId);
          } catch (_) {
            items = const <dynamic>[];
          }
        }
        if (items.isEmpty) continue;
        _hostItemsCache[hostId] = items;
        _indexHostMetadata(hostId, items);
      }
      if (mounted) {
        setState(() {});
      }
    } catch (_) {}
  }

  bool _isIgnoredOctetsItem(dynamic item) {
    final name = (item['name'] ?? '').toString().toLowerCase();
    final key = (item['key_'] ?? '').toString().toLowerCase();
    final hay = '$name $key';
    return hay.contains('rx octets') || hay.contains('tx octets');
  }

  bool _isRxPowerItem(dynamic item) {
    final name = (item['name'] ?? '').toString().toLowerCase();
    final key = (item['key_'] ?? '').toString().toLowerCase();
    final hay = '$name $key';
    return hay.contains('rx power') || hay.contains('optical rx');
  }

  bool _isSapItem(dynamic item) {
    final name = (item['name'] ?? '').toString().toLowerCase();
    final key = (item['key_'] ?? '').toString().toLowerCase();
    final hay = '$name $key';
    if (hay.contains('sapid') || hay.contains('sapid=')) return true;
    if (hay.contains('sap[') || hay.contains(' sap ')) return true;
    // SAP items use key pattern: sap.if.*[SAPID] where SAPID is port:vlan.svlan
    if (RegExp(r'sap\.if\.\w+\[').hasMatch(key)) return true;
    if (RegExp(r'(^|[^a-z])sap([^a-z]|$)').hasMatch(hay)) return true;
    return false;
  }

  bool _isBngSrHost(dynamic host) {
    final name = (host?['name'] ?? host?['host'] ?? '')
        .toString()
        .toLowerCase();
    return name.contains('bng') && name.contains('sr');
  }

  String _metadataCoverageLabel() {
    final known = AppCache.instance.hosts;
    if (known.isEmpty) return '';
    var ready = 0;
    for (final h in known) {
      final hostId = (h['hostid'] ?? '').toString();
      if (hostId.isNotEmpty && _hostMetaBlobById.containsKey(hostId)) {
        ready++;
      }
    }
    return '$ready/${known.length} host metadata cached';
  }

  /// Returns true for groups containing full Zabbix item sets (BNG, PE).
  /// ICMP/SR/TIP/OLT/Monitor groups get LLD-based display instead.
  bool _isNetworkGroupName(String? groupName) {
    final g = (groupName ?? '').toLowerCase();
    // Network device groups
    if (g.contains('bng') && !g.contains('icmp')) return true;
    if (g.contains('pe')) return true;
    // Explicitly NOT network: ICMP, SR, TIP, OLT, Monitor, Script
    if (g.contains('icmp')) return false;
    if (g.contains('sr')) return false;
    if (g.contains('tip')) return false;
    if (g.contains('olt')) return false;
    if (g.contains('monitor')) return false;
    if (g.contains('script')) return false;
    // Unknown groups → fetch full items (graceful default)
    return true;
  }

  /// Groups that show ICMP/ping dashboards
  bool _isIcmpGroupName(String? groupName) {
    final g = (groupName ?? '').toLowerCase();
    return g.contains('icmp') ||
        g.contains('sr') ||
        g.contains('tip') ||
        g.contains('olt');
  }

  /// Groups that show Monitor/script dashboards
  bool _isMonitorGroupName(String? groupName) {
    final g = (groupName ?? '').toLowerCase();
    return g.contains('monitor') || g.contains('script');
  }

  List<dynamic> _wrapLldRules(List<dynamic> rules) => rules
      .map(
        (r) => {
          'itemid': 'lld-${r['itemid']}',
          'name': r['name'] ?? 'LLD Rule',
          'key_': r['key_'] ?? '',
          'lastvalue': '',
          'value_type': '4',
          'units': '',
          'lastclock': '',
          '_is_lld_rule': true,
        },
      )
      .toList();

  bool _hasIcmpKey(dynamic i) {
    final k = (i['key_'] ?? '').toString().toLowerCase();
    return k.startsWith('bng.ping.') ||
        k.startsWith('ping.') ||
        k.startsWith('bng.olt.') ||
        k.startsWith('bng.sr.') ||
        k.startsWith('bng.tip.') ||
        k.startsWith('icmp.') ||
        k.startsWith('icmpping');
  }

  bool _hasMonitorKey(dynamic i) {
    final k = (i['key_'] ?? '').toString().toLowerCase();
    return k.startsWith('collector.') || k.startsWith('monitor.device.');
  }

  double _parseNumericValue(dynamic item) {
    if (item == null) return 0;
    return itemNumericValue(item) ?? 0;
  }

  String _itemName(dynamic item) =>
      (item['name'] ?? item['key_'] ?? 'Unnamed').toString();

  String _itemValueText(dynamic item) {
    final value = (item['lastvalue'] ?? '-').toString();
    final units = (item['units'] ?? '').toString();
    return units.isEmpty ? value : '$value $units';
  }

  String _formatBps(double bps) {
    double trunc2(double v) => (v * 100).truncateToDouble() / 100;
    final absVal = bps.abs();
    if (absVal >= 1000000000) {
      return '${trunc2(bps / 1000000000).toStringAsFixed(2)} Gbps';
    }
    if (absVal >= 1000000) {
      return '${trunc2(bps / 1000000).toStringAsFixed(2)} Mbps';
    }
    if (absVal >= 1000) return '${trunc2(bps / 1000).toStringAsFixed(2)} Kbps';
    return '${trunc2(bps).toStringAsFixed(2)} bps';
  }

  String _trafficValueText(dynamic item) {
    if (item == null) return '-';
    final n = itemNumericValue(item);
    if (n == null) return _itemValueText(item);
    return _formatBps(n);
  }

  String? _extractSapId(dynamic item) {
    final raw =
        '${(item['name'] ?? '').toString()} ${(item['key_'] ?? '').toString()}';
    final lower = raw.toLowerCase();
    final sapIdMatch = RegExp(
      r'sapid\s*[=:]\s*([a-z0-9\-_:./]+)',
      caseSensitive: false,
    ).firstMatch(lower);
    if (sapIdMatch != null && sapIdMatch.groupCount >= 1) {
      return sapIdMatch.group(1);
    }
    final sapBracketMatch = RegExp(
      r'sap\[(.*?)\]',
      caseSensitive: false,
    ).firstMatch(raw);
    if (sapBracketMatch != null && sapBracketMatch.groupCount >= 1) {
      final inside = (sapBracketMatch.group(1) ?? '').trim();
      if (inside.isNotEmpty) return inside;
    }
    return null;
  }

  /// Extracts the full SAP ID from an item.
  ///
  /// SAP IDs follow Nokia format: port:outer_vlan.service_vlan
  ///   No service VLAN (untagged): 1/1/c1/1:1986.0
  ///   With service VLAN:          1/1/c1/1:3070.1569
  ///
  /// The LLD macro {#SAPID} appears as the bracket arg: sap.if.rx_bytes[1/1/c1/1:3070.1569]
  String? _extractSapPortVlan(dynamic item) {
    final key = (item['key_'] ?? '').toString();
    final name = (item['name'] ?? '').toString();

    // Primary: extract bracket arg from sap.if.* key
    final bracketKey = RegExp(
      r'sap\.if\.\w+\[([^\]]+)\]',
      caseSensitive: false,
    ).firstMatch(key);
    if (bracketKey != null) {
      final sapId = bracketKey.group(1)?.trim() ?? '';
      if (sapId.isNotEmpty) return sapId;
    }

    // Fallback: match full Nokia SAP ID anywhere in key or name
    // Format: port/slot/card/port:outer.svc  e.g. 1/1/c1/1:3070.1569 or 1/1/c1/1:1986.0
    final haystack = '$key $name';
    final sapFull = RegExp(
      r'\d+/\d+/c\d+/\d+:\d+\.\d+',
      caseSensitive: false,
    ).firstMatch(haystack);
    if (sapFull != null) return sapFull.group(0);

    // Legacy: sap[...] bracket in name
    final sapBracket = RegExp(
      r'sap\[([^\]]+)\]',
      caseSensitive: false,
    ).firstMatch(haystack);
    if (sapBracket != null) {
      final inside = (sapBracket.group(1) ?? '').trim();
      if (inside.isNotEmpty) return inside;
    }
    return null;
  }

  /// Derives display entity name for a SAP item.
  /// SAP ID format: port:outer_vlan.service_vlan
  ///   1/1/c1/1:1986.0    → No service VLAN (ends in .0)
  ///   1/1/c1/1:3070.1569 → Has service VLAN (ends in 4-digit number)
  String _sapEntityFromItem(dynamic item, String fallbackEntity) {
    final portVlan = _extractSapPortVlan(item);
    if (portVlan != null && portVlan.isNotEmpty) return portVlan;
    final sapId = _extractSapId(item);
    if (sapId != null && sapId.isNotEmpty) return sapId;
    return fallbackEntity;
  }

  /// Returns a type label for display based on the SAP ID suffix.
  static String sapTypeLabel(String sapId) {
    final dotIdx = sapId.lastIndexOf('.');
    if (dotIdx == -1) return 'SAP';
    final svc = sapId.substring(dotIdx + 1).trim();
    if (svc == '0') return 'No Svc VLAN';
    final n = int.tryParse(svc);
    if (n != null && n > 0) return 'Svc VLAN $n';
    return 'SAP';
  }

  dynamic _findItem(List<dynamic> items, List<String> needles) {
    for (final item in items) {
      final hay =
          '${(item['name'] ?? '').toString().toLowerCase()} ${(item['key_'] ?? '').toString().toLowerCase()}';
      var ok = true;
      for (final n in needles) {
        if (!hay.contains(n)) {
          ok = false;
          break;
        }
      }
      if (ok) return item;
    }
    return null;
  }

  bool _containsAny(String text, List<String> needles) {
    for (final n in needles) {
      if (text.contains(n)) return true;
    }
    return false;
  }

  bool _itemKeyContains(dynamic item, String fragment) {
    final key = (item?['key_'] ?? '').toString().toLowerCase();
    return key.contains(fragment.toLowerCase());
  }

  List<String> _extractIpList(String raw) {
    final matches = RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}\b').allMatches(raw);
    final out = <String>[];
    for (final m in matches) {
      final ip = m.group(0);
      if (ip != null && ip.isNotEmpty && !out.contains(ip)) out.add(ip);
    }
    return out;
  }

  bool _isAdminStatusLike(dynamic item) {
    if (item == null) return false;
    final hay =
        '${(item['name'] ?? '').toString().toLowerCase()} ${(item['key_'] ?? '').toString().toLowerCase()}';
    return _containsAny(hay, const [
      'ifadminstatus',
      'admin status',
      'administrative',
    ]);
  }

  String _interfaceStatusText(dynamic item) {
    if (item == null) return 'UNKNOWN';
    final raw = (item['lastvalue'] ?? '').toString().trim().toLowerCase();
    if (raw.isEmpty) return 'UNKNOWN';
    final numeric = double.tryParse(raw.replaceAll(RegExp(r'[^0-9\.\-]'), ''));

    if (raw.contains('administratively down') || raw.contains('admin down')) {
      return 'ADMIN DOWN';
    }
    if (_containsAny(raw, const ['up', 'ok', 'enabled', 'true'])) return 'UP';
    if (_containsAny(raw, const ['down', 'disabled', 'false'])) {
      return _isAdminStatusLike(item) ? 'ADMIN DOWN' : 'DOWN';
    }
    if (numeric != null) {
      if (numeric == 1) return 'UP';
      if (numeric == 2) return _isAdminStatusLike(item) ? 'ADMIN DOWN' : 'DOWN';
      return 'DOWN';
    }
    return 'DOWN';
  }

  String _operStatusText(dynamic item) {
    if (item == null) return 'UNKNOWN';
    final raw = (item['lastvalue'] ?? '').toString().trim().toLowerCase();
    if (raw.isEmpty) return 'UNKNOWN';
    final numeric = double.tryParse(raw.replaceAll(RegExp(r'[^0-9\.\-]'), ''));
    if (_containsAny(raw, const ['up', 'ok', 'running', 'true'])) return 'UP';
    if (_containsAny(raw, const ['down', 'disabled', 'false'])) return 'DOWN';
    if (numeric != null) return numeric == 1 ? 'UP' : 'DOWN';
    return 'DOWN';
  }

  bool _isUpFromItem(dynamic item) {
    if (item == null) return false;
    final raw = (item['lastvalue'] ?? '').toString().trim().toLowerCase();
    if (raw.isEmpty) return false;

    final numeric = double.tryParse(raw.replaceAll(RegExp(r'[^0-9\.\-]'), ''));
    if (numeric != null) {
      if (numeric == 1) return true; // SNMP ifOperStatus up(1)
      if (numeric == 2 || numeric == 0) return false;
      return numeric > 0;
    }

    if (_containsAny(raw, const ['up', 'ok', 'running', 'enabled', 'true'])) {
      return true;
    }
    if (_containsAny(raw, const [
      'down',
      'disabled',
      'false',
      'fail',
      'notpresent',
    ])) {
      return false;
    }
    return false;
  }

  dynamic _findInterfaceStatusItem(List<dynamic> items) {
    final byKey = items.firstWhere(
      (item) => _itemKeyContains(item, '.admin['),
      orElse: () => null,
    );
    if (byKey != null) return byKey;

    final preferred = items.firstWhere((item) {
      final hay =
          '${(item['name'] ?? '').toString().toLowerCase()} ${(item['key_'] ?? '').toString().toLowerCase()}';
      return _containsAny(hay, const [
            'ifoperstatus',
            'oper status',
            'interface status',
          ]) &&
          !hay.contains('protocol');
    }, orElse: () => null);
    if (preferred != null) return preferred;
    final adminFirst = items.firstWhere((item) {
      final hay =
          '${(item['name'] ?? '').toString().toLowerCase()} ${(item['key_'] ?? '').toString().toLowerCase()}';
      return _containsAny(hay, const [
        'ifadminstatus',
        'admin status',
        'administrative',
      ]);
    }, orElse: () => null);
    if (adminFirst != null) return adminFirst;
    return _findItem(items, const ['status']);
  }

  dynamic _findProtocolStatusItem(List<dynamic> items) {
    final byKey = items.firstWhere(
      (item) => _itemKeyContains(item, '.oper['),
      orElse: () => null,
    );
    if (byKey != null) return byKey;

    final exact = items.firstWhere((item) {
      final hay =
          '${(item['name'] ?? '').toString().toLowerCase()} ${(item['key_'] ?? '').toString().toLowerCase()}';
      return _containsAny(hay, const [
        'line protocol',
        'ifoperstatus',
        'oper status',
      ]);
    }, orElse: () => null);
    if (exact != null) return exact;
    return items.firstWhere((item) {
      final hay =
          '${(item['name'] ?? '').toString().toLowerCase()} ${(item['key_'] ?? '').toString().toLowerCase()}';
      return _containsAny(hay, const ['protocol status']);
    }, orElse: () => null);
  }

  List<dynamic> _findItemsAny(List<dynamic> items, List<String> needles) {
    return items.where((item) {
      final hay =
          '${(item['name'] ?? '').toString().toLowerCase()} ${(item['key_'] ?? '').toString().toLowerCase()}';
      for (final n in needles) {
        if (hay.contains(n)) return true;
      }
      return false;
    }).toList();
  }

  List<dynamic> _rxTxGraphItems(List<dynamic> items) {
    bool isRxTx(dynamic item) {
      final hay =
          '${(item['name'] ?? '').toString().toLowerCase()} ${(item['key_'] ?? '').toString().toLowerCase()}';
      final rx = hay.contains('rx') || hay.contains('in');
      final tx = hay.contains('tx') || hay.contains('out');
      final traffic =
          hay.contains('traffic') ||
          hay.contains('bps') ||
          hay.contains('bitrate');
      return (rx || tx) &&
          traffic &&
          isNumericItem(item) &&
          !_isIgnoredOctetsItem(item);
    }

    final selected = items.where(isRxTx).toList();
    selected.sort((a, b) {
      final ah =
          '${(a['name'] ?? '').toString().toLowerCase()} ${(a['key_'] ?? '').toString().toLowerCase()}';
      final bh =
          '${(b['name'] ?? '').toString().toLowerCase()} ${(b['key_'] ?? '').toString().toLowerCase()}';
      final aRank = ah.contains('rx') || ah.contains('in') ? 0 : 1;
      final bRank = bh.contains('rx') || bh.contains('in') ? 0 : 1;
      return aRank.compareTo(bRank);
    });
    return selected;
  }

  List<dynamic> _errorDropGraphItems(List<dynamic> items) {
    bool isErrDrop(dynamic item) {
      final hay =
          '${(item['name'] ?? '').toString().toLowerCase()} ${(item['key_'] ?? '').toString().toLowerCase()}';
      final isRxOrIn = hay.contains('rx') || hay.contains('in');
      final isErrDrop = hay.contains('error') || hay.contains('drop');
      return isRxOrIn && isErrDrop && isNumericItem(item);
    }

    return items.where(isErrDrop).toList();
  }

  String _lastUpdatedFor(List<dynamic> items) {
    int latest = 0;
    for (final item in items) {
      final clock = int.tryParse((item['lastclock'] ?? '').toString()) ?? 0;
      if (clock > latest) latest = clock;
    }
    if (latest <= 0) return 'Unknown';
    final dt = DateTime.fromMillisecondsSinceEpoch(latest * 1000).toLocal();
    return formatDateTimeInput(dt);
  }

  Color _statusColor(String status) {
    if (status == 'UP') return Colors.green;
    if (status == 'ADMIN DOWN') return Colors.amber;
    if (status == 'UNKNOWN') return Colors.blueGrey;
    return Colors.red;
  }

  Widget _statusBadge({required String label, required String status}) {
    final color = _statusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            '$label: $status',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: color,
              fontSize: 15,
            ),
          ),
        ],
      ),
    );
  }

  Widget _utilGauge(String label, double valuePercent, Color color) {
    final clamped = valuePercent.clamp(0.0, 100.0);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: clamped / 100.0,
              minHeight: 8,
              backgroundColor: Colors.black12,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
            const SizedBox(height: 6),
            Text('${clamped.toStringAsFixed(1)}%'),
          ],
        ),
      ),
    );
  }

  Widget _metricCard({
    required String label,
    required String value,
    required Color accent,
    String? subtitle,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.22),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: accent.withValues(alpha: 0.5)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: TextStyle(
                color: accent,
                fontWeight: FontWeight.w700,
                fontSize: 18,
              ),
            ),
            if (subtitle != null && subtitle.isNotEmpty)
              Text(
                subtitle,
                style: const TextStyle(color: Colors.white60, fontSize: 11),
              ),
          ],
        ),
      ),
    );
  }

  List<dynamic> _filteredHostGroups() {
    final cacheHosts = AppCache.instance.hosts;
    final problemByHost = <String, StringBuffer>{};
    for (final p in AppCache.instance.problems) {
      final tags = (p['tags'] is List) ? (p['tags'] as List) : const [];
      final tagText = tags
          .map(
            (t) =>
                '${(t['tag'] ?? '').toString()} ${(t['value'] ?? '').toString()}',
          )
          .join(' ');
      if (tagText.isEmpty) continue;
      final pHosts = (p['hosts'] is List) ? (p['hosts'] as List) : const [];
      for (final h in pHosts) {
        final hid = (h['hostid'] ?? '').toString();
        if (hid.isEmpty) continue;
        final b = problemByHost.putIfAbsent(hid, () => StringBuffer());
        b.write(' ');
        b.write(tagText);
      }
    }

    final groups = hostGroups.where((g) {
      final name = (g['name'] ?? '').toString().trim();
      final id = (g['groupid'] ?? '').toString().trim();
      final sb = StringBuffer('$name $id');

      for (final h in cacheHosts) {
        final groups = _hostGroupsOf(h);
        if (!groups.contains(name)) continue;
        final hid = (h['hostid'] ?? '').toString();
        sb.write(' ');
        sb.write((h['name'] ?? h['host'] ?? '').toString());
        sb.write(' ');
        sb.write(extractIp(h));
        sb.write(' ');
        sb.write(problemByHost[hid]?.toString() ?? '');

        final metaBlob = _hostMetaBlobById[hid];
        if (metaBlob != null && metaBlob.isNotEmpty) {
          sb.write(' ');
          sb.write(metaBlob);
        } else {
          final cachedItems = _hostItemsCache[hid] ?? const <dynamic>[];
          for (final i in cachedItems) {
            sb.write(' ');
            sb.write((i['name'] ?? '').toString());
            sb.write(' ');
            sb.write((i['key_'] ?? '').toString());
            sb.write(' ');
            sb.write(_itemTagsText(i));
          }
        }
      }
      return _matchesSearch(sb.toString());
    }).toList();
    groups.sort(
      (a, b) =>
          (a['name'] ?? '').toString().compareTo((b['name'] ?? '').toString()),
    );
    return groups;
  }

  Future<void> _loadHostsForGroup(String groupId, String groupName) async {
    try {
      _hostLoadSeq++;
      setState(() {
        selectedGroupId = groupId;
        selectedGroupName = groupName;
        selectedHost = null;
        hosts = [];
        currentItems = [];
        entityToItems = {};
        selectedItemIds.clear();
        _showHostFilters = false;
        _hostTagFilters.clear();
      });

      final groupHosts = await ApiClient.fetchHosts(groupId: groupId);
      if (!mounted) return;
      setState(() {
        hosts = groupHosts;
        error = '';
      });
      unawaited(_warmHostMetadataForList(groupHosts));
    } catch (e) {
      if (!mounted) return;
      setState(() => error = 'Failed to load hosts from group: $e');
    }
  }

  Map<String, List<dynamic>> _buildDisplayMapFromItems({
    required String hostId,
    required bool isNetwork,
    required List<dynamic> items,
  }) {
    if (!isNetwork && items.isNotEmpty) {
      // Detect ICMP by key content OR by the selected group name
      final hasIcmp = items.any(_hasIcmpKey) || _isIcmpGroupName(selectedGroupName);
      final hasMon = items.any(_hasMonitorKey);
      if (hasIcmp) return {'ICMP Metrics': items};
      if (hasMon) {
        final byGroup = <String, List<dynamic>>{};
        for (final item in items) {
          final key = (item['key_'] ?? '').toString();
          final bracket =
              RegExp(r'\[([^\]]*)\]').firstMatch(key)?.group(1) ?? '';
          final groupKey = bracket.isNotEmpty ? bracket : 'Collector Metrics';
          byGroup.putIfAbsent(groupKey, () => <dynamic>[]).add(item);
        }
        return byGroup.isEmpty ? {'Collector Metrics': items} : byGroup;
      }
      final byEntity = <String, List<dynamic>>{};
      for (final item in items) {
        final entity = entityName(item);
        byEntity.putIfAbsent(entity, () => <dynamic>[]).add(item);
      }
      if (byEntity.keys.every((k) => k == 'General' || k == 'Misc')) {
        return {'All Metrics': items};
      }
      return byEntity;
    }

    final byEntity = <String, List<dynamic>>{};
    for (final item in items) {
      final entity = entityName(item);
      byEntity.putIfAbsent(entity, () => <dynamic>[]).add(item);
    }
    return byEntity;
  }

  Future<void> _loadItemsForHost(dynamic host) async {
    final hostId = host['hostid']?.toString();
    if (hostId == null || hostId.isEmpty) return;
    final seq = ++_hostLoadSeq;

    try {
      setState(() {
        selectedHost = host;
        loadingItems = true;
        currentItems = _hostItemsCache[hostId] ?? <dynamic>[];
        entityToItems = _hostEntityCache[hostId] ?? <String, List<dynamic>>{};
        selectedItemIds.clear();
      });

      final isNetwork = _isNetworkGroupName(selectedGroupName);

      // Fast path: show metadata from local storage immediately.
      if ((_hostItemsCache[hostId] ?? const <dynamic>[]).isEmpty) {
        try {
          final seeded = await ApiClient.fetchItemsMetadata(
            hostId,
            cacheOnly: true,
          );
          if (seeded.isNotEmpty && mounted) {
            final curId = selectedHost?['hostid']?.toString();
            if (seq == _hostLoadSeq && curId == hostId) {
              final seededMap = _buildDisplayMapFromItems(
                hostId: hostId,
                isNetwork: isNetwork,
                items: seeded,
              );
              _hostItemsCache[hostId] = seeded;
              _hostEntityCache[hostId] = seededMap;
              _indexHostMetadata(hostId, seeded);
              setState(() {
                currentItems = seeded;
                entityToItems = seededMap;
              });
            }
          }
        } catch (_) {}
      }

      List<dynamic> allItems = <dynamic>[];
      if (isNetwork) {
        allItems = await ApiClient.fetchItems(hostId);
        if (allItems.isEmpty) {
          allItems = _wrapLldRules(await ApiClient.fetchLldRules(hostId));
        }
      } else {
        try {
          allItems = await ApiClient.fetchItems(hostId);
        } catch (_) {
          allItems = [];
        }
        if (allItems.isEmpty) {
          allItems = _wrapLldRules(await ApiClient.fetchLldRules(hostId));
        }
      }

      final displayMap = _buildDisplayMapFromItems(
        hostId: hostId,
        isNetwork: isNetwork,
        items: allItems,
      );

      if (!mounted) return;
      final curId = selectedHost?['hostid']?.toString();
      if (seq != _hostLoadSeq || curId != hostId) return;
      _indexHostMetadata(hostId, allItems);
      // Detect ICMP groups before setState to prevent entity-list flash.
      final isIcmpGroup = _isIcmpGroupName(selectedGroupName);
      final willAutoNav = isIcmpGroup && displayMap.length == 1;

      setState(() {
        currentItems = allItems;
        entityToItems = displayMap;
        _hostItemsCache[hostId] = allItems;
        _hostEntityCache[hostId] = displayMap;
        selectedItemIds
          ..clear()
          ..addAll(const <String>{});
        // Keep loading state while navigating to avoid entity-list flash
        loadingItems = willAutoNav;
        error = '';
      });

      // Auto-navigate directly for ICMP group hosts (skip entity-list step)
      if (willAutoNav && mounted) {
        final entity = displayMap.keys.first;
        final items  = displayMap.values.first;
        final hName  = (host['name'] ?? host['host'] ?? 'Host').toString();
        final hIp    = extractIp(host);
        // Pass the full group hosts list for host-level swipe navigation
        final neighbours = List<dynamic>.from(hosts);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          // Reset loading before push so Back returns to the hosts list cleanly
          setState(() => loadingItems = false);
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => InterfaceDashboardScreen(
                hostId: hostId,
                hostName: hName,
                hostIp: hIp,
                interfaceName: entity,
                preloadedItems: items,
                interfaceOrder: [entity],
                interfaceItemsByName: displayMap,
                hostNeighbours: neighbours,
              ),
            ),
          );
        });
      }
    } catch (e) {
      if (!mounted) return;
      final currentHostId = selectedHost?['hostid']?.toString();
      if (seq != _hostLoadSeq || currentHostId != hostId) return;
      var msg = 'Failed to load host properties: $e';
      if (e.toString().toLowerCase().contains('timeout')) {
        try {
          final rules = await ApiClient.fetchLldRules(hostId);
          final byEntity = <String, List<dynamic>>{};
          for (final r in rules) {
            final name = (r['name'] ?? r['key_'] ?? 'Discovery').toString();
            byEntity.putIfAbsent(name, () => <dynamic>[]).add({
              'itemid': 'lld-${r['itemid']}',
              'name': r['name'] ?? 'LLD Rule',
              'key_': r['key_'] ?? '',
              'lastvalue': '',
              'value_type': '4',
              'units': '',
              'lastclock': '',
              '_is_lld_rule': true,
            });
          }
          if (byEntity.isNotEmpty) {
            _hostItemsCache[hostId] = byEntity.values.expand((e) => e).toList();
            _hostEntityCache[hostId] = byEntity;
          }
        } catch (_) {}
        msg =
            'Host has a very large interface/property list and timed out. Cached/partial data is shown if available. For complete fix, backend pagination is required.';
      }
      setState(() {
        currentItems = _hostItemsCache[hostId] ?? currentItems;
        entityToItems = _hostEntityCache[hostId] ?? entityToItems;
        loadingItems = false;
        error = msg;
      });
    }
  }

  Future<bool> _onBackPressed() async {
    if (selectedHost != null) {
      setState(() {
        selectedHost = null;
        _ifSearch = '';
        currentItems = [];
        entityToItems = {};
        selectedItemIds.clear();
      });
      return false;
    }
    if (selectedGroupId != null) {
      setState(() {
        selectedGroupId = null;
        selectedGroupName = null;
        selectedHost = null;
        _ifSearch = '';
        _showHostFilters = false;
        _hostTagFilters.clear();
        hosts = [];
        currentItems = [];
        entityToItems = {};
        selectedItemIds.clear();
      });
      return false;
    }
    // At the top-level group list — call onExit to navigate to Dashboard
    // instead of popping the Navigator (which would leave a blank screen).
    if (widget.onExit != null) {
      widget.onExit!();
      return false;
    }
    return true;
  }

  Widget _emptyStateCard({
    required IconData icon,
    required String title,
    required String message,
    VoidCallback? onRetry,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ZbxT.card(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZbxT.rim(context)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: _rxBlue.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: _rxBlue, size: 20),
          ),
          const SizedBox(height: 10),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: ZbxT.textPri(context),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: ZbxT.textSec(context)),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 14),
              label: const Text('Retry'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _groupsView() {
    final groups = _filteredHostGroups();
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 900;
        final gridWidth = isWide
            ? (constraints.maxWidth - 8) / 2
            : constraints.maxWidth;
        return ListView(
          padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  Text(
                    'Host Groups',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: ZbxT.textPri(context),
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: ZbxPalette.rxBlue.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '${groups.length}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: ZbxPalette.rxBlue,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_metadataCoverageLabel().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _metadataCoverageLabel(),
                  style: TextStyle(fontSize: 11, color: ZbxT.textSec(context)),
                ),
              ),
            if (groups.isEmpty)
              _emptyStateCard(
                icon: Icons.folder_off_outlined,
                title: 'No Host Groups',
                message: 'No host groups were returned by the backend.',
                onRetry: _loadGroupsFromCache,
              ),
            if (groups.isNotEmpty && isWide)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: groups
                    .map(
                      (group) => SizedBox(
                        width: gridWidth,
                        child: _buildGroupCard(group),
                      ),
                    )
                    .toList(),
              )
            else
              ...groups.map(_buildGroupCard),
          ],
        );
      },
    );
  }

  Widget _buildGroupCard(dynamic group) {
    final groupName = (group['name'] ?? '').toString();
    final groupId = (group['groupid'] ?? '').toString();
    final lower = groupName.toLowerCase();
    final Color accent = lower.contains('bng') || lower.contains('pe')
        ? _rxBlue
        : lower.contains('icmp') ||
              lower.contains('sr') ||
              lower.contains('tip') ||
              lower.contains('olt')
        ? _txGreen
        : lower.contains('monitor') || lower.contains('script')
        ? ZbxPalette.warnAmb
        : ZbxT.textSec(context);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: ZbxT.card(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.25)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _loadHostsForGroup(groupId, groupName),
        child: Row(
          children: [
            Container(
              width: 4,
              height: 58,
              decoration: BoxDecoration(
                color: accent,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(12),
                  bottomLeft: Radius.circular(12),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.folder_outlined, size: 16, color: accent),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    groupName,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: ZbxT.textPri(context),
                    ),
                  ),
                  Text(
                    'ID: $groupId',
                    style: TextStyle(fontSize: 10, color: ZbxT.textSec(context)),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              color: ZbxT.textSec(context).withValues(alpha: 0.5),
              size: 18,
            ),
            const SizedBox(width: 10),
          ],
        ),
      ),
    );
  }

  Future<void> _openHostFromSearch(
    String groupId,
    String groupName,
    dynamic host,
  ) async {
    await _loadHostsForGroup(groupId, groupName);
    if (!mounted) return;
    final hostId = (host['hostid'] ?? '').toString();
    final target = hosts.firstWhere(
      (h) => (h['hostid'] ?? '').toString() == hostId,
      orElse: () => host,
    );
    await _loadItemsForHost(target);
  }

  Widget _searchTreeView() {
    final query = widget.searchQuery.trim();
    final allHosts = AppCache.instance.hosts.isNotEmpty
        ? AppCache.instance.hosts
        : hosts;
    final groups = hostGroups.toList()
      ..sort(
        (a, b) => (a['name'] ?? '').toString().compareTo(
          (b['name'] ?? '').toString(),
        ),
      );

    final groupResults = <Map<String, dynamic>>[];
    for (final g in groups) {
      final groupName = (g['name'] ?? '').toString();
      final groupId = (g['groupid'] ?? '').toString();
      final groupMatched = _matchesSearch('$groupName $groupId');

      final hostHits = <Map<String, dynamic>>[];
      for (final h in allHosts) {
        final hostGroupNames = _hostGroupsOf(h);
        if (!hostGroupNames.contains(groupName)) continue;

        final hostId = (h['hostid'] ?? '').toString();
        final hostName = (h['name'] ?? h['host'] ?? '').toString();
        final hostIp = extractIp(h);
        final hostCoreMatched = _matchesSearch(
          '$hostName $hostIp ${hostGroupNames.join(' ')}',
        );

        final blob = _hostMetaBlobById[hostId] ?? '';
        final itemMetaMatched = blob.isNotEmpty && _matchesSearch(blob);
        if (!(groupMatched || hostCoreMatched || itemMetaMatched)) continue;

        final matchedItems = <dynamic>[];
        if (itemMetaMatched) {
          final items = _hostItemsCache[hostId] ?? const <dynamic>[];
          for (final i in items) {
            final itemText =
                '${(i['name'] ?? '').toString()} ${(i['key_'] ?? '').toString()} ${_itemTagsText(i)}';
            if (_matchesSearch(itemText)) {
              matchedItems.add(i);
              if (matchedItems.length >= 12) break;
            }
          }
        }

        hostHits.add(<String, dynamic>{
          'host': h,
          'matchedItems': matchedItems,
          'hostMatched': hostCoreMatched,
          'metaLoaded': blob.isNotEmpty,
        });
      }

      if (groupMatched || hostHits.isNotEmpty) {
        hostHits.sort((a, b) {
          final an = (a['host']?['name'] ?? a['host']?['host'] ?? '')
              .toString()
              .toLowerCase();
          final bn = (b['host']?['name'] ?? b['host']?['host'] ?? '')
              .toString()
              .toLowerCase();
          return an.compareTo(bn);
        });
        groupResults.add(<String, dynamic>{
          'group': g,
          'groupMatched': groupMatched,
          'hosts': hostHits,
        });
      }
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      children: [
        Row(
          children: [
            Text(
              'Search Results',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: ZbxT.textPri(context),
              ),
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: ZbxPalette.rxBlue.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '${groupResults.length} group(s)',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: ZbxPalette.rxBlue,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'Query: $query',
          style: TextStyle(fontSize: 11, color: ZbxT.textSec(context)),
        ),
        if (_warmingHostMeta)
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 4),
            child: Row(
              children: [
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.8),
                ),
                const SizedBox(width: 8),
                Text(
                  'Loading more item metadata...',
                  style: TextStyle(fontSize: 11, color: ZbxT.textSec(context)),
                ),
              ],
            ),
          ),
        if (_metadataCoverageLabel().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 4),
            child: Text(
              _metadataCoverageLabel(),
              style: TextStyle(fontSize: 11, color: ZbxT.textSec(context)),
            ),
          ),
        const SizedBox(height: 8),
        if (groupResults.isEmpty)
          _emptyStateCard(
            icon: Icons.search_off,
            title: 'No Search Matches',
            message: 'Try a broader term to match groups, hosts, or items.',
          ),
        ...groupResults.map((entry) {
          final group = entry['group'];
          final groupName = (group['name'] ?? '').toString();
          final groupId = (group['groupid'] ?? '').toString();
          final groupMatched = entry['groupMatched'] == true;
          final hostsInGroup =
              (entry['hosts'] as List<dynamic>? ?? const <dynamic>[]);

          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: ZbxT.card(context),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: groupMatched
                    ? ZbxPalette.rxBlue.withValues(alpha: 0.55)
                    : ZbxT.rim(context),
              ),
            ),
            child: ExpansionTile(
              initiallyExpanded: true,
              tilePadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 2,
              ),
              childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              leading: const Icon(
                Icons.folder_outlined,
                color: ZbxPalette.rxBlue,
                size: 18,
              ),
              title: Text(
                groupName,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: ZbxT.textPri(context),
                ),
              ),
              subtitle: Text(
                '${hostsInGroup.length} host(s)',
                style: TextStyle(fontSize: 11, color: ZbxT.textSec(context)),
              ),
              children: [
                if (hostsInGroup.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Group matched search. No host-level match.',
                      style: TextStyle(
                        fontSize: 11,
                        color: ZbxT.textSec(context),
                      ),
                    ),
                  ),
                ...hostsInGroup.map((hit) {
                  final host = hit['host'];
                  final hostName = (host['name'] ?? host['host'] ?? 'Host')
                      .toString();
                  final hostIp = extractIp(host);
                  final hostMatched = hit['hostMatched'] == true;
                  final metaLoaded = hit['metaLoaded'] == true;
                  final matchedItems =
                      (hit['matchedItems'] as List<dynamic>? ??
                      const <dynamic>[]);

                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: ZbxT.lift(context),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: ZbxT.rim(context)),
                    ),
                    child: ExpansionTile(
                      tilePadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 2,
                      ),
                      childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                      leading: const Icon(
                        Icons.dns_outlined,
                        size: 16,
                        color: ZbxPalette.rxBlue,
                      ),
                      title: Text(
                        hostName,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: ZbxT.textPri(context),
                        ),
                      ),
                      subtitle: Text(
                        matchedItems.isNotEmpty
                            ? '$hostIp • ${matchedItems.length} matching item(s)'
                            : (hostMatched
                                  ? '$hostIp • host matched'
                                  : '$hostIp • metadata matched'),
                        style: TextStyle(
                          fontSize: 10,
                          color: ZbxT.textSec(context),
                        ),
                      ),
                      trailing: TextButton(
                        onPressed: () =>
                            _openHostFromSearch(groupId, groupName, host),
                        child: const Text('Open'),
                      ),
                      children: [
                        if (matchedItems.isEmpty && !metaLoaded)
                          Text(
                            'Item metadata is still loading for this host.',
                            style: TextStyle(
                              fontSize: 11,
                              color: ZbxT.textSec(context),
                            ),
                          ),
                        ...matchedItems.map((item) {
                          final name = (item['name'] ?? 'Item').toString();
                          final key = (item['key_'] ?? '').toString();
                          return Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(top: 4),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: ZbxT.card(context),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: ZbxT.rim(context)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: ZbxT.textPri(context),
                                  ),
                                ),
                                if (key.isNotEmpty)
                                  Text(
                                    key,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: ZbxT.textMono(context),
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                              ],
                            ),
                          );
                        }),
                      ],
                    ),
                  );
                }),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _hostsView() {
    final hostIds = hosts
        .map((h) => (h['hostid'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toSet();
    final hostTagValuesByHost = <String, Map<String, Set<String>>>{};
    final tagOptions = <String, Set<String>>{};

    for (final p in AppCache.instance.problems) {
      final pHosts = (p['hosts'] is List) ? (p['hosts'] as List) : const [];
      final problemHostIds = <String>[];
      for (final h in pHosts) {
        final id = (h['hostid'] ?? '').toString();
        if (id.isNotEmpty && hostIds.contains(id)) {
          problemHostIds.add(id);
        }
      }
      if (problemHostIds.isEmpty) continue;

      final tags = (p['tags'] is List) ? (p['tags'] as List) : const [];
      for (final t in tags) {
        final tagName = (t['tag'] ?? '').toString().trim();
        final tagValue = (t['value'] ?? '').toString().trim();
        if (tagName.isEmpty || tagValue.isEmpty) continue;

        tagOptions.putIfAbsent(tagName, () => <String>{}).add(tagValue);
        for (final hostId in problemHostIds) {
          final hostMap = hostTagValuesByHost.putIfAbsent(
            hostId,
            () => <String, Set<String>>{},
          );
          hostMap.putIfAbsent(tagName, () => <String>{}).add(tagValue);
        }
      }
    }

    // Add item tag metadata from indexed/cached host items.
    for (final hid in hostIds) {
      final hostMap = hostTagValuesByHost.putIfAbsent(
        hid,
        () => <String, Set<String>>{},
      );
      final indexed = _hostTagMetaById[hid];
      if (indexed != null && indexed.isNotEmpty) {
        for (final e in indexed.entries) {
          tagOptions.putIfAbsent(e.key, () => <String>{}).addAll(e.value);
          hostMap.putIfAbsent(e.key, () => <String>{}).addAll(e.value);
        }
        continue;
      }

      final items = _hostItemsCache[hid] ?? const <dynamic>[];
      if (items.isEmpty) continue;
      for (final i in items) {
        final tags = (i['tags'] is List) ? (i['tags'] as List) : const [];
        for (final t in tags) {
          final tagName = (t['tag'] ?? '').toString().trim();
          final tagValue = (t['value'] ?? '').toString().trim();
          if (tagName.isEmpty || tagValue.isEmpty) continue;
          tagOptions.putIfAbsent(tagName, () => <String>{}).add(tagValue);
          hostMap.putIfAbsent(tagName, () => <String>{}).add(tagValue);
        }
      }
    }

    final tagNames = tagOptions.keys.toList()..sort();
    final effectiveTagFilters = Map<String, String>.fromEntries(
      _hostTagFilters.entries.where(
        (e) =>
            e.value == 'All' || (tagOptions[e.key]?.contains(e.value) ?? false),
      ),
    );
    final filteredHosts = hosts.where((host) {
      final hostId = (host['hostid'] ?? '').toString();
      final name = (host['name'] ?? host['host'] ?? '').toString();
      final ip = extractIp(host);
      final groups = _hostGroupsOf(host).join(' ');
      final tags =
          (hostTagValuesByHost[hostId] ?? const <String, Set<String>>{}).entries
              .map((e) => '${e.key} ${e.value.join(' ')}')
              .join(' ');
      final itemMeta =
          _hostMetaBlobById[hostId] ??
          (_hostItemsCache[hostId] ?? const <dynamic>[])
              .map(
                (i) =>
                    '${(i['name'] ?? '').toString()} ${(i['key_'] ?? '').toString()} ${_itemTagsText(i)}',
              )
              .join(' ');
      if (!_matchesSearch('$name $ip $groups $tags $itemMeta')) return false;
      for (final e in effectiveTagFilters.entries) {
        final selected = e.value;
        if (selected == 'All') continue;
        final vals = hostTagValuesByHost[hostId]?[e.key];
        if (vals == null ||
            !vals.any((v) => v.toLowerCase() == selected.toLowerCase())) {
          return false;
        }
      }
      return true;
    }).toList();

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 900;
        final gridWidth = isWide
            ? (constraints.maxWidth - 8) / 2
            : constraints.maxWidth;
        return ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          children: [
            Row(
              children: [
                InkWell(
                  onTap: () => setState(() {
                    selectedGroupId = null;
                    selectedGroupName = null;
                    _showHostFilters = false;
                    _hostTagFilters.clear();
                    hosts = [];
                  }),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.arrow_back_ios_new,
                          size: 14,
                          color: ZbxPalette.rxBlue,
                        ),
                        const SizedBox(width: 4),
                        const Text(
                          'Groups',
                          style: TextStyle(
                            fontSize: 13,
                            color: ZbxPalette.rxBlue,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    selectedGroupName ?? '-',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: ZbxT.textPri(context),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: ZbxPalette.rxBlue.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${filteredHosts.length}/${hosts.length}',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: ZbxPalette.rxBlue,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (_warmingHostMeta)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 1.8),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Loading item metadata for search/filters…',
                      style: TextStyle(
                        fontSize: 11,
                        color: ZbxT.textSec(context),
                      ),
                    ),
                  ],
                ),
              ),
            if (_metadataCoverageLabel().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  _metadataCoverageLabel(),
                  style: TextStyle(fontSize: 11, color: ZbxT.textSec(context)),
                ),
              ),
            if (tagNames.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () =>
                      setState(() => _showHostFilters = !_showHostFilters),
                  icon: const Icon(Icons.filter_list),
                  label: Text(_showHostFilters ? 'Hide Filters' : 'Filters'),
                ),
              ),
            if (_showHostFilters && tagNames.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: ZbxT.card(context),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: ZbxT.rim(context)),
                ),
                child: Column(
                  children: tagNames.map((tag) {
                    final options = <String>[
                      'All',
                      ...(tagOptions[tag]!.toList()..sort()),
                    ];
                    final selected = options.contains(effectiveTagFilters[tag])
                        ? effectiveTagFilters[tag]
                        : 'All';
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 120,
                            child: Text(
                              tag,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: ZbxT.textPri(context),
                              ),
                            ),
                          ),
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              value: selected,
                              items: options
                                  .map(
                                    (v) => DropdownMenuItem<String>(
                                      value: v,
                                      child: Text(v),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (v) => setState(() {
                                _hostTagFilters[tag] = v ?? 'All';
                              }),
                              decoration: const InputDecoration(
                                isDense: true,
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
            if (filteredHosts.isEmpty)
              _emptyStateCard(
                icon: Icons.dns_outlined,
                title: hosts.isEmpty
                    ? 'No Hosts In Group'
                    : 'No Hosts Match Filters',
                message: hosts.isEmpty
                    ? 'This group has no hosts available right now.'
                    : 'Change filters or clear search to see hosts.',
              ),
            if (filteredHosts.isNotEmpty && isWide)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: filteredHosts
                    .map(
                      (host) => SizedBox(
                        width: gridWidth,
                        child: _buildHostCard(host),
                      ),
                    )
                    .toList(),
              )
            else
              ...filteredHosts.map(_buildHostCard),
          ],
        );
      },
    );
  }

  Widget _buildHostCard(dynamic host) {
    final name = (host['name'] ?? host['host'] ?? 'Unknown').toString();
    final ip = extractIp(host);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: ZbxT.card(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZbxT.rim(context)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _loadItemsForHost(host),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: _rxBlue.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.dns_outlined, size: 16, color: _rxBlue),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: ZbxT.textPri(context),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      ip,
                      style: TextStyle(
                        fontSize: 11,
                        color: ZbxT.textMono(context),
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: ZbxT.textSec(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _hostDetailView() {
    final hostName =
        (selectedHost?['name'] ?? selectedHost?['host'] ?? 'Selected Host')
            .toString();
    final ip = extractIp(selectedHost);

    final isBngSr = _isBngSrHost(selectedHost);
    final normalEntities = <String, List<dynamic>>{};
    final sapEntities = <String, List<dynamic>>{};

    final names = entityToItems.keys.toList()..sort();
    for (final entity in names) {
      final list = (entityToItems[entity] ?? <dynamic>[])
          .where((item) => !_isIgnoredOctetsItem(item))
          .where((item) {
            final name = (item['name'] ?? '').toString();
            final key = (item['key_'] ?? '').toString();
            final tags = _itemTagsText(item);
            return _matchesSearch('$entity $name $key $tags');
          })
          .toList();
      if (list.isEmpty) continue;

      if (isBngSr) {
        for (final item in list) {
          if (_isSapItem(item)) {
            final sapEntity = _sapEntityFromItem(item, entity);
            sapEntities.putIfAbsent(sapEntity, () => <dynamic>[]).add(item);
          } else {
            normalEntities.putIfAbsent(entity, () => <dynamic>[]).add(item);
          }
        }
      } else {
        normalEntities.putIfAbsent(entity, () => <dynamic>[]).addAll(list);
      }
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Row(
          children: [
            InkWell(
              onTap: () => setState(() {
                selectedHost = null;
                currentItems = [];
                entityToItems = {};
                selectedItemIds.clear();
              }),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  children: [
                    const Icon(
                      Icons.arrow_back_ios_new,
                      size: 14,
                      color: ZbxPalette.rxBlue,
                    ),
                    const SizedBox(width: 4),
                    const Text(
                      'Hosts',
                      style: TextStyle(fontSize: 13, color: ZbxPalette.rxBlue),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                hostName,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: ZbxT.textPri(context),
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        Text(
          'IP: $ip',
          style: TextStyle(
            color: ZbxT.textMono(context),
            fontSize: 11,
            fontFamily: 'monospace',
          ),
        ),
        const SizedBox(height: 10),
        if (loadingItems)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(
              backgroundColor: ZbxT.rim(context),
              color: _rxBlue,
              minHeight: 2,
            ),
          ),
        if (!loadingItems && currentItems.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _emptyStateCard(
              icon: Icons.rule_folder_outlined,
              title: 'No Host Properties',
              message: 'No properties or LLD rules were found for this host.',
              onRetry: selectedHost == null
                  ? null
                  : () => _loadItemsForHost(selectedHost),
            ),
          ),

        // ── Interface search bar ──────────────────────────────────────
        if (!loadingItems &&
            (sapEntities.isNotEmpty || normalEntities.isNotEmpty))
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: TextField(
              onChanged: (v) =>
                  setState(() => _ifSearch = v.trim().toLowerCase()),
              style: TextStyle(fontSize: 13, color: ZbxT.textPri(context)),
              decoration: InputDecoration(
                hintText: 'Filter by interface name, VRF, customer…',
                hintStyle: TextStyle(fontSize: 12, color: ZbxT.textSec(context)),
                prefixIcon: Icon(
                  Icons.search,
                  size: 18,
                  color: ZbxT.textSec(context),
                ),
                filled: true,
                fillColor: ZbxT.lift(context),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: ZbxT.rim(context)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: ZbxT.rim(context)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(
                    color: ZbxPalette.rxBlue,
                    width: 1.5,
                  ),
                ),
              ),
            ),
          ),

        if (isBngSr &&
            (_ifSearch.isEmpty
                    ? sapEntities
                    : Map.fromEntries(
                        sapEntities.entries.where(
                          (e) => e.key.toLowerCase().contains(_ifSearch),
                        ),
                      ))
                .isNotEmpty)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: ZbxT.card(context),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: ZbxPalette.txGreen.withValues(alpha: 0.3),
              ),
            ),
            child: Theme(
              data: Theme.of(
                context,
              ).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                initiallyExpanded: true,
                tilePadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 4,
                ),
                childrenPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.hub_outlined,
                  size: 18,
                  color: ZbxPalette.txGreen,
                ),
                title: Text(
                  'SAP Interfaces',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: ZbxT.textPri(context),
                  ),
                ),
                subtitle: Text(
                  '${(_ifSearch.isEmpty ? sapEntities : Map.fromEntries(sapEntities.entries.where((e) => e.key.toLowerCase().contains(_ifSearch)))).length} SAP interface(s)',
                  style: TextStyle(fontSize: 11, color: ZbxT.textSec(context)),
                ),
                children: [
                  Container(height: 1, color: ZbxT.rim(context)),
                  ...(_ifSearch.isEmpty
                          ? sapEntities
                          : Map.fromEntries(
                              sapEntities.entries.where(
                                (e2) =>
                                    e2.key.toLowerCase().contains(_ifSearch),
                              ),
                            ))
                      .entries
                      .map((e) {
                        return InkWell(
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => InterfaceDashboardScreen(
                                hostId: (selectedHost?['hostid'] ?? '')
                                    .toString(),
                                hostName: hostName,
                                hostIp: ip,
                                interfaceName: e.key,
                                isSap: true,
                                preloadedItems: e.value,
                                interfaceOrder:
                                    (_ifSearch.isEmpty
                                            ? sapEntities
                                            : Map.fromEntries(
                                                sapEntities.entries.where(
                                                  (e2) => e2.key
                                                      .toLowerCase()
                                                      .contains(_ifSearch),
                                                ),
                                              ))
                                        .keys
                                        .toList()
                                      ..sort(),
                                interfaceItemsByName: _ifSearch.isEmpty
                                    ? sapEntities
                                    : Map.fromEntries(
                                        sapEntities.entries.where(
                                          (e2) => e2.key.toLowerCase().contains(
                                            _ifSearch,
                                          ),
                                        ),
                                      ),
                              ),
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 11,
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.cable,
                                  size: 14,
                                  color: ZbxPalette.txGreen,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    e.key,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: ZbxT.textPri(context),
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Text(
                                  '${e.value.length} items',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: ZbxT.textSec(context),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Icon(
                                  Icons.chevron_right,
                                  size: 16,
                                  color: ZbxT.textSec(context),
                                ),
                              ],
                            ),
                          ),
                        );
                      }),
                ],
              ),
            ),
          ),
        ...(_ifSearch.isEmpty
                ? normalEntities
                : Map.fromEntries(
                    normalEntities.entries.where(
                      (e2) => e2.key.toLowerCase().contains(_ifSearch),
                    ),
                  ))
            .entries
            .map((e) {
              final order = normalEntities.keys.toList()..sort();
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: ZbxT.card(context),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: ZbxT.rim(context)),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => InterfaceDashboardScreen(
                        hostId: (selectedHost?['hostid'] ?? '').toString(),
                        hostName: hostName,
                        hostIp: ip,
                        interfaceName: e.key,
                        preloadedItems: e.value,
                        interfaceOrder: order,
                        interfaceItemsByName: normalEntities,
                      ),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(7),
                          decoration: BoxDecoration(
                            color: ZbxPalette.rxBlue.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(
                            Icons.settings_ethernet,
                            size: 15,
                            color: ZbxPalette.rxBlue,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                e.key,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: ZbxT.textPri(context),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${e.value.length} items',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: ZbxT.textSec(context),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          Icons.chevron_right,
                          size: 18,
                          color: ZbxT.textSec(context),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
      ],
    );
  }

  Widget _buildInterfacePanel(
    String entity,
    List<dynamic> list, {
    required bool isSap,
  }) {
    final rxTxItems = _rxTxGraphItems(list);
    final interfaceStatusItem = _findInterfaceStatusItem(list);
    final protocolStatusItem = _findProtocolStatusItem(list);
    final interfaceStatus = _interfaceStatusText(interfaceStatusItem);
    final protocolStatus = _operStatusText(protocolStatusItem);
    final inUtilItem =
        _findItem(list, ['in', 'util']) ??
        _findItem(list, ['rx', 'util']) ??
        _findItem(list, ['inutil']);
    final outUtilItem =
        _findItem(list, ['out', 'util']) ??
        _findItem(list, ['tx', 'util']) ??
        _findItem(list, ['oututil']);
    final rxErrItem =
        _findItem(list, ['rx', 'error']) ?? _findItem(list, ['in', 'error']);
    final rxDropItem =
        _findItem(list, ['rx', 'drop']) ?? _findItem(list, ['in', 'drop']);
    final errorDropGraphItems = _errorDropGraphItems(list);
    final arpCountItem = list.firstWhere(
      (i) => _itemKeyContains(i, '.arp.count['),
      orElse: () => null,
    );
    final arpIpItems = list
        .where((i) => _itemKeyContains(i, '.arp.ip['))
        .toList();
    final arpIps = <String>[];
    for (final i in arpIpItems) {
      final val = (i['lastvalue'] ?? '').toString();
      arpIps.addAll(_extractIpList(val));
    }
    final uniqueArpIps = arpIps.toSet().toList()..sort();
    final rxTraffic =
        _findItem(list, ['rx', 'traffic']) ??
        _findItem(list, ['in', 'traffic']);
    final txTraffic =
        _findItem(list, ['tx', 'traffic']) ??
        _findItem(list, ['out', 'traffic']);
    final sharedKey = '${selectedHost?['hostid'] ?? '-'}::$entity';
    final fromCtrl = _sharedFromCtrls.putIfAbsent(
      sharedKey,
      TextEditingController.new,
    );
    final toCtrl = _sharedToCtrls.putIfAbsent(
      sharedKey,
      TextEditingController.new,
    );
    final shownIds = <String>{};
    void mark(dynamic item) {
      final id = (item?['itemid'] ?? '').toString();
      if (id.isNotEmpty) shownIds.add(id);
    }

    for (final i in rxTxItems) {
      mark(i);
    }
    mark(interfaceStatusItem);
    mark(protocolStatusItem);
    mark(inUtilItem);
    mark(outUtilItem);
    mark(rxErrItem);
    mark(rxDropItem);
    mark(arpCountItem);
    for (final i in arpIpItems) {
      mark(i);
    }

    final textItems = list.where((i) {
      final id = (i['itemid'] ?? '').toString();
      if (id.isEmpty || shownIds.contains(id)) return false;
      final value = (i['lastvalue'] ?? '').toString().trim();
      return value.isNotEmpty;
    }).toList();

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: ZbxT.card(context),
        border: Border.all(color: ZbxPalette.rxBlue.withValues(alpha: 0.20)),
      ),
      child: ExpansionTile(
        initiallyExpanded: false,
        collapsedIconColor: Colors.white70,
        iconColor: Colors.white,
        textColor: Colors.white,
        collapsedTextColor: Colors.white,
        title: Text(
          isSap ? 'SAP: $entity' : entity,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
        subtitle: Text(
          '${list.length} properties',
          style: const TextStyle(color: Colors.white70),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isSap ? 'SAP Interface' : 'Interface',
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
                const SizedBox(height: 3),
                Text(
                  entity,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Last Updated: ${_lastUpdatedFor(list)}',
                  style: const TextStyle(fontSize: 12, color: Colors.white60),
                ),
              ],
            ),
          ),
          const Divider(color: Colors.white24),
          if (interfaceStatusItem != null || protocolStatusItem != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (interfaceStatusItem != null)
                    _statusBadge(label: 'Interface', status: interfaceStatus),
                  if (protocolStatusItem != null)
                    _statusBadge(label: 'Operational', status: protocolStatus),
                ],
              ),
            ),
          if (inUtilItem != null || outUtilItem != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
              child: Row(
                children: [
                  if (inUtilItem != null)
                    _utilGauge(
                      'In Util',
                      _parseNumericValue(inUtilItem),
                      Colors.green,
                    ),
                  if (inUtilItem != null && outUtilItem != null)
                    const SizedBox(width: 8),
                  if (outUtilItem != null)
                    _utilGauge(
                      'Out Util',
                      _parseNumericValue(outUtilItem),
                      Colors.orange,
                    ),
                ],
              ),
            ),
          if (rxTraffic != null || txTraffic != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
              child: Row(
                children: [
                  _metricCard(
                    label: 'Rx Traffic',
                    value: _trafficValueText(rxTraffic),
                    accent: ZbxPalette.rxBlue,
                    subtitle: 'Live',
                  ),
                  const SizedBox(width: 8),
                  _metricCard(
                    label: 'Tx Traffic',
                    value: _trafficValueText(txTraffic),
                    accent: Colors.greenAccent,
                    subtitle: 'Live',
                  ),
                ],
              ),
            ),
          if (rxTxItems.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
              child: InteractiveLineGraph(
                key: ValueKey(
                  '$entity:${rxTxItems.map((e) => e['itemid']).join(',')}',
                ),
                selectedNumericItems: rxTxItems,
                externalFromController: fromCtrl,
                externalToController: toCtrl,
                showControls: true,
                mode: GraphRenderMode.line,
                backgroundColor: ZbxT.panel(context),
                foregroundColor: Colors.white,
              ),
            )
          else
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 2, 12, 10),
              child: Text(
                'No Rx/Tx traffic series found for this interface.',
                style: TextStyle(fontSize: 12, color: Colors.white70),
              ),
            ),
          if (errorDropGraphItems.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
              child: InteractiveLineGraph(
                key: ValueKey(
                  '$entity:errdrop:${errorDropGraphItems.map((e) => e['itemid']).join(',')}',
                ),
                selectedNumericItems: errorDropGraphItems,
                externalFromController: fromCtrl,
                externalToController: toCtrl,
                showControls: false,
                mode: GraphRenderMode.line,
                backgroundColor: ZbxT.panel(context),
                foregroundColor: Colors.white,
              ),
            ),
          if (textItems.isNotEmpty)
            const Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.only(left: 8, top: 6, bottom: 4),
                child: Text(
                  'Text/State Properties',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          if (rxErrItem != null || rxDropItem != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
              child: Row(
                children: [
                  if (rxErrItem != null)
                    Expanded(
                      child: ListTile(
                        dense: true,
                        title: const Text(
                          'RX Errors',
                          style: TextStyle(color: Colors.white),
                        ),
                        subtitle: Text(
                          _itemValueText(rxErrItem),
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ),
                    ),
                  if (rxErrItem != null && rxDropItem != null)
                    const SizedBox(width: 8),
                  if (rxDropItem != null)
                    Expanded(
                      child: ListTile(
                        dense: true,
                        title: const Text(
                          'RX Drops',
                          style: TextStyle(color: Colors.white),
                        ),
                        subtitle: Text(
                          _itemValueText(rxDropItem),
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          if (uniqueArpIps.isNotEmpty)
            Theme(
              data: Theme.of(
                context,
              ).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                collapsedIconColor: Colors.white70,
                iconColor: Colors.white,
                tilePadding: const EdgeInsets.symmetric(horizontal: 12),
                childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                leading: const Icon(Icons.manage_search, color: Colors.white),
                title: const Text(
                  'ARP IP Addresses',
                  style: TextStyle(color: Colors.white),
                ),
                subtitle: Text(
                  'Discovered: ${arpCountItem == null ? uniqueArpIps.length : _itemValueText(arpCountItem)}',
                  style: const TextStyle(color: Colors.white70),
                ),
                children: uniqueArpIps
                    .map(
                      (ip) => ListTile(
                        dense: true,
                        title: Text(
                          ip,
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          ...textItems.map((item) {
            final rawName = (item['name'] ?? item['key_'] ?? 'Unnamed')
                .toString()
                .replaceAll(RegExp(r'\[.*?\]'), '')
                .trim();
            final value = (item['lastvalue'] ?? '-').toString().trim();
            final units = (item['units'] ?? '').toString().trim();
            final display = units.isEmpty ? value : '$value $units';
            final isOk =
                value == '1' ||
                value.toLowerCase() == 'up' ||
                value.toLowerCase() == 'ok' ||
                value.toLowerCase() == 'normal';
            final isError =
                value == '0' ||
                value.toLowerCase() == 'down' ||
                value.toLowerCase() == 'error';
            final valueColor = isOk
                ? ZbxPalette.txGreen
                : isError
                ? const Color(0xFFEF5350)
                : ZbxT.textMono(context);
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 3,
                    height: 20,
                    margin: const EdgeInsets.only(top: 1, right: 10),
                    decoration: BoxDecoration(
                      color: valueColor.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      rawName,
                      style: TextStyle(
                        fontSize: 12,
                        color: ZbxT.textMono(context),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    display,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: valueColor,
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

  Widget _buildSapInterfacePanel(String entity, List<dynamic> list) {
    final rxTxItems = _rxTxGraphItems(list);
    final rxTraffic =
        _findItem(list, ['rx', 'traffic']) ??
        _findItem(list, ['in', 'traffic']);
    final txTraffic =
        _findItem(list, ['tx', 'traffic']) ??
        _findItem(list, ['out', 'traffic']);

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: ZbxT.card(context),
        border: Border.all(color: ZbxPalette.txGreen.withValues(alpha: 0.22)),
      ),
      child: ExpansionTile(
        initiallyExpanded: false,
        collapsedIconColor: Colors.white70,
        iconColor: Colors.white,
        textColor: Colors.white,
        collapsedTextColor: Colors.white,
        title: Text(
          entity,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
        subtitle: Text(
          'SAP traffic interface',
          style: const TextStyle(color: Colors.white70),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
            child: Text(
              'Last Updated: ${_lastUpdatedFor(list)}',
              style: const TextStyle(fontSize: 12, color: Colors.white60),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
            child: Row(
              children: [
                _metricCard(
                  label: 'Rx Traffic',
                  value: _trafficValueText(rxTraffic),
                  accent: ZbxPalette.rxBlue,
                  subtitle: 'Live',
                ),
                const SizedBox(width: 8),
                _metricCard(
                  label: 'Tx Traffic',
                  value: _trafficValueText(txTraffic),
                  accent: Colors.greenAccent,
                  subtitle: 'Live',
                ),
              ],
            ),
          ),
          if (rxTxItems.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
              child: InteractiveLineGraph(
                key: ValueKey(
                  'sap:$entity:${rxTxItems.map((e) => e['itemid']).join(',')}',
                ),
                selectedNumericItems: rxTxItems,
                backgroundColor: ZbxT.panel(context),
                foregroundColor: Colors.white,
              ),
            ),
          if (rxTxItems.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 2, 12, 8),
              child: Text(
                'No Rx/Tx traffic series found for this SAP interface.',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(child: CircularProgressIndicator(color: _rxBlue));
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final canLeave = await _onBackPressed();
        if (canLeave && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: RefreshIndicator(
        onRefresh: () async => _loadGroupsFromCache(),
        color: _rxBlue,
        backgroundColor: ZbxT.card(context),
        child: Column(
          children: [
            if (error.isNotEmpty)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFEF5350).withValues(alpha: 0.10),
                  border: Border.all(
                    color: const Color(0xFFEF5350).withValues(alpha: 0.35),
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  error,
                  style: const TextStyle(
                    color: Color(0xFFEF5350),
                    fontSize: 12,
                  ),
                ),
              ),
            Expanded(
              child: selectedGroupId == null
                  ? (_searchTokens().isNotEmpty
                        ? _searchTreeView()
                        : _groupsView())
                  : (selectedHost == null ? _hostsView() : _hostDetailView()),
            ),
          ],
        ),
      ),
    );
  }
}
