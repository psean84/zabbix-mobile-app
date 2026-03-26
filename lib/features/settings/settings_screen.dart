import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/app_cache.dart';
import '../../core/app_settings.dart';
import '../../core/local_store.dart';
import '../../core/zbx_theme.dart';

const _rxBlue = ZbxPalette.rxBlue;
const _txGreen = ZbxPalette.txGreen;
const _downRed = ZbxPalette.downRed;
const _warnAmb = ZbxPalette.warnAmb;
const _textSec = ZbxPalette.textSecDark;

const _sevLabels = <int, String>{
  0: 'Not classified',
  1: 'Information',
  2: 'Warning',
  3: 'Average',
  4: 'High',
  5: 'Disaster',
};
Color _sevColor(int s) {
  switch (s) {
    case 5:
      return const Color(0xFF7B1FA2);
    case 4:
      return _downRed;
    case 3:
      return _warnAmb;
    case 2:
      return const Color(0xFFFFD54F);
    case 1:
      return _rxBlue;
    default:
      return _textSec;
  }
}

bool _isPeGroup(String n) => n.toLowerCase().contains('pe');

// ── Theme-aware color helper ──────────────────────────────────────────────────
// ── Theme helper via ZbxT (see zbx_theme.dart) ────

class SettingsScreen extends StatefulWidget {
  final AppSettings settings;
  const SettingsScreen({super.key, required this.settings});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late Set<int> _sev;
  late Set<String> _groups;
  late Set<String> _hosts;
  late Set<String> _vrfs;
  late Set<String> _customers;
  bool _allowSelfSigned = false;
  String _grpSearch = '', _hostSearch = '', _vrfSearch = '';

  @override
  void initState() {
    super.initState();
    final f = widget.settings.notifFilter;
    _sev = Set.from(f.severities);
    _groups = Set.from(f.hostgroups);
    _hosts = Set.from(f.hosts);
    _vrfs = Set.from(f.vrfs);
    _customers = Set.from(f.customers);
    _allowSelfSigned = widget.settings.allowSelfSignedCertificates;
    AppCache.instance.addListener(_r);
  }

  @override
  void dispose() {
    AppCache.instance.removeListener(_r);
    super.dispose();
  }

  void _r() {
    if (mounted) setState(() {});
  }

  List<String> get _allGroups =>
      AppCache.instance.hostGroups
          .map((g) => (g['name'] ?? '').toString())
          .where((n) => n.isNotEmpty)
          .toList()
        ..sort();

  List<String> get _filteredHosts {
    final cache = AppCache.instance;
    if (cache.hosts.isEmpty) return [];
    if (_groups.isEmpty) {
      return cache.hosts
          .map((h) => (h['name'] ?? h['host'] ?? '').toString())
          .where((n) => n.isNotEmpty)
          .toList()
        ..sort();
    }
    final out = <String>{};
    for (final h in cache.hosts) {
      final name = (h['name'] ?? h['host'] ?? '').toString();
      if (name.isEmpty) continue;
      final gs = h['groups'] ?? h['hostgroups'] ?? [];
      if (gs is List &&
          gs.any((g) => _groups.contains((g['name'] ?? '').toString()))) {
        out.add(name);
      }
    }
    return out.toList()..sort();
  }

  bool get _vrfAvailable => _groups.isNotEmpty && _groups.any(_isPeGroup);
  List<String> get _filteredVrfs {
    final all = AppCache.instance.allVrfs;
    if (_vrfSearch.isEmpty) return all;
    final q = _vrfSearch.toLowerCase();
    return all.where((v) {
      final c = AppCache.instance.customerForVrf(v).toLowerCase();
      return v.toLowerCase().contains(q) || c.contains(q);
    }).toList();
  }

