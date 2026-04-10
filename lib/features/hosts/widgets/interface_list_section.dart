import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/zbx_theme.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Data model
// ─────────────────────────────────────────────────────────────────────────────
class InterfaceCardData {
  /// Interface name from LLD macro #IFNAME  (e.g. "1/1/c1/1")
  final String name;

  /// Interface status — from net.if.status[#IFNAME], 1 = up
  final bool isActive;

  /// BW tag value from net.if.intip[#IFNAME]  (e.g. "1G", "10G")
  final String speed;

  /// Inbound traffic Mbps — from net.if.rx_bps[#IFNAME] ÷ 1e6
  final double inBps;

  /// Outbound traffic Mbps — from net.if.tx_bps[#IFNAME] ÷ 1e6
  final double outBps;

  /// Inbound utilisation 0-100 — derived or from net.if.util[#IFNAME,in]
  final double inPct;

  /// Outbound utilisation 0-100 — derived or from net.if.util[#IFNAME,out]
  final double outPct;

  /// Description tag from net.if.intip[#IFNAME]
  final String? description;

  /// LCID tag from net.if.intip[#IFNAME]
  final String? lcid;

  /// QoS tag from net.if.intip[#IFNAME]  (e.g. "GOLD", "SILVER", "BRONZE")
  final String? qos;

  /// Human-readable staleness label  (e.g. "2s ago")
  final String updatedAgo;

  /// When true, render only Rx/Tx traffic UI (for SAP virtual interfaces).
  final bool trafficOnly;

  const InterfaceCardData({
    required this.name,
    required this.isActive,
    required this.speed,
    required this.inBps,
    required this.outBps,
    required this.inPct,
    required this.outPct,
    this.description,
    this.lcid,
    this.qos,
    required this.updatedAgo,
    this.trafficOnly = false,
  });
}

typedef InterfaceCardTapCallback = void Function(InterfaceCardData card);

// ─────────────────────────────────────────────────────────────────────────────
// Main widget
// ─────────────────────────────────────────────────────────────────────────────
class InterfaceListSection extends StatefulWidget {
  final String title;
  final String? subtitle;
  final List<InterfaceCardData> interfaces;
  final int? discoveredCount;
  final InterfaceCardTapCallback? onTap;
  final int? maxItems;
  final Color? accentColor;

  const InterfaceListSection({
    super.key,
    required this.title,
    required this.interfaces,
    this.discoveredCount,
    this.subtitle,
    this.onTap,
    this.maxItems,
    this.accentColor,
  });

  @override
  State<InterfaceListSection> createState() => _InterfaceListSectionState();
}

class _InterfaceListSectionState extends State<InterfaceListSection> {
  String _query = '';

