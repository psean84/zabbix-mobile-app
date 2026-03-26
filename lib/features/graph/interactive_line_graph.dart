import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/utils.dart';
import '../../core/zbx_theme.dart';

// ─── Mode kept for compatibility, but both render as line graph ───────────────
enum GraphRenderMode { line, bar }

// ─── Time-range preset definition ─────────────────────────────────────────────
// ── Theme-aware color helper ──────────────────────────────────────────────────
// ── Theme-aware color helper ──────────────────────────────────────────────────
class _T {
  static Color card(BuildContext ctx) => ZbxTheme.of(ctx).bgCard;
  static Color panel(BuildContext ctx) => ZbxTheme.of(ctx).bgPanel;
  static Color rim(BuildContext ctx) => ZbxTheme.of(ctx).rim;
  static Color textPri(BuildContext ctx) => ZbxTheme.of(ctx).textPri;
  static Color textSec(BuildContext ctx) => ZbxTheme.of(ctx).textSec;
}

class _TimePreset {
  final String label;
  final int? minutes; // null = use days
  final int? days;

  const _TimePreset(this.label, {this.minutes, this.days})
    : assert(minutes != null || days != null);
}

const _kPresets = [
  _TimePreset('15m', minutes: 15),
  _TimePreset('1h', minutes: 60),
  _TimePreset('3h', minutes: 180),
  _TimePreset('6h', minutes: 360),
  _TimePreset('12h', minutes: 720),
  _TimePreset('24h', minutes: 1440),
  _TimePreset('2d', days: 2),
  _TimePreset('7d', days: 7),
  _TimePreset('30d', days: 30),
];

// ─── Design tokens ─────────────────────────────────────────────────────────────
const _bgPanel = ZbxPalette.panelDark;
const _rim = ZbxPalette.rimDark;
const _rxBlue = ZbxPalette.rxBlue;
const _txGreen = ZbxPalette.txGreen;
const _warnAmb = ZbxPalette.warnAmb;
const _downRed = ZbxPalette.downRed;
const _textSec = ZbxPalette.textSecDark;

// ─── Main widget ───────────────────────────────────────────────────────────────
class InteractiveLineGraph extends StatefulWidget {
  final List<dynamic> selectedNumericItems;
  final TextEditingController? externalFromController;
  final TextEditingController? externalToController;
  final bool showControls;
  final GraphRenderMode mode; // kept for compat; both render as line chart
  final Color? backgroundColor;
  final Color? foregroundColor;
  final double chartHeight;
  final String? title; // optional override title

  const InteractiveLineGraph({
    super.key,
    required this.selectedNumericItems,
    this.externalFromController,
    this.externalToController,
    this.showControls = true,
    this.mode = GraphRenderMode.line,
    this.backgroundColor,
    this.foregroundColor,
    this.chartHeight = 280,
    this.title,
  });

  @override
  State<InteractiveLineGraph> createState() => _InteractiveLineGraphState();
}

class _InteractiveLineGraphState extends State<InteractiveLineGraph> {
  final _localFromCtrl = TextEditingController();
  final _localToCtrl = TextEditingController();

  bool _loading = false;
  String _error = '';
  int _loadedChunks = 0;
  int _totalChunks = 0;
  bool _showTimePicker = false;

  // Active preset label for highlight
  String? _activePreset;

  // Cache
  int? _cacheFrom;
  int? _cacheTo;
  Set<String> _cacheItemIds = {};
  final Map<String, List<FlSpot>> _cacheSeries = {};

  // Chart data
  final Map<String, List<FlSpot>> _series = {};
  double _minX = 0, _maxX = 1, _minY = 0, _maxY = 1;
  double _viewMinX = 0, _viewMaxX = 1;
  double? _dragStartX, _dragEndX;

  // Remember last drag selection to allow toggle (tap clears it)
  double? _lastDragFrom, _lastDragTo;

  // Long-press panning
  bool _isPanning = false;
  double _panStartViewMin = 0;
  double _panStartViewMax = 0;
  double _panStartLocalX = 0;

  Timer? _debounce;

  TextEditingController get _fromCtrl =>
      widget.externalFromController ?? _localFromCtrl;
  TextEditingController get _toCtrl =>
      widget.externalToController ?? _localToCtrl;

