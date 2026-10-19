class DashboardStats {
  final bool success;
  final bool isUserFiltered;
  final Map<String, dynamic>? targetUser;
  final DashboardKpi kpi;
  final List<TimelinePoint> timeline;
  final List<UserEvolutionPoint> userEvolution;
  final List<TaxonomyItem> sourceModes;
  final List<TaxonomyItem> fileFormats;
  final List<TaxonomyItem> languages;
  final List<TaxonomyItem> lengthTiers;

  DashboardStats({
    required this.success,
    required this.isUserFiltered,
    this.targetUser,
    required this.kpi,
    required this.timeline,
    required this.userEvolution,
    required this.sourceModes,
    required this.fileFormats,
    required this.languages,
    required this.lengthTiers,
  });

  factory DashboardStats.fromJson(Map<String, dynamic> json) {
    return DashboardStats(
      success: json['success'] == true,
      isUserFiltered: json['is_user_filtered'] == true,
      targetUser: json['target_user'] as Map<String, dynamic>?,
      kpi: DashboardKpi.fromJson(json['kpi'] ?? {}),
      timeline: ((json['audio_volume_timeline'] ?? json['timeline']) as List? ?? [])
          .map((e) => TimelinePoint.fromJson(e))
          .toList(),
      userEvolution: (json['user_evolution'] as List? ?? [])
          .map((e) => UserEvolutionPoint.fromJson(e))
          .toList(),
      sourceModes: (json['categories']?['source_modes'] as List? ?? [])
          .map((e) => TaxonomyItem.fromJson(e))
          .toList(),
      fileFormats: (json['categories']?['file_formats'] as List? ?? [])
          .map((e) => TaxonomyItem.fromJson(e))
          .toList(),
      languages: (json['categories']?['languages'] as List? ?? [])
          .map((e) => TaxonomyItem.fromJson(e))
          .toList(),
      lengthTiers: (json['categories']?['length_tiers'] as List? ?? [])
          .map((e) => TaxonomyItem.fromJson(e))
          .toList(),
    );
  }
}

class DashboardKpi {
  final int totalJobs;
  final double totalSeconds;
  final double totalMinutes;
  final double totalHours;
  final String totalAudioHuman;
  final double avgDurationSeconds;
  final String avgDurationHuman;
  final int totalUsers;
  final int activeContributors;
  final int guestJobs;
  final bool isUserFiltered;
  final Map<String, dynamic>? targetUser;

  DashboardKpi({
    required this.totalJobs,
    required this.totalSeconds,
    required this.totalMinutes,
    required this.totalHours,
    required this.totalAudioHuman,
    required this.avgDurationSeconds,
    required this.avgDurationHuman,
    required this.totalUsers,
    required this.activeContributors,
    this.guestJobs = 0,
    this.isUserFiltered = false,
    this.targetUser,
  });

  factory DashboardKpi.fromJson(Map<String, dynamic> json) {
    return DashboardKpi(
      totalJobs: (json['total_jobs'] as num?)?.toInt() ?? 0,
      totalSeconds: (json['total_seconds'] as num?)?.toDouble() ?? 0.0,
      totalMinutes: (json['total_minutes'] as num?)?.toDouble() ?? 0.0,
      totalHours: (json['total_hours'] as num?)?.toDouble() ?? 0.0,
      totalAudioHuman: json['total_formatted']?.toString() ?? json['total_audio_human']?.toString() ?? '0s',
      avgDurationSeconds: (json['avg_duration_seconds'] as num?)?.toDouble() ?? 0.0,
      avgDurationHuman: json['avg_duration_formatted']?.toString() ?? json['avg_duration_human']?.toString() ?? '0s',
      totalUsers: (json['total_users'] as num?)?.toInt() ?? 0,
      activeContributors: (json['active_users'] as num?)?.toInt() ?? (json['active_contributors'] as num?)?.toInt() ?? 0,
      guestJobs: (json['guest_jobs'] as num?)?.toInt() ?? 0,
      isUserFiltered: json['is_user_filtered'] == true,
      targetUser: json['target_user'] as Map<String, dynamic>?,
    );
  }
}

class TimelinePoint {
  final String date;
  final String label;
  final double minutes;
  final double hours;
  final int jobs;
  final double cumulativeHours;

  TimelinePoint({
    required this.date,
    required this.label,
    required this.minutes,
    required this.hours,
    required this.jobs,
    required this.cumulativeHours,
  });

  factory TimelinePoint.fromJson(Map<String, dynamic> json) {
    return TimelinePoint(
      date: json['date']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
      minutes: (json['minutes'] as num?)?.toDouble() ?? 0.0,
      hours: (json['hours'] as num?)?.toDouble() ?? 0.0,
      jobs: (json['jobs'] as num?)?.toInt() ?? 0,
      cumulativeHours: (json['cumulative_hours'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

class UserEvolutionPoint {
  final String date;
  final String label;
  final int newUsers;
  final int cumulativeUsers;
  final int activeJobs;

  UserEvolutionPoint({
    required this.date,
    required this.label,
    required this.newUsers,
    required this.cumulativeUsers,
    required this.activeJobs,
  });

  factory UserEvolutionPoint.fromJson(Map<String, dynamic> json) {
    return UserEvolutionPoint(
      date: json['date']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
      newUsers: (json['new_users'] as num?)?.toInt() ?? 0,
      cumulativeUsers: (json['cumulative_users'] as num?)?.toInt() ?? 0,
      activeJobs: (json['active_jobs'] as num?)?.toInt() ?? 0,
    );
  }
}

class TaxonomyItem {
  final String name;
  final int count;
  final double minutes;
  final String formatted;
  final double percentage;

  TaxonomyItem({
    required this.name,
    required this.count,
    required this.minutes,
    required this.formatted,
    required this.percentage,
  });

  factory TaxonomyItem.fromJson(Map<String, dynamic> json) {
    return TaxonomyItem(
      name: json['name']?.toString() ?? json['label']?.toString() ?? '',
      count: (json['count'] as num?)?.toInt() ?? 0,
      minutes: (json['minutes'] as num?)?.toDouble() ?? 0.0,
      formatted: json['formatted']?.toString() ?? '',
      percentage: (json['percentage'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

class DashboardUserItem {
  final int id;
  final String username;
  final String email;
  final bool isActive;
  final bool isStaff;
  final int jobsCount;
  final double audioMinutes;
  final String audioHuman;
  final String dateJoined;

  DashboardUserItem({
    required this.id,
    required this.username,
    required this.email,
    required this.isActive,
    required this.isStaff,
    required this.jobsCount,
    required this.audioMinutes,
    required this.audioHuman,
    required this.dateJoined,
  });

  factory DashboardUserItem.fromJson(Map<String, dynamic> json) {
    return DashboardUserItem(
      id: (json['id'] as num?)?.toInt() ?? 0,
      username: json['username']?.toString() ?? '',
      email: json['email']?.toString() ?? '',
      isActive: json['is_active'] == true,
      isStaff: json['is_staff'] == true,
      jobsCount: (json['jobs_count'] as num?)?.toInt() ?? 0,
      audioMinutes: (json['audio_minutes'] as num?)?.toDouble() ?? 0.0,
      audioHuman: json['audio_human']?.toString() ?? '0m',
      dateJoined: json['date_joined']?.toString() ?? '',
    );
  }
}