  List<InterfaceCardData> get _filtered {
    final q = _query.toLowerCase();
    if (q.isEmpty) return widget.interfaces;
    return widget.interfaces.where((c) =>
        c.name.toLowerCase().contains(q) ||
        (c.description?.toLowerCase().contains(q) ?? false) ||
        (c.lcid?.toLowerCase().contains(q) ?? false) ||
        (c.qos?.toLowerCase().contains(q) ?? false)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    final visible = widget.maxItems == null
        ? filtered
        : filtered.take(widget.maxItems!).toList();
    final hiddenCount = filtered.length - visible.length;
    final accent = widget.accentColor ?? ZbxPalette.rxBlue;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          title: widget.title,
          subtitle: widget.subtitle,
          readyCount: widget.interfaces.length,
          discoveredCount: widget.discoveredCount,
          accentColor: accent,
        ),
        const SizedBox(height: 10),
        _SearchBar(onChanged: (v) => setState(() => _query = v)),
        const SizedBox(height: 10),
        Divider(height: 1, thickness: 1, color: ZbxT.rim(context)),
        const SizedBox(height: 10),
        if (filtered.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Center(
              child: Text(
                'No interfaces match "$_query"',
                style: TextStyle(fontSize: 11, color: ZbxT.textSec(context)),
              ),
            ),
          )
        else
          ...visible.map((card) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _InterfaceGaugeCard(
                  data: card,
                  accentColor: accent,
                  onTap: widget.onTap == null ? null : () => widget.onTap!(card),
                ),
              )),
        if (hiddenCount > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '+ $hiddenCount more interface${hiddenCount == 1 ? '' : 's'}',
              style: TextStyle(fontSize: 10, color: ZbxT.textSec(context)),
            ),
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Section header
// ─────────────────────────────────────────────────────────────────────────────
class _SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final int readyCount;
  final int? discoveredCount;
  final Color accentColor;
  const _SectionHeader({
    required this.title,
    required this.readyCount,
    this.discoveredCount,
    required this.accentColor,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Container(width: 3, height: 32, color: accentColor),
      const SizedBox(width: 8),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: ZbxT.textSec(context),
                letterSpacing: 1.0),
          ),
          if (subtitle != null)
            Text(subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: ZbxT.textPri(context))),
        ]),
      ),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 84),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: accentColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(4),
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              discoveredCount != null
                  ? '$readyCount/$discoveredCount'
                  : '$readyCount',
              maxLines: 1,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: accentColor),
            ),
          ),
        ),
      ),
    ]);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Search bar
