import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

import 'core/api_client.dart';
import 'core/app_cache.dart';
import 'core/app_settings.dart';
import 'core/secure_store.dart';
import 'core/zbx_theme.dart';
import 'features/home/home_screen.dart';
import 'features/login/login_screen.dart';

@pragma('vm:entry-point')
Future<void> _bgHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = FlutterError.presentError;

  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(_bgHandler);

  final settings = AppSettings();
  await settings.load();
  ApiClient.setAllowSelfSignedCertificates(
    true,
  );

  runApp(MyApp(settings: settings));
}

// ── Theme helper via ZbxT (see zbx_theme.dart) ───────────────────────────────

class MyApp extends StatefulWidget {
  final AppSettings settings;
  final bool enableFcmHandlers;
  const MyApp({
    super.key,
    required this.settings,
    this.enableFcmHandlers = true,
  });

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  bool _checking = true;
  bool _showLogin = false;
  String _pushStatus = 'Initializing…';
  String _loadMsg = 'Checking session…';
  bool _openProblems = false;
  StreamSubscription<String>? _sessionExpiredSub;

  // NavigatorKey so we can navigate from FCM callbacks outside widget tree
  final _navKey = GlobalKey<NavigatorState>();
  final _scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.settings.addListener(_onSettings);
    _onSettings();
    // Listen for 401 responses from any screen and force back to login
    _sessionExpiredSub = ApiClient.authErrorStream.listen((_) => _forceLogout());
    AppCache.instance.startConnectivityMonitor();
    _startup();
    if (widget.enableFcmHandlers) {
      _setupFcmTapHandlers();
    }
  }

  @override
  void dispose() {
    _sessionExpiredSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.settings.removeListener(_onSettings);
    super.dispose();
  }

  void _onSettings() {
    ApiClient.setAllowSelfSignedCertificates(
      true,
    );
    ApiClient.setMetaCacheEnabled(widget.settings.metaCacheEnabled);
    ApiClient.configureNetwork(
      intranetUrl: widget.settings.intranetUrl,
      internetUrl: widget.settings.internetUrl,
      preferIntranet: widget.settings.preferIntranet,
      autoSelect: widget.settings.autoSelectEndpoint,
      timeoutSec: widget.settings.reachabilityTimeoutSec,
      intervalMin: widget.settings.reachabilityIntervalMin,
    );
    if (mounted) setState(() {});
  }

  // ── App lifecycle ─────────────────────────────────────────────────────────────
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        // Screen off / app backgrounded — stop the timer so it doesn't fire
        // against a potentially expired server session.
        AppCache.instance.stopAutoRefresh();
        break;

      case AppLifecycleState.resumed:
        // App is back in the foreground.  Only act if the user is logged in.
        if (_showLogin || _checking) break;
        _resumeSession();
        break;

      case AppLifecycleState.detached:
        break;
    }
  }

  /// Called when the app resumes from background.
  /// Silently re-validates the token; if it has expired on the server side
  /// we force back to login.  If still valid, restart the timer and refresh.
  Future<void> _resumeSession() async {
    // Attempt a lightweight token check by re-reading session metadata.
    final stillValid = await ApiClient.restoreSession();
    if (!mounted) return;
    if (!stillValid) {
      // Token expired while backgrounded — clean logout without 401 noise.
      await _forceLogout();
      return;
    }
    // Session still valid — restart the shared timer and do one refresh.
    AppCache.instance.startAutoRefresh();
    AppCache.instance.refresh().catchError((_) {});
  }

  Future<void> _forceLogout() async {
    AppCache.instance.reset();
    await ApiClient.logout();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _showLogin = true;
      _openProblems = false;
    });
    _scaffoldMessengerKey.currentState?.showSnackBar(
      const SnackBar(
        content: Text('Session expired — please sign in again.'),
        duration: Duration(seconds: 4),
      ),
    );
  }

  // ── FCM tap handlers ──────────────────────────────────────────────────────────
  void _setupFcmTapHandlers() {
    // App opened by tapping a notification (from terminated state)
    FirebaseMessaging.instance.getInitialMessage().then((msg) {
      if (msg != null) _handleNotificationTap(msg);
    });

    // App in background, user taps notification
    FirebaseMessaging.onMessageOpenedApp.listen(_handleNotificationTap);

    // App in foreground — show a snack/banner but don't navigate
    FirebaseMessaging.onMessage.listen((msg) {
      if (!mounted) return;
      final title = msg.notification?.title ?? 'Alert';
      final body = msg.notification?.body ?? '';
      final messenger = _scaffoldMessengerKey.currentState;
      if (messenger == null) return;
      try {
        messenger.showSnackBar(
          SnackBar(
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                if (body.isNotEmpty)
                  Text(
                    body,
                    style: const TextStyle(fontSize: 12),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
            backgroundColor: ZbxT.card(context),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: 'View',
              textColor: const Color(0xFF29B6F6),
              onPressed: () => _navigateToProblems(msg),
            ),
          ),
        );
      } catch (_) {}
    });
  }

  void _handleNotificationTap(RemoteMessage msg) {
    if (!mounted) return;
    // If app not yet shown (terminated state), store for after build
    if (_checking) {
      setState(() {
        _openProblems = true;
      });
    } else {
      _navigateToProblems(msg);
    }
  }

  void _navigateToProblems(RemoteMessage msg) {
    // Tell the HomeScreen to open Problems via its state key
    _homeScreenKey.currentState?.openProblems();
  }

  final _homeScreenKey = GlobalKey<HomeScreenState>();

  // ── Startup ───────────────────────────────────────────────────────────────────
  Future<void> _startup() async {
    setState(() => _loadMsg = 'Checking session…');
    // If rememberMe is off, skip session restoration and go straight to login.
    final hasSession = widget.settings.rememberMe
        ? await ApiClient.restoreSession()
        : false;

    if (!hasSession) {
      if (!widget.settings.rememberMe) {
        // Clear any stored token so the user truly starts fresh.
        await ApiClient.logout();
      }
      if (mounted) {
        setState(() {
          _checking = false;
          _showLogin = true;
        });
      }
      return;
    }

    setState(() => _loadMsg = 'Loading host groups…');
    await AppCache.instance.load().catchError((_) {});
    setState(() => _loadMsg = 'Metadata ready…');
    await Future.delayed(const Duration(milliseconds: 200));

    // Single app-wide refresh timer — screens listen via AppCache
    AppCache.instance.startAutoRefresh();
    unawaited(_initPushAsync());

    if (mounted) {
      setState(() {
        _checking = false;
        _showLogin = false;
      });
    }
  }

  Future<void> _initPushAsync() async {
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission();
      final t = await messaging.getToken().timeout(const Duration(seconds: 20));
      if (t == null) {
        if (mounted) setState(() => _pushStatus = 'FCM token unavailable');
        return;
      }

      // Store FCM token in secure storage
      await SecureStore.write('fcm:token', t);

      // Register with current filter preferences
      final filter = widget.settings.notifFilter.toJson();
      await ApiClient.registerDeviceToken(t, filter: filter);

      if (mounted) setState(() => _pushStatus = 'Push notifications active');
    } on TimeoutException {
      if (mounted) setState(() => _pushStatus = 'Push timeout');
    } catch (_) {
      if (mounted) setState(() => _pushStatus = 'Push error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BSNL NIB Monitor',
      theme: widget.settings.buildLightTheme(),
      darkTheme: widget.settings.buildTheme(),
      themeMode: widget.settings.themeMode.flutterMode,
      debugShowCheckedModeBanner: false,
      navigatorKey: _navKey,
      scaffoldMessengerKey: _scaffoldMessengerKey,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(widget.settings.fontSize.scale),
        ),
        child: child ?? const SizedBox.shrink(),
      ),
      home: _checking
          ? _SplashScreen(message: _loadMsg, settings: widget.settings)
          : _showLogin
          ? LoginScreen(settings: widget.settings, pushStatus: _pushStatus)
          : HomeScreen(
              key: _homeScreenKey,
              settings: widget.settings,
              pushStatus: _pushStatus,
              openProblemsOnStart: _openProblems,
            ),
    );
  }
}

