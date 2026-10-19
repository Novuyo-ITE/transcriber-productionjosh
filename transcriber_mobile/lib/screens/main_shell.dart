import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../providers/transcription_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'dashboard_screen.dart';
import 'workspace_screen.dart';
import 'stream_studio_screen.dart';
import 'history_screen.dart';
import 'settings_profile_screen.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<TranscriptionProvider>().fetchHistory();
    });
  }

  void _onTabTapped(int index) {
    if (_currentIndex != index) {
      HapticFeedback.selectionClick();
      setState(() => _currentIndex = index);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final transcriptionProv = context.watch<TranscriptionProvider>();
    final historyCount = transcriptionProv.history.length;

    final screens = [
      DashboardScreen(
        onTranscriptionComplete: () {
          setState(() => _currentIndex = 1);
        },
      ),
      const WorkspaceScreen(),
      StreamStudioScreen(
        onSavedToWorkspace: () {
          setState(() => _currentIndex = 1);
        },
      ),
      HistoryScreen(
        onSelectTranscription: () {
          setState(() => _currentIndex = 1);
        },
      ),
      const SettingsProfileScreen(),
    ];

    return Scaffold(
      // Top navbar is completely removed for full edge-to-edge immersion
      appBar: null,

      // Body wrapped in SafeArea with bottom set to false to hug bottom navigation bar
      body: SafeArea(
        bottom: false,
        child: IndexedStack(
          index: _currentIndex.clamp(0, screens.length - 1),
          children: screens,
        ),
      ),

      // Downer (Bottom) Navigation Bar housing all functionalities
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: isDark ? AppColors.darkBgSidebar : AppColors.lightBgSidebar,
          border: Border(
            top: BorderSide(
              color: isDark ? AppColors.darkBorderPanel : AppColors.lightBorderPanel,
              width: 1,
            ),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.12),
              blurRadius: 10,
              offset: const Offset(0, -3),
            ),
          ],
        ),
        child: BottomNavigationBar(
          currentIndex: _currentIndex.clamp(0, screens.length - 1),
          onTap: _onTabTapped,
          type: BottomNavigationBarType.fixed,
          backgroundColor: Colors.transparent,
          elevation: 0,
          selectedItemColor: AppColors.emeraldPrimary,
          unselectedItemColor: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
          selectedLabelStyle: GoogleFonts.plusJakartaSans(
            fontWeight: FontWeight.w800,
            fontSize: 10.5,
          ),
          unselectedLabelStyle: GoogleFonts.plusJakartaSans(
            fontWeight: FontWeight.w600,
            fontSize: 10.5,
          ),
          items: [
            const BottomNavigationBarItem(
              icon: Icon(Icons.dashboard_outlined, size: 22),
              activeIcon: Icon(Icons.dashboard, size: 22),
              label: 'Dashboard',
            ),
            const BottomNavigationBarItem(
              icon: Icon(Icons.article_outlined, size: 22),
              activeIcon: Icon(Icons.article, size: 22),
              label: 'Workspace',
            ),
            const BottomNavigationBarItem(
              icon: Icon(Icons.graphic_eq_rounded, size: 22),
              activeIcon: Icon(Icons.graphic_eq, size: 22),
              label: 'Stream',
            ),
            BottomNavigationBarItem(
              icon: Badge(
                isLabelVisible: historyCount > 0,
                label: Text(
                  historyCount > 99 ? '99+' : historyCount.toString(),
                  style: AppTheme.mono(fontSize: 8, fontWeight: FontWeight.w900),
                ),
                backgroundColor: AppColors.emeraldPrimary,
                textColor: const Color(0xFF030712),
                child: const Icon(Icons.history_rounded, size: 22),
              ),
              activeIcon: Badge(
                isLabelVisible: historyCount > 0,
                label: Text(
                  historyCount > 99 ? '99+' : historyCount.toString(),
                  style: AppTheme.mono(fontSize: 8, fontWeight: FontWeight.w900),
                ),
                backgroundColor: AppColors.emeraldPrimary,
                textColor: const Color(0xFF030712),
                child: const Icon(Icons.history, size: 22),
              ),
              label: 'History',
            ),
            const BottomNavigationBarItem(
              icon: Icon(Icons.tune_rounded, size: 22),
              activeIcon: Icon(Icons.tune, size: 22),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }
}