  // ── Life-cycle ───────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    if (_fromCtrl.text.trim().isEmpty || _toCtrl.text.trim().isEmpty) {
      _applyPreset(_kPresets[1]); // default 1h, no load yet
    }
    // ALL graphs sharing external controllers listen to range changes —
    // whether they show controls or not. This ensures selecting a preset
    // on the primary (traffic) graph also reloads utilization/error graphs.
    if (widget.externalFromController != null &&
        widget.externalToController != null) {
      widget.externalFromController!.addListener(_onExternalChanged);
      widget.externalToController!.addListener(_onExternalChanged);
    }
    _loadHistory();
  }

  @override
  void didUpdateWidget(covariant InteractiveLineGraph old) {
    super.didUpdateWidget(old);
    final oldIds = old.selectedNumericItems
        .map((i) => (i['itemid'] ?? '').toString())
        .toSet();
    final newIds = widget.selectedNumericItems
        .map((i) => (i['itemid'] ?? '').toString())
        .toSet();
    if (!oldIds.containsAll(newIds) || oldIds.length != newIds.length) {
      _loadHistory();
    }
  }

  @override
  void dispose() {
    if (widget.externalFromController != null &&
        widget.externalToController != null) {
      widget.externalFromController!.removeListener(_onExternalChanged);
      widget.externalToController!.removeListener(_onExternalChanged);
    }
    _debounce?.cancel();
    _localFromCtrl.dispose();
    _localToCtrl.dispose();
    super.dispose();
  }

  void _onExternalChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) _loadHistory();
    });
  }

  // ── Preset helpers ────────────────────────────────────────────────────────────
  void _applyPreset(_TimePreset p, {bool load = false}) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final toEpoch = parseTimeInputToEpoch(_toCtrl.text.trim()) ?? now;
    final minutes = p.minutes ?? (p.days! * 24 * 60);
    final fromEpoch = toEpoch - (minutes * 60);
    setState(() {
      _fromCtrl.text = formatDateTimeInput(
        DateTime.fromMillisecondsSinceEpoch(fromEpoch * 1000).toLocal(),
      );
      _toCtrl.text = formatDateTimeInput(
        DateTime.fromMillisecondsSinceEpoch(toEpoch * 1000).toLocal(),
      );
      _activePreset = p.label;
    });
    if (load) _loadHistory();
  }

  // ── Cache helpers ─────────────────────────────────────────────────────────────
  bool _hasCoveringCache(List<String> ids, int from, int to) {
    if (_cacheFrom == null || _cacheTo == null || _cacheSeries.isEmpty) {
      return false;
    }
    if (from < _cacheFrom! || to > _cacheTo!) return false;
    final req = ids.toSet();
    return req.length == _cacheItemIds.length && req.containsAll(_cacheItemIds);
  }

  Map<String, List<FlSpot>> _sliceCache(int from, int to) {
    final out = <String, List<FlSpot>>{};
    for (final e in _cacheSeries.entries) {
      out[e.key] = e.value.where((p) => p.x >= from && p.x <= to).toList()
        ..sort((a, b) => a.x.compareTo(b.x));
    }
    return out;
  }

  void _applySeriesView(Map<String, List<FlSpot>> map, int from, int to) {
    double lMinX = double.infinity,
        lMaxX = double.negativeInfinity,
        lMinY = double.infinity,
        lMaxY = double.negativeInfinity;
    for (final pts in map.values) {
      for (final p in pts) {
        if (p.x < lMinX) lMinX = p.x;
        if (p.x > lMaxX) lMaxX = p.x;
        if (p.y < lMinY) lMinY = p.y;
        if (p.y > lMaxY) lMaxY = p.y;
      }
    }
    setState(() {
      _series
        ..clear()
        ..addAll(map);
      _minX = lMinX.isFinite ? lMinX : from.toDouble();
      _maxX = lMaxX.isFinite ? lMaxX : to.toDouble();
      _minY = lMinY.isFinite ? (lMinY < 0 ? lMinY : 0) : 0;
      _maxY = lMaxY.isFinite ? lMaxY : 1;
      _viewMinX = _minX;
      _viewMaxX = _maxX;
      _loading = false;
    });
  }

  // ── Data loading ─────────────────────────────────────────────────────────────
  Future<void> _loadHistory() async {
    final ids = widget.selectedNumericItems
        .where(isNumericItem)
        .map((i) => (i['itemid'] ?? '').toString())
        .where((id) => id.isNotEmpty && !id.startsWith('lld-'))
        .toList();

    if (ids.isEmpty) {
      setState(() {
        _loading = false;
        _error = 'No numeric items to graph.';
        _series.clear();
      });
      return;
    }

    final from = parseTimeInputToEpoch(_fromCtrl.text.trim());
    final to = parseTimeInputToEpoch(_toCtrl.text.trim());
    if (from == null || to == null || from >= to) {
      setState(() {
        _loading = false;
        _error = 'Invalid time range.';
      });
      return;
    }

    if (mounted) {
      setState(() {
        _loading = true;
        _error = '';
        _loadedChunks = 0;
        _totalChunks = 0;
      });
    }

    if (_hasCoveringCache(ids, from, to)) {
      _applySeriesView(_downsample(_sliceCache(from, to), from, to), from, to);
      return;
    }

    try {
      final map = <String, List<FlSpot>>{};
      const chunkSec = 12 * 3600;
      final span = to - from;
      final chunks = span <= chunkSec ? 1 : (span / chunkSec).ceil();
      if (mounted) {
        setState(() {
          _totalChunks = chunks;
        });
      }

      String partialErr = '';
      for (var i = 0; i < chunks; i++) {
        final cf = from + (i * chunkSec);
        final ct = (cf + chunkSec) > to ? to : (cf + chunkSec);
        try {
          final data = await ApiClient.fetchHistoryChunk(
            itemIds: ids,
            from: cf,
            to: ct,
          );
          final pts = data['points'];
          if (pts is! List) continue;
          for (final p in pts) {
            final id = (p['itemid'] ?? '').toString();
            final x = (p['clock'] is num)
                ? (p['clock'] as num).toDouble()
                : double.tryParse((p['clock'] ?? '').toString());
            final y = (p['value'] is num)
                ? (p['value'] as num).toDouble()
                : double.tryParse((p['value'] ?? '').toString());
            if (id.isEmpty || x == null || y == null) continue;
            map.putIfAbsent(id, () => []).add(FlSpot(x, y));
          }
        } catch (e) {
          partialErr = 'Some chunks failed: $e';
        } finally {
          if (mounted) setState(() => _loadedChunks = i + 1);
        }
      }

      for (final e in map.entries) {
        e.value.sort((a, b) => a.x.compareTo(b.x));
      }

      // Downsample to reduce chart point count for large time ranges
      final downsampled = _downsample(map, from, to);

      if (!mounted) return;
      _cacheFrom = from;
      _cacheTo = to;
      _cacheItemIds = ids.toSet();
      _cacheSeries
        ..clear()
        ..addAll(map); // cache raw, display downsampled
      _applySeriesView(downsampled, from, to);
      setState(() => _error = partialErr);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Failed: $e';
      });
    }
  }

  // ── Item label mapping (network + ICMP + Monitor) ─────────────────────────
  String _labelFor(String itemId) {
    final item = widget.selectedNumericItems.firstWhere(
      (i) => (i['itemid'] ?? '').toString() == itemId,
      orElse: () => <String, dynamic>{},
    );
    final key = (item['key_'] ?? '').toString().toLowerCase();
    final name = (item['name'] ?? '').toString().toLowerCase();
    final hay = '$key $name';

    // ICMP / ping metrics
    if (key.contains('bng.ping.avg') || name.contains('avg.')) {
      return 'Avg Latency';
    }
    if (key.contains('bng.ping.min') || name.contains(' min')) {
      return 'Min Latency';
    }
    if (key.contains('bng.ping.max') || name.contains(' max')) {
      return 'Max Latency';
    }
    if (key.contains('bng.ping.loss') || name.contains('loss')) {
      return 'Packet Loss %';
    }
    if (key.contains('bng.ping.jitter')) return 'Jitter';

    // OLT ping
    if (key.contains('ping.avg')) return 'Avg Latency';
    if (key.contains('ping.min')) return 'Min Latency';
    if (key.contains('ping.max')) return 'Max Latency';
    if (key.contains('ping.loss')) return 'Packet Loss %';
    if (key.contains('ping.jitter')) return 'Jitter';

    // Monitor / collector metrics
    if (key.contains('collector.lag_s')) return 'Lag (s)';
    if (key.contains('collector.last_ms')) return 'Poll Time (ms)';
    if (key.contains('collector.success_rate')) return 'Success Rate';
    if (key.contains('collector.ok_count')) return 'Ok Count';
    if (key.contains('collector.total_count')) return 'Total Count';
    if (key.contains('collector.items')) return 'Items';
    if (key.contains('collector.interval_s')) return 'Interval (s)';
    if (key.contains('monitor.device.poll_duration')) return 'Poll Duration';

    // ── Network interface items only — exclude Zabbix built-in/internal keys ──
    // Internal keys start with system., zabbix., agent., net.tcp., icmpping, etc.
    // They often contain words like "in" (login, incoming) that falsely match
    // the hasRx regex. Skip them and fall through to the name-based label.
    final isZabbixInternal =
        key.startsWith('system.') ||
        key.startsWith('zabbix.') ||
        key.startsWith('agent.') ||
        key.startsWith('net.tcp.') ||
        key.startsWith('net.udp.') ||
        key.startsWith('icmpping') ||
        key.startsWith('proc.') ||
        key.startsWith('vm.') ||
        key.startsWith('vfs.') ||
        key.startsWith('kernel.') ||
        key.startsWith('web.') ||
        key.startsWith('log[') ||
        key.startsWith('eventlog[');

    if (!isZabbixInternal) {
      final hasTx = RegExp(r'(^|[^a-z])(tx|out)([^a-z]|$)').hasMatch(hay);
      final hasRx = RegExp(r'(^|[^a-z])(rx|in)([^a-z]|$)').hasMatch(hay);
      if (hasTx &&
          (hay.contains('traffic') ||
              hay.contains('bps') ||
              hay.contains('tx_bytes') ||
              hay.contains('tx_octets'))) {
        return 'Tx Traffic';
      }
      if (hasRx &&
          (hay.contains('traffic') ||
              hay.contains('bps') ||
              hay.contains('rx_bytes') ||
              hay.contains('rx_octets'))) {
        return 'Rx Traffic';
      }
      if (hay.contains('in_util') || (hasRx && hay.contains('util'))) {
        return 'Rx Utilization %';
      }
      if (hay.contains('out_util') || (hasTx && hay.contains('util'))) {
        return 'Tx Utilization %';
      }
      if (hasRx && hay.contains('drop')) return 'Rx Drops';
      if (hasRx && hay.contains('error')) return 'Rx Errors';
      if (hasRx && hay.contains('octet')) return 'Rx Octets';
      if (hasTx && hay.contains('octet')) return 'Tx Octets';
      if (hay.contains('arp') && hay.contains('count')) return 'ARP Count';
      if (hay.contains('rx_power')) return 'Rx Power (dBm)';
      // SAP
      if (key.contains('sap.if.rx')) return 'SAP Rx';
      if (key.contains('sap.if.tx')) return 'SAP Tx';
    }

    return (item['name'] ?? 'Metric')
        .toString()
        .replaceAll(RegExp(r'\[.*?\]'), '')
        .trim();
  }

  int _labelOrder(String label) {
    const order = {
      'Rx Traffic': 0,
      'Tx Traffic': 1,
      'Rx Utilization %': 2,
      'Tx Utilization %': 3,
      'Avg Latency': 10,
      'Min Latency': 11,
      'Max Latency': 12,
      'Packet Loss %': 13,
      'Jitter': 14,
      'Rx Drops': 20,
      'Rx Errors': 21,
      'Lag (s)': 30,
      'Poll Time (ms)': 31,
      'Success Rate': 32,
      'Ok Count': 33,
      'Total Count': 34,
    };
    return order[label] ?? 99;
  }

  // ── Color assignment for series ───────────────────────────────────────────────
  Color _colorFor(String label, int idx) {
    switch (label) {
      case 'Rx Traffic':
        return _rxBlue;
      case 'Tx Traffic':
        return _txGreen;
      case 'Rx Utilization %':
        return const Color(0xFF64B5F6);
      case 'Tx Utilization %':
        return const Color(0xFF81C784);
      case 'Avg Latency':
        return _rxBlue;
      case 'Min Latency':
        return _txGreen;
      case 'Max Latency':
        return _warnAmb;
      case 'Packet Loss %':
        return _downRed;
      case 'Jitter':
        return const Color(0xFFCE93D8);
      case 'Rx Drops':
        return _warnAmb;
      case 'Rx Errors':
        return _downRed;
      case 'Lag (s)':
        return _warnAmb;
      case 'Poll Time (ms)':
        return _rxBlue;
      case 'Success Rate':
        return _txGreen;
      case 'Ok Count':
        return _txGreen;
      case 'Total Count':
        return _textSec;
    }
    return seriesColor(idx);
  }

  // ── Axis formatting ───────────────────────────────────────────────────────────
  String _fmtAxis(double v) {
    final abs = v.abs();
    if (abs >= 1e9) return '${(v / 1e9).toStringAsFixed(1)}G';
    if (abs >= 1e6) return '${(v / 1e6).toStringAsFixed(1)}M';
    if (abs >= 1e3) return '${(v / 1e3).toStringAsFixed(1)}k';
    if (abs < 1 && abs > 0) return v.toStringAsFixed(2);
    return v.toStringAsFixed(abs >= 100 ? 0 : (abs >= 10 ? 1 : 2));
  }

  String _fmtTime(double epoch) {
    final dt = DateTime.fromMillisecondsSinceEpoch(
      (epoch * 1000).toInt(),
    ).toLocal();
    final rangeSec = _viewMaxX - _viewMinX;
    if (rangeSec > 6 * 86400) {
      // Show date only
      final m = dt.month.toString().padLeft(2, '0');
      final d = dt.day.toString().padLeft(2, '0');
      return '$m/$d';
    } else if (rangeSec > 86400) {
      // Date + hour
      final m = dt.month.toString().padLeft(2, '0');
      final d = dt.day.toString().padLeft(2, '0');
      final h = dt.hour.toString().padLeft(2, '0');
      return '$m/$d $h:00';
    } else {
      // Hour:minute
      final h = dt.hour.toString().padLeft(2, '0');
      final min = dt.minute.toString().padLeft(2, '0');
      return '$h:$min';
    }
  }

  double _xInterval() {
    final span = _viewMaxX - _viewMinX;
    if (span <= 0) return 3600;
    if (span <= 3600) return 600;
    if (span <= 3 * 3600) return 1800;
    if (span <= 6 * 3600) return 3600;
    if (span <= 12 * 3600) return 2 * 3600;
    if (span <= 24 * 3600) return 4 * 3600;
    if (span <= 2 * 86400) return 6 * 3600;
    if (span <= 7 * 86400) return 86400;
    return 3 * 86400;
  }

  // ── Downsampling — average into buckets based on time span ──────────────────
  /// Returns bucket size in seconds for a given span.
  static int _bucketSec(int spanSec) {
    if (spanSec <= 15 * 60) return 0; // ≤15 min  → raw
    if (spanSec <= 60 * 60) return 30; // ≤1 h     → 30 s avg
    if (spanSec <= 3 * 3600) return 60; // ≤3 h     → 1 min avg
    if (spanSec <= 6 * 3600) return 2 * 60; // ≤6 h     → 2 min avg
    if (spanSec <= 12 * 3600) return 5 * 60; // ≤12 h    → 5 min avg
    if (spanSec <= 24 * 3600) return 10 * 60; // ≤24 h    → 10 min avg
    if (spanSec <= 2 * 86400) return 20 * 60; // ≤2 d     → 20 min avg
    if (spanSec <= 7 * 86400) return 60 * 60; // ≤7 d     → 1 h avg
    return 6 * 3600; // >7 d     → 6 h avg
  }

  Map<String, List<FlSpot>> _downsample(
    Map<String, List<FlSpot>> raw,
    int from,
    int to,
  ) {
    final span = to - from;
    final bucket = _bucketSec(span);
    if (bucket == 0) return raw; // no downsampling needed

    final out = <String, List<FlSpot>>{};
    for (final entry in raw.entries) {
      final pts = entry.value;
      if (pts.isEmpty) {
        out[entry.key] = pts;
        continue;
      }

      final averaged = <FlSpot>[];
      double sumY = 0;
      int count = 0;
      int bucketStart = ((pts.first.x / bucket).floor()) * bucket;

      for (final p in pts) {
        final b = ((p.x / bucket).floor()) * bucket;
        if (b != bucketStart && count > 0) {
          averaged.add(FlSpot(bucketStart + bucket / 2, sumY / count));
          sumY = 0;
          count = 0;
          bucketStart = b;
        }
        sumY += p.y;
        count += 1;
      }
      if (count > 0) {
        averaged.add(FlSpot(bucketStart + bucket / 2, sumY / count));
      }
      out[entry.key] = averaged;
    }
    return out;
  }

  // ── Drag selection for zoom ───────────────────────────────────────────────────
  void _applyDrag() {
    if (_dragStartX == null || _dragEndX == null) return;
    final from = _dragStartX! < _dragEndX! ? _dragStartX! : _dragEndX!;
    final to = _dragStartX! < _dragEndX! ? _dragEndX! : _dragStartX!;

    // Very short drag (< 30 s) — treat as tap: toggle back to previous range
    if ((to - from) < 30) {
      setState(() {
        _dragStartX = _dragEndX = null;
      });
      // If we have a remembered previous selection, restore it; otherwise reset
      if (_lastDragFrom != null && _lastDragTo != null) {
        final pf = _lastDragFrom!;
        final pt = _lastDragTo!;
        setState(() {
          _fromCtrl.text = formatDateTimeInput(
            DateTime.fromMillisecondsSinceEpoch((pf.toInt()) * 1000).toLocal(),
          );
          _toCtrl.text = formatDateTimeInput(
            DateTime.fromMillisecondsSinceEpoch((pt.toInt()) * 1000).toLocal(),
          );
          _activePreset = null;
          _lastDragFrom = null;
          _lastDragTo = null;
        });
        _loadHistory();
      }
      return;
    }

    // Remember previous range so a subsequent short-tap can restore it
    final prevFrom = parseTimeInputToEpoch(_fromCtrl.text.trim());
    final prevTo = parseTimeInputToEpoch(_toCtrl.text.trim());
    setState(() {
      _lastDragFrom = prevFrom?.toDouble();
      _lastDragTo = prevTo?.toDouble();
      _fromCtrl.text = formatDateTimeInput(
        DateTime.fromMillisecondsSinceEpoch((from.toInt()) * 1000).toLocal(),
      );
      _toCtrl.text = formatDateTimeInput(
        DateTime.fromMillisecondsSinceEpoch((to.toInt()) * 1000).toLocal(),
      );
      _activePreset = null;
      _dragStartX = _dragEndX = null;
    });
    _loadHistory();
  }

  // ── Build ─────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final bg = widget.backgroundColor ?? _T.card(context);
    final fg = widget.foregroundColor ?? _T.textPri(context);

    final orderedEntries = _series.entries.toList()
      ..sort((a, b) {
        final la = _labelFor(a.key);
        final lb = _labelFor(b.key);
        final c = _labelOrder(la).compareTo(_labelOrder(lb));
        return c != 0 ? c : la.compareTo(lb);
      });

    var idx = 0;
    final lines = <LineChartBarData>[];
    for (final e in orderedEntries) {
      final label = _labelFor(e.key);
      lines.add(
        LineChartBarData(
          spots: e.value,
          isCurved: true,
          curveSmoothness: 0.25,
          barWidth: 2,
          color: _colorFor(label, idx++),
          dotData: const FlDotData(show: false),
          belowBarData: BarAreaData(
            show: orderedEntries.length == 1,
            color: _colorFor(label, idx - 1).withValues(alpha: 0.08),
          ),
        ),
      );
    }

    final graphTitle =
        widget.title ??
        (widget.mode == GraphRenderMode.bar
            ? 'Errors & Drops'
            : 'Traffic Graph');

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _T.rim(context)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header row ────────────────────────────────────────────────────
            Row(
              children: [
                Text(
                  graphTitle,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: fg,
                  ),
                ),
                const Spacer(),
                if (widget.showControls)
                  GestureDetector(
                    onTap: () =>
                        setState(() => _showTimePicker = !_showTimePicker),
                    child: Icon(
                      _showTimePicker
                          ? Icons.schedule
                          : Icons.schedule_outlined,
                      size: 18,
                      color: _showTimePicker ? _rxBlue : _T.textSec(context),
                    ),
                  ),
                const SizedBox(width: 8),
                if (_loading)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: _rxBlue,
                    ),
                  )
                else
                  GestureDetector(
                    onTap: _loadHistory,
                    child: Icon(
                      Icons.refresh,
                      size: 18,
                      color: _T.textSec(context),
                    ),
                  ),
              ],
            ),

            // ── Custom time picker (collapsible) ──────────────────────────────
            if (widget.showControls && _showTimePicker) ...[
              const SizedBox(height: 10),
              _buildTimePicker(fg),
            ],

            const SizedBox(height: 10),

            // ── Preset chip row ───────────────────────────────────────────────
            if (widget.showControls)
              SizedBox(
                height: 28,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _kPresets.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(width: 6),
                  itemBuilder: (_, i) {
                    final p = _kPresets[i];
                    final active = _activePreset == p.label;
                    return GestureDetector(
                      onTap: () => _applyPreset(p, load: true),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 11,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: active
                              ? _rxBlue.withValues(alpha: 0.18)
                              : _T.rim(context).withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: active ? _rxBlue : _T.rim(context),
                            width: active ? 1.5 : 1,
                          ),
                        ),
                        child: Text(
                          p.label,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: active ? _rxBlue : _T.textSec(context),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),

            if (widget.showControls) const SizedBox(height: 8),

            // ── Progress / error ──────────────────────────────────────────────
            if (_loading && _totalChunks > 1)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: _totalChunks > 0
                              ? _loadedChunks / _totalChunks
                              : null,
                          backgroundColor: _T.rim(context),
                          color: _rxBlue,
                          minHeight: 3,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '$_loadedChunks/$_totalChunks',
                      style: TextStyle(
                        fontSize: 10,
                        color: _T.textSec(context),
                      ),
                    ),
                  ],
                ),
              ),
            if (_loading && _totalChunks <= 1)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: LinearProgressIndicator(
                  backgroundColor: _T.rim(context),
                  color: _rxBlue,
                  minHeight: 2,
                ),
              ),
            if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  _error,
                  style: const TextStyle(fontSize: 11, color: _downRed),
                ),
              ),

            // ── Chart ─────────────────────────────────────────────────────────
            SizedBox(
              height: widget.chartHeight,
              child: LayoutBuilder(
                builder: (ctx, constraints) {
                  final W = constraints.maxWidth;
                  if (_series.isEmpty && !_loading) {
                    return Center(
                      child: Text(
                        'No data for selected range',
                        style: TextStyle(
                          fontSize: 12,
                          color: fg.withValues(alpha: 0.45),
                        ),
                      ),
                    );
                  }
                  return GestureDetector(
                    // ── Short drag = selection zoom ──────────────────────────────
                    onHorizontalDragStart: (d) {
                      if (_isPanning || _maxX <= _minX) return;
                      final x =
                          _minX + (d.localPosition.dx / W) * (_maxX - _minX);
                      setState(() {
                        _dragStartX = x;
                        _dragEndX = x;
                      });
                    },
                    onHorizontalDragUpdate: (d) {
                      if (_isPanning || _dragStartX == null || _maxX <= _minX) {
                        return;
                      }
                      final x =
                          _minX +
                          (d.localPosition.dx.clamp(0.0, W) / W) *
                              (_maxX - _minX);
                      setState(() {
                        _dragEndX = x;
                      });
                    },
                    onHorizontalDragEnd: (_) {
                      if (!_isPanning) _applyDrag();
                    },
                    // ── Long-press = pan the view without reloading ───────────────
                    onLongPressStart: (d) {
                      if (_maxX <= _minX) return;
                      setState(() {
                        _isPanning = true;
                        _panStartViewMin = _viewMinX;
                        _panStartViewMax = _viewMaxX;
                        _panStartLocalX = d.localPosition.dx;
                        _dragStartX = null;
                        _dragEndX = null;
                      });
                    },
                    onLongPressMoveUpdate: (d) {
                      if (!_isPanning || W <= 0) return;
                      final viewSpan = _panStartViewMax - _panStartViewMin;
                      final pxDelta = d.localPosition.dx - _panStartLocalX;
                      // moving right → shift view left (earlier in time)
                      final timeDelta = -(pxDelta / W) * viewSpan;
                      var newMin = _panStartViewMin + timeDelta;
                      var newMax = _panStartViewMax + timeDelta;
                      // Clamp to data bounds
                      if (newMin < _minX) {
                        newMax += (_minX - newMin);
                        newMin = _minX;
                      }
                      if (newMax > _maxX) {
                        newMin -= (newMax - _maxX);
                        newMax = _maxX;
                      }
                      if (newMin < _minX) newMin = _minX;
                      setState(() {
                        _viewMinX = newMin;
                        _viewMaxX = newMax;
                      });
                    },
                    onLongPressEnd: (_) {
                      setState(() => _isPanning = false);
                    },
                    onLongPressCancel: () {
                      setState(() => _isPanning = false);
                    },
                    child: Stack(
                      children: [
                        LineChart(
                          LineChartData(
                            minX: _viewMinX,
                            maxX: _viewMaxX,
                            minY: _minY == _maxY ? _minY - 1 : _minY,
                            maxY: _minY == _maxY ? _maxY + 1 : _maxY * 1.05,
                            lineBarsData: lines,
                            lineTouchData: LineTouchData(
                              enabled: true,
                              touchCallback: (event, response) {},
                              getTouchedSpotIndicator: (bar, spots) => spots
                                  .map(
                                    (_) => TouchedSpotIndicatorData(
                                      FlLine(
                                        color: _T
                                            .textSec(context)
                                            .withValues(alpha: 0.5),
                                        strokeWidth: 1,
                                        dashArray: [4, 4],
                                      ),
                                      FlDotData(
                                        show: true,
                                        getDotPainter:
                                            (spot, percent, barData, index) =>
                                                FlDotCirclePainter(
                                                  radius: 3.5,
                                                  color: Colors.white,
                                                  strokeWidth: 1.5,
                                                  strokeColor: _rxBlue,
                                                ),
                                      ),
                                    ),
                                  )
                                  .toList(),
                              touchTooltipData: LineTouchTooltipData(
                                getTooltipColor: (_) => _T.panel(context),
                                getTooltipItems: (spots) {
                                  return spots.asMap().entries.map((e) {
                                    final spot = e.value;
                                    final id = orderedEntries.length > e.key
                                        ? orderedEntries[e.key].key
                                        : '';
                                    final label = _labelFor(id);
                                    return LineTooltipItem(
                                      '$label\n',
                                      TextStyle(
                                        fontSize: 10,
                                        color: _colorFor(label, e.key),
                                        fontWeight: FontWeight.w700,
                                      ),
                                      children: [
                                        TextSpan(
                                          text: _fmtAxis(spot.y),
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: _T.textPri(context),
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                      ],
                                    );
                                  }).toList();
                                },
                              ),
                            ),
                            gridData: FlGridData(
                              show: true,
                              drawVerticalLine: true,
                              getDrawingHorizontalLine: (_) => FlLine(
                                color: _T.rim(context).withValues(alpha: 0.5),
                                strokeWidth: 0.5,
                              ),
                              getDrawingVerticalLine: (_) => FlLine(
                                color: _T.rim(context).withValues(alpha: 0.3),
                                strokeWidth: 0.5,
                              ),
                            ),
                            borderData: FlBorderData(
                              show: true,
                              border: Border.all(
                                color: _T.rim(context),
                                width: 0.5,
                              ),
                            ),
                            titlesData: FlTitlesData(
                              topTitles: const AxisTitles(
                                sideTitles: SideTitles(showTitles: false),
                              ),
                              rightTitles: const AxisTitles(
                                sideTitles: SideTitles(showTitles: false),
                              ),
                              leftTitles: AxisTitles(
                                sideTitles: SideTitles(
                                  showTitles: true,
                                  reservedSize: 46,
                                  getTitlesWidget: (v, meta) => SideTitleWidget(
                                    meta: meta,
                                    child: Text(
                                      _fmtAxis(v),
                                      style: TextStyle(
                                        fontSize: 9,
                                        color: fg.withValues(alpha: 0.65),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              bottomTitles: AxisTitles(
                                sideTitles: SideTitles(
                                  showTitles: true,
                                  reservedSize: 28,
                                  interval: (_xInterval().clamp(
                                    0.001,
                                    double.infinity,
                                  )),
                                  getTitlesWidget: (v, meta) => SideTitleWidget(
                                    meta: meta,
                                    child: Text(
                                      _fmtTime(v),
                                      style: TextStyle(
                                        fontSize: 9,
                                        color: fg.withValues(alpha: 0.65),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          duration: const Duration(milliseconds: 200),
                        ),
                        // Drag selection overlay
                        if (_dragStartX != null && _dragEndX != null)
                          Positioned.fill(
                            child: CustomPaint(
                              painter: _SelectionPainter(
                                minX: _minX,
                                maxX: _maxX,
                                startX: _dragStartX!,
                                endX: _dragEndX!,
                              ),
                            ),
                          ),
                        // Pan mode overlay — subtle tinted bar at top
                        if (_isPanning)
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: Container(
                              height: 3,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    Colors.transparent,
                                    _rxBlue.withValues(alpha: 0.7),
                                    Colors.transparent,
                                  ],
                                ),
                              ),
                            ),
                          ),
                        // Pan hint label
                        if (_isPanning)
                          Positioned(
                            top: 6,
                            right: 8,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: _T.panel(context).withValues(alpha: 0.9),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: _rxBlue.withValues(alpha: 0.4),
                                ),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.pan_tool_outlined,
                                    size: 9,
                                    color: _rxBlue,
                                  ),
                                  SizedBox(width: 4),
                                  Text(
                                    'Panning',
                                    style: TextStyle(
                                      fontSize: 9,
                                      color: _rxBlue,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),

            const SizedBox(height: 6),
            // ── Interaction hints ─────────────────────────────────────────────
            if (widget.showControls)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _HintChip(
                      icon: Icons.touch_app_outlined,
                      label: 'Drag to zoom',
                    ),
                    const SizedBox(width: 8),
                    _HintChip(
                      icon: Icons.pan_tool_outlined,
                      label: 'Long-press to pan',
                    ),
                    if (_lastDragFrom != null) ...[
                      const SizedBox(width: 8),
                      _HintChip(
                        icon: Icons.undo_outlined,
                        label: 'Tap to undo zoom',
                        highlight: true,
                      ),
                    ],
                  ],
                ),
              ),

            const SizedBox(height: 10),

            // ── Legend ────────────────────────────────────────────────────────
            if (orderedEntries.isNotEmpty)
              Wrap(
                spacing: 14,
                runSpacing: 6,
                children: orderedEntries.asMap().entries.map((e) {
                  final label = _labelFor(e.value.key);
                  final color = _colorFor(label, e.key);
                  // Show last value if available
                  final lastY = e.value.value.isNotEmpty
                      ? e.value.value.last.y
                      : null;
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 20,
                        height: 2.5,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 11,
                          color: _T.textSec(context),
                        ),
                      ),
                      if (lastY != null) ...[
                        const SizedBox(width: 4),
                        Text(
                          _fmtAxis(lastY),
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: color,
                          ),
                        ),
                      ],
                    ],
                  );
                }).toList(),
              ),

            // ── Time range display ────────────────────────────────────────────
            const SizedBox(height: 6),
            Text(
              '${_fromCtrl.text}  →  ${_toCtrl.text}',
              style: TextStyle(fontSize: 9, color: _T.textSec(context)),
            ),
          ],
        ),
      ),
    );
  }

  // ── Custom time picker widget ─────────────────────────────────────────────────
  Widget _buildTimePicker(Color fg) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _T.panel(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _T.rim(context)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: _timeField('From', _fromCtrl)),
              const SizedBox(width: 8),
              Expanded(child: _timeField('To', _toCtrl)),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _loading
                  ? null
                  : () {
                      setState(() {
                        _showTimePicker = false;
                        _activePreset = null;
                      });
                      _loadHistory();
                    },
              style: FilledButton.styleFrom(
                backgroundColor: _rxBlue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Text(
                'Apply Range',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _timeField(String hint, TextEditingController ctrl) {
    return TextField(
      controller: ctrl,
      style: TextStyle(
        fontSize: 11,
        color: _T.textPri(context),
        fontFamily: 'monospace',
      ),
      decoration: InputDecoration(
        labelText: hint,
        labelStyle: TextStyle(fontSize: 10, color: _T.textSec(context)),
        isDense: true,
        filled: true,
        fillColor: _T.card(context),
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: _T.rim(context)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: _T.rim(context)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _rxBlue, width: 1.5),
        ),
      ),
    );
  }
}

// ─── Drag-selection painter ────────────────────────────────────────────────────
// ─── Interaction hint chip ────────────────────────────────────────────────────
class _HintChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool highlight;
  const _HintChip({
    required this.icon,
    required this.label,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = highlight ? ZbxPalette.rxBlue : ZbxTheme.of(context).textSec;
    final textColor = highlight ? ZbxPalette.rxBlue : ZbxTheme.of(context).textSec;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: color.withValues(alpha: highlight ? 0.4 : 0.2),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 9, color: textColor),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 9,
              color: textColor,
              fontWeight: highlight ? FontWeight.w700 : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}

class _SelectionPainter extends CustomPainter {
  final double minX, maxX, startX, endX;
  const _SelectionPainter({
    required this.minX,
    required this.maxX,
    required this.startX,
    required this.endX,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (maxX <= minX) return;
    final l =
        ((startX < endX ? startX : endX) - minX) / (maxX - minX) * size.width;
    final r =
        ((startX < endX ? endX : startX) - minX) / (maxX - minX) * size.width;
    final rect = Rect.fromLTRB(l, 0, r, size.height);
    canvas.drawRect(rect, Paint()..color = _rxBlue.withValues(alpha: 0.12));
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = _rxBlue.withValues(alpha: 0.5)
        ..strokeWidth = 1.2,
    );
  }

  @override
  bool shouldRepaint(covariant _SelectionPainter o) =>
      o.startX != startX || o.endX != endX;
}
