import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter/services.dart';

import '../../core/api_client.dart';
import '../../core/app_cache.dart';
import '../../core/app_settings.dart';
import '../../core/zbx_theme.dart';
import '../dashboard/dashboard_screen.dart';
import '../hosts/hosts_screen.dart';
import '../problems/problems_screen.dart';
import '../settings/settings_screen.dart';
import '../about/about_screen.dart';
import '../login/login_screen.dart';

const _rxBlue = ZbxPalette.rxBlue;
const _txGreen = ZbxPalette.txGreen;
const _downRed = ZbxPalette.downRed;

enum _Page { dashboard, hosts, problems, settings, about }

// â”€â”€ Theme-aware color helper â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
// â”€â”€ Theme-aware color helper â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
class _T {
  static Color card(BuildContext ctx) => ZbxTheme.of(ctx).bgCard;
  static Color rim(BuildContext ctx) => ZbxTheme.of(ctx).rim;
  static Color textPri(BuildContext ctx) => ZbxTheme.of(ctx).textPri;
  static Color textSec(BuildContext ctx) => ZbxTheme.of(ctx).textSec;
}

class HomeScreen extends StatefulWidget {
  final String pushStatus;
  final AppSettings settings;
  final bool openProblemsOnStart;

  const HomeScreen({
    super.key,
    required this.pushStatus,
    required this.settings,
    this.openProblemsOnStart = false,
  });

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

// Public state so GlobalKey<HomeScreenState> can call openProblems()
class HomeScreenState extends State<HomeScreen> {
  _Page _currentPage = _Page.dashboard;
  String _searchQuery = '';
  String? _initialGroupId;
  String? _initialGroupName;

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final _problemsKey = GlobalKey<ProblemsScreenState>();

  // Called from main.dart when a FCM notification is tapped
  void openProblems() {
    if (mounted) {
      setState(() {
        _currentPage = _Page.problems;
        _searchQuery = '';
      });
    }
  }

  void _navigateProblemsBySeverity(int severity) {
    // Navigate to problems with a search filter for the severity level
    if (mounted) {
      setState(() {
        _currentPage = _Page.problems;
        _searchQuery = '';
      });
    }
  }

  static const _pageMeta = {
    _Page.dashboard: (
      title: 'Dashboard',
      icon: Icons.dashboard_outlined,
      iconActive: Icons.dashboard,
    ),
    _Page.hosts: (
      title: 'Hosts',
      icon: Icons.router_outlined,
      iconActive: Icons.router,
    ),
    _Page.problems: (
      title: 'Problems',
      icon: Icons.warning_amber_outlined,
      iconActive: Icons.warning_amber_rounded,
    ),
    _Page.settings: (
      title: 'Settings',
      icon: Icons.settings_outlined,
      iconActive: Icons.settings,
    ),
    _Page.about: (
      title: 'About',
      icon: Icons.info_outline,
      iconActive: Icons.info,
    ),
  };

  String get _pageTitle => _pageMeta[_currentPage]?.title ?? 'NIB Monitor';
  bool get _showSearch =>
      _currentPage == _Page.hosts || _currentPage == _Page.problems;

