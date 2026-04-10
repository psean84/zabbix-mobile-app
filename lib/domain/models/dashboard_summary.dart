class DashboardSummary {
  final int totalHosts;
  final int totalGroups;
  final int totalProblems;
  final int disasterCount;
  final int highCount;
  final int warningCount;
  final List<GroupAlertSummary> groupAlerts;

  const DashboardSummary({
    required this.totalHosts,
    required this.totalGroups,
    required this.totalProblems,
    required this.disasterCount,
    required this.highCount,
    required this.warningCount,
    required this.groupAlerts,
  });

  const DashboardSummary.empty()
    : totalHosts = 0,
      totalGroups = 0,
      totalProblems = 0,
      disasterCount = 0,
      highCount = 0,
      warningCount = 0,
      groupAlerts = const [];
}

class GroupAlertSummary {
  final String groupId;
  final String groupName;
  final int count;
  final int maxSeverity;

  const GroupAlertSummary({
    required this.groupId,
    required this.groupName,
    required this.count,
    required this.maxSeverity,
  });
}
