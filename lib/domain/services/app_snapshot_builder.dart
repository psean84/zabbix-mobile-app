import '../models/app_snapshot.dart';

class AppSnapshotBuilder {
  const AppSnapshotBuilder();

  AppSnapshot build({
    required List<dynamic> hostGroups,
    required List<dynamic> hosts,
    required List<dynamic> problems,
  }) {
    return AppSnapshot(
      hostGroups: List<dynamic>.unmodifiable(hostGroups),
      hosts: List<dynamic>.unmodifiable(hosts),
      problems: List<dynamic>.unmodifiable(problems),
      vrfToCustomer: Map<String, String>.unmodifiable(
        _buildVrfToCustomerMap(problems),
      ),
    );
  }

  Map<String, String> _buildVrfToCustomerMap(List<dynamic> problems) {
    final map = <String, String>{};

    for (final problem in problems) {
      final tags = (problem['tags'] is List) ? (problem['tags'] as List) : const [];
      String? vrf;
      String? customer;

      for (final tag in tags) {
        final key = (tag['tag'] ?? '').toString().toLowerCase();
        final value = (tag['value'] ?? '').toString().trim();
        if (value.isEmpty) continue;

        if (key == 'vrf' || key == 'vrfname' || key == 'vrf_name') {
          vrf = value;
        }
        if (key == 'customer' || key == 'cust' || key == 'customer_name') {
          customer = value;
        }
      }

      if (vrf != null && vrf.isNotEmpty) {
        map[vrf] = customer ?? map[vrf] ?? '';
      }
    }

    return map;
  }
}
