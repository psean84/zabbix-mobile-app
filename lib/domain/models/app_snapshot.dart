class AppSnapshot {
  final List<dynamic> hostGroups;
  final List<dynamic> hosts;
  final List<dynamic> problems;
  final Map<String, String> vrfToCustomer;

  const AppSnapshot({
    required this.hostGroups,
    required this.hosts,
    required this.problems,
    required this.vrfToCustomer,
  });

  const AppSnapshot.empty()
    : hostGroups = const [],
      hosts = const [],
      problems = const [],
      vrfToCustomer = const {};

  List<String> get allVrfs {
    final values = <String>{...vrfToCustomer.keys};
    return values.toList()..sort();
  }

  List<String> get allCustomers {
    final values = <String>{
      ...vrfToCustomer.values.where((value) => value.isNotEmpty),
    };
    return values.toList()..sort();
  }

  String customerForVrf(String vrf) => vrfToCustomer[vrf] ?? '';

  String? vrfForCustomer(String customer) {
    for (final entry in vrfToCustomer.entries) {
      if (entry.value == customer) return entry.key;
    }
    return null;
  }

  Map<String, dynamic>? hostById(String id) {
    for (final host in hosts) {
      if (host['hostid']?.toString() == id) {
        return host as Map<String, dynamic>?;
      }
    }
    return null;
  }
}
