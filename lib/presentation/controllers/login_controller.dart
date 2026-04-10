import '../../core/app_cache.dart';
import '../../core/app_settings.dart';
import '../../data/repositories/session_repository.dart';

typedef LoginStatusCallback = void Function(String message);

class LoginController {
  LoginController({
    SessionRepository? sessionRepository,
    AppCache? appCache,
  }) : _sessionRepository = sessionRepository ?? const SessionRepository(),
       _appCache = appCache ?? AppCache.instance;

  final SessionRepository _sessionRepository;
  final AppCache _appCache;

  String get currentBaseUrl => _sessionRepository.baseUrl;

  void setAllowSelfSignedCertificates(bool enabled) {
    _sessionRepository.setAllowSelfSignedCertificates(enabled);
  }

  Future<void> login({
    required AppSettings settings,
    required String username,
    required String password,
    required bool allowSelfSignedCertificates,
    required bool rememberMe,
    LoginStatusCallback? onStatus,
  }) async {
    onStatus?.call('Connecting...');
    await _sessionRepository.prepareForLogin(
      settings: settings,
      allowSelfSignedCertificates: allowSelfSignedCertificates,
    );

    onStatus?.call('Authenticating...');
    await _sessionRepository.login(username: username, password: password);

    await settings.setRememberMe(rememberMe);

    onStatus?.call('Loading network data...');
    await _appCache.load(force: true);
  }

  String friendlyError(Object error) {
    final message = error.toString().replaceFirst('Exception: ', '');
    if (message.contains('SocketException') ||
        message.contains('Connection refused') ||
        message.contains('unreachable') ||
        message.contains('Failed host lookup') ||
        message.toLowerCase().contains('timeout')) {
      return 'Cannot reach server. Check the URL and your network.';
    }

    if (message.contains('401') ||
        message.toLowerCase().contains('invalid') ||
        message.toLowerCase().contains('incorrect') ||
        message.toLowerCase().contains('unauthori')) {
      return 'Login failed. Check your username and password.';
    }

    return message.isNotEmpty ? message : 'Login failed. Please try again.';
  }
}