// ─────────────────────────────────────────────────────────────────────────────
class _SearchBar extends StatelessWidget {
  final ValueChanged<String> onChanged;
  const _SearchBar({required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      decoration: BoxDecoration(
        color: ZbxT.card(context),
        border: Border.all(color: ZbxT.rim(context)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(children: [
        const SizedBox(width: 10),
        Icon(Icons.search, size: 13, color: ZbxT.textSec(context)),
        const SizedBox(width: 6),
        Expanded(
          child: TextField(
            onChanged: onChanged,
            style: TextStyle(fontSize: 12, color: ZbxT.textPri(context)),
            decoration: InputDecoration(
              hintText: 'Search interfaces…',
              hintStyle:
                  TextStyle(fontSize: 12, color: ZbxT.textSec(context)),
              border: InputBorder.none,
              isDense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Interface gauge card
// ─────────────────────────────────────────────────────────────────────────────
class _InterfaceGaugeCard extends StatelessWidget {
  final InterfaceCardData data;
  final Color accentColor;
  final VoidCallback? onTap;

  const _InterfaceGaugeCard({
    required this.data,
    required this.accentColor,
    this.onTap,
  });

  static Color _utilColor(double pct) {
    if (pct >= 90) return const Color(0xFFE53935);
    if (pct >= 70) return const Color(0xFFFF9800);
    return const Color(0xFF66BB6A);
  }

  Color get _statusColor =>
      data.isActive ? const Color(0xFF66BB6A) : const Color(0xFFE53935);

  String _fmtMbps(double v) {
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}\nGbps';
    if (v >= 1) {
      final s = v >= 10 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
      return '$s\nMbps';
    }
    final kbps = v * 1000;
    final s = kbps >= 10 ? kbps.toStringAsFixed(0) : kbps.toStringAsFixed(1);
    return '$s\nKbps';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Slightly elevated surface vs the page background
    final cardBg = isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF5F5F5);
    final rimCol = ZbxT.rim(context);
    final inColor  = _utilColor(data.inPct);
    final outColor = _utilColor(data.outPct);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: rimCol.withValues(alpha: 0.6)),
        ),
        child: IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // Left accent strip
            Container(
              width: 4,
              decoration: BoxDecoration(
                color: accentColor,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(10),
                  bottomLeft: Radius.circular(10),
                ),
              ),
            ),

            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [

                    // ── Row 1: name · description · status ──────────
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  data.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                    color: ZbxT.textPri(context),
                                    fontFamily: 'monospace',
                                    letterSpacing: 0.3,
                                  ),
                                ),
                              ),
                              if (data.description != null) ...[
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Padding(
                                    padding: const EdgeInsets.only(top: 3),
                                    child: Text(
                                      data.description!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: ZbxT.textSec(context)),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (!data.trafficOnly) ...[
                          const SizedBox(width: 8),
                          // Status indicator
                          Row(mainAxisSize: MainAxisSize.min, children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: _statusColor,
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: _statusColor.withValues(alpha: 0.45),
                                    blurRadius: 5,
                                    spreadRadius: 1,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              data.isActive ? 'Active' : 'Down',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: _statusColor,
                              ),
                            ),
                          ]),
                        ],
                      ],
                    ),

                    const SizedBox(height: 12),

                    if (data.trafficOnly)
                      Row(
                        children: [
                          Expanded(
                            child: _TrafficTile(
                              label: 'RX',
                              valueText: _fmtMbps(data.inBps),
                              color: accentColor,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _TrafficTile(
                              label: 'TX',
                              valueText: _fmtMbps(data.outBps),
                              color: accentColor,
                            ),
                          ),
                        ],
                      )
                    else ...[
                      // ── Row 2: dual arc gauges ───────────────────────
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _GaugeWidget(
                            label: 'IN',
                            valueText: _fmtMbps(data.inBps),
                            pct: data.inPct,
                            arcColor: inColor,
                            trackColor: rimCol,
                          ),
                          _GaugeWidget(
                            label: 'OUT',
                            valueText: _fmtMbps(data.outBps),
                            pct: data.outPct,
                            arcColor: outColor,
                            trackColor: rimCol,
                          ),
                        ],
                      ),

                      const SizedBox(height: 10),
                      Divider(height: 1, thickness: 1, color: rimCol),
                      const SizedBox(height: 8),

                      // ── Row 3: LCID · BW · QoS ──────────────────────
                      Row(children: [
                        if (data.lcid != null) ...[
                          Text('LCID: ',
                              style: TextStyle(
                                  fontSize: 10,
                                  color: ZbxT.textSec(context))),
                          Text(
                            data.lcid!,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: ZbxT.textPri(context),
                              fontFamily: 'monospace',
                            ),
                          ),
                          const SizedBox(width: 14),
                        ],
                        Text(
                          data.speed,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: ZbxT.textSec(context),
                          ),
                        ),
                        const Spacer(),
                        if (data.qos != null) _QosBadge(qos: data.qos!),
                      ]),

                      const SizedBox(height: 5),

                      // ── Row 4: updated ───────────────────────────────
                      Text(
                        'Updated ${data.updatedAgo}',
                        style: TextStyle(
                          fontSize: 9,
                          color: ZbxT.textSec(context).withValues(alpha: 0.5),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _TrafficTile extends StatelessWidget {
  final String label;
  final String valueText;
  final Color color;

  const _TrafficTile({
    required this.label,
    required this.valueText,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final parts = valueText.split('\n');
    final numStr = parts.isNotEmpty ? parts[0] : '-';
    final unitStr = parts.length > 1 ? parts[1] : '';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: ZbxT.card(context),
        border: Border.all(color: ZbxT.rim(context)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
              color: color,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            numStr,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: ZbxT.textPri(context),
              height: 1.0,
            ),
          ),
          Text(
            unitStr,
            style: TextStyle(fontSize: 10, color: ZbxT.textSec(context)),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Arc gauge widget
// ─────────────────────────────────────────────────────────────────────────────
class _GaugeWidget extends StatelessWidget {
  final String label;
  final String valueText; // "120\nMbps"
  final double pct;
  final Color arcColor;
  final Color trackColor;

  const _GaugeWidget({
    required this.label,
    required this.valueText,
    required this.pct,
    required this.arcColor,
    required this.trackColor,
  });

  @override
  Widget build(BuildContext context) {
    final fraction = (pct / 100).clamp(0.0, 1.0);
    final parts    = valueText.split('\n');
    final numStr   = parts.isNotEmpty ? parts[0] : '';
    final unitStr  = parts.length > 1  ? parts[1] : '';

    return Column(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        width: 110,
        height: 110,
        child: Stack(alignment: Alignment.center, children: [
          CustomPaint(
            size: const Size(110, 110),
            painter: _ArcGaugePainter(
              fraction: fraction,
              arcColor: arcColor,
              trackColor: trackColor,
            ),
          ),
          // Centre value
          Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
              numStr,
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w800,
                color: ZbxT.textPri(context),
                height: 1.0,
              ),
            ),
            Text(
              unitStr,
              style: TextStyle(
                fontSize: 10,
                color: ZbxT.textSec(context),
                height: 1.2,
              ),
            ),
          ]),
          // % label near bottom gap
          Positioned(
            bottom: 8,
            child: Text(
              '${pct.toStringAsFixed(0)}%',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: arcColor,
              ),
            ),
          ),
        ]),
      ),
      const SizedBox(height: 3),
      Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: ZbxT.textSec(context),
          letterSpacing: 1.5,
        ),
      ),
    ]);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Arc gauge painter — open horseshoe, tick marks at 25 / 50 / 75 %
