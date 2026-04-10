import '../../core/utils.dart';
import '../models/app_snapshot.dart';
import '../models/dashboard_summary.dart';

class DashboardSummaryBuilder {
  const DashboardSummaryBuilder();

  DashboardSummary build(AppSnapshot snapshot) {
    final problems = snapshot.problems;

    final disasterCount = problems
        .where((problem) => severityValue(problem['priority']?.toString() ?? '0') >= 5)
        .length;

    final highCount = problems.where((problem) {
      final severity = severityValue(problem['priority']?.toString() ?? '0');
      return severity == 4;
    }).length;

    final warningCount = problems.where((problem) {
      final severity = severityValue(problem['priority']?.toString() ?? '0');
      return severity >= 2 && severity < 4;
    }).length;

    return DashboardSummary(
      totalHosts: snapshot.hosts.length,
      totalGroups: snapshot.hostGroups.length,
      totalProblems: problems.length,
      disasterCount: disasterCount,
      highCount: highCount,
      warningCount: warningCount,
      groupAlerts: _buildGroupAlerts(snapshot),
    );
  }

  List<GroupAlertSummary> _buildGroupAlerts(AppSnapshot snapshot) {
    final hostMap = <String, dynamic>{};
    for (final host in snapshot.hosts) {
      final id = host['hostid']?.toString();
      if (id != null) hostMap[id] = host;
    }

    final groupIdMap = <String, String>{};
    for (final group in snapshot.hostGroups) {
      final name = (group['name'] ?? '').toString();
      final id = (group['groupid'] ?? '').toString();
      if (name.isNotEmpty && id.isNotEmpty) {
        groupIdMap[name] = id;
      }
    }

    final grouped = <String, GroupAlertSummary>{};
    for (final problem in snapshot.problems) {
      final severity = severityValue(problem['priority']?.toString() ?? '0');
      final triggerHosts = problem['hosts'];
      if (triggerHosts is! List) continue;

      final seenGroupNames = <String>{};
      for (final triggerHost in triggerHosts) {
        final hostId = triggerHost['hostid']?.toString();
        final host = hostId != null ? hostMap[hostId] : null;
        if (host == null) continue;

        final rawGroups = host['groups'] ?? host['hostgroups'];
        if (rawGroups is! List) continue;

        for (final group in rawGroups) {
          final groupName = (group['name'] ?? '').toString().trim();
          if (groupName.isEmpty || seenGroupNames.contains(groupName)) continue;
          seenGroupNames.add(groupName);

          final previous = grouped[groupName];
          grouped[groupName] = GroupAlertSummary(
            groupId: previous?.groupId.isNotEmpty == true
                ? previous!.groupId
                : (groupIdMap[groupName] ?? ''),
            groupName: groupName,
            count: (previous?.count ?? 0) + 1,
            maxSeverity: previous == null
                ? severity
                : (severity > previous.maxSeverity ? severity : previous.maxSeverity),
          );
        }
      }
    }

    final alerts = grouped.values.toList()
      ..sort((a, b) => b.count.compareTo(a.count));
    return alerts;
  }
}