  Future<void> _save() async {
    final f = NotifFilter(
      severities: Set.from(_sev),
      hostgroups: Set.from(_groups),
      hosts: Set.from(_hosts),
      vrfs: Set.from(_vrfs),
      customers: Set.from(_customers),
    );
    await widget.settings.setNotifFilter(f);
    try {
      final s = await LocalStore.readMap('fcm:token');
      final t = (s?['token'] ?? '').toString();
      if (t.isNotEmpty) await ApiClient.updateDeviceFilter(t, f.toJson());
    } catch (_) {}
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Filter saved & synced'),
        backgroundColor: _txGreen,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  Future<void> _setAllowSelfSigned(bool value) async {
    setState(() => _allowSelfSigned = value);
    await widget.settings.setAllowSelfSignedCertificates(value);
    ApiClient.setAllowSelfSignedCertificates(value);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          value
              ? 'Self-signed TLS enabled for this app session.'
              : 'Strict TLS validation restored.',
        ),
        backgroundColor: value ? _warnAmb : _txGreen,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isWide = screenWidth >= 900;
    final wideCardWidth = (screenWidth - 48) / 2;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'Settings',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        backgroundColor: ZbxT.card(context),
        surfaceTintColor: Colors.transparent,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: ZbxT.rim(context)),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 60),
        children: [
          _sec('THEME', Icons.brightness_medium_outlined),
          const SizedBox(height: 10),
          _buildTheme(),
          const SizedBox(height: 20),
          _sec('SECURITY', Icons.security_outlined),
          const SizedBox(height: 10),
          _buildSecurity(),
          const SizedBox(height: 20),
          _sec('FONT SIZE', Icons.text_fields_outlined),
          const SizedBox(height: 10),
          _buildFonts(),
          const SizedBox(height: 24),
          _sec('NOTIFICATION FILTER', Icons.notifications_outlined),
          const SizedBox(height: 8),
          _info(
            'Filters cascade: Host Groups → Hosts (filtered by selected groups) → VRF (PE groups only). Empty = all alerts received.',
          ),
          const SizedBox(height: 14),
          if (isWide)
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                SizedBox(
                  width: wideCardWidth,
                  child: _card(
                    'Severity',
                    _sev.length == 6
                        ? 'All levels (default)'
                        : '${_sev.length} of 6',
                    _buildSev(),
                  ),
                ),
                SizedBox(
                  width: wideCardWidth,
                  child: _card(
                    'Host Groups',
                    _groups.isEmpty
                        ? 'All groups (default)'
                        : '${_groups.length} selected',
                    _buildGroups(),
                  ),
                ),
                SizedBox(
                  width: wideCardWidth,
                  child: _card(
                    'Hosts',
                    _hosts.isEmpty
                        ? (_groups.isEmpty
                              ? 'All hosts (default)'
                              : 'All hosts in selected groups')
                        : '${_hosts.length} selected',
                    _buildHosts(),
                  ),
                ),
                SizedBox(
                  width: wideCardWidth,
                  child: _vrfAvailable
                      ? _card(
                          'VRF / Customer',
                          _vrfs.isEmpty
                              ? 'All VRFs (default)'
                              : '${_vrfs.length} selected',
                          _buildVrfs(),
                        )
                      : Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: ZbxT.card(context).withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: ZbxT.rim(context).withValues(alpha: 0.4),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.lan_outlined,
                                size: 14,
                                color: ZbxT.textSec(context),
                              ),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'VRF ??? select a PE host group first',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: ZbxT.textSec(context),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
              ],
            )
          else ...[
            _card(
              'Severity',
              _sev.length == 6 ? 'All levels (default)' : '${_sev.length} of 6',
              _buildSev(),
            ),
            const SizedBox(height: 10),
            _card(
              'Host Groups',
              _groups.isEmpty
                  ? 'All groups (default)'
                  : '${_groups.length} selected',
              _buildGroups(),
            ),
            const SizedBox(height: 10),
            _card(
              'Hosts',
              _hosts.isEmpty
                  ? (_groups.isEmpty
                        ? 'All hosts (default)'
                        : 'All hosts in selected groups')
                  : '${_hosts.length} selected',
              _buildHosts(),
            ),
            const SizedBox(height: 10),
            _vrfAvailable
                ? _card(
                    'VRF / Customer',
                    _vrfs.isEmpty
                        ? 'All VRFs (default)'
                        : '${_vrfs.length} selected',
                    _buildVrfs(),
                  )
                : Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: ZbxT.card(context).withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: ZbxT.rim(context).withValues(alpha: 0.4),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.lan_outlined,
                          size: 14,
                          color: ZbxT.textSec(context),
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'VRF ??? select a PE host group first',
                            style: TextStyle(
                              fontSize: 11,
                              color: ZbxT.textSec(context),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
          ],
          const SizedBox(height: 24),
          FilledButton.icon(
            icon: const Icon(Icons.save_outlined, size: 18),
            label: const Text(
              'Save Notification Filter',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            onPressed: _save,
            style: FilledButton.styleFrom(
              backgroundColor: _rxBlue,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => setState(() {
              _sev = {0, 1, 2, 3, 4, 5};
              _groups.clear();
              _hosts.clear();
              _vrfs.clear();
              _customers.clear();
            }),
            child: Text(
              'Reset all filters',
              style: TextStyle(color: ZbxT.textSec(context), fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTheme() => Row(
    children: AppThemeMode.values.map((m) {
      final active = widget.settings.themeMode == m;
      return Expanded(
        child: GestureDetector(
          onTap: () => widget.settings.setThemeMode(m),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            margin: const EdgeInsets.symmetric(horizontal: 4),
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: active
                  ? _rxBlue.withValues(alpha: 0.15)
                  : ZbxT.card(context),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: active ? _rxBlue : ZbxT.rim(context),
                width: active ? 1.5 : 1,
              ),
            ),
            child: Column(
              children: [
                Icon(
                  m.icon,
                  size: 20,
                  color: active ? _rxBlue : ZbxT.textSec(context),
                ),
                SizedBox(height: 5),
                Text(
                  m.label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: active ? FontWeight.w700 : FontWeight.normal,
                    color: active ? _rxBlue : ZbxT.textSec(context),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }).toList(),
  );

  Widget _buildSecurity() => Container(
    decoration: BoxDecoration(
      color: ZbxT.card(context),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: ZbxT.rim(context)),
    ),
    child: Column(
      children: [
        SwitchListTile(
          value: _allowSelfSigned,
          onChanged: _setAllowSelfSigned,
          activeThumbColor: _warnAmb,
          activeTrackColor: _warnAmb.withValues(alpha: 0.35),
          title: Text(
            'Allow Self-Signed TLS Certificate',
            style: TextStyle(
              color: ZbxT.textPri(context),
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          subtitle: Text(
            'Use only for lab/internal testing. Keep OFF in production.',
            style: TextStyle(color: ZbxT.textSec(context), fontSize: 11),
          ),
        ),
        Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: _warnAmb.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _warnAmb.withValues(alpha: 0.35)),
          ),
          child: Text(
            'When enabled, the app only bypasses certificate trust checks for the configured API host.',
            style: TextStyle(fontSize: 11, color: ZbxT.textSec(context)),
          ),
        ),
      ],
    ),
  );

  Widget _buildFonts() => Container(
    decoration: BoxDecoration(
      color: ZbxT.card(context),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: ZbxT.rim(context)),
    ),
    padding: const EdgeInsets.all(14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Text(
            'Interface GigabitEthernet0/0/0  Rx: 450 Mbps',
            style: TextStyle(
              fontSize: 14 * widget.settings.fontSize.scale,
              color: ZbxT.textPri(context),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Row(
          children: AppFontSize.values.map((sz) {
            final active = widget.settings.fontSize == sz;
            return Expanded(
              child: GestureDetector(
                onTap: () => widget.settings.setFontSize(sz),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: active
                        ? _rxBlue.withValues(alpha: 0.15)
                        : ZbxT.lift(context),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: active ? _rxBlue : ZbxT.rim(context),
                      width: active ? 1.5 : 1,
                    ),
                  ),
                  child: Column(
                    children: [
                      Text(
                        'Aa',
                        style: TextStyle(
                          fontSize: 8 + sz.index * 2.0,
                          fontWeight: FontWeight.w700,
                          color: active ? _rxBlue : ZbxT.textSec(context),
                        ),
                      ),
                      SizedBox(height: 3),
                      Text(
                        sz.label.split(' ').first,
                        style: TextStyle(
                          fontSize: 8,
                          color: active ? _rxBlue : ZbxT.textSec(context),
                          letterSpacing: 0.2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    ),
  );

  Widget _buildSev() => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [5, 4, 3, 2, 1, 0].map((s) {
      final active = _sev.contains(s);
      final color = _sevColor(s);
      return GestureDetector(
        onTap: () => setState(() {
          if (active) {
            if (_sev.length > 1) _sev.remove(s);
          } else {
            _sev.add(s);
          }
        }),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: active ? color.withValues(alpha: 0.15) : ZbxT.lift(context),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: active ? color : ZbxT.rim(context),
              width: active ? 1.5 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (active) ...[
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 5),
              ],
              Text(
                _sevLabels[s] ?? '$s',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: active ? color : ZbxT.textSec(context),
                ),
              ),
            ],
          ),
        ),
      );
    }).toList(),
  );

  Widget _buildGroups() {
    final items = _allGroups
        .where(
          (g) =>
              _grpSearch.isEmpty ||
              g.toLowerCase().contains(_grpSearch.toLowerCase()),
        )
        .toList();
    return _CList(
      items: items,
      selected: _groups,
      hint: 'Search host groups…',
      onSearch: (v) => setState(() => _grpSearch = v),
      onToggle: (n, add) => setState(() {
        if (add) {
          _groups.add(n);
        } else {
          _groups.remove(n);
          if (!_vrfAvailable) {
            _vrfs.clear();
            _customers.clear();
          }
        }
      }),
      loading: AppCache.instance.isLoading,
      empty: 'No groups',
      tag: (n) => _isPeGroup(n)
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: _txGreen.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: _txGreen.withValues(alpha: 0.4)),
              ),
              child: const Text(
                'PE',
                style: TextStyle(
                  fontSize: 8,
                  color: _txGreen,
                  fontWeight: FontWeight.w700,
                ),
              ),
            )
          : null,
    );
  }

  Widget _buildHosts() {
    final items = _filteredHosts
        .where(
          (h) =>
              _hostSearch.isEmpty ||
              h.toLowerCase().contains(_hostSearch.toLowerCase()),
        )
        .toList();
    return _CList(
      items: items,
      selected: _hosts,
      hint: 'Search hosts…',
      onSearch: (v) => setState(() => _hostSearch = v),
      onToggle: (n, add) => setState(() {
        if (add) {
          _hosts.add(n);
        } else {
          _hosts.remove(n);
        }
      }),
      loading: AppCache.instance.isLoading,
      empty: _groups.isEmpty
          ? 'All hosts (no group filter)'
          : 'No hosts in selected groups',
    );
  }

  Widget _buildVrfs() {
    final items = _filteredVrfs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'VRFs from selected PE groups.',
          style: TextStyle(fontSize: 10, color: ZbxT.textSec(context)),
        ),
        const SizedBox(height: 8),
        _CList(
          items: items,
          selected: _vrfs,
          hint: 'Search VRF or Customer…',
          onSearch: (v) => setState(() => _vrfSearch = v),
          onToggle: (n, add) => setState(() {
            if (add) {
              _vrfs.add(n);
              final c = AppCache.instance.customerForVrf(n);
              if (c.isNotEmpty) _customers.add(c);
            } else {
              _vrfs.remove(n);
              final c = AppCache.instance.customerForVrf(n);
              if (c.isNotEmpty) _customers.remove(c);
            }
          }),
          loading: AppCache.instance.isLoading,
          empty: 'No VRF data',
          sub: (n) {
            final c = AppCache.instance.customerForVrf(n);
            return c.isNotEmpty ? c : null;
          },
        ),
      ],
    );
  }

  Widget _sec(String t, IconData icon) => Row(
    children: [
      Icon(icon, size: 13, color: ZbxT.textSec(context)),
      SizedBox(width: 6),
      Text(
        t,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: ZbxT.textSec(context),
          letterSpacing: 1.0,
        ),
      ),
      SizedBox(width: 8),
      Expanded(child: Container(height: 1, color: ZbxT.rim(context))),
    ],
  );
  Widget _info(String msg) => Container(
    padding: EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: _rxBlue.withValues(alpha: 0.07),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: _rxBlue.withValues(alpha: 0.2)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline, size: 14, color: _rxBlue),
        SizedBox(width: 8),
        Expanded(
          child: Text(
            msg,
            style: TextStyle(
              fontSize: 11,
              color: ZbxT.textSec(context),
              height: 1.5,
            ),
          ),
        ),
      ],
    ),
  );
  Widget _card(String title, String sub, Widget child) => Container(
    decoration: BoxDecoration(
      color: ZbxT.card(context),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: ZbxT.rim(context)),
    ),
    child: Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        childrenPadding: EdgeInsets.fromLTRB(14, 0, 14, 14),
        title: Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: ZbxT.textPri(context),
          ),
        ),
        subtitle: Text(
          sub,
          style: TextStyle(fontSize: 11, color: ZbxT.textSec(context)),
        ),
        children: [
          Container(height: 1, color: ZbxT.rim(context)),
          SizedBox(height: 12),
          child,
        ],
      ),
    ),
  );
}