// ─── Splash ──────────────────────────────────────────────────────────────────
class _SplashScreen extends StatefulWidget {
  final String message;
  final AppSettings settings;
  const _SplashScreen({required this.message, required this.settings});

  @override
  State<_SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<_SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
      lowerBound: 0.92,
      upperBound: 1.04,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = widget.settings.colorScheme;
    return Scaffold(
      backgroundColor: cs.scaffold,
      body: ListenableBuilder(
        listenable: AppCache.instance,
        builder: (_, _) {
          final cache = AppCache.instance;
          return Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ScaleTransition(
                    scale: _pulse,
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: cs.accent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: cs.accent.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Icon(
                        Icons.monitor_heart_outlined,
                        size: 36,
                        color: cs.accent,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
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
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: cs.accent,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    widget.message,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: ZbxT.textSec(context)),
                  ),
                  if (cache.isLoaded) ...[
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF26C67C).withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: const Color(0xFF26C67C).withValues(alpha: 0.3),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.check_circle,
                            size: 14,
                            color: Color(0xFF26C67C),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${cache.hostGroups.length} groups · '
                            '${cache.hosts.length} hosts · '
                            '${cache.problems.length} alerts',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF26C67C),
                            ),
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
      ),
    );
  }
}

void unawaited(Future<void> future) {
  future.catchError((_) {});
}
