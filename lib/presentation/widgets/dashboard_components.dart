import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/utils.dart';
import '../../core/zbx_theme.dart';

enum DashboardVisualStyle { standard, metro }

Widget buildDashboardErrorBanner(
  BuildContext context,
  String message, {
  DashboardVisualStyle style = DashboardVisualStyle.standard,
}) {
  switch (style) {
    case DashboardVisualStyle.metro:
      return Container(
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        color: ZbxPalette.downRed,
        child: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.white, size: 15),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  fontSize: 11,
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      );
    case DashboardVisualStyle.standard:
      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: ZbxPalette.downRed.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: ZbxPalette.downRed.withValues(alpha: 0.3),
          ),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.error_outline,
              color: ZbxPalette.downRed,
              size: 15,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  fontSize: 11,
                  color: ZbxPalette.downRed,
                ),
              ),
            ),
          ],
        ),
      );
  }
}

Widget buildDashboardSectionHeader(
  BuildContext context,
  String title,
  IconData icon, {
  DashboardVisualStyle style = DashboardVisualStyle.standard,
}) {
  switch (style) {
    case DashboardVisualStyle.metro:
      return Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Row(
          children: [
            Container(width: 3, height: 18, color: ZbxPalette.rxBlue),
            const SizedBox(width: 8),
            Icon(icon, size: 12, color: ZbxT.textSec(context)),
            const SizedBox(width: 6),
            Text(
              title,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w800,
                color: ZbxT.textSec(context),
                letterSpacing: 1.0,
              ),
            ),
          ],
        ),
      );
    case DashboardVisualStyle.standard:
      return Row(
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
          const SizedBox(width: 8),
          Expanded(child: Container(height: 1, color: ZbxT.rim(context))),
        ],
      );
  }
}

class DashboardStatTile extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;
  final List<int>? trendValues;
  final int? trendDelta;
  final DashboardVisualStyle style;

  const DashboardStatTile({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.onTap,
    this.trendValues,
    this.trendDelta,
    this.style = DashboardVisualStyle.standard,
  });

  @override
  Widget build(BuildContext context) {
    switch (style) {
      case DashboardVisualStyle.metro:
        return GestureDetector(
          onTap: onTap,
          child: Container(
            color: color,
            padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
            child: Stack(
              children: [
                Positioned(
                  right: -8,
                  bottom: -10,
                  child: Icon(
                    icon,
                    size: 56,
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            label.toUpperCase(),
                            style: TextStyle(
                              fontSize: 9,
                              color: Colors.white.withValues(alpha: 0.82),
                              fontWeight: FontWeight.w500,
                              letterSpacing: 0.8,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            value,
                            style: const TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                              height: 1.0,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if ((trendValues ?? const <int>[]).length >= 2)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: _TrendMini(
                          values: trendValues!,
                          accent: Colors.white,
                          delta: trendDelta ?? 0,
                        ),
                      ),
                    if (onTap != null)
                      const Icon(
                        Icons.chevron_right,
                        size: 14,
                        color: Colors.white,
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      case DashboardVisualStyle.standard:
        return GestureDetector(
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
  }
}

class DashboardSeverityBar extends StatelessWidget {
  final List<dynamic> problems;
  final DashboardVisualStyle style;

  const DashboardSeverityBar({
    super.key,
    required this.problems,
    this.style = DashboardVisualStyle.standard,
  });

  static const _standardColors = {
    5: Color(0xFF7B1FA2),
    4: Color(0xFFEF5350),
    3: Color(0xFFFFAB40),
    2: Color(0xFFFFD54F),
    1: Color(0xFF29B6F6),
    0: Color(0xFF7A90B4),
  };

  static const _metroColors = {
    5: Color(0xFF7B1FA2),
    4: Color(0xFFE51400),
    3: Color(0xFFFA6800),
    2: Color(0xFFF0A30A),
    1: Color(0xFF1BA1E2),
    0: Color(0xFF647687),
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
    for (final problem in problems) {
      final severity = severityValue(problem['priority']?.toString() ?? '0');
      counts[severity] = (counts[severity] ?? 0) + 1;
    }

    final total = problems.length;
    final colors = style == DashboardVisualStyle.metro
        ? _metroColors
        : _standardColors;

    switch (style) {
      case DashboardVisualStyle.metro:
        return Container(
          color: ZbxT.card(context),
          child: Column(
            children: [
              SizedBox(
                height: 12,
                child: Row(
                  children: [5, 4, 3, 2, 1, 0].map((severity) {
                    final count = counts[severity] ?? 0;
                    if (count == 0 || total == 0) {
                      return const SizedBox.shrink();
                    }
                    return Flexible(
                      flex: count,
                      child: Container(color: colors[severity]),
                    );
                  }).toList(),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                child: Wrap(
                  spacing: 14,
                  runSpacing: 6,
                  children: [5, 4, 3, 2, 1, 0]
                      .where((severity) => (counts[severity] ?? 0) > 0)
                      .map(
                        (severity) => Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              color: colors[severity],
                            ),
                            const SizedBox(width: 5),
                            Text(
                              '${_labels[severity]} (${counts[severity]})',
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
              ),
            ],
          ),
        );
      case DashboardVisualStyle.standard:
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
                    children: [5, 4, 3, 2, 1, 0].map((severity) {
                      final count = counts[severity] ?? 0;
                      if (count == 0 || total == 0) {
                        return const SizedBox.shrink();
                      }
                      return Flexible(
                        flex: count,
                        child: Container(color: colors[severity]),
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
                    .where((severity) => (counts[severity] ?? 0) > 0)
                    .map(
                      (severity) => Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: colors[severity],
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 5),
                          Text(
                            '${_labels[severity]} (${counts[severity]})',
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
}

class DashboardGroupAlertRow extends StatelessWidget {
  final String group;
  final int count;
  final int maxSeverity;
  final VoidCallback? onTap;
  final DashboardVisualStyle style;

  const DashboardGroupAlertRow({
    super.key,
    required this.group,
    required this.count,
    required this.maxSeverity,
    this.onTap,
    this.style = DashboardVisualStyle.standard,
  });

  @override
  Widget build(BuildContext context) {
    final color = severityColor('$maxSeverity');

    switch (style) {
      case DashboardVisualStyle.metro:
        return GestureDetector(
          onTap: onTap,
          child: Container(
            margin: const EdgeInsets.only(bottom: 2),
            color: ZbxT.card(context),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(width: 4, color: color),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 11,
                      ),
                      child: Row(
                        children: [
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
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            color: color,
                            child: Text(
                              '$count',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w900,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          if (onTap != null) ...[
                            const SizedBox(width: 8),
                            Icon(
                              Icons.chevron_right,
                              size: 14,
                              color: ZbxT.textSec(context).withValues(alpha: 0.4),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      case DashboardVisualStyle.standard:
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
        .map((entry) => FlSpot(entry.key.toDouble(), entry.value.toDouble()))
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
