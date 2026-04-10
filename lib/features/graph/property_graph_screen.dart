import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/utils.dart';
import '../../core/zbx_theme.dart';
import 'interactive_line_graph.dart';

const _rxBlue = ZbxPalette.rxBlue;

/// Standalone full-screen graph for a set of selected numeric items.
/// Delegates entirely to [InteractiveLineGraph].
class PropertyGraphScreen extends StatefulWidget {
  final String hostName;
  final List<dynamic> items;

  const PropertyGraphScreen({
    super.key,
    required this.hostName,
    required this.items,
  });

  @override
  State<PropertyGraphScreen> createState() => _PropertyGraphScreenState();
}

class _PropertyGraphScreenState extends State<PropertyGraphScreen> {
  final _fromCtrl = TextEditingController();
  final _toCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _fromCtrl.text = formatDateTimeInput(
      DateTime.fromMillisecondsSinceEpoch((now - 3600) * 1000).toLocal(),
    );
    _toCtrl.text = formatDateTimeInput(
      DateTime.fromMillisecondsSinceEpoch(now * 1000).toLocal(),
    );
  }

  @override
  void dispose() {
    _fromCtrl.dispose();
    _toCtrl.dispose();
    super.dispose();
  }

  List<dynamic> get _numericItems => widget.items.where(isNumericItem).toList();

  @override
  Widget build(BuildContext context) {
    final isDark = ZbxTheme.of(context).isDark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: ZbxT.scaffold(context),
        appBar: AppBar(
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
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Properties Graph',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: ZbxT.textPri(context),
                ),
              ),
              Text(
                widget.hostName,
                style: TextStyle(fontSize: 11, color: ZbxT.textSec(context)),
              ),
            ],
          ),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(1),
            child: Container(height: 1, color: ZbxT.rim(context)),
          ),
        ),
        body: _numericItems.isEmpty
            ? _buildEmpty(context)
            : ListView(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 40),
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: _numericItems.take(8).map((item) {
                      final name = (item['name'] ?? item['key_'] ?? '')
                          .toString()
                          .replaceAll(RegExp(r'\[.*?\]'), '')
                          .trim();
                      final value = (item['lastvalue'] ?? '-').toString();
                      final unit = (item['units'] ?? '').toString();
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: _rxBlue.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: _rxBlue.withValues(alpha: 0.3),
                          ),
                        ),
                        child: Text(
                          '$name: $value${unit.isNotEmpty ? ' $unit' : ''}',
                          style: TextStyle(
                            fontSize: 11,
                            color: ZbxT.textPri(context),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),
                  InteractiveLineGraph(
                    selectedNumericItems: _numericItems,
                    externalFromController: _fromCtrl,
                    externalToController: _toCtrl,
                    showControls: true,
                    mode: GraphRenderMode.line,
                    backgroundColor: ZbxT.card(context),
                    foregroundColor: ZbxT.textPri(context),
                    chartHeight: 320,
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.show_chart,
            size: 52,
            color: ZbxT.textSec(context).withValues(alpha: 0.4),
          ),
          const SizedBox(height: 14),
          Text(
            'No numeric items to graph',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: ZbxT.textSec(context),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Select items with numeric values first.',
            style: TextStyle(fontSize: 12, color: ZbxT.textSec(context)),
          ),
        ],
      ),
    );
  }
}
