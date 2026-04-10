import '../../core/api_client.dart';
import '../../domain/models/app_snapshot.dart';
import '../../domain/services/app_snapshot_builder.dart';

class MonitoringRepository {
  const MonitoringRepository({AppSnapshotBuilder? snapshotBuilder})
    : _snapshotBuilder = snapshotBuilder ?? const AppSnapshotBuilder();

  final AppSnapshotBuilder _snapshotBuilder;

  Future<AppSnapshot> fetchAppSnapshot() async {
    final hostGroupsFuture = ApiClient.fetchHostGroups();
    final hostsFuture = ApiClient.fetchHosts();
    final problemsFuture = ApiClient.fetchTriggers();

    final hostGroups = await hostGroupsFuture;
    final hosts = await hostsFuture;
    final problems = await problemsFuture;

    return _snapshotBuilder.build(
      hostGroups: hostGroups,
      hosts: hosts,
      problems: problems,
    );
  }

  Future<List<dynamic>> fetchHosts({String? groupId}) {
    return ApiClient.fetchHosts(groupId: groupId);
  }

  Future<List<dynamic>> fetchItems(String hostId) {
    return ApiClient.fetchItems(hostId);
  }

  Future<List<dynamic>> fetchItemsMetadata(
    String hostId, {
    bool cacheOnly = false,
    bool forceRefresh = false,
  }) {
    return ApiClient.fetchItemsMetadata(
      hostId,
      cacheOnly: cacheOnly,
      forceRefresh: forceRefresh,
    );
  }

  Future<List<dynamic>> fetchItemPrototypes(
    String hostId, {
    bool cacheOnly = false,
  }) {
    return ApiClient.fetchItemPrototypes(hostId, cacheOnly: cacheOnly);
  }

  Future<List<dynamic>> fetchLldRules(String hostId) {
    return ApiClient.fetchLldRules(hostId);
  }
}