class _CList extends StatelessWidget {
  final List<String> items;
  final Set<String> selected;
  final String hint;
  final ValueChanged<String> onSearch;
  final void Function(String, bool) onToggle;
  final bool loading;
  final String empty;
  final Widget? Function(String)? tag;
  final String? Function(String)? sub;
  const _CList({
    required this.items,
    required this.selected,
    required this.hint,
    required this.onSearch,
    required this.onToggle,
    required this.loading,
    required this.empty,
    this.tag,
    this.sub,
  });
  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 1.5, color: _rxBlue),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          onChanged: onSearch,
          style: TextStyle(fontSize: 12, color: ZbxT.textPri(context)),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(fontSize: 11, color: ZbxT.textSec(context)),
            prefixIcon: Icon(
              Icons.search,
              size: 15,
              color: ZbxT.textSec(context),
            ),
            isDense: true,
            filled: true,
            fillColor: ZbxT.lift(context),
            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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
              borderSide: BorderSide(color: _rxBlue, width: 1.5),
            ),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton(
              onPressed: () {
                for (final i in items) {
                  onToggle(i, false);
                }
              },
              child: const Text(
                'All (clear)',
                style: TextStyle(fontSize: 11, color: _rxBlue),
              ),
            ),
            TextButton(
              onPressed: () {
                for (final i in items) {
                  onToggle(i, true);
                }
              },
              child: const Text(
                'Select all',
                style: TextStyle(fontSize: 11, color: _rxBlue),
              ),
            ),
          ],
        ),
        if (items.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              empty,
              style: TextStyle(fontSize: 11, color: ZbxT.textSec(context)),
            ),
          )
        else
          ...items.map((item) {
            final active = selected.contains(item);
            final s = sub?.call(item);
            final t = tag?.call(item);
            return InkWell(
              onTap: () => onToggle(item, !active),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
                child: Row(
                  children: [
                    AnimatedContainer(
                      duration: Duration(milliseconds: 140),
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: active ? _rxBlue : Colors.transparent,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: active ? _rxBlue : ZbxT.textSec(context),
                          width: 1.5,
                        ),
                      ),
                      child: active
                          ? Icon(Icons.check, size: 12, color: Colors.white)
                          : null,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item,
                            style: TextStyle(
                              fontSize: 12,
                              color: active
                                  ? ZbxT.textPri(context)
                                  : ZbxT.textSec(context),
                              fontWeight: active
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                          ),
                          if (s != null)
                            Text(
                              s,
                              style: TextStyle(
                                fontSize: 10,
                                color: active
                                    ? _txGreen
                                    : ZbxT.textSec(context)
                                          .withValues(alpha: 0.6),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (t != null) ...[const SizedBox(width: 6), t],
                  ],
                ),
              ),
            );
          }),
      ],
    );
  }
}
