import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api_client.dart';
import '../../core/utils.dart';
import '../../core/zbx_theme.dart';
import '../graph/interactive_line_graph.dart';

// ─── Design tokens ────────────────────────────────────────────────────────────
const _bgPanel = ZbxPalette.panelDark;
const _rxBlue = ZbxPalette.rxBlue;
const _txGreen = ZbxPalette.txGreen;
const _upGreen = ZbxPalette.upGreen;
const _downRed = ZbxPalette.downRed;
const _warnAmb = ZbxPalette.warnAmb;
const _textSec = ZbxPalette.textSecDark;
const _latBlue = ZbxPalette.rxBlue;
const _latMin = ZbxPalette.txGreen;
const _latMax = ZbxPalette.warnAmb;
const _monOk = ZbxPalette.txGreen;

// ─── Dashboard mode detected from item keys ────────────────────────────────────
enum _DashMode { network, icmp, monitor, generic, storage }

// ─── Widget ───────────────────────────────────────────────────────────────────
// ── Theme-aware color helper ──────────────────────────────────────────────────
// ── Theme-aware color helper ──────────────────────────────────────────────────
// ── Theme helper via ZbxT (see zbx_theme.dart) ────

class InterfaceDashboardScreen extends StatefulWidget {
  final String hostId;
  final String hostName;
  final String hostIp;
  final String interfaceName;
  final bool isSap;
  final List<dynamic>? preloadedItems;
  final List<String>? interfaceOrder;
  final Map<String, List<dynamic>>? interfaceItemsByName;
  /// Ordered neighbour-hosts in the same group – used for ICMP host swipe.
  final List<dynamic>? hostNeighbours;

  const InterfaceDashboardScreen({
    super.key,
    required this.hostId,
    required this.hostName,
    required this.hostIp,
    required this.interfaceName,
    this.isSap = false,
    this.preloadedItems,
    this.interfaceOrder,
    this.interfaceItemsByName,
    this.hostNeighbours,
  });

  @override
  State<InterfaceDashboardScreen> createState() =>
      _InterfaceDashboardScreenState();
}

