import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';

import '../../core/app_cache.dart';
import '../../core/api_client.dart';
import '../../core/app_settings.dart';
import '../../core/local_store.dart';
import '../../core/zbx_theme.dart';
import '../../presentation/controllers/login_controller.dart';
import '../home/home_screen.dart';

const _rxBlue = ZbxPalette.rxBlue;
const _txGreen = ZbxPalette.txGreen;
const _downRed = ZbxPalette.downRed;

// ── Theme-aware color helper ──────────────────────────────────────────────────
// ── Theme-aware color helper ──────────────────────────────────────────────────
// ── Theme helper via ZbxT (see zbx_theme.dart) ────

class LoginScreen extends StatefulWidget {
  final AppSettings settings;
  final String pushStatus;
  const LoginScreen({
    super.key,
    required this.settings,
    required this.pushStatus,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _loginController = LoginController();
  _LoginFooterApiInfo get _apiInfo =>
      _LoginFooterApiInfo(_loginController.currentBaseUrl);
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _loading = false;
  bool _obscure = true;
  bool _rememberMe = true;
  String _error = '';
  String _loadMsg = '';
  bool _checkingRelays = false;
  List<Map<String, dynamic>> _relayStatus = const [];
  Timer? _relayTimer;

  late final AnimationController _anim;
  late final Animation<double> _fadeIn;
  late final Animation<Offset> _slideUp;

  @override
  void initState() {
    super.initState();
    _rememberMe = widget.settings.rememberMe;
    _loginController.setAllowSelfSignedCertificates(true);
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _fadeIn = CurvedAnimation(parent: _anim, curve: Curves.easeOut);
    _slideUp = Tween<Offset>(
      begin: const Offset(0, 0.06),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic));
    _anim.forward();
    _loadSaved();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _refreshRelayStatus();
      _relayTimer = Timer.periodic(
        const Duration(seconds: 8),
        (_) => _refreshRelayStatus(),
      );
    });
  }

  @override
  void dispose() {
    _anim.dispose();
    _relayTimer?.cancel();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSaved() async {
    try {
      final s = await LocalStore.readMap('auth:session');
      final u = (s?['username'] ?? '').toString();
      if (u.isNotEmpty && mounted) setState(() => _userCtrl.text = u);
    } catch (_) {}
  }

  Future<void> _refreshRelayStatus() async {
    if (_checkingRelays || !mounted) return;
    setState(() => _checkingRelays = true);
    try {
      final status = await ApiClient.probeRelayReachability(
        updateBaseSelection: true,
      );
      if (!mounted) return;
      setState(() => _relayStatus = status);
    } catch (_) {
      if (!mounted) return;
      setState(() => _relayStatus = const []);
    } finally {
      if (mounted) setState(() => _checkingRelays = false);
    }
  }

  Future<void> _login() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = '';
      _loadMsg = 'Connecting…';
    });

    try {
      setState(() => _loadMsg = 'Authenticating…');
      await _loginController.login(
        settings: widget.settings,
        username: _userCtrl.text.trim(),
        password: _passCtrl.text.trim(),
        allowSelfSignedCertificates: true,
        rememberMe: _rememberMe,
        onStatus: (message) {
          if (!mounted) return;
          setState(() => _loadMsg = message);
        },
      );
      setState(() => _loadMsg = 'Loading network data…');

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => HomeScreen(
            settings: widget.settings,
            pushStatus: widget.pushStatus,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadMsg = '';
        _error = _loginController.friendlyError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: _loading ? _buildLoading() : _buildForm(),
      ),
    );
  }

  // ── Post-login loading screen ────────────────────────────────────────────────
  Widget _buildLoading() {
    return ListenableBuilder(
      listenable: AppCache.instance,
      builder: (_, _) {
        final cache = AppCache.instance;
        return Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: _rxBlue.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _rxBlue.withValues(alpha: 0.3)),
                  ),
                  child: const Icon(
                    Icons.monitor_heart_outlined,
                    size: 36,
                    color: _rxBlue,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'BSNL NIB NAGPUR',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: ZbxT.textPri(context),
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 20),
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: _rxBlue,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  _loadMsg,
                  style: TextStyle(fontSize: 12, color: ZbxT.textSec(context)),
                ),
                if (cache.isLoaded) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: _txGreen.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _txGreen.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.check_circle,
                          color: _txGreen,
                          size: 14,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${cache.hostGroups.length} groups · '
                          '${cache.hosts.length} hosts · '
                          '${cache.problems.length} alerts',
                          style: const TextStyle(fontSize: 11, color: _txGreen),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  // ── Login form ────────────────────────────────────────────────────────────────
  Widget _buildForm() {
    return FadeTransition(
      opacity: _fadeIn,
      child: SlideTransition(
        position: _slideUp,
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const SizedBox(height: 40),

                  // ── Header ──────────────────────────────────────────────────
                  _buildHeader(),
                  const SizedBox(height: 36),

                  // ── Error ────────────────────────────────────────────────────
                  if (_error.isNotEmpty) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: _downRed.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: _downRed.withValues(alpha: 0.4)),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.error_outline,
                            color: _downRed,
                            size: 16,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _error,
                              style: const TextStyle(
                                fontSize: 12,
                                color: _downRed,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],

                  _fieldLabel('Relay Servers (fixed priority)'),
                  const SizedBox(height: 6),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: ZbxT.lift(context),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: ZbxT.rim(context)),
                    ),
                    child: Text(
                      '1) https://192.168.10.100:8443\n'
                      '2) https://zabbix-mobile-backend.duckdns.org:8443\n'
                      '3) https://tunnel.zabbix-ngp-mobile.net.eu.org:443',
                      style: TextStyle(
                        fontSize: 10,
                        color: ZbxT.textSec(context),
                        fontFamily: 'monospace',
                        height: 1.35,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: ZbxT.card(context),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: ZbxT.rim(context)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              'Reachability',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: ZbxT.textSec(context),
                                letterSpacing: 0.5,
                              ),
                            ),
                            const SizedBox(width: 8),
                            if (_checkingRelays)
                              const SizedBox(
                                width: 10,
                                height: 10,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.4,
                                  color: _rxBlue,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        ..._relayStatus.map((s) {
                          final ok = s['reachable'] == true;
                          final url = (s['url'] ?? '').toString();
                          final name = (s['name'] ?? '').toString();
          final active = url == _loginController.currentBaseUrl;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Row(
                              children: [
                                Container(
                                  width: 7,
                                  height: 7,
                                  decoration: BoxDecoration(
                                    color: ok ? _txGreen : _downRed,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '$name: ${ok ? 'reachable' : 'unreachable'}',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: ZbxT.textSec(context),
                                    ),
                                  ),
                                ),
                                if (active)
                                  const Text(
                                    'ACTIVE',
                                    style: TextStyle(
                                      fontSize: 9,
                                      color: _rxBlue,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                              ],
                            ),
                          );
                        }),
                        if (_relayStatus.isEmpty && !_checkingRelays)
                          Text(
                            'No status yet',
                            style: TextStyle(
                              fontSize: 10,
                              color: ZbxT.textSec(context),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // ── Username ─────────────────────────────────────────────────
                  _fieldLabel('Username'),
                  const SizedBox(height: 6),
                  TextFormField(
                    controller: _userCtrl,
                    style: TextStyle(fontSize: 14, color: ZbxT.textPri(context)),
                    keyboardType: TextInputType.text,
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                    inputFormatters: [LengthLimitingTextInputFormatter(64)],
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? 'Username required'
                        : null,
                    decoration: _fieldDeco(
                      hint: 'Zabbix username',
                      icon: Icons.person_outline,
                    ),
                  ),
                  const SizedBox(height: 16),

                  // ── Password ─────────────────────────────────────────────────
                  _fieldLabel('Password'),
                  const SizedBox(height: 6),
                  TextFormField(
                    controller: _passCtrl,
                    obscureText: _obscure,
                    style: TextStyle(fontSize: 14, color: ZbxT.textPri(context)),
                    textInputAction: TextInputAction.done,
                    inputFormatters: [LengthLimitingTextInputFormatter(128)],
                    onFieldSubmitted: (_) {
                      if (!_loading) _login();
                    },
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) return 'Password required';
                      if (v.trim().length < 4) return 'Password must be at least 4 characters';
                      return null;
                    },
                    decoration: _fieldDeco(
                      hint: '••••••••',
                      icon: Icons.lock_outline,
                      suffix: IconButton(
                        icon: Icon(
                          _obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          size: 18,
                          color: ZbxT.textSec(context),
                        ),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // ── Remember me ──────────────────────────────────────────────
                  Row(
                    children: [
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: Checkbox(
                          value: _rememberMe,
                          onChanged: (v) =>
                              setState(() => _rememberMe = v ?? true),
                          activeColor: _rxBlue,
                          checkColor: Colors.white,
                          side: BorderSide(
                            color: ZbxT.textSec(context),
                            width: 1.5,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Keep me signed in',
                        style: TextStyle(
                          fontSize: 13,
                          color: ZbxT.textSec(context),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  const SizedBox(height: 28),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _loading ? null : _login,
                      style: FilledButton.styleFrom(
                        backgroundColor: _rxBlue,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        disabledBackgroundColor: _rxBlue.withValues(alpha: 0.4),
                      ),
                      child: const Text(
                        'Sign In',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),

                  // ── Footer ────────────────────────────────────────────────────
                  const SizedBox(height: 40),
                  _buildFooter(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Header widget ─────────────────────────────────────────────────────────────
  Widget _buildHeader() {
    return Column(
      children: [
        // BSNL logo placeholder – coloured emblem
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF0D47A1), Color(0xFF1565C0)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.15),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF1565C0).withValues(alpha: 0.4),
                blurRadius: 20,
                spreadRadius: 2,
              ),
            ],
          ),
          child: const Center(
            child: Text(
              'BSNL',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w900,
                color: Colors.white,
                letterSpacing: 2,
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),

        // Organisation name
        Text(
          'BSNL NIB NAGPUR',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w900,
            color: ZbxT.textPri(context),
            letterSpacing: 2.0,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          width: 120,
          height: 1.5,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.transparent, _rxBlue, Colors.transparent],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'Network Intelligence Bureau',
          style: TextStyle(
            fontSize: 13,
            color: ZbxT.textSec(context),
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Network Monitoring System',
          style: TextStyle(
            fontSize: 11,
            color: ZbxT.textSec(context),
            letterSpacing: 0.4,
          ),
        ),
      ],
    );
  }

  // ── Footer widget ─────────────────────────────────────────────────────────────
  Widget _buildFooter() {
    return Column(
      children: [
        Container(
          width: double.infinity,
          height: 1,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.transparent, ZbxT.rim(context), Colors.transparent],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(
                color: _rxBlue,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            RichText(
              text: TextSpan(
                style: TextStyle(
                  fontSize: 10,
                  color: ZbxT.textSec(context),
                  letterSpacing: 0.3,
                ),
                children: [
                  TextSpan(text: 'Created and designed by '),
                  TextSpan(
                    text: 'Claude',
                    style: TextStyle(
                      color: _rxBlue,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  TextSpan(text: ' & '),
                  TextSpan(
                    text: 'Codex AI',
                    style: TextStyle(
                      color: _txGreen,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(
                color: _txGreen,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'v1.0  •  ${_apiInfo.baseUrl}',
          style: TextStyle(
            fontSize: 9,
            color: ZbxT.textSec(context).withValues(alpha: 0.5),
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }

  Widget _fieldLabel(String text) => Align(
    alignment: Alignment.centerLeft,
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w700,
        color: ZbxT.textSec(context),
        letterSpacing: 0.8,
      ),
    ),
  );

  InputDecoration _fieldDeco({
    required String hint,
    required IconData icon,
    Widget? suffix,
  }) => InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(fontSize: 13, color: ZbxT.textSec(context)),
    prefixIcon: Icon(icon, size: 18, color: ZbxT.textSec(context)),
    suffixIcon: suffix,
    filled: true,
    fillColor: ZbxT.lift(context),
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: ZbxT.rim(context)),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: ZbxT.rim(context)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: _rxBlue, width: 1.5),
    ),
    errorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: _downRed),
    ),
    focusedErrorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: _downRed, width: 1.5),
    ),
  );
}

class _LoginFooterApiInfo {
  final String baseUrl;

  const _LoginFooterApiInfo(this.baseUrl);
}
