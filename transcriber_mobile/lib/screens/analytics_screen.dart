import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fl_chart/fl_chart.dart';
import '../models/analytics.dart';
import '../services/api_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../widgets/taxonomy_pie_chart.dart';

class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  bool _isLoading = true;
  String? _error;
  DashboardStats? _stats;
  List<DashboardUserItem> _users = [];

  String _currentRange = 'all';
  String _selectedUserId = 'all';
  String _currentMetric = 'minutes';

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final stats = await ApiService().getDashboardStats(
        range: _currentRange,
        userId: _selectedUserId,
      );
      final users = await ApiService().getDashboardUsers();
      setState(() {
        _stats = stats;
        _users = users;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _openCreateUserDialog() async {
    final userCtrl = TextEditingController();
    final emailCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    bool isStaff = false;

    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Add New User', style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: userCtrl, decoration: const InputDecoration(labelText: 'Username')),
              const SizedBox(height: 10),
              TextField(controller: emailCtrl, decoration: const InputDecoration(labelText: 'Email')),
              const SizedBox(height: 10),
              TextField(controller: passCtrl, obscureText: true, decoration: const InputDecoration(labelText: 'Password')),
              const SizedBox(height: 10),
              Row(
                children: [
                  Checkbox(
                    value: isStaff,
                    onChanged: (v) => setDialogState(() => isStaff = v ?? false),
                    activeColor: AppColors.emeraldPrimary,
                  ),
                  const Text('Staff / Admin Role'),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Create User')),
          ],
        ),
      ),
    );

    if (created == true && userCtrl.text.trim().isNotEmpty && passCtrl.text.trim().isNotEmpty) {
      try {
        await ApiService().createDashboardUser(
          userCtrl.text.trim(),
          emailCtrl.text.trim(),
          passCtrl.text.trim(),
          isStaff,
        );
        _loadData();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('User created successfully!'), backgroundColor: AppColors.emeraldPrimary),
        );
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error creating user: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(color: AppColors.emeraldPrimary));
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.lock_person_outlined, size: 48, color: Colors.redAccent),
              const SizedBox(height: 12),
              Text(
                'Admin Privileges Required',
                style: GoogleFonts.plusJakartaSans(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                _error!.contains('ADMIN_REQUIRED')
                    ? 'The Customer & Software Analytics Dashboard is strictly reserved for Admin Gideoni.'
                    : 'Error: $_error',
                textAlign: TextAlign.center,
                style: GoogleFonts.plusJakartaSans(fontSize: 12.5, color: isDark ? AppColors.darkTextMuted : AppColors.lightTextMuted),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _loadData,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final kpi = _stats!.kpi;

    return RefreshIndicator(
      onRefresh: _loadData,
      color: AppColors.emeraldPrimary,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Top Bar
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isDark ? AppColors.darkBgPanel : AppColors.lightBgPanel,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: isDark ? AppColors.darkBorderPanel : AppColors.lightBorderPanel),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Analytics & Intelligence',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppColors.emeraldPrimary.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: AppColors.emeraldPrimary.withOpacity(0.4)),
                        ),
                        child: Text(
                          'ADMIN: GIDEONI',
                          style: AppTheme.mono(fontSize: 9.5, fontWeight: FontWeight.w700, color: AppColors.emeraldLight),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Workspace telemetry: audio hours, file taxonomy & user management.',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 11.5,
                      color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Filter Controls
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      // Date range filter
                      _buildDropdown(
                        value: _currentRange,
                        items: const [
                          DropdownMenuItem(value: 'all', child: Text('All Time')),
                          DropdownMenuItem(value: '30d', child: Text('Last 30 Days')),
                          DropdownMenuItem(value: '7d', child: Text('Last 7 Days')),
                        ],
                        onChanged: (val) {
                          if (val != null) {
                            setState(() => _currentRange = val);
                            _loadData();
                          }
                        },
                      ),

                      // Metric selector
                      _buildDropdown(
                        value: _currentMetric,
                        items: const [
                          DropdownMenuItem(value: 'minutes', child: Text('Minutes')),
                          DropdownMenuItem(value: 'jobs', child: Text('Jobs')),
                        ],
                        onChanged: (val) {
                          if (val != null) setState(() => _currentMetric = val);
                        },
                      ),

                      // User filter
                      _buildDropdown(
                        value: _selectedUserId,
                        items: [
                          const DropdownMenuItem(value: 'all', child: Text('🌐 All Users')),
                          ..._users.map((u) => DropdownMenuItem(value: u.id.toString(), child: Text('👤 ${u.username}'))),
                        ],
                        onChanged: (val) {
                          if (val != null) {
                            setState(() => _selectedUserId = val);
                            _loadData();
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // 4 Glowing KPI Cards Grid
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 2,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 1.25,
              children: [
                _buildKpiCard(
                  title: 'AUDIO VOLUME',
                  value: kpi.totalAudioHuman,
                  subtext: '${kpi.totalMinutes.toStringAsFixed(0)} mins',
                  accentColor: AppColors.emeraldPrimary,
                  icon: Icons.audiotrack,
                ),
                _buildKpiCard(
                  title: 'JOBS PROCESSED',
                  value: kpi.totalJobs.toString(),
                  subtext: 'Cloud accelerated',
                  accentColor: const Color(0xFF06B6D4),
                  icon: Icons.description_outlined,
                ),
                _buildKpiCard(
                  title: 'AVG AUDIO LENGTH',
                  value: kpi.avgDurationHuman,
                  subtext: 'Per ingestion',
                  accentColor: const Color(0xFFF59E0B),
                  icon: Icons.timer_outlined,
                ),
                _buildKpiCard(
                  title: 'CONTRIBUTORS',
                  value: kpi.totalUsers.toString(),
                  subtext: '${kpi.activeContributors} active',
                  accentColor: const Color(0xFFA855F7),
                  icon: Icons.people_outline,
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Audio Volume Evolution Chart
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: isDark ? AppColors.darkBgPanel : AppColors.lightBgPanel,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: isDark ? AppColors.darkBorderPanel : AppColors.lightBorderPanel),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Audio Volume Evolution',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                        ),
                      ),
                      Text(
                        _currentMetric.toUpperCase(),
                        style: AppTheme.mono(fontSize: 10, color: AppColors.emeraldLight, fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 180,
                    child: _buildTimelineChart(isDark),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // User Evolution Chart
            if (_stats!.userEvolution.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: isDark ? AppColors.darkBgPanel : AppColors.lightBgPanel,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: isDark ? AppColors.darkBorderPanel : AppColors.lightBorderPanel),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'User Growth & Adoption Curve',
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      height: 150,
                      child: _buildUserEvolutionChart(isDark),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],

            // File Taxonomy Breakdown (4 Interactive Pie Charts)
            Row(
              children: [
                const Icon(Icons.donut_large, size: 16, color: AppColors.emeraldPrimary),
                const SizedBox(width: 8),
                Text(
                  'FILE TAXONOMY & CATEGORY BREAKDOWN',
                  style: AppTheme.mono(fontSize: 11.5, fontWeight: FontWeight.w700, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TaxonomyPieChart(
              title: 'Ingestion & Source Modes',
              subtitle: 'Audio Uploads, Video Extractions, YouTube Media, Live Mic, and Real-Time Streams.',
              tag: '${_stats!.sourceModes.length} Modes',
              items: _stats!.sourceModes,
              isDark: isDark,
            ),
            const SizedBox(height: 12),
            TaxonomyPieChart(
              title: 'File Formats & Extensions',
              subtitle: 'Media extension distribution (.mp3, .wav, .m4a, .mp4, .stream, etc.)',
              tag: '${_stats!.fileFormats.length} Formats',
              items: _stats!.fileFormats,
              isDark: isDark,
            ),
            const SizedBox(height: 12),
            TaxonomyPieChart(
              title: 'Audio Duration Length Tiers',
              subtitle: 'Quick (<2m), Short (2-10m), Medium (10-30m), Extended (30m+)',
              tag: '4 Tiers',
              items: _stats!.lengthTiers,
              isDark: isDark,
            ),
            const SizedBox(height: 12),
            TaxonomyPieChart(
              title: 'Language Taxonomy Distribution',
              subtitle: 'Luganda, English, Swahili, French, Lingala model workloads',
              tag: '${_stats!.languages.length} Languages',
              items: _stats!.languages,
              isDark: isDark,
            ),
            const SizedBox(height: 24),

            // User Management Table
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isDark ? AppColors.darkBgPanel : AppColors.lightBgPanel,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: isDark ? AppColors.darkBorderPanel : AppColors.lightBorderPanel),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'User Accounts (${_users.length})',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                        ),
                      ),
                      ElevatedButton.icon(
                        onPressed: _openCreateUserDialog,
                        icon: const Icon(Icons.add, size: 14),
                        label: const Text('Add User'),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          textStyle: GoogleFonts.plusJakartaSans(fontSize: 11, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _users.length,
                    separatorBuilder: (_, __) => Divider(height: 1, color: isDark ? AppColors.darkBorderPanel : AppColors.lightBorderPanel),
                    itemBuilder: (context, idx) {
                      final u = _users[idx];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 16,
                              backgroundColor: AppColors.emeraldPrimary.withOpacity(0.2),
                              child: Text(
                                u.username.isNotEmpty ? u.username[0].toUpperCase() : 'U',
                                style: GoogleFonts.plusJakartaSans(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.emeraldLight),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        u.username,
                                        style: GoogleFonts.plusJakartaSans(fontSize: 13, fontWeight: FontWeight.w700),
                                      ),
                                      if (u.isStaff) ...[
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                          decoration: BoxDecoration(
                                            color: Colors.purple.withOpacity(0.18),
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: Text('ADMIN', style: AppTheme.mono(fontSize: 8.5, color: Colors.purpleAccent, fontWeight: FontWeight.w700)),
                                        ),
                                      ],
                                    ],
                                  ),
                                  Text(
                                    '${u.jobsCount} jobs • ${u.audioHuman}',
                                    style: AppTheme.mono(fontSize: 10.5, color: isDark ? AppColors.darkTextMuted : AppColors.lightTextMuted),
                                  ),
                                ],
                              ),
                            ),
                            // Status toggle
                            IconButton(
                              icon: Icon(
                                u.isActive ? Icons.check_circle : Icons.cancel,
                                color: u.isActive ? AppColors.emeraldPrimary : Colors.redAccent,
                                size: 20,
                              ),
                              tooltip: u.isActive ? 'Deactivate User' : 'Activate User',
                              onPressed: () async {
                                await ApiService().toggleUserStatus(u.id);
                                _loadData();
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }

  Widget _buildDropdown({
    required String value,
    required List<DropdownMenuItem<String>> items,
    required ValueChanged<String?> onChanged,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkBgInput : AppColors.lightBgInput,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: isDark ? AppColors.darkBorderInput : AppColors.lightBorderInput),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isDense: true,
          dropdownColor: isDark ? AppColors.darkBgPanel : AppColors.lightBgPanel,
          items: items,
          style: AppTheme.mono(fontSize: 11.5, color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary),
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _buildKpiCard({
    required String title,
    required String value,
    required String subtext,
    required Color accentColor,
    required IconData icon,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkBgPanel : AppColors.lightBgPanel,
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: accentColor, width: 3.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.mono(fontSize: 10, fontWeight: FontWeight.w700, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
                ),
              ),
              Icon(icon, size: 16, color: accentColor),
            ],
          ),
          Text(
            value,
            style: AppTheme.mono(fontSize: 20, fontWeight: FontWeight.w800, color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary),
          ),
          Text(
            subtext,
            style: GoogleFonts.plusJakartaSans(fontSize: 10.5, color: isDark ? AppColors.darkTextMuted : AppColors.lightTextMuted),
          ),
        ],
      ),
    );
  }

  Widget _buildTimelineChart(bool isDark) {
    final timeline = _stats!.timeline;
    if (timeline.isEmpty) {
      return Center(child: Text('No timeline data available', style: GoogleFonts.plusJakartaSans(fontSize: 12)));
    }

    final spots = <FlSpot>[];
    for (int i = 0; i < timeline.length; i++) {
      final y = _currentMetric == 'minutes' ? timeline[i].minutes : timeline[i].jobs.toDouble();
      spots.add(FlSpot(i.toDouble(), y));
    }

    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (val) => FlLine(
            color: isDark ? Colors.white.withOpacity(0.05) : Colors.black.withOpacity(0.05),
            strokeWidth: 1,
          ),
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              getTitlesWidget: (val, meta) {
                final idx = val.toInt();
                if (idx >= 0 && idx < timeline.length && (idx % (timeline.length > 5 ? 2 : 1) == 0)) {
                  return Text(timeline[idx].label, style: AppTheme.mono(fontSize: 9));
                }
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
        borderData: FlBorderData(show: false),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: AppColors.emeraldPrimary,
            barWidth: 2.5,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: AppColors.emeraldPrimary.withOpacity(0.12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUserEvolutionChart(bool isDark) {
    final evo = _stats!.userEvolution;
    if (evo.isEmpty) {
      return Center(
        child: Text('No evolution data recorded', style: AppTheme.mono(fontSize: 11)),
      );
    }

    final spots = <FlSpot>[];
    for (int i = 0; i < evo.length; i++) {
      spots.add(FlSpot(i.toDouble(), evo[i].cumulativeUsers.toDouble()));
    }

    return LineChart(
      LineChartData(
        gridData: const FlGridData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 20,
              getTitlesWidget: (val, meta) {
                final idx = val.toInt();
                if (idx >= 0 && idx < evo.length && (idx % (evo.length > 5 ? 2 : 1) == 0)) {
                  return Text(evo[idx].label, style: AppTheme.mono(fontSize: 8.5));
                }
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
        borderData: FlBorderData(show: false),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: const Color(0xFFA855F7),
            barWidth: 2.5,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: const Color(0xFFA855F7).withOpacity(0.12),
            ),
          ),
        ],
      ),
    );
  }
}