class _InterfaceDashboardScreenState extends State<InterfaceDashboardScreen>
    with SingleTickerProviderStateMixin {
  List<dynamic> _items = [];
  bool _loading = true;
  String _error = '';

  late final AnimationController _fadeCtrl;
  late final Animation<double> _fade;

  final _fromCtrl = TextEditingController();
  final _toCtrl = TextEditingController();

  // ── ICMP chart preset state ───────────────────────────────────────────────────
  String? _icmpActivePreset = '1h';

  static const _kIcmpPresets = [
    ('15m', 15), ('1h', 60), ('3h', 180), ('6h', 360),
    ('12h', 720), ('24h', 1440), ('2d', 2880), ('7d', 10080),
  ];

  void _applyIcmpPreset(String label) {
    final entry = _kIcmpPresets.firstWhere(
      (p) => p.$1 == label,
      orElse: () => ('', 0),
    );
    if (entry.$2 == 0) return;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final from = now - (entry.$2 * 60);
    setState(() {
      _fromCtrl.text = formatDateTimeInput(
        DateTime.fromMillisecondsSinceEpoch(from * 1000).toLocal(),
      );
      _toCtrl.text = formatDateTimeInput(
        DateTime.fromMillisecondsSinceEpoch(now * 1000).toLocal(),
      );
      _icmpActivePreset = label;
    });
  }

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _fade = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);

    // Default time range: last 1 hour so all graphs load without user interaction
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _fromCtrl.text = formatDateTimeInput(
      DateTime.fromMillisecondsSinceEpoch((now - 3600) * 1000).toLocal(),
    );
    _toCtrl.text = formatDateTimeInput(
      DateTime.fromMillisecondsSinceEpoch(now * 1000).toLocal(),
    );

    _load();
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    _fromCtrl.dispose();
    _toCtrl.dispose();
    super.dispose();
  }

  // ── Data loading ─────────────────────────────────────────────────────────────
  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final target = widget.interfaceName.toLowerCase().trim();

      if (widget.preloadedItems != null) {
        if (!mounted) return;
        setState(() {
          _items = widget.preloadedItems!;
          _loading = false;
          _error = '';
        });
        _fadeCtrl.forward(from: 0);
        return;
      }

      final all = await ApiClient.fetchItems(widget.hostId);

      // ── For ICMP/Monitor hosts there is no [interface] bracket in keys.
      // We detect those by key prefix and return ALL items for the host.
      final isIcmpHost = all.any(_isIcmpKey);
      final isMonHost = all.any(_isMonitorKey);

      List<dynamic> filtered;
      if (isIcmpHost || isMonHost) {
        // Host-level items – return all numeric ones
        filtered = all
            .where((i) => isNumericItem(i) || _isStatusKey(i))
            .toList();
      } else {
        // Network interface – exact bracket match
        if (target.isEmpty) {
          filtered = [];
        } else {
          final isPath = RegExp(r'^\d+/\d+').hasMatch(target);
          filtered = all.where((i) {
            final key = (i['key_'] ?? '').toString().toLowerCase();
            final name = (i['name'] ?? '').toString().toLowerCase();
            final entity = entityName(i).toLowerCase();
            final bMatch = RegExp(r'\[([^\]]*)\]').firstMatch(key);
            final bracket = bMatch?.group(1)?.toLowerCase().trim() ?? '';
            if (isPath) return bracket == target || entity == target;
            return bracket == target ||
                entity == target ||
                key.contains(target) ||
                name.contains(target);
          }).toList();
        }
      }

      if (!mounted) return;
      setState(() {
        _items = filtered;
        _loading = false;
        _error = filtered.isEmpty
            ? 'No items found for "${widget.interfaceName}".'
            : '';
      });
      _fadeCtrl.forward(from: 0);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Load failed: $e';
      });
    }
  }

  // ── Dashboard mode detection ─────────────────────────────────────────────────
  _DashMode get _mode {
    if (_items.any(_isIcmpKey)) return _DashMode.icmp;
    if (_items.any(_isMonitorKey)) return _DashMode.monitor;
    // Only show network UI if there is genuine traffic evidence (bps/bytes/etc.)
    if (_items.any(_isTrafficItem)) return _DashMode.network;
    // Storage/system health items (disk, CPU, memory, uptime) -> storage mode
    if (_items.any(_isStorageItem)) return _DashMode.storage;
    return _DashMode.generic;
  }

  /// True when the item carries network traffic data (bps, bytes in/out, etc.)
  bool _isTrafficItem(dynamic i) {
    final key   = (i['key_'] ?? '').toString().toLowerCase();
    final name  = (i['name'] ?? '').toString().toLowerCase();
    final units = (i['units'] ?? '').toString().toLowerCase();
    final hay   = '  ';
    return hay.contains('traffic') ||
        hay.contains('bps') ||
        units.contains('bps') ||
        units.contains('bit/s') ||
        key.contains('rx_bytes') ||
        key.contains('tx_bytes') ||
        key.contains('ifhcinoctets') ||
        key.contains('ifhcoutoctets') ||
        _unitsLikeBps(i);
  }

  /// True when the item is a storage/system-health metric (disk, CPU, memory).
  bool _isStorageItem(dynamic i) {
    final k = (i['key_'] ?? '').toString().toLowerCase();
    return k.startsWith('vfs.fs.') ||
        k.startsWith('vfs.dev.') ||
        k.startsWith('system.cpu.') ||
        k.startsWith('system.swap.') ||
        k.startsWith('system.uptime') ||
        k.startsWith('system.localtime') ||
        k.startsWith('system.hostname') ||
        k.startsWith('system.uname') ||
        k.startsWith('system.users.') ||
        k.startsWith('vm.memory.') ||
        k.startsWith('proc.num') ||
        k.startsWith('kernel.');
  }

  bool _isIcmpKey(dynamic i) {
    final k = (i['key_'] ?? '').toString().toLowerCase();
    return k.startsWith('bng.ping.') ||
        k.startsWith('bng.olt.') ||
        k == 'bng.ping.avg' ||
        k == 'bng.ping.loss';
  }

  bool _isMonitorKey(dynamic i) {
    final k = (i['key_'] ?? '').toString().toLowerCase();
    return k.startsWith('collector.') || k.startsWith('monitor.device.');
  }

  bool _isStatusKey(dynamic i) {
    final vt = (i['value_type'] ?? '').toString();
    return vt == '4'; // CHAR type
  }

  // ── Network helper finders ────────────────────────────────────────────────────
  dynamic _find(List<String> needles) {
    for (final i in _items) {
      final hay =
          '${(i["name"] ?? "").toString().toLowerCase()} ${(i["key_"] ?? "").toString().toLowerCase()}';
      if (needles.every((n) => hay.contains(n))) return i;
    }
    return null;
  }

  dynamic _findByKeyPart(String part) {
    for (final i in _items) {
      if ((i['key_'] ?? '').toString().toLowerCase().contains(part)) return i;
    }
    return null;
  }

  dynamic _findTrafficItem({required bool rx}) {
    dynamic best;
    var bestScore = -1;
    for (final i in _items) {
      final key = (i['key_'] ?? '').toString().toLowerCase();
      final name = (i['name'] ?? '').toString().toLowerCase();
      final hay = '$key $name';
      final hasTraffic =
          hay.contains('traffic') ||
          hay.contains('bps') ||
          hay.contains('rx_bytes') ||
          hay.contains('tx_bytes') ||
          hay.contains('ifhcinoctets') ||
          hay.contains('ifhcoutoctets');
      if (!hasTraffic) continue;
      final hasRx = RegExp(r'(^|[^a-z])(rx|in)([^a-z]|$)').hasMatch(hay);
      final hasTx = RegExp(r'(^|[^a-z])(tx|out)([^a-z]|$)').hasMatch(hay);
      if (rx) {
        if (!hasRx || hasTx) continue;
      } else {
        if (!hasTx || hasRx) continue;
      }
      var score = 1;
      if (hay.contains('traffic')) score += 3;
      if (hay.contains('bps') || _unitsLikeBps(i)) score += 2;
      if (hay.contains('ifhc')) score += 1;
      if (score > bestScore) {
        bestScore = score;
        best = i;
      }
    }
    return best;
  }

  List<dynamic> _networkErrDropItems() => _items.where((i) {
    final hay =
        '${(i["name"] ?? "").toString().toLowerCase()} ${(i["key_"] ?? "").toString().toLowerCase()}';
    return (hay.contains('error') ||
            hay.contains('drop') ||
            hay.contains('in_err') ||
            hay.contains('in_drop')) &&
        isNumericItem(i);
  }).toList();

  List<dynamic> _rxTxItems() {
    final rx = _findTrafficItem(rx: true);
    final tx = _findTrafficItem(rx: false);
    final out = <dynamic>[];
    if (rx != null && isNumericItem(rx)) out.add(rx);
    if (tx != null &&
        isNumericItem(tx) &&
        (tx['itemid'] ?? '') != (rx?['itemid'] ?? '')) {
      out.add(tx);
    }
    return out;
  }

  List<dynamic> _utilizationItems() => _items.where((i) {
    final key = (i['key_'] ?? '').toString().toLowerCase();
    return (key.contains('in_util') || key.contains('out_util')) &&
        isNumericItem(i);
  }).toList();

  /// Returns utilization percent (0–100) for Rx or Tx from util items.
  double? _utilPct(List<dynamic> utilItems, {required bool rx}) {
    for (final i in utilItems) {
      final key = (i['key_'] ?? '').toString().toLowerCase();
      final isRx = key.contains('in_util') || key.contains('rx_util');
      final isTx = key.contains('out_util') || key.contains('tx_util');
      if ((rx && isRx) || (!rx && isTx)) {
        return itemNumericValue(i);
      }
    }
    return null;
  }

  bool _unitsLikeBps(dynamic i) {
    final u = (i?['units'] ?? '').toString().toLowerCase();
    return u.contains('bps') || u.contains('bit/s');
  }

  String _statusText(dynamic item, {bool admin = false}) {
    if (item == null) return 'UNKNOWN';
    final raw = (item['lastvalue'] ?? '').toString().trim().toLowerCase();
    final n = double.tryParse(raw.replaceAll(RegExp(r'[^0-9.\-]'), ''));
    if (raw.contains('administratively down') || raw.contains('admin down')) {
      return 'ADMIN DOWN';
    }
    if (raw.contains('up') || raw.contains('ok') || raw.contains('enabled')) {
      return 'UP';
    }
    if (raw.contains('down') || raw.contains('disabled')) {
      return admin ? 'ADMIN DOWN' : 'DOWN';
    }
    if (n != null) {
      if (n == 1) return 'UP';
      if (n == 2) return admin ? 'ADMIN DOWN' : 'DOWN';
    }
    return 'UNKNOWN';
  }

  Color _statusColor(String s) {
    switch (s) {
      case 'UP':
        return _upGreen;
      case 'DOWN':
        return _downRed;
      case 'ADMIN DOWN':
        return _warnAmb;
      default:
        return _textSec;
    }
  }

  ({String val, String unit}) _splitTraffic(dynamic item) {
    if (item == null) return (val: '—', unit: '');
    final key = (item['key_'] ?? '').toString().toLowerCase();
    final units = (item['units'] ?? '').toString().toLowerCase();
    final n = itemNumericValue(item);
    final isTraffic =
        key.contains('bps') ||
        key.contains('traffic') ||
        key.contains('rx_bytes') ||
        key.contains('tx_bytes') ||
        units.contains('bps') ||
        units.contains('bit/s');
    if (n != null && isTraffic) {
      if (n.abs() >= 1e9) {
        return (val: (n / 1e9).toStringAsFixed(2), unit: 'Gbps');
      }
      if (n.abs() >= 1e6) {
        return (val: (n / 1e6).toStringAsFixed(2), unit: 'Mbps');
      }
      if (n.abs() >= 1e3) {
        return (val: (n / 1e3).toStringAsFixed(2), unit: 'Kbps');
      }
      return (val: n.toStringAsFixed(2), unit: 'bps');
    }
    final v = (item['lastvalue'] ?? '—').toString();
    final u = (item['units'] ?? '').toString();
    return (val: v, unit: u);
  }

  String _tagFromItem(dynamic item, String tagName) {
    if (item == null) return '';
    for (final t
        in (item['tags'] is List) ? (item['tags'] as List) : const []) {
      if ((t['tag'] ?? '').toString().toLowerCase() == tagName.toLowerCase()) {
        final v = (t['value'] ?? '').toString();
        if (v.isNotEmpty) return v;
      }
    }
    return '';
  }

  String _tagValue(String tagName) {
    for (final i in _items) {
      final v = _tagFromItem(i, tagName);
      if (v.isNotEmpty) return v;
    }
    return '';
  }

  String _firstTagValue(List<String> aliases, {dynamic preferredItem}) {
    for (final a in aliases) {
      final v = _tagFromItem(preferredItem, a);
      if (v.isNotEmpty) return v;
    }
    for (final a in aliases) {
      final v = _tagValue(a);
      if (v.isNotEmpty) return v;
    }
    return '';
  }

  // ── Navigation ────────────────────────────────────────────────────────────────
  void _swipeTo(int delta) {
    // ICMP mode: swipe between hosts in the same group.
    if (_mode == _DashMode.icmp && widget.hostNeighbours != null) {
      _swipeToHost(delta);
      return;
    }
    // Otherwise: swipe between interfaces of the same host.
    final order = widget.interfaceOrder;
    if (order == null || order.isEmpty) return;
    final idx = order.indexOf(widget.interfaceName);
    if (idx < 0) return;
    final next = idx + delta;
    if (next < 0 || next >= order.length) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (_, _, _) => InterfaceDashboardScreen(
          hostId: widget.hostId,
          hostName: widget.hostName,
          hostIp: widget.hostIp,
          interfaceName: order[next],
          isSap: widget.isSap,
          preloadedItems: widget.interfaceItemsByName?[order[next]],
          interfaceOrder: order,
          interfaceItemsByName: widget.interfaceItemsByName,
          hostNeighbours: widget.hostNeighbours,
        ),
        transitionsBuilder: (_, anim, _, child) => SlideTransition(
          position: Tween<Offset>(
            begin: Offset(delta > 0 ? 1 : -1, 0),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
          child: child,
        ),
      ),
    );
  }

  /// Navigate to the previous / next host in the ICMP neighbours list.
  void _swipeToHost(int delta) {
    final neighbours = widget.hostNeighbours!;
    final idx = neighbours.indexWhere(
      (h) => (h['hostid'] ?? '').toString() == widget.hostId,
    );
    if (idx < 0) return;
    final next = idx + delta;
    if (next < 0 || next >= neighbours.length) return;
    final nextHost = neighbours[next];
    final nextId   = (nextHost['hostid'] ?? '').toString();
    final nextName = (nextHost['name'] ?? nextHost['host'] ?? 'Host').toString();
    final nextIp   = extractIp(nextHost);
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (_, _, _) => InterfaceDashboardScreen(
          hostId: nextId,
          hostName: nextName,
          hostIp: nextIp,
          interfaceName: 'ICMP Metrics',
          hostNeighbours: neighbours,
        ),
        transitionsBuilder: (_, anim, _, child) => SlideTransition(
          position: Tween<Offset>(
            begin: Offset(delta > 0 ? 1 : -1, 0),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
          child: child,
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // BUILD
  // ═══════════════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final order = widget.interfaceOrder;
    final orderIdx = order != null ? order.indexOf(widget.interfaceName) : -1;
    final hasOrder = order != null && order.isNotEmpty && orderIdx >= 0;
    // ICMP host navigation
    final neighbours = widget.hostNeighbours;
    final hostIdx = neighbours != null
        ? neighbours.indexWhere((h) => (h['hostid'] ?? '').toString() == widget.hostId)
        : -1;
    final hasHostNav = _mode == _DashMode.icmp &&
        neighbours != null &&
        neighbours.length > 1 &&
        hostIdx >= 0;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: _buildAppBar(hasOrder, orderIdx, order, hasHostNav, hostIdx, neighbours),
        body: _loading
            ? _buildLoader()
            : GestureDetector(
                onHorizontalDragEnd: (d) {
                  final v = d.primaryVelocity ?? 0;
                  if (v < -300) _swipeTo(1);
                  if (v > 300) _swipeTo(-1);
                },
                child: RefreshIndicator(
                  onRefresh: _load,
                  color: _rxBlue,
                  backgroundColor: ZbxT.card(context),
                  child: FadeTransition(opacity: _fade, child: _buildBody()),
                ),
              ),
      ),
    );
  }

  // ── AppBar ────────────────────────────────────────────────────────────────────
  PreferredSizeWidget _buildAppBar(
    bool hasOrder,
    int idx,
    List<String>? order,
    bool hasHostNav,
    int hostIdx,
    List<dynamic>? neighbours,
  ) {
    final modeIcon = _loading
        ? Icons.hourglass_top
        : (_mode == _DashMode.icmp
              ? Icons.signal_cellular_alt
              : _mode == _DashMode.monitor
              ? Icons.monitor_heart_outlined
              : _mode == _DashMode.storage
              ? Icons.storage_outlined
              : Icons.cable);

    return AppBar(
      backgroundColor: ZbxT.card(context),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      leading: IconButton(
        icon: Icon(
          Icons.arrow_back_ios_new,
          size: 18,
          color: ZbxT.textPri(context),
        ),
        onPressed: () => Navigator.of(context).maybePop(),
      ),
      title: Row(
        children: [
          Icon(modeIcon, size: 14, color: ZbxT.textSec(context)),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  // ICMP mode: show host name prominently
                  _mode == _DashMode.icmp ? widget.hostName : widget.interfaceName,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: ZbxT.textPri(context),
                  ),
                ),
                Text(
                  _mode == _DashMode.icmp
                      ? (widget.hostIp.isNotEmpty && widget.hostIp != '-'
                          ? widget.hostIp
                          : 'ICMP Monitor')
                      : widget.hostName,
                  style: TextStyle(fontSize: 10, color: ZbxT.textSec(context)),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        if (hasHostNav) ...[
          IconButton(
            icon: Icon(Icons.chevron_left, color: ZbxT.textSec(context)),
            onPressed: hostIdx > 0 ? () => _swipeTo(-1) : null,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '${hostIdx + 1}/${neighbours!.length}',
              style: TextStyle(
                fontSize: 11,
                color: ZbxT.textSec(context),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          IconButton(
            icon: Icon(Icons.chevron_right, color: ZbxT.textSec(context)),
            onPressed: hostIdx < neighbours!.length - 1 ? () => _swipeTo(1) : null,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ] else if (hasOrder) ...[
          IconButton(
            icon: Icon(Icons.chevron_left, color: ZbxT.textSec(context)),
            onPressed: idx > 0 ? () => _swipeTo(-1) : null,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '${idx + 1}/${order!.length}',
              style: TextStyle(
                fontSize: 11,
                color: ZbxT.textSec(context),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          IconButton(
            icon: Icon(Icons.chevron_right, color: ZbxT.textSec(context)),
            onPressed: idx < order.length - 1 ? () => _swipeTo(1) : null,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
        IconButton(
          icon: Icon(Icons.refresh, size: 18, color: ZbxT.textSec(context)),
          onPressed: _load,
        ),
        const SizedBox(width: 4),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(height: 1, color: ZbxT.rim(context)),
      ),
    );
  }

  Widget _buildLoader() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 32,
          height: 32,
          child: CircularProgressIndicator(strokeWidth: 2, color: _rxBlue),
        ),
        const SizedBox(height: 14),
        Text(
          'Loading interface data…',
          style: TextStyle(fontSize: 12, color: ZbxT.textSec(context)),
        ),
      ],
    ),
  );

  // ── Body dispatcher ───────────────────────────────────────────────────────────
  Widget _buildBody() {
    final children = <Widget>[
      if (_error.isNotEmpty) _buildErrorBanner(),
      _buildHostRow(),
      const SizedBox(height: 14),
    ];

    switch (_mode) {
      case _DashMode.icmp:
        children.addAll(_buildIcmpBody());
        break;
      case _DashMode.monitor:
        children.addAll(_buildMonitorBody());
        break;
      case _DashMode.generic:
        children.addAll(_buildGenericBody());
        break;
      case _DashMode.storage:
        children.addAll(_buildStorageBody());
        break;
      case _DashMode.network:
        children.addAll(_buildNetworkBody());
        break;
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 48),
      children: children,
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // ICMP / Ping Dashboard
  // ═══════════════════════════════════════════════════════════════════════════
  List<Widget> _buildIcmpBody() {
    final avg = _findByKeyPart('bng.ping.avg') ?? _findByKeyPart('ping.avg');
    final min = _findByKeyPart('bng.ping.min') ?? _findByKeyPart('ping.min');
    final max = _findByKeyPart('bng.ping.max') ?? _findByKeyPart('ping.max');
    final loss = _findByKeyPart('bng.ping.loss') ?? _findByKeyPart('ping.loss');
    final jitter =
        _findByKeyPart('bng.ping.jitter') ?? _findByKeyPart('ping.jitter');
    final reach = _findByKeyPart('bng.ping.reachable');

    final reachVal = (reach?['lastvalue'] ?? '').toString().trim();
    final isReachable = reachVal == '1' || reachVal.toLowerCase() == 'true';

    final graphItems = _items.where((i) {
      final k = (i['key_'] ?? '').toString().toLowerCase();
      return (k.contains('ping.avg') ||
              k.contains('ping.min') ||
              k.contains('ping.max') ||
              k.contains('ping.jitter')) &&
          isNumericItem(i);
    }).toList();

    final lossItems = _items.where((i) {
      final k = (i['key_'] ?? '').toString().toLowerCase();
      return k.contains('ping.loss') && isNumericItem(i);
    }).toList();

    String ms(dynamic item) {
      if (item == null) return '—';
      final n = itemNumericValue(item);
      return n != null
          ? n.toStringAsFixed(2)
          : (item['lastvalue'] ?? '—').toString();
    }

    String pct(dynamic item) {
      if (item == null) return '—';
      final n = itemNumericValue(item);
      if (n == null) return (item['lastvalue'] ?? '—').toString();
      return '${n.toStringAsFixed(1)}%';
    }

    return [
      if (reach != null) ...[
        _buildSection('REACHABILITY', Icons.wifi_tethering),
        const SizedBox(height: 8),
        _StatusPill(
          label: 'Ping Status',
          status: isReachable ? 'REACHABLE' : 'UNREACHABLE',
          color: isReachable ? _upGreen : _downRed,
        ),
        const SizedBox(height: 14),
      ],
      _buildSection('LATENCY', Icons.timer_outlined),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: _MetricTile(
              label: 'Avg',
              value: ms(avg),
              unit: 'ms',
              color: _latBlue,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _MetricTile(
              label: 'Min',
              value: ms(min),
              unit: 'ms',
              color: _latMin,
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: _MetricTile(
              label: 'Max',
              value: ms(max),
              unit: 'ms',
              color: _latMax,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _MetricTile(
              label: 'Jitter',
              value: ms(jitter),
              unit: 'ms',
              color: const Color(0xFFCE93D8),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      _PacketLossTile(value: pct(loss), item: loss),
      if (graphItems.isNotEmpty || lossItems.isNotEmpty) ...[
        const SizedBox(height: 16),
        _buildSection('LATENCY & PACKET LOSS HISTORY', Icons.show_chart),
        const SizedBox(height: 4),
        Row(
          children: [
            _legendDot(_latBlue),
            const SizedBox(width: 4),
            Text(
              'Latency (ms)',
              style: TextStyle(fontSize: 9, color: ZbxT.textSec(context)),
            ),
            const SizedBox(width: 12),
            _legendDot(_downRed),
            const SizedBox(width: 4),
            Text(
              'Loss % (below 0)',
              style: TextStyle(fontSize: 9, color: ZbxT.textSec(context)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // ── Time-range preset chips ───────────────────────────────────────────
        SizedBox(
          height: 28,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _kIcmpPresets.length,
            separatorBuilder: (_, __) => const SizedBox(width: 6),
            itemBuilder: (_, i) {
              final label = _kIcmpPresets[i].$1;
              final active = _icmpActivePreset == label;
              return GestureDetector(
                onTap: () => _applyIcmpPreset(label),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: active
                        ? ZbxPalette.rxBlue.withValues(alpha: 0.18)
                        : ZbxT.rim(context).withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: active ? ZbxPalette.rxBlue : ZbxT.rim(context),
                      width: active ? 1.5 : 1,
                    ),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: active
                          ? ZbxPalette.rxBlue
                          : ZbxT.textSec(context),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        _IcmpCombinedChart(
          latencyItems: graphItems,
          lossItems: lossItems,
          fromCtrl: _fromCtrl,
          toCtrl: _toCtrl,
        ),
      ],
    ];
  }

  Widget _legendDot(Color c) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(color: c, shape: BoxShape.circle),
  );

  // ═══════════════════════════════════════════════════════════════════════════
  // Generic / Zabbix-Internal Dashboard (shows raw item values, no Rx/Tx mapping)
  // ═══════════════════════════════════════════════════════════════════════════
  List<Widget> _buildGenericBody() {
    // Group items by their key prefix (e.g. "system", "agent", "vm")
    final groups = <String, List<dynamic>>{};
    for (final item in _items) {
      final key = (item['key_'] ?? '').toString();
      final prefix = key.contains('[')
          ? key.substring(0, key.indexOf('['))
          : (key.contains('.') ? key.split('.').take(2).join('.') : key);
      final group = prefix.isEmpty ? 'Other' : prefix;
      groups.putIfAbsent(group, () => []).add(item);
    }

    if (groups.isEmpty) {
      return [_buildNoData('No items to display')];
    }

    final widgets = <Widget>[];
    widgets.add(_buildSection('PROPERTIES', Icons.list_alt_outlined));
    widgets.add(const SizedBox(height: 10));

    // Numeric items: show as a graph
    final numericItems = _items.where(isNumericItem).toList();
    if (numericItems.isNotEmpty && numericItems.length <= 12) {
      widgets.add(
        InteractiveLineGraph(
          selectedNumericItems: numericItems,
          externalFromController: _fromCtrl,
          externalToController: _toCtrl,
          showControls: true,
          mode: GraphRenderMode.line,
          backgroundColor: ZbxT.panel(context),
          foregroundColor: ZbxT.textPri(context),
          chartHeight: 200,
          title: 'Metrics History',
        ),
      );
      widgets.add(const SizedBox(height: 16));
    }

    // All items as name/value table — use actual Zabbix name, no label remapping
    widgets.add(_buildSection('CURRENT VALUES', Icons.data_array_outlined));
    widgets.add(const SizedBox(height: 8));
    widgets.add(
      Container(
        decoration: BoxDecoration(
          color: ZbxT.card(context),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: ZbxT.rim(context)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: _items.asMap().entries.map((e) {
            final item = e.value;
            final isLast = e.key == _items.length - 1;
            // Use Zabbix item name directly — no Rx/Tx remapping
            final name = (item['name'] ?? item['key_'] ?? 'Unknown')
                .toString()
                .replaceAll(RegExp(r'\[.*?\]'), '')
                .trim();
            final rawVal = (item['lastvalue'] ?? '—').toString().trim();
            final units = (item['units'] ?? '').toString().trim();
            final display = units.isEmpty ? rawVal : '$rawVal $units';

            // Colour-code value: try numeric first
            Color valColor = ZbxT.textMono(context);
            if (rawVal.toLowerCase() == 'up' || rawVal == '1') {
              valColor = _upGreen;
            }
            if (rawVal.toLowerCase() == 'down' || rawVal == '0') {
              valColor = _downRed;
            }

            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 9,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 3,
                        height: 18,
                        margin: const EdgeInsets.only(right: 10, top: 1),
                        decoration: BoxDecoration(
                          color: valColor.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          name,
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
                          color: valColor,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!isLast) Container(height: 1, color: ZbxT.rim(context)),
              ],
            );
          }).toList(),
        ),
      ),
    );

    return widgets;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Monitor / Script-Health Dashboard
  // ═══════════════════════════════════════════════════════════════════════════
  List<Widget> _buildMonitorBody() {
    dynamic itemForKey(String keyPart) => _findByKeyPart(keyPart);

    final lagItem = itemForKey('collector.lag_s');
    final lastMsItem = itemForKey('collector.last_ms');
    final okItem = itemForKey('collector.ok_count');
    final totalItem = itemForKey('collector.total_count');
    final rateItem = itemForKey('collector.success_rate');
    final statusItem = itemForKey('collector.status');
    final intervalItem = itemForKey('collector.interval_s');
    final pollDurItem = itemForKey('monitor.device.poll_duration');
    final devStatus = itemForKey('monitor.device.status');

    final statusVal = (statusItem?['lastvalue'] ?? '').toString().trim();
    final isRunning =
        statusVal.toLowerCase() == 'running' ||
        statusVal.toLowerCase() == 'ok' ||
        statusVal == '1';

    String valueText(dynamic i, {String? suffix}) {
      if (i == null) return '—';
      final v = (i['lastvalue'] ?? '—').toString();
      if (suffix != null && v != '—') return '$v $suffix';
      return v;
    }

    String formatMs(dynamic i) {
      if (i == null) return '—';
      final n = itemNumericValue(i);
      if (n == null) return (i['lastvalue'] ?? '—').toString();
      return n >= 1000
          ? '${(n / 1000).toStringAsFixed(2)}s'
          : '${n.toStringAsFixed(0)}ms';
    }

    final lagItems = _items.where((i) {
      final k = (i['key_'] ?? '').toString().toLowerCase();
      return (k.contains('collector.lag_s') ||
              k.contains('collector.last_ms') ||
              k.contains('monitor.device.poll_duration')) &&
          isNumericItem(i);
    }).toList();

    final rateItems = _items.where((i) {
      final k = (i['key_'] ?? '').toString().toLowerCase();
      return k.contains('collector.success_rate') && isNumericItem(i);
    }).toList();

    return [
      // Status pill
      if (statusItem != null || devStatus != null) ...[
        _buildSection('COLLECTOR STATUS', Icons.monitor_heart_outlined),
        const SizedBox(height: 8),
        _StatusPill(
          label: 'Collector',
          status: isRunning ? 'RUNNING' : statusVal.toUpperCase(),
          color: isRunning ? _upGreen : _downRed,
        ),
        const SizedBox(height: 14),
      ],

      // Performance tiles
      _buildSection('PERFORMANCE', Icons.speed),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: _MetricTile(
              label: 'Last Poll',
              value: formatMs(lastMsItem),
              unit: '',
              color: _rxBlue,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _MetricTile(
              label: 'Lag',
              value: valueText(lagItem),
              unit: 's',
              color: lagItem != null && (itemNumericValue(lagItem) ?? 0) > 5
                  ? _warnAmb
                  : _txGreen,
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: _MetricTile(
              label: 'Success Rate',
              value: rateItem != null
                  ? (itemNumericValue(rateItem) ?? 0).toStringAsFixed(1)
                  : '—',
              unit: '%',
              color: _monOk,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _MetricTile(
              label: 'Interval',
              value: valueText(intervalItem),
              unit: 's',
              color: ZbxT.textSec(context),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: _MetricTile(
              label: 'Ok Count',
              value: valueText(okItem),
              unit: '',
              color: _monOk,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _MetricTile(
              label: 'Total',
              value: valueText(totalItem),
              unit: '',
              color: ZbxT.textSec(context),
            ),
          ),
        ],
      ),

      // Poll duration (device level)
      if (pollDurItem != null) ...[
        const SizedBox(height: 8),
        _MetricTile(
          label: 'Poll Duration',
          value: formatMs(pollDurItem),
          unit: '',
          color: _rxBlue,
          fullWidth: true,
        ),
      ],

      // Lag + poll time graph
      if (lagItems.isNotEmpty) ...[
        const SizedBox(height: 16),
        _buildSection('TIMING HISTORY', Icons.show_chart),
        const SizedBox(height: 8),
        InteractiveLineGraph(
          selectedNumericItems: lagItems,
          externalFromController: _fromCtrl,
          externalToController: _toCtrl,
          showControls: true,
          mode: GraphRenderMode.line,
          backgroundColor: ZbxT.panel(context),
          foregroundColor: ZbxT.textPri(context),
          chartHeight: 200,
          title: 'Collector Timing',
        ),
      ],

      // Success rate graph
      if (rateItems.isNotEmpty) ...[
        const SizedBox(height: 12),
        InteractiveLineGraph(
          selectedNumericItems: rateItems,
          externalFromController: _fromCtrl,
          externalToController: _toCtrl,
          showControls: false,
          mode: GraphRenderMode.line,
          backgroundColor: ZbxT.panel(context),
          foregroundColor: ZbxT.textPri(context),
          chartHeight: 140,
          title: 'Success Rate %',
        ),
      ],
    ];
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Network Interface Dashboard (BNG / PE)
  // ═══════════════════════════════════════════════════════════════════════════

  // ═══════════════════════════════════════════════════════════════════════════
  // Storage / System Health Dashboard
  // ═══════════════════════════════════════════════════════════════════════════
  List<Widget> _buildStorageBody() {
    final widgets = <Widget>[];

    // ── Disk space ───────────────────────────────────────────────────────────
    final diskItems = _items
        .where((i) => (i['key_'] ?? '').toString().toLowerCase().startsWith('vfs.fs.size'))
        .toList();

    if (diskItems.isNotEmpty) {
      final fsByPath = <String, Map<String, dynamic>>{};
      for (final item in diskItems) {
        final key = (item['key_'] ?? '').toString();
        final m = RegExp(
          r'vfs\.fs\.size\[([^,\]]+)[,\]]',
          caseSensitive: false,
        ).firstMatch(key);
        if (m == null) continue;
        final path = m.group(1) ?? '/';
        final kl = key.toLowerCase();
        final kind = kl.contains(',pfree')
            ? 'pfree'
            : kl.contains(',pused')
            ? 'pused'
            : kl.contains(',free')
            ? 'free'
            : kl.contains(',used')
            ? 'used'
            : kl.contains(',total')
            ? 'total'
            : 'other';
        fsByPath.putIfAbsent(path, () => {})[kind] = item;
      }

      if (fsByPath.isNotEmpty) {
        widgets.add(_buildSection('DISK SPACE', Icons.storage_outlined));
        widgets.add(const SizedBox(height: 10));

        for (final entry in fsByPath.entries) {
          final path = entry.key;
          final parts = entry.value;

          double? usedPct;
          String usedStr = '';
          String totalStr = '';

          if (parts['pfree'] != null) {
            final pf = itemNumericValue(parts['pfree']);
            if (pf != null) usedPct = (100.0 - pf).clamp(0.0, 100.0);
          } else if (parts['pused'] != null) {
            usedPct = (itemNumericValue(parts['pused']) ?? 0.0).clamp(0.0, 100.0);
          } else if (parts['used'] != null && parts['total'] != null) {
            final u = itemNumericValue(parts['used']);
            final t = itemNumericValue(parts['total']);
            if (u != null && t != null && t > 0) {
              usedPct = ((u / t) * 100).clamp(0.0, 100.0);
            }
          }
          if (parts['used'] != null) usedStr = _fmtBytes(itemNumericValue(parts['used']));
          if (parts['total'] != null) totalStr = _fmtBytes(itemNumericValue(parts['total']));

          final pct = usedPct ?? 0.0;
          final barColor = pct >= 90 ? _downRed : pct >= 75 ? _warnAmb : _txGreen;

          widgets.add(
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: ZbxT.card(context),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: ZbxT.rim(context)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.folder_outlined, size: 13, color: ZbxT.textSec(context)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          path,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: ZbxT.textPri(context),
                          ),
                        ),
                      ),
                      Text(
                        usedPct != null ? '${pct.toStringAsFixed(1)}%' : '—',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: barColor,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: usedPct != null ? pct / 100 : 0,
                      minHeight: 7,
                      backgroundColor: ZbxT.rim(context),
                      valueColor: AlwaysStoppedAnimation<Color>(barColor),
                    ),
                  ),
                  if (usedStr.isNotEmpty || totalStr.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      [
                        if (usedStr.isNotEmpty) '$usedStr used',
                        if (totalStr.isNotEmpty) '$totalStr total',
                      ].join(' / '),
                      style: TextStyle(fontSize: 11, color: ZbxT.textSec(context)),
                    ),
                  ],
                ],
              ),
            ),
          );
        }
        widgets.add(const SizedBox(height: 6));
      }
    }

    // ── CPU ──────────────────────────────────────────────────────────────────
    final cpuUtil = _items.firstWhere(
      (i) => (i['key_'] ?? '').toString().toLowerCase().startsWith('system.cpu.util'),
      orElse: () => null,
    );
    final cpuLoad = _items.firstWhere(
      (i) => (i['key_'] ?? '').toString().toLowerCase().startsWith('system.cpu.load'),
      orElse: () => null,
    );

    if (cpuUtil != null || cpuLoad != null) {
      widgets.add(_buildSection('CPU', Icons.memory_outlined));
      widgets.add(const SizedBox(height: 10));
      final cpuRow = <Widget>[];

      if (cpuUtil != null) {
        final pct = (itemNumericValue(cpuUtil) ?? 0).clamp(0.0, 100.0);
        final c = pct >= 90 ? _downRed : pct >= 75 ? _warnAmb : _rxBlue;
        cpuRow.add(Expanded(
          child: _buildGaugeTile('CPU Usage', '${pct.toStringAsFixed(1)}%', pct / 100, c, Icons.speed_outlined),
        ));
      }
      if (cpuLoad != null) {
        final load = itemNumericValue(cpuLoad);
        cpuRow.add(Expanded(
          child: _buildStatTile('Load Avg', load != null ? load.toStringAsFixed(2) : '—', Icons.show_chart, _rxBlue),
        ));
      }

      if (cpuRow.isNotEmpty) {
        final withGaps = <Widget>[];
        for (var j = 0; j < cpuRow.length; j++) {
          withGaps.add(cpuRow[j]);
          if (j < cpuRow.length - 1) withGaps.add(const SizedBox(width: 10));
        }
        widgets.add(Row(children: withGaps));
        widgets.add(const SizedBox(height: 12));
      }
    }

    // ── Memory ───────────────────────────────────────────────────────────────
    final memAvail = _items.firstWhere(
      (i) {
        final k = (i['key_'] ?? '').toString().toLowerCase();
        return k.startsWith('vm.memory.') && (k.contains('available') || k.contains('avail'));
      },
      orElse: () => null,
    );
    final memTotal = _items.firstWhere(
      (i) {
        final k = (i['key_'] ?? '').toString().toLowerCase();
        return k.startsWith('vm.memory.') && k.contains('total');
      },
      orElse: () => null,
    );
    final memUsed = _items.firstWhere(
      (i) {
        final k = (i['key_'] ?? '').toString().toLowerCase();
        return k.startsWith('vm.memory.') && (k.contains(',used') || k.contains('[used'));
      },
      orElse: () => null,
    );

    if (memAvail != null || memUsed != null || memTotal != null) {
      final avail = itemNumericValue(memAvail);
      final total = itemNumericValue(memTotal);
      final used  = itemNumericValue(memUsed);

      double? usedPct;
      if (avail != null && total != null && total > 0) {
        usedPct = ((1 - avail / total) * 100).clamp(0.0, 100.0);
      } else if (used != null && total != null && total > 0) {
        usedPct = ((used / total) * 100).clamp(0.0, 100.0);
      }

      final barColor = (usedPct ?? 0) >= 90
          ? _downRed
          : (usedPct ?? 0) >= 75
          ? _warnAmb
          : _rxBlue;

      widgets.add(_buildSection('MEMORY', Icons.memory));
      widgets.add(const SizedBox(height: 10));
      widgets.add(
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: ZbxT.card(context),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: ZbxT.rim(context)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'RAM Usage',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: ZbxT.textPri(context),
                      ),
                    ),
                  ),
                  Text(
                    usedPct != null ? '${usedPct.toStringAsFixed(1)}%' : '—',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: barColor),
                  ),
                ],
              ),
              if (usedPct != null) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: usedPct / 100,
                    minHeight: 7,
                    backgroundColor: ZbxT.rim(context),
                    valueColor: AlwaysStoppedAnimation<Color>(barColor),
                  ),
                ),
              ],
              if (avail != null || total != null) ...[
                const SizedBox(height: 6),
                Text(
                  [
                    if (avail != null) '${_fmtBytes(avail)} free',
                    if (total != null) '${_fmtBytes(total)} total',
                  ].join(' / '),
                  style: TextStyle(fontSize: 11, color: ZbxT.textSec(context)),
                ),
              ],
            ],
          ),
        ),
      );
      widgets.add(const SizedBox(height: 12));
    }

    // ── Metrics history graph ─────────────────────────────────────────────────
    final numericItems = _items.where(isNumericItem).take(8).toList();
    if (numericItems.isNotEmpty) {
      widgets.add(_buildSection('METRICS HISTORY', Icons.show_chart));
      widgets.add(const SizedBox(height: 10));
      widgets.add(InteractiveLineGraph(
        selectedNumericItems: numericItems,
        externalFromController: _fromCtrl,
        externalToController: _toCtrl,
        showControls: true,
        mode: GraphRenderMode.line,
        backgroundColor: ZbxT.panel(context),
        foregroundColor: ZbxT.textPri(context),
        chartHeight: 200,
        title: 'System Metrics',
      ));
      widgets.add(const SizedBox(height: 16));
    }

    // ── Current values table ─────────────────────────────────────────────────
    widgets.add(_buildSection('CURRENT VALUES', Icons.data_array_outlined));
    widgets.add(const SizedBox(height: 8));
    widgets.add(_buildItemTable(_items));

    return widgets;
  }

  Widget _buildGaugeTile(String label, String valueStr, double fraction, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ZbxT.card(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZbxT.rim(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 13, color: ZbxT.textSec(context)),
              const SizedBox(width: 5),
              Expanded(
                child: Text(label, style: TextStyle(fontSize: 11, color: ZbxT.textSec(context))),
              ),
              Text(valueStr, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: color)),
            ],
          ),
          const SizedBox(height: 7),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: fraction.clamp(0.0, 1.0),
              minHeight: 5,
              backgroundColor: ZbxT.rim(context),
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatTile(String label, String valueStr, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ZbxT.card(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZbxT.rim(context)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 14, color: ZbxT.textSec(context)),
          const SizedBox(width: 8),
          Expanded(child: Text(label, style: TextStyle(fontSize: 11, color: ZbxT.textSec(context)))),
          Text(valueStr, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: color)),
        ],
      ),
    );
  }

  Widget _buildItemTable(List<dynamic> items) {
    if (items.isEmpty) return _buildNoData('No items to display');
    return Container(
      decoration: BoxDecoration(
        color: ZbxT.card(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZbxT.rim(context)),
      ),
      child: Column(
        children: items.asMap().entries.map((e) {
          final item   = e.value;
          final isLast = e.key == items.length - 1;
          final name   = (item['name'] ?? item['key_'] ?? 'Unknown')
              .toString()
              .replaceAll(RegExp(r'\[.*?\]'), '')
              .trim();
          final rawVal = (item['lastvalue'] ?? '—').toString().trim();
          final units  = (item['units'] ?? '').toString().trim();
          final display = units.isEmpty ? rawVal : '$rawVal $units';

          Color valColor = ZbxT.textMono(context);
          if (rawVal.toLowerCase() == 'up' || rawVal == '1') valColor = _upGreen;
          if (rawVal.toLowerCase() == 'down' || rawVal == '0') valColor = _downRed;

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 3,
                      height: 18,
                      margin: const EdgeInsets.only(right: 10, top: 1),
                      decoration: BoxDecoration(
                        color: valColor.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Expanded(child: Text(name, style: TextStyle(fontSize: 12, color: ZbxT.textMono(context)))),
                    const SizedBox(width: 8),
                    Text(display, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: valColor)),
                  ],
                ),
              ),
              if (!isLast) Container(height: 1, color: ZbxT.rim(context)),
            ],
          );
        }).toList(),
      ),
    );
  }

  String _fmtBytes(double? v) {
    if (v == null) return '—';
    if (v >= 1e12) return '${(v / 1e12).toStringAsFixed(2)} TB';
    if (v >= 1e9)  return '${(v / 1e9).toStringAsFixed(2)} GB';
    if (v >= 1e6)  return '${(v / 1e6).toStringAsFixed(2)} MB';
    if (v >= 1e3)  return '${(v / 1e3).toStringAsFixed(2)} KB';
    return '${v.toStringAsFixed(0)} B';
  }

  List<Widget> _buildNetworkBody() {
    // Guard: if there are no genuine traffic items, fall back to generic view.
    if (!_items.any(_isTrafficItem)) {
      return [
        _buildSection('PROPERTIES', Icons.list_alt_outlined),
        const SizedBox(height: 10),
        _buildNoData('No traffic data found for this item set.'),
        const SizedBox(height: 16),
        _buildSection('CURRENT VALUES', Icons.data_array_outlined),
        const SizedBox(height: 8),
        _buildItemTable(_items),
      ];
    }
    final rxItem =
        _findTrafficItem(rx: true) ??
        _find(['rx', 'traffic']) ??
        _find(['in', 'traffic']);
    final txItem =
        _findTrafficItem(rx: false) ??
        _find(['tx', 'traffic']) ??
        _find(['out', 'traffic']);
    final adminItem = _findByKeyPart('.admin[');
    final operItem = _findByKeyPart('.oper[');
    final rxPower = _findByKeyPart('.rx_power[');
    final arpCnt = _items.firstWhere(
      (i) => (i['key_'] ?? '').toString().toLowerCase().contains('.arp.count['),
      orElse: () => null,
    );
    final arpIpItem = _items.firstWhere(
      (i) => (i['key_'] ?? '').toString().toLowerCase().contains('.arp.ip['),
      orElse: () => null,
    );

    final arpIps = <String>{};
    if (arpIpItem != null) {
      RegExp(
        r'\b(?:\d{1,3}\.){3}\d{1,3}\b',
      ).allMatches((arpIpItem['lastvalue'] ?? '').toString()).forEach((m) {
        if (m.group(0) != null) arpIps.add(m.group(0)!);
      });
    }

    final adminStatus = _statusText(adminItem, admin: true);
    final operStatus = _statusText(operItem);
    final rxSplit = _splitTraffic(rxItem);
    final txSplit = _splitTraffic(txItem);
    final rtItems = _rxTxItems();
    final errItems = _networkErrDropItems();
    final utilItems = _utilizationItems();

    final desc = _firstTagValue(const [
      'Description',
      'desc',
      'ifdesc',
      'if_description',
    ], preferredItem: adminItem);
    final cust = _firstTagValue(const [
      'Customer',
      'cust',
      'customer_name',
    ], preferredItem: arpCnt);
    final vrf = _firstTagValue(const [
      'VRF',
      'vrf',
      'vrfname',
      'vrf_name',
    ], preferredItem: arpCnt);

    int errCount = 0, dropCount = 0;
    for (final i in errItems) {
      final hay =
          '${(i["name"] ?? "").toString().toLowerCase()} ${(i["key_"] ?? "").toString().toLowerCase()}';
      final n = itemNumericValue(i)?.toInt() ?? 0;
      if (hay.contains('error') || hay.contains('in_err')) errCount += n;
      if (hay.contains('drop') || hay.contains('in_drop')) dropCount += n;
    }

    return [
      // Status pills
      if (adminItem != null || operItem != null) ...[
        Row(
          children: [
            if (adminItem != null)
              Expanded(
                child: _StatusPill(
                  label: 'Interface',
                  status: adminStatus,
                  color: _statusColor(adminStatus),
                ),
              ),
            if (adminItem != null && operItem != null)
              const SizedBox(width: 10),
            if (operItem != null)
              Expanded(
                child: _StatusPill(
                  label: 'Protocol',
                  status: operStatus,
                  color: _statusColor(operStatus),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
      ],

      // Traffic tiles with embedded utilization gauges + tap-to-graph
      Row(
        children: [
          Expanded(
            child: _TrafficTileWithGauge(
              label: 'Rx Traffic',
              val: rxSplit.val,
              unit: rxSplit.unit,
              color: _rxBlue,
              icon: Icons.arrow_downward_rounded,
              utilPct: _utilPct(utilItems, rx: true),
              utilItems: utilItems.where((i) {
                final k = (i['key_'] ?? '').toString().toLowerCase();
                return k.contains('in_util') || k.contains('rx_util');
              }).toList(),
              fromCtrl: _fromCtrl,
              toCtrl: _toCtrl,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _TrafficTileWithGauge(
              label: 'Tx Traffic',
              val: txSplit.val,
              unit: txSplit.unit,
              color: _txGreen,
              icon: Icons.arrow_upward_rounded,
              utilPct: _utilPct(utilItems, rx: false),
              utilItems: utilItems.where((i) {
                final k = (i['key_'] ?? '').toString().toLowerCase();
                return k.contains('out_util') || k.contains('tx_util');
              }).toList(),
              fromCtrl: _fromCtrl,
              toCtrl: _toCtrl,
            ),
          ),
        ],
      ),

      // Rx Error + Drop counts — always visible
      if (errCount > 0 || dropCount > 0 || errItems.isNotEmpty) ...[
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _CounterTile(
                label: 'Rx Errors',
                count: errCount,
                okColor: _upGreen,
                warnColor: _downRed,
                icon: Icons.close_rounded,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _CounterTile(
                label: 'Rx Drops',
                count: dropCount,
                okColor: _upGreen,
                warnColor: _warnAmb,
                icon: Icons.arrow_drop_down_circle_outlined,
              ),
            ),
          ],
        ),
      ],

      // Rx Power (BNG-specific)
      if (rxPower != null) ...[
        const SizedBox(height: 8),
        _MetricTile(
          label: 'Rx Power',
          value:
              itemNumericValue(rxPower)?.toStringAsFixed(2) ??
              (rxPower['lastvalue'] ?? '—').toString(),
          unit: 'dBm',
          color: const Color(0xFFCE93D8),
          fullWidth: true,
        ),
      ],

      // PE Metadata: Description, Customer, VRF
      if (desc.isNotEmpty || cust.isNotEmpty || vrf.isNotEmpty) ...[
        const SizedBox(height: 16),
        _buildMetaRow(desc: desc, cust: cust, vrf: vrf),
      ],

      // Traffic history graph
      const SizedBox(height: 16),
      _buildSection('TRAFFIC HISTORY', Icons.show_chart),
      const SizedBox(height: 8),
      if (rtItems.isNotEmpty)
        InteractiveLineGraph(
          selectedNumericItems: rtItems,
          externalFromController: _fromCtrl,
          externalToController: _toCtrl,
          showControls: true,
          mode: GraphRenderMode.line,
          backgroundColor: ZbxT.panel(context),
          foregroundColor: ZbxT.textPri(context),
          chartHeight: 240,
          title: 'Traffic (bps)',
        )
      else
        _buildNoData('No traffic history available'),

      // Errors & drops as bar graph
      if (errItems.isNotEmpty) ...[
        const SizedBox(height: 16),
        _buildSection('ERRORS & DROPS', Icons.warning_amber_rounded),
        const SizedBox(height: 8),
        _ErrBarChart(items: errItems, fromCtrl: _fromCtrl, toCtrl: _toCtrl),
      ],

      // ARP
      if (arpCnt != null || arpIps.isNotEmpty) ...[
        const SizedBox(height: 16),
        _buildSection('ARP DISCOVERY', Icons.radar),
        const SizedBox(height: 8),
        _ArpCard(
          count: arpCnt != null
              ? (itemNumericValue(arpCnt)?.toInt() ??
                    int.tryParse((arpCnt['lastvalue'] ?? '0').toString()) ??
                    arpIps.length)
              : arpIps.length,
          ips: arpIps,
        ),
      ],

      // Swipe hint
      if (widget.interfaceOrder != null &&
          (widget.interfaceOrder?.length ?? 0) > 1)
        Padding(
          padding: const EdgeInsets.only(top: 28),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.swipe,
                size: 13,
                color: ZbxT.textSec(context).withValues(alpha: 0.4),
              ),
              const SizedBox(width: 6),
              Text(
                'Swipe for ${widget.interfaceOrder!.length} interfaces',
                style: TextStyle(
                  fontSize: 10,
                  color: ZbxT.textSec(context).withValues(alpha: 0.4),
                ),
              ),
            ],
          ),
        ),
    ];
  }

  // ── Shared UI helpers ─────────────────────────────────────────────────────────
  Widget _buildSection(String title, IconData icon) => Row(
    children: [
      Icon(icon, size: 12, color: ZbxT.textSec(context)),
      const SizedBox(width: 6),
      Text(
        title,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: ZbxT.textSec(context),
          letterSpacing: 0.8,
        ),
      ),
      const SizedBox(width: 8),
      Expanded(child: Container(height: 1, color: ZbxT.rim(context))),
    ],
  );

  Widget _buildHostRow() => Row(
    children: [
      Container(
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(
          color: _rxBlue.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(Icons.dns_outlined, size: 14, color: _rxBlue),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.hostName,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: ZbxT.textPri(context),
              ),
            ),
            Text(
              widget.hostIp,
              style: TextStyle(
                fontSize: 11,
                color: ZbxT.textMono(context),
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _buildErrorBanner() => Container(
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
            _error,
            style: const TextStyle(fontSize: 11, color: _downRed),
          ),
        ),
      ],
    ),
  );

  Widget _buildNoData(String msg) => Container(
    height: 60,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: ZbxT.card(context),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: ZbxT.rim(context)),
    ),
    child: Text(
      msg,
      style: TextStyle(fontSize: 11, color: ZbxT.textSec(context)),
    ),
  );

  Widget _buildMetaRow({
    required String desc,
    required String cust,
    required String vrf,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section label
        _buildSection('INTERFACE DETAILS', Icons.info_outline),
        const SizedBox(height: 8),
        // Three individual chips — only shown if non-empty
        if (desc.isNotEmpty)
          _PEMetaTile(
            icon: Icons.description_outlined,
            label: 'Description',
            value: desc,
            color: const Color(0xFF7EB8F7),
          ),
        if (desc.isNotEmpty) const SizedBox(height: 8),
        if (cust.isNotEmpty)
          _PEMetaTile(
            icon: Icons.business_outlined,
            label: 'Customer',
            value: cust,
            color: _txGreen,
          ),
        if (cust.isNotEmpty) const SizedBox(height: 8),
        if (vrf.isNotEmpty)
          _PEMetaTile(
            icon: Icons.lan_outlined,
            label: 'VRF',
            value: vrf,
            color: const Color(0xFFCE93D8),
          ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Shared sub-widgets
// ═══════════════════════════════════════════════════════════════════════════════

// ─── Traffic tile: circular arc utilization gauge (reference-image style) ────────
class _TrafficTileWithGauge extends StatelessWidget {
  final String label, val, unit;
  final Color color;
  final IconData icon;
  final double? utilPct; // 0–100

  const _TrafficTileWithGauge({
    required this.label,
    required this.val,
    required this.unit,
    required this.color,
    required this.icon,
    this.utilPct,
    // Unused params kept for call-site compat
    List<dynamic> utilItems = const [],
    TextEditingController? fromCtrl,
    TextEditingController? toCtrl,
  });

  static Color _gaugeColor(double pct) {
    if (pct <= 60) return ZbxPalette.txGreen;
    if (pct <= 75) return const Color(0xFFFFD54F);
    if (pct <= 90) return const Color(0xFFFFAB40);
    return const Color(0xFFEF5350);
  }

  @override
  Widget build(BuildContext context) {
    final pct = utilPct?.clamp(0.0, 100.0);
    final gaugeColor = pct != null ? _gaugeColor(pct) : color;
    final fraction = (pct ?? 0) / 100.0;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ZbxT.card(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: gaugeColor.withValues(alpha: 0.25)),
      ),
      child: Column(
        children: [
          // ── Label row ──────────────────────────────────────────────────────
          Row(
            children: [
              Icon(icon, size: 11, color: color),
              const SizedBox(width: 4),
              Text(
                label.toUpperCase(),
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  color: color,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // ── Circular arc gauge ─────────────────────────────────────────────
          SizedBox(
            width: double.infinity,
            child: AspectRatio(
              aspectRatio: 1,
              child: CustomPaint(
                painter: _ArcGaugePainter(
                  fraction: fraction,
                  trackColor: ZbxT.rim(context),
                  fillColor: gaugeColor,
                ),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: RichText(
                          text: TextSpan(
                            children: [
                              TextSpan(
                                text: val,
                                style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w800,
                                  color: color,
                                  height: 1,
                                ),
                              ),
                              TextSpan(
                                text: '\n$unit',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: color.withValues(alpha: 0.7),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (pct != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            '${pct.toStringAsFixed(1)}%',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              color: gaugeColor,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Arc gauge painter ─────────────────────────────────────────────────────────
class _ArcGaugePainter extends CustomPainter {
  final double fraction; // 0.0–1.0
  final Color trackColor;
  final Color fillColor;

  const _ArcGaugePainter({
    required this.fraction,
    required this.trackColor,
    required this.fillColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const startAngle = 3.14159 * 0.65; // ~117° (bottom-left)
    const sweepFull = 3.14159 * 1.7; // 306° total arc
    final strokeWidth = size.width * 0.09;
    final rect = Rect.fromCircle(
      center: Offset(size.width / 2, size.height / 2),
      radius: (size.width - strokeWidth) / 2,
    );

    final trackPaint = Paint()
      ..color = trackColor
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, startAngle, sweepFull, false, trackPaint);

    if (fraction > 0) {
      final fillPaint = Paint()
        ..color = fillColor
        ..strokeWidth = strokeWidth
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      // Glow
      final glowPaint = Paint()
        ..color = fillColor.withValues(alpha: 0.25)
        ..strokeWidth = strokeWidth * 1.8
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
      canvas.drawArc(rect, startAngle, sweepFull * fraction, false, glowPaint);
      canvas.drawArc(rect, startAngle, sweepFull * fraction, false, fillPaint);
    }
  }

  @override
  bool shouldRepaint(_ArcGaugePainter old) =>
      old.fraction != fraction || old.fillColor != fillColor;
}

// ─── Error/Drop bar chart (real fl_chart BarChart) ──────────────────────────
class _ErrBarChart extends StatefulWidget {
  final List<dynamic> items;
  final TextEditingController fromCtrl;
  final TextEditingController toCtrl;
  const _ErrBarChart({
    required this.items,
    required this.fromCtrl,
    required this.toCtrl,
  });
  @override
  State<_ErrBarChart> createState() => _ErrBarChartState();
}

class _ErrBarChartState extends State<_ErrBarChart> {
  List<BarChartGroupData> _groups = [];
  double _maxY = 1;
  bool _loading = true;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    widget.fromCtrl.addListener(_onRange);
    widget.toCtrl.addListener(_onRange);
    _load();
  }

  @override
  void dispose() {
    widget.fromCtrl.removeListener(_onRange);
    widget.toCtrl.removeListener(_onRange);
    _debounce?.cancel();
    super.dispose();
  }

  void _onRange() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    final rimColor = ZbxT.rim(context);
    final from = parseTimeInputToEpoch(widget.fromCtrl.text.trim());
    final to = parseTimeInputToEpoch(widget.toCtrl.text.trim());
    if (from == null || to == null || from >= to) return;

    final ids = widget.items
        .where(isNumericItem)
        .map((i) => (i['itemid'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toList();
    if (ids.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    if (mounted) setState(() => _loading = true);
    try {
      final data = await ApiClient.fetchHistory(
        itemIds: ids,
        from: from,
        to: to,
      );
      final pts = data['points'];
      if (pts is! List) {
        if (mounted) setState(() => _loading = false);
        return;
      }

      // Bucket into ~40 bars across the time span
      final span = to - from;
      final bucket = (span / 40).ceil().clamp(60, 86400);
      final buckets = <int, double>{};
      for (final p in pts) {
        final x = (p['clock'] is num)
            ? (p['clock'] as num).toInt()
            : int.tryParse((p['clock'] ?? '').toString()) ?? 0;
        final y = (p['value'] is num)
            ? (p['value'] as num).toDouble()
            : double.tryParse((p['value'] ?? '').toString()) ?? 0.0;
        if (x == 0) continue;
        final b = (x ~/ bucket) * bucket;
        buckets[b] = (buckets[b] ?? 0) + y;
      }

      if (buckets.isEmpty) {
        if (mounted) {
          setState(() {
            _loading = false;
            _groups = [];
          });
        }
        return;
      }

      final sorted = buckets.keys.toList()..sort();
      double maxY = 0;
      final groups = <BarChartGroupData>[];
      for (int i = 0; i < sorted.length; i++) {
        final v = buckets[sorted[i]]!;
        if (v > maxY) maxY = v;
        groups.add(
          BarChartGroupData(
            x: i,
            barRods: [
              BarChartRodData(
                toY: v,
                color: v > 0 ? _downRed.withValues(alpha: 0.75) : rimColor,
                width: (sorted.length < 20) ? 8 : 4,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(2),
                  topRight: Radius.circular(2),
                ),
              ),
            ],
          ),
        );
      }

      if (!mounted) return;
      setState(() {
        _groups = groups;
        _maxY = maxY > 0 ? maxY * 1.2 : 1;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        height: 90,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: ZbxPalette.rxBlue,
            ),
          ),
        ),
      );
    }
    if (_groups.isEmpty) {
      return SizedBox(
        height: 60,
        child: Center(
          child: Text(
            'No error data',
            style: TextStyle(fontSize: 11, color: ZbxT.textSec(context)),
          ),
        ),
      );
    }

    return SizedBox(
      height: 120,
      child: BarChart(
        BarChartData(
          maxY: _maxY,
          minY: 0,
          barGroups: _groups,
          gridData: FlGridData(
            show: true,
            getDrawingHorizontalLine: (_) =>
                FlLine(color: ZbxT.rim(context), strokeWidth: 0.5),
            getDrawingVerticalLine: (_) =>
                FlLine(color: ZbxT.rim(context), strokeWidth: 0.5),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
            bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (_) => ZbxT.card(context),
              getTooltipItem: (group, _, rod, _) => BarTooltipItem(
                rod.toY.toStringAsFixed(0),
                const TextStyle(
                  fontSize: 10,
                  color: Color(0xFFEF5350),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── ICMP Combined Chart ─────────────────────────────────────────────────────
/// Single fl_chart canvas with:
///   • Shaded band between min and max latency
///   • Avg latency line (blue) drawn on top
///   • Jitter line (purple, dashed)
///   • Packet loss represented as NEGATIVE bars (red)
class _IcmpCombinedChart extends StatefulWidget {
  final List<dynamic> latencyItems; // avg/min/max/jitter items
  final List<dynamic> lossItems; // loss % items
  final TextEditingController fromCtrl;
  final TextEditingController toCtrl;

  const _IcmpCombinedChart({
    required this.latencyItems,
    required this.lossItems,
    required this.fromCtrl,
    required this.toCtrl,
  });

  @override
  State<_IcmpCombinedChart> createState() => _IcmpCombinedChartState();
}

class _IcmpCombinedChartState extends State<_IcmpCombinedChart> {
  Map<String, List<FlSpot>> _latSeries = {};
  List<FlSpot> _lossSeries = [];
  bool _loading = true;
  String _error = '';
  double _minX = 0, _maxX = 1;
  double _maxLatency = 1;
  double _maxLoss = 0;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    widget.fromCtrl.addListener(_onRangeChanged);
    widget.toCtrl.addListener(_onRangeChanged);
    _loadData();
  }

  @override
  void dispose() {
    widget.fromCtrl.removeListener(_onRangeChanged);
    widget.toCtrl.removeListener(_onRangeChanged);
    _debounce?.cancel();
    super.dispose();
  }

  void _onRangeChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted) _loadData();
    });
  }

  int? _epoch(String text) => parseTimeInputToEpoch(text.trim());

  Future<void> _loadData() async {
    final from = _epoch(widget.fromCtrl.text);
    final to = _epoch(widget.toCtrl.text);
    if (from == null || to == null || from >= to) return;

    final allItems = [...widget.latencyItems, ...widget.lossItems];
    final ids = allItems
        .where(isNumericItem)
        .map((i) => (i['itemid'] ?? '').toString())
        .where((id) => id.isNotEmpty && !id.startsWith('lld-'))
        .toList();
    if (ids.isEmpty) {
      setState(() {
        _loading = false;
      });
      return;
    }

    if (mounted) {
      setState(() {
        _loading = true;
        _error = '';
      });
    }

    try {
      final data = await ApiClient.fetchHistory(
        itemIds: ids,
        from: from,
        to: to,
      );
      final pts = data['points'];
      if (pts is! List) throw Exception('No data');

      final raw = <String, List<FlSpot>>{};
      for (final p in pts) {
        final id = (p['itemid'] ?? '').toString();
        final x = (p['clock'] is num)
            ? (p['clock'] as num).toDouble()
            : double.tryParse((p['clock'] ?? '').toString());
        final y = (p['value'] is num)
            ? (p['value'] as num).toDouble()
            : double.tryParse((p['value'] ?? '').toString());
        if (id.isEmpty || x == null || y == null) continue;
        raw.putIfAbsent(id, () => []).add(FlSpot(x, y));
      }
      for (final e in raw.entries) {
        e.value.sort((a, b) => a.x.compareTo(b.x));
      }

      // Separate latency vs loss
      final lossIds = widget.lossItems
          .map((i) => (i['itemid'] ?? '').toString())
          .toSet();

      double maxLat = 0;
      double maxLoss = 0;
      double minX = double.infinity, maxX = double.negativeInfinity;

      final latSeries = <String, List<FlSpot>>{};
      List<FlSpot> lossSeries = [];

      for (final e in raw.entries) {
        for (final p in e.value) {
          if (p.x < minX) minX = p.x;
          if (p.x > maxX) maxX = p.x;
        }
        if (lossIds.contains(e.key)) {
          lossSeries = e.value;
          maxLoss = e.value.map((s) => s.y).fold(0, (a, b) => a > b ? a : b);
        } else {
          latSeries[e.key] = e.value;
          final m = e.value.map((s) => s.y).fold(0.0, (a, b) => a > b ? a : b);
          if (m > maxLat) maxLat = m;
        }
      }

      if (!mounted) return;
      setState(() {
        _latSeries = latSeries;
        _lossSeries = lossSeries;
        _maxLatency = maxLat > 0 ? maxLat : 1;
        _maxLoss = maxLoss;
        _minX = minX.isFinite ? minX : from.toDouble();
        _maxX = maxX.isFinite ? maxX : to.toDouble();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  // Map itemId → display label
  String _label(String itemId) {
    final item = [...widget.latencyItems, ...widget.lossItems].firstWhere(
      (i) => (i['itemid'] ?? '').toString() == itemId,
      orElse: () => {},
    );
    final k = (item['key_'] ?? '').toString().toLowerCase();
    if (k.contains('avg')) return 'Avg';
    if (k.contains('min')) return 'Min';
    if (k.contains('max')) return 'Max';
    if (k.contains('jitter')) return 'Jitter';
    if (k.contains('loss')) return 'Loss %';
    return (item['name'] ?? itemId).toString();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        height: 280,
        child: Center(
          child: CircularProgressIndicator(
            color: ZbxPalette.rxBlue,
            strokeWidth: 2,
          ),
        ),
      );
    }
    if (_error.isNotEmpty) {
      return Container(
        height: 60,
        alignment: Alignment.center,
        child: Text(
          _error,
          style: const TextStyle(fontSize: 11, color: Color(0xFFEF5350)),
        ),
      );
    }
    if (_latSeries.isEmpty && _lossSeries.isEmpty) {
      return SizedBox(
        height: 80,
        child: Center(
          child: Text(
            'No data for selected range',
            style: TextStyle(fontSize: 12, color: ZbxT.textSec(context)),
          ),
        ),
      );
    }

    // The chart Y range: positive for latency, negative for loss
    // positive Y: 0 → _maxLatency * 1.15
    // negative Y: -_maxLoss * 1.3 → 0  (loss displayed as negative bars)
    final yMin = _maxLoss > 0 ? -(_maxLoss * 1.35) : -5.0;
    final yMax = _maxLatency * 1.15;

    // ── Build line bar data ────────────────────────────────────────────────
    final lineBars = <LineChartBarData>[];

    // Find min/max series for shading
    List<FlSpot>? minSpots, maxSpots, avgSpots, jitterSpots;
    for (final e in _latSeries.entries) {
      final label = _label(e.key);
      if (label == 'Min') minSpots = e.value;
      if (label == 'Max') maxSpots = e.value;
      if (label == 'Avg') avgSpots = e.value;
      if (label == 'Jitter') jitterSpots = e.value;
    }

    // 1. Shaded band: invisible min line with belowBarData filled to max
    if (minSpots != null && minSpots.isNotEmpty) {
      lineBars.add(
        LineChartBarData(
          spots: minSpots,
          isCurved: true,
          barWidth: 0,
          color: Colors.transparent,
          dotData: FlDotData(show: false),
          belowBarData: BarAreaData(show: false),
        ),
      );
    }

    // 2. Max line with shading down to min (betweenBarData doesn't exist in 1.x
    //    so we shade from max line down, then cover with background color from min)
    if (maxSpots != null && maxSpots.isNotEmpty) {
      lineBars.add(
        LineChartBarData(
          spots: maxSpots,
          isCurved: true,
          barWidth: 1.5,
          color: ZbxT.textSec(context).withValues(alpha: 0.5),
          dotData: FlDotData(show: false),
          belowBarData: BarAreaData(
            show: minSpots != null,
            color: ZbxPalette.rxBlue.withValues(alpha: 0.12),
            // Use cutOffY from minSpots interpolation
            applyCutOffY: minSpots != null,
            cutOffY: minSpots != null && minSpots.isNotEmpty
                ? minSpots.map((s) => s.y).reduce((a, b) => a + b) /
                      minSpots
                          .length // approximate cut with average of min
                : 0,
          ),
        ),
      );
    }

    // 3. Avg line — main blue line
    if (avgSpots != null && avgSpots.isNotEmpty) {
      lineBars.add(
        LineChartBarData(
          spots: avgSpots,
          isCurved: true,
          curveSmoothness: 0.3,
          barWidth: 2.5,
          color: ZbxPalette.rxBlue,
          dotData: FlDotData(show: false),
          belowBarData: BarAreaData(show: false),
        ),
      );
    }

    // 4. Jitter line — dashed purple (simulate dash with thin opacity)
    if (jitterSpots != null && jitterSpots.isNotEmpty) {
      lineBars.add(
        LineChartBarData(
          spots: jitterSpots,
          isCurved: false,
          barWidth: 1.5,
          color: const Color(0xFFCE93D8).withValues(alpha: 0.8),
          dotData: FlDotData(show: false),
          dashArray: const [4, 4],
          belowBarData: BarAreaData(show: false),
        ),
      );
    }

    // 5. Loss — fill DOWN from Y=0 to negative values using belowBarData on zero line
    if (_lossSeries.isNotEmpty) {
      final negLoss = _lossSeries.map((s) => FlSpot(s.x, -s.y.abs())).toList();
      // Zero-anchor line: belowBarData fills from 0 down to negLoss
      lineBars.add(
        LineChartBarData(
          spots: _lossSeries.map((s) => FlSpot(s.x, 0.0)).toList(),
          isCurved: false,
          barWidth: 0,
          color: Colors.transparent,
          dotData: FlDotData(show: false),
          belowBarData: BarAreaData(
            show: true,
            color: const Color(0xFFEF5350).withValues(alpha: 0.5),
            applyCutOffY: true,
            cutOffY: 0,
          ),
        ),
      );
      // Thin red line at the bottom of each bar
      lineBars.add(
        LineChartBarData(
          spots: negLoss,
          isCurved: false,
          barWidth: 1.5,
          color: const Color(0xFFEF5350).withValues(alpha: 0.9),
          dotData: FlDotData(show: false),
          belowBarData: BarAreaData(show: false),
        ),
      );
    }

    final bg = ZbxT.panel(context);

    return Container(
      height: 300,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZbxT.rim(context)),
      ),
      padding: const EdgeInsets.fromLTRB(4, 14, 14, 8),
      child: LineChart(
        LineChartData(
          minX: _minX,
          maxX: _maxX,
          minY: yMin,
          maxY: yMax,
          lineBarsData: lineBars,
          // Zero line separator
          extraLinesData: ExtraLinesData(
            horizontalLines: [
              HorizontalLine(
                y: 0,
                color: const Color(0xFF3A5070),
                strokeWidth: 1,
                dashArray: [4, 4],
                label: HorizontalLineLabel(
                  show: true,
                  alignment: Alignment.centerRight,
                  style: TextStyle(fontSize: 9, color: ZbxT.textSec(context)),
                  labelResolver: (_) => '  0',
                ),
              ),
            ],
          ),
          gridData: FlGridData(
            show: true,
            getDrawingHorizontalLine: (_) =>
                FlLine(color: ZbxT.rim(context), strokeWidth: 0.5),
            getDrawingVerticalLine: (_) =>
                FlLine(color: ZbxT.rim(context), strokeWidth: 0.5),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 40,
                getTitlesWidget: (value, meta) {
                  final isLoss = value < 0;
                  final disp = isLoss
                      ? '${(-value).toStringAsFixed(0)}%'
                      : '${value.toStringAsFixed(0)}ms';
                  return SideTitleWidget(
                    meta: meta,
                    child: Text(
                      disp,
                      style: TextStyle(
                        fontSize: 8,
                        color: isLoss
                            ? const Color(0xFFEF5350).withValues(alpha: 0.8)
                            : ZbxT.textSec(context),
                      ),
                    ),
                  );
                },
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 22,
                interval: ((_maxX - _minX).clamp(0.001, double.infinity)) / 4,
                getTitlesWidget: (value, meta) {
                  final dt = DateTime.fromMillisecondsSinceEpoch(
                    (value * 1000).toInt(),
                  );
                  final h = dt.hour.toString().padLeft(2, '0');
                  final m = dt.minute.toString().padLeft(2, '0');
                  return SideTitleWidget(
                    meta: meta,
                    child: Text(
                      '$h:$m',
                      style: TextStyle(fontSize: 8, color: ZbxT.textSec(context)),
                    ),
                  );
                },
              ),
            ),
          ),
          lineTouchData: LineTouchData(
            enabled: true,
            touchTooltipData: LineTouchTooltipData(
              getTooltipColor: (_) => ZbxT.card(context),
              getTooltipItems: (spots) => spots.map((spot) {
                final isNeg = spot.y < 0;
                final label = isNeg
                    ? 'Loss: ${(-spot.y).toStringAsFixed(1)}%'
                    : '${spot.y.toStringAsFixed(2)} ms';
                return LineTooltipItem(
                  label,
                  TextStyle(
                    fontSize: 10,
                    color: isNeg
                        ? const Color(0xFFEF5350)
                        : ZbxPalette.rxBlue,
                  ),
                );
              }).toList(),
            ),
          ),
        ),
      ),
    );
  }
}

// --- Status pill ---
class _StatusPill extends StatelessWidget {
  final String label, status;
  final Color color;
  const _StatusPill({
    required this.label,
    required this.status,
    required this.color,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    decoration: BoxDecoration(
      color: ZbxT.card(context),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: color.withValues(alpha: 0.35)),
    ),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label.toUpperCase(),
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  color: ZbxT.textSec(context),
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                status,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: color,
                ),
              ),
            ],
          ),
        ),
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 7),
            ],
          ),
        ),
      ],
    ),
  );
}

class _MetricTile extends StatelessWidget {
  final String label, value, unit;
  final Color color;
  final bool fullWidth;
  const _MetricTile({
    required this.label,
    required this.value,
    required this.unit,
    required this.color,
    this.fullWidth = false,
  });

  @override
  Widget build(BuildContext context) => Container(
    width: fullWidth ? double.infinity : null,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: ZbxT.card(context),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: color.withValues(alpha: 0.22)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w700,
            color: ZbxT.textSec(context),
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 8),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: value,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: color,
                    height: 1,
                  ),
                ),
                if (unit.isNotEmpty)
                  TextSpan(
                    text: ' $unit',
                    style: TextStyle(
                      fontSize: 11,
                      color: color.withValues(alpha: 0.7),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class _PacketLossTile extends StatelessWidget {
  final String value;
  final dynamic item;
  const _PacketLossTile({required this.value, required this.item});

  @override
  Widget build(BuildContext context) {
    final n = item != null ? (itemNumericValue(item) ?? 0.0) : 0.0;
    final Color color = n == 0
        ? _upGreen
        : n < 5
        ? _warnAmb
        : _downRed;
    final String badge = n == 0 ? 'OK' : (n < 5 ? 'DEGRADED' : 'HIGH LOSS');

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ZbxT.card(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'PACKET LOSS',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    color: ZbxT.textSec(context),
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: color,
                    height: 1,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: color.withValues(alpha: 0.4)),
            ),
            child: Text(
              badge,
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w800,
                color: color,
                letterSpacing: 0.6,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CounterTile extends StatelessWidget {
  final String label;
  final int count;
  final Color okColor, warnColor;
  final IconData icon;
  const _CounterTile({
    required this.label,
    required this.count,
    required this.okColor,
    required this.warnColor,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final color = count == 0 ? okColor : warnColor;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ZbxT.card(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 11, color: color),
              const SizedBox(width: 4),
              Text(
                label.toUpperCase(),
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  color: color,
                  letterSpacing: 0.7,
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: color,
                  height: 1,
                ),
              ),
              const SizedBox(width: 7),
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    count == 0 ? 'OK' : 'ALERT',
                    style: TextStyle(
                      fontSize: 8,
                      fontWeight: FontWeight.w800,
                      color: color,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── PE Metadata tile (Description / Customer / VRF) ─────────────────────────
class _PEMetaTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _PEMetaTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: ZbxT.card(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            margin: const EdgeInsets.only(right: 12, top: 1),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 15, color: color),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label.toUpperCase(),
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    color: color.withValues(alpha: 0.8),
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: ZbxT.textPri(context),
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── ARP discovery card ───────────────────────────────────────────────────────
class _ArpCard extends StatefulWidget {
  final int count;
  final Set<String> ips;
  const _ArpCard({required this.count, required this.ips});

  @override
  State<_ArpCard> createState() => _ArpCardState();
}

class _ArpCardState extends State<_ArpCard> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final sorted = (widget.ips.toList()..sort());
    final filtered = _filter.isEmpty
        ? sorted
        : sorted.where((ip) => ip.contains(_filter)).toList();

    return Container(
      decoration: BoxDecoration(
        color: ZbxT.card(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ZbxT.rim(context)),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          childrenPadding: EdgeInsets.zero,
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: _rxBlue.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Icon(Icons.radar, size: 13, color: _rxBlue),
              ),
              const SizedBox(width: 10),
              Text(
                'ARP Discovered',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: ZbxT.textPri(context),
                ),
              ),
            ],
          ),
          trailing: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: _rxBlue.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: _rxBlue.withValues(alpha: 0.4)),
            ),
            child: Text(
              '${widget.count}',
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: _rxBlue,
              ),
            ),
          ),
          children: [
            Container(height: 1, color: ZbxT.rim(context)),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
              child: TextField(
                onChanged: (v) => setState(() => _filter = v.trim()),
                style: TextStyle(fontSize: 11, color: ZbxT.textPri(context)),
                decoration: InputDecoration(
                  hintText: 'Filter IP addresses…',
                  hintStyle: TextStyle(
                    fontSize: 11,
                    color: ZbxT.textSec(context),
                  ),
                  prefixIcon: Icon(
                    Icons.search,
                    size: 15,
                    color: ZbxT.textSec(context),
                  ),
                  isDense: true,
                  filled: true,
                  fillColor: ZbxT.lift(context),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: ZbxT.rim(context)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: ZbxT.rim(context)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: _rxBlue, width: 1.5),
                  ),
                ),
              ),
            ),
            Container(
              color: ZbxT.lift(context),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'IP ADDRESS',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        color: ZbxT.textSec(context),
                        letterSpacing: 0.7,
                      ),
                    ),
                  ),
                  Text(
                    'MAC / FIRST SEEN',
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      color: ZbxT.textSec(context),
                      letterSpacing: 0.7,
                    ),
                  ),
                ],
              ),
            ),
            ...filtered.take(80).toList().asMap().entries.map((e) {
              final odd = e.key.isOdd;
              return Container(
                color: odd ? ZbxT.panel(context) : Colors.transparent,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 7,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 4,
                      height: 4,
                      margin: const EdgeInsets.only(right: 8),
                      decoration: BoxDecoration(
                        color: _rxBlue,
                        shape: BoxShape.circle,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        e.value,
                        style: TextStyle(
                          fontSize: 11,
                          color: ZbxT.textPri(context),
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    Text(
                      '—',
                      style: TextStyle(
                        fontSize: 11,
                        color: ZbxT.textSec(context),
                      ),
                    ),
                  ],
                ),
              );
            }),
            if (filtered.length > 80)
              Padding(
                padding: const EdgeInsets.all(10),
                child: Text(
                  '+ ${filtered.length - 80} more…',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 10, color: ZbxT.textSec(context)),
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