// ─────────────────────────────────────────────────────────────────────────────
class _ArcGaugePainter extends CustomPainter {
  final double fraction;
  final Color arcColor;
  final Color trackColor;

  const _ArcGaugePainter({
    required this.fraction,
    required this.arcColor,
    required this.trackColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const startAngle = math.pi * 0.65;  // ~117°
    const sweepFull  = math.pi * 1.70;  // ~306°
    final strokeW    = size.width * 0.095;
    final center     = Offset(size.width / 2, size.height / 2);
    final radius     = (size.width - strokeW) / 2;
    final rect       = Rect.fromCircle(center: center, radius: radius);

    // Track arc
    canvas.drawArc(
      rect, startAngle, sweepFull, false,
      Paint()
        ..color       = trackColor
        ..style       = PaintingStyle.stroke
        ..strokeCap   = StrokeCap.round
        ..strokeWidth = strokeW,
    );

    // Value arc
    if (fraction > 0) {
      canvas.drawArc(
        rect, startAngle, sweepFull * fraction, false,
        Paint()
          ..color       = arcColor
          ..style       = PaintingStyle.stroke
          ..strokeCap   = StrokeCap.round
          ..strokeWidth = strokeW,
      );
    }

    // Tick marks at 25 / 50 / 75 %
    final tickPaint = Paint()
      ..color       = trackColor.withValues(alpha: 0.85)
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 1.8;
    final outerR = radius + strokeW * 0.35;
    final innerR = radius - strokeW * 0.35;
    for (final t in [0.25, 0.50, 0.75]) {
      final a = startAngle + sweepFull * t;
      canvas.drawLine(
        center + Offset(math.cos(a) * innerR, math.sin(a) * innerR),
        center + Offset(math.cos(a) * outerR, math.sin(a) * outerR),
        tickPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_ArcGaugePainter old) =>
      old.fraction != fraction ||
      old.arcColor != arcColor ||
      old.trackColor != trackColor;
}

// ─────────────────────────────────────────────────────────────────────────────
// QoS tier badge
// ─────────────────────────────────────────────────────────────────────────────
class _QosBadge extends StatelessWidget {
  final String qos;
  const _QosBadge({required this.qos});

  Color _color() {
    switch (qos.toUpperCase()) {
      case 'GOLD':   return const Color(0xFFFFB300);
      case 'SILVER': return const Color(0xFF9E9E9E);
      case 'BRONZE': return const Color(0xFF8D6E63);
      default:       return const Color(0xFF42A5F5);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _color();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.15),
        border: Border.all(color: c.withValues(alpha: 0.55)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        qos.toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          color: c,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}
