import 'package:flutter/material.dart';
import '../../core/zbx_theme.dart';

const _rxBlue = ZbxPalette.rxBlue;
const _txGreen = ZbxPalette.txGreen;

// ── Theme-aware color helper ──────────────────────────────────────────────────
// ── Theme-aware color helper ──────────────────────────────────────────────────
class _T {
  static Color card(BuildContext ctx) => ZbxTheme.of(ctx).bgCard;
  static Color lift(BuildContext ctx) => ZbxTheme.of(ctx).bgLift;
  static Color panel(BuildContext ctx) => ZbxTheme.of(ctx).bgPanel;
  static Color rim(BuildContext ctx) => ZbxTheme.of(ctx).rim;
  static Color textPri(BuildContext ctx) => ZbxTheme.of(ctx).textPri;
  static Color textSec(BuildContext ctx) => ZbxTheme.of(ctx).textSec;
  static Color textMono(BuildContext ctx) => ZbxTheme.of(ctx).textMono;
}

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'About',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        backgroundColor: _T.card(context),
        surfaceTintColor: Colors.transparent,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: _T.rim(context)),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 32, 20, 48),
        children: [
          // Logo / icon block
          Center(
            child: Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: _rxBlue.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _rxBlue.withValues(alpha: 0.3)),
              ),
              child: const Icon(
                Icons.monitor_heart_outlined,
                size: 42,
                color: _rxBlue,
              ),
            ),
          ),
          const SizedBox(height: 18),
          Center(
            child: Text(
              'Zabbix Monitor',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: _T.textPri(context),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Center(
            child: Text(
              'v1.0.0',
              style: TextStyle(fontSize: 13, color: _T.textSec(context)),
            ),
          ),
          const SizedBox(height: 32),

          _infoCard(context, 'Application', [
            ('Purpose', 'Real-time Zabbix network monitoring for Android'),
            ('Backend', 'Node.js relay server on local network'),
            ('Push', 'Firebase Cloud Messaging'),
          ]),
          const SizedBox(height: 12),

          _infoCard(context, 'Supported Host Types', [
            ('Network Devices', 'BNG & PE routers (Nokia / Cisco)'),
            ('ICMP Monitoring', 'SR / ICMP / TIP_OLT host groups'),
            ('Script Monitor', 'Python collector health metrics'),
          ]),
          const SizedBox(height: 12),

          _infoCard(context, 'Templates', [
            ('BNG_Network_Statistics', 'Interface stats, SAP, Rx Power'),
            ('PE_Network_Statistics', 'Interface stats, ARP, Customer, VRF'),
            ('ICMP Template', 'Latency, jitter, packet loss'),
            ('OLT Reachability', 'Ping metrics for OLT devices'),
            ('Monitor Script Health', 'Collector performance'),
          ]),
          const SizedBox(height: 12),

          _infoCard(context, 'Built With', [
            ('Flutter', 'UI framework (Dart)'),
            ('fl_chart', 'Line graphs'),
            ('Firebase Messaging', 'Push notifications'),
            ('flutter_secure_storage', 'Secure token storage (Keystore/Keychain)'),
            ('google_fonts', 'Inter typography'),
            ('path_provider', 'Local cache persistence'),
          ]),

          const SizedBox(height: 32),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _rxBlue.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _rxBlue.withValues(alpha: 0.2)),
            ),
            child: Text(
              'For internal network operations use only.\n'
              'Configure the relay server IP in ApiClient before deployment.',
              style: TextStyle(
                fontSize: 12,
                color: _T.textSec(context),
                height: 1.6,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoCard(
    BuildContext context,
    String title,
    List<(String, String)> rows,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: _T.card(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _T.rim(context)),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              color: _T.textSec(context),
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 10),
          ...rows.asMap().entries.map((e) {
            return Padding(
              padding: EdgeInsets.only(bottom: e.key < rows.length - 1 ? 8 : 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 130,
                    child: Text(
                      e.value.$1,
                      style: TextStyle(
                        fontSize: 12,
                        color: _T.textSec(context),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      e.value.$2,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: _T.textPri(context),
                      ),
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
}
