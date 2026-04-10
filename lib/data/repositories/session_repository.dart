import '../../core/api_client.dart';
import '../../core/app_settings.dart';

class SessionRepository {
  const SessionRepository();

  String get baseUrl => ApiClient.baseUrl;

  void setAllowSelfSignedCertificates(bool enabled) {
    ApiClient.setAllowSelfSignedCertificates(enabled);
  }

  Future<void> prepareForLogin({
    required AppSettings settings,
    required bool allowSelfSignedCertificates,
  }) async {
    ApiClient.setAllowSelfSignedCertificates(allowSelfSignedCertificates);
    // configureNetwork already runs relay selection once; avoid doubling probe time.
    await ApiClient.configureNetwork(
      intranetUrl: settings.intranetUrl,
      internetUrl: settings.internetUrl,
      tunnelUrl: settings.tunnelUrl,
      preferIntranet: true,
      autoSelect: true,
      timeoutSec: settings.reachabilityTimeoutSec,
      intervalMin: settings.reachabilityIntervalMin,
    );
    // Keep a stable relay for this authenticated session.
    ApiClient.lockBaseUrlForSession();
  }

  Future<void> login({
    required String username,
    required String password,
  }) {
    return ApiClient.login(username, password);
  }

  Future<bool> restoreSession() {
    return ApiClient.restoreSession();
  }

  Future<void> logout() {
    return ApiClient.logout();
  }
}