  @override
  void initState() {
    super.initState();
    // If launched via notification tap, open Problems immediately
    if (widget.openProblemsOnStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) => openProblems());
    }
  }

  void _navigate(_Page page, {String? groupId, String? groupName}) {
    try {
      if (_scaffoldKey.currentState?.isDrawerOpen == true) {
        Navigator.of(context).pop();
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _currentPage = page;
      _searchQuery = '';
      _initialGroupId = groupId;
      _initialGroupName = groupName;
    });
  }

  /// Called by HostsScreen when the user presses back at the top level.
  void _onHostsExit() {
    if (!mounted) return;
    setState(() => _currentPage = _Page.dashboard);
  }

  void _onLogout() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => LoginScreen(
          settings: widget.settings,
          pushStatus: widget.pushStatus,
        ),
      ),
    );
  }

  Future<void> _confirmLogout() async {
    try {
      if (_scaffoldKey.currentState?.isDrawerOpen == true) {
        Navigator.of(context).pop();
      }
    } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 200));
    if (!mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: ZbxT.card(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(
          'Sign out',
          style: TextStyle(
            color: ZbxT.textPri(context),
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          'This will clear your saved session and return to the login screen.',
          style: TextStyle(color: ZbxT.textSec(context), fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel', style: TextStyle(color: ZbxT.textSec(context))),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(
              'Sign out',
              style: TextStyle(color: _downRed, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ApiClient.logout();
    _onLogout();
  }

  Widget _buildPage() {
    try {
      switch (_currentPage) {
        case _Page.dashboard:
          return DashboardScreen(
            onGroupTap: (id, name) => _navigate(_Page.problems),
            onProblemsTap: () => _navigate(_Page.problems),
            onHostsTap: () => _navigate(_Page.hosts),
            onGroupsTap: () => _navigate(_Page.hosts),
            onSeverityTap: (sev) => _navigateProblemsBySeverity(sev),
          );
        case _Page.hosts:
          return HostsScreen(
            pushStatus: widget.pushStatus,
            searchQuery: _searchQuery,
            initialGroupId: _initialGroupId,
            initialGroupName: _initialGroupName,
            onExit: _onHostsExit,
          );
        case _Page.problems:
          return ProblemsScreen(key: _problemsKey, searchQuery: _searchQuery);
        case _Page.settings:
          return SettingsScreen(settings: widget.settings);
        case _Page.about:
          return const AboutScreen();
      }
    } catch (e) {
      return _ErrorPage(error: e.toString(), onRetry: () => setState(() {}));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.settings,
      builder: (context, _) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          key: _scaffoldKey,
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          drawer: _buildDrawer(),
          appBar: _buildAppBar(),
          body: ListenableBuilder(
            listenable: AppCache.instance,
            builder: (context, _) => Column(
              children: [
                if (AppCache.instance.isOffline)
                  Container(
                    width: double.infinity,
                    color: const Color(0xFFB71C1C),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.wifi_off, color: Colors.white, size: 16),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'No network connection — showing cached data',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    transitionBuilder: (child, anim) =>
                        FadeTransition(opacity: anim, child: child),
                    child: KeyedSubtree(
                      key: ValueKey(_currentPage),
                      child: _buildPage(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: ZbxT.card(context),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      leading: IconButton(
        icon: Icon(Icons.menu, color: ZbxT.textPri(context)),
        onPressed: () {
          try {
            _scaffoldKey.currentState?.openDrawer();
          } catch (_) {}
        },
      ),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _pageTitle,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: ZbxT.textPri(context),
            ),
          ),
          Text(
            'BSNL NIB NAGPUR',
            style: TextStyle(
              fontSize: 9,
              color: ZbxT.textSec(context),
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
      actions: [
        if (_currentPage == _Page.dashboard) ...[
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color:
                        widget.pushStatus.contains('active') ||
                            widget.pushStatus.contains('registered')
                        ? _txGreen
                        : ZbxPalette.warnAmb,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color:
                            (widget.pushStatus.contains('active') ||
                                        widget.pushStatus.contains('registered')
                                    ? _txGreen
                                    : ZbxPalette.warnAmb)
                                .withValues(alpha: 0.5),
                        blurRadius: 5,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  'FCM',
                  style: TextStyle(fontSize: 9, color: ZbxT.textSec(context)),
                ),
              ],
            ),
          ),
          ListenableBuilder(
            listenable: AppCache.instance,
            builder: (_, _) => IconButton(
              icon: AppCache.instance.isLoading
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: ZbxT.textSec(context),
                      ),
                    )
                  : Icon(Icons.refresh, size: 18, color: ZbxT.textSec(context)),
              onPressed: () => AppCache.instance.refresh(),
              tooltip: 'Refresh',
            ),
          ),
        ],
        if (_currentPage == _Page.problems)
          IconButton(
            icon: const Icon(Icons.share_outlined, size: 20),
            tooltip: 'Share active problems',
            onPressed: () => _problemsKey.currentState?.shareProblems(),
          ),
      ],
      bottom: _showSearch
          ? PreferredSize(
              preferredSize: const Size.fromHeight(52),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: TextField(
                  onChanged: (v) => setState(() => _searchQuery = v.trim()),
                  style: TextStyle(fontSize: 13, color: ZbxT.textPri(context)),
                  decoration: InputDecoration(
                    hintText: _currentPage == _Page.hosts
                        ? 'Search groups, hosts, interfacesâ€¦'
                        : 'Search problem groups, hostsâ€¦',
                    hintStyle: TextStyle(
                      fontSize: 13,
                      color: ZbxT.textSec(context),
                    ),
                    prefixIcon: Icon(
                      Icons.search,
                      size: 18,
                      color: ZbxT.textSec(context),
                    ),
                    filled: true,
                    fillColor: ZbxT.card(context),
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
                      borderSide: BorderSide(color: _rxBlue, width: 1.5),
                    ),
                  ),
                ),
              ),
            )
          : PreferredSize(
              preferredSize: const Size.fromHeight(1),
              child: Container(height: 1, color: ZbxT.rim(context)),
            ),
    );
  }

  Widget _buildDrawer() {
    final cs = widget.settings.colorScheme;
    return Drawer(
      width: 280,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      child: Column(
        children: [
          // â”€â”€ Header â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(20, 52, 20, 20),
            decoration: BoxDecoration(
              color: ZbxT.card(context),
              border: Border(
                bottom: BorderSide(color: ZbxT.rim(context), width: 1),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF0D47A1), Color(0xFF1565C0)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.15),
                        ),
                      ),
                      child: const Center(
                        child: Text(
                          'BSNL',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w900,
                            color: Colors.white,
                            letterSpacing: 1,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'NIB NAGPUR',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: ZbxT.textPri(context),
                              letterSpacing: 1,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Network Monitor',
                            style: TextStyle(
                              fontSize: 10,
                              color: ZbxT.textSec(context).withValues(alpha: 0.8),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Push status
                Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: widget.pushStatus.contains('active')
                            ? _txGreen
                            : ZbxPalette.warnAmb,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        widget.pushStatus,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10,
                          color: ZbxT.textSec(context),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 6),

          // â”€â”€ Nav items â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              children: [
                _DrawerItem(
                  icon: _pageMeta[_Page.dashboard]!.icon,
                  iconActive: _pageMeta[_Page.dashboard]!.iconActive,
                  label: 'Dashboard',
                  active: _currentPage == _Page.dashboard,
                  accent: cs.accent,
                  onTap: () => _navigate(_Page.dashboard),
                ),
                _DrawerItem(
                  icon: _pageMeta[_Page.hosts]!.icon,
                  iconActive: _pageMeta[_Page.hosts]!.iconActive,
                  label: 'Hosts',
                  active: _currentPage == _Page.hosts,
                  accent: cs.accent,
                  onTap: () => _navigate(_Page.hosts),
                ),
                ListenableBuilder(
                  listenable: AppCache.instance,
                  builder: (_, _) => _DrawerItem(
                    icon: _pageMeta[_Page.problems]!.icon,
                    iconActive: _pageMeta[_Page.problems]!.iconActive,
                    label: 'Problems',
                    active: _currentPage == _Page.problems,
                    accent: cs.accent,
                    badgeCount: AppCache.instance.problems.length,
                    onTap: () => _navigate(_Page.problems),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  child: Divider(color: ZbxT.rim(context), height: 1),
                ),
                _DrawerItem(
                  icon: _pageMeta[_Page.settings]!.icon,
                  iconActive: _pageMeta[_Page.settings]!.iconActive,
                  label: 'Settings',
                  active: _currentPage == _Page.settings,
                  accent: cs.accent,
                  onTap: () => _navigate(_Page.settings),
                ),
                _DrawerItem(
                  icon: _pageMeta[_Page.about]!.icon,
                  iconActive: _pageMeta[_Page.about]!.iconActive,
                  label: 'About',
                  active: _currentPage == _Page.about,
                  accent: cs.accent,
                  onTap: () => _navigate(_Page.about),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  child: Divider(color: ZbxT.rim(context), height: 1),
                ),
                // â”€â”€ Logout â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
                _DrawerItem(
                  icon: Icons.logout,
                  iconActive: Icons.logout,
                  label: 'Sign Out',
                  active: false,
                  accent: _downRed,
                  onTap: _confirmLogout,
                  danger: true,
                ),
              ],
            ),
          ),

          // â”€â”€ Footer â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: ZbxT.rim(context))),
            ),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: cs.accent,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    cs.label,
                    style: TextStyle(fontSize: 9, color: ZbxT.textSec(context)),
                  ),
                ),
                GestureDetector(
                  onTap: () => _navigate(_Page.settings),
                  child: Icon(Icons.tune, size: 15, color: ZbxT.textSec(context)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// â”€â”€â”€ Drawer item â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
class _DrawerItem extends StatelessWidget {
  final IconData icon, iconActive;
  final String label;
  final bool active;
  final Color accent;
  final VoidCallback onTap;
  final bool danger;
  final int badgeCount;

  const _DrawerItem({
    required this.icon,
    required this.iconActive,
    required this.label,
    required this.active,
    required this.accent,
    required this.onTap,
    this.danger = false,
    this.badgeCount = 0,
  });

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 180),
    margin: const EdgeInsets.symmetric(vertical: 1),
    decoration: BoxDecoration(
      color: active ? accent.withValues(alpha: 0.12) : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      border: active ? Border.all(color: accent.withValues(alpha: 0.3)) : null,
    ),
    child: ListTile(
      dense: true,
      leading: Icon(
        active ? iconActive : icon,
        size: 21,
        color: danger
            ? accent.withValues(alpha: 0.8)
            : active
            ? accent
            : ZbxT.textSec(context),
      ),
      title: Text(
        label,
        style: TextStyle(
          fontSize: 14,
          fontWeight: active || danger ? FontWeight.w700 : FontWeight.normal,
          color: danger
              ? accent.withValues(alpha: 0.9)
              : active
              ? ZbxT.textPri(context)
              : ZbxT.textSec(context),
        ),
      ),
      trailing: badgeCount > 0
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFFEF5350),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                badgeCount > 99 ? '99+' : '$badgeCount',
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            )
          : null,
      onTap: onTap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
  );
}

// â”€â”€â”€ Error page â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
class _ErrorPage extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _ErrorPage({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 48, color: Color(0xFFEF5350)),
          const SizedBox(height: 14),
          Text(
            'Something went wrong',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: ZbxT.textPri(context),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            error,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: ZbxT.textSec(context)),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Retry'),
            style: FilledButton.styleFrom(
              backgroundColor: ZbxPalette.rxBlue,
            ),
          ),
        ],
      ),
    ),
  );
}
