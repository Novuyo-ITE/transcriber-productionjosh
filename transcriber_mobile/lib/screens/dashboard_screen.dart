import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:fl_chart/fl_chart.dart';
import '../models/analytics.dart';
import '../services/api_service.dart';
import '../providers/transcription_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../widgets/loading_overlay.dart';
import '../widgets/taxonomy_pie_chart.dart';

class DashboardScreen extends StatefulWidget {
  final VoidCallback onTranscriptionComplete;

  const DashboardScreen({super.key, required this.onTranscriptionComplete});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> with SingleTickerProviderStateMixin {
  int _viewMode = 0; // 0: Transcribe, 1: Analytics & Charts
  int _selectedTab = 0; // 0: Audio, 1: Video, 2: YouTube, 3: Live Mic
  String? _selectedAudioPath;
  String? _selectedAudioName;
  String? _selectedVideoPath;
  String? _selectedVideoName;
  final TextEditingController _youtubeController = TextEditingController();

  // Transcription Options
  String _selectedLanguage = 'Luganda';
  bool _diarize = true;
  final TextEditingController _numSpeakersController = TextEditingController();

  final List<String> _languages = [
    'Luganda',
    'English',
    'Swahili',
    'French',
    'Lingala',
  ];

  // ====== LIVE MIC RECORDING STATE ======
  final AudioRecorder _audioRecorder = AudioRecorder();
  final AudioPlayer _previewPlayer = AudioPlayer();
  bool _isLiveRecording = false;
  bool _isLivePaused = false;
  int _liveRecordSec = 0;
  Timer? _liveRecordTimer;
  String? _liveRecordedAudioPath;
  bool _isPlayingPreview = false;
  Duration _previewDuration = Duration.zero;
  Duration _previewPosition = Duration.zero;
  late AnimationController _waveAnimController;

  // ====== ANALYTICS STATE ======
  bool _isLoadingAnalytics = false;
  String? _analyticsError;
  DashboardStats? _dashboardStats;
  List<DashboardUserItem> _dashboardUsers = [];
  String _currentRange = 'all';
  String _selectedUserId = 'all';
  String _currentMetric = 'minutes';

  @override
  void initState() {
    super.initState();
    _waveAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);

    _previewPlayer.onPlayerStateChanged.listen((state) {
      if (mounted) {
        setState(() => _isPlayingPreview = state == PlayerState.playing);
      }
    });
    _previewPlayer.onDurationChanged.listen((d) {
      if (mounted) setState(() => _previewDuration = d);
    });
    _previewPlayer.onPositionChanged.listen((p) {
      if (mounted) setState(() => _previewPosition = p);
    });

    _loadAnalyticsData();
  }

  @override
  void dispose() {
    _waveAnimController.dispose();
    _liveRecordTimer?.cancel();
    _previewPlayer.dispose();
    _audioRecorder.dispose();
    _youtubeController.dispose();
    _numSpeakersController.dispose();
    super.dispose();
  }

  Future<void> _loadAnalyticsData() async {
    setState(() {
      _isLoadingAnalytics = true;
      _analyticsError = null;
    });

    try {
      final stats = await ApiService().getDashboardStats(
        range: _currentRange,
        userId: _selectedUserId,
      );
      List<DashboardUserItem> users = [];
      try {
        users = await ApiService().getDashboardUsers();
      } catch (_) {}

      if (mounted) {
        setState(() {
          _dashboardStats = stats;
          _dashboardUsers = users;
          _isLoadingAnalytics = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _analyticsError = e.toString();
          _isLoadingAnalytics = false;
        });
      }
    }
  }

  // ====== FILE PICKING ======
  Future<void> _pickAudioFile() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp3', 'wav', 'm4a', 'aac', 'flac', 'ogg'],
    );
    if (files.isNotEmpty && files.first.path != null) {
      setState(() {
        _selectedAudioPath = files.first.path;
        _selectedAudioName = files.first.name;
      });
    }
  }

  Future<void> _pickVideoFile() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp4', 'mkv', 'avi', 'mov', 'webm'],
    );
    if (files.isNotEmpty && files.first.path != null) {
      setState(() {
        _selectedVideoPath = files.first.path;
        _selectedVideoName = files.first.name;
      });
    }
  }

  // ====== LIVE RECORDING LOGIC ======
  Future<void> _startLiveRecording() async {
    final status = await Permission.microphone.request();
    if (status != PermissionStatus.granted) {
      _showToast('Microphone permission is required to record audio');
      return;
    }

    final hasPerm = await _audioRecorder.hasPermission();
    if (!hasPerm) {
      _showToast('Microphone access is not permitted');
      return;
    }

    await _previewPlayer.stop();

    try {
      final tempDir = await getTemporaryDirectory();
      final path = '${tempDir.path}/Live_Recording_${DateTime.now().millisecondsSinceEpoch}.wav';

      await _audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: path,
      );

      setState(() {
        _isLiveRecording = true;
        _isLivePaused = false;
        _liveRecordSec = 0;
        _liveRecordedAudioPath = null;
        _selectedAudioPath = null;
        _selectedAudioName = null;
      });

      _liveRecordTimer?.cancel();
      _liveRecordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _liveRecordSec++);
      });
    } catch (e) {
      _showToast('Failed to start recording: $e');
    }
  }

  Future<void> _pauseResumeLiveRecording() async {
    try {
      if (_isLivePaused) {
        await _audioRecorder.resume();
        setState(() => _isLivePaused = false);
      } else {
        await _audioRecorder.pause();
        setState(() => _isLivePaused = true);
      }
    } catch (e) {
      _showToast('Error: $e');
    }
  }

  Future<void> _stopLiveRecording() async {
    _liveRecordTimer?.cancel();
    try {
      final path = await _audioRecorder.stop();
      if (path != null) {
        final filename = path.split(Platform.pathSeparator).last;
        setState(() {
          _isLiveRecording = false;
          _isLivePaused = false;
          _liveRecordedAudioPath = path;
          _selectedAudioPath = path;
          _selectedAudioName = filename;
        });

        await _previewPlayer.setSource(DeviceFileSource(path));
      }
    } catch (e) {
      _showToast('Failed to stop recording: $e');
    }
  }

  Future<void> _togglePreviewPlay() async {
    if (_isPlayingPreview) {
      await _previewPlayer.pause();
    } else {
      if (_liveRecordedAudioPath != null) {
        await _previewPlayer.resume();
      }
    }
  }

  Future<void> _discardLiveRecording() async {
    await _previewPlayer.stop();
    if (_liveRecordedAudioPath != null) {
      final file = File(_liveRecordedAudioPath!);
      if (await file.exists()) {
        try { await file.delete(); } catch (_) {}
      }
    }
    setState(() {
      _liveRecordedAudioPath = null;
      _selectedAudioPath = null;
      _selectedAudioName = null;
      _liveRecordSec = 0;
      _isPlayingPreview = false;
      _previewPosition = Duration.zero;
      _previewDuration = Duration.zero;
    });
  }

  String _formatSeconds(int sec) {
    final m = sec ~/ 60;
    final s = sec % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  // ====== SUBMISSION ======
  void _submit() async {
    String sourceType;
    String? audioPath;
    String? videoPath;
    String? ytUrl;

    if (_selectedTab == 0) {
      sourceType = 'audio_file';
      audioPath = _selectedAudioPath;
      if (audioPath == null) {
        _showToast('Please select an audio file first');
        return;
      }
    } else if (_selectedTab == 1) {
      sourceType = 'video_file';
      videoPath = _selectedVideoPath;
      if (videoPath == null) {
        _showToast('Please select a video file first');
        return;
      }
    } else if (_selectedTab == 2) {
      sourceType = 'youtube_url';
      ytUrl = _youtubeController.text.trim();
      if (ytUrl.isEmpty) {
        _showToast('Please enter a valid YouTube URL');
        return;
      }
    } else {
      if (_isLiveRecording) {
        await _stopLiveRecording();
      }
      sourceType = 'audio_file';
      audioPath = _liveRecordedAudioPath ?? _selectedAudioPath;
      if (audioPath == null) {
        _showToast('Please record live audio first using the microphone');
        return;
      }
    }

    final numSpk = int.tryParse(_numSpeakersController.text.trim());

    context.read<TranscriptionProvider>().submitAndTrackJob(
      sourceType: sourceType,
      language: _selectedLanguage,
      diarize: _diarize,
      numSpeakers: numSpk,
      audioFilePath: audioPath,
      videoFilePath: videoPath,
      youtubeUrl: ytUrl,
      isLiveRec: _selectedTab == 3,
      onComplete: () {
        _loadAnalyticsData(); // Refresh metrics after transcription
        widget.onTranscriptionComplete();
      },
      onError: (err) {
        _showToast('Transcription error: $err');
      },
    );
  }

  void _showToast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: const Color(0xFFEF4444),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final provider = context.watch<TranscriptionProvider>();

    return Stack(
      children: [
        SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Top Brand Header
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Row(
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.emeraldPrimary.withOpacity(0.25),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.asset(
                          'assets/logo.png',
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Image.asset(
                      'assets/novuscribe_full_logo.png',
                      height: 22,
                      fit: BoxFit.contain,
                    ),
                  ],
                ),
              ),

              // Top Segmented Switch: Transcribe vs Analytics & Charts
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF0D121F) : const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isDark ? AppColors.darkBorderPanel : AppColors.lightBorderPanel,
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: () => setState(() => _viewMode = 0),
                        borderRadius: BorderRadius.circular(9),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 9),
                          decoration: BoxDecoration(
                            color: _viewMode == 0
                                ? (_selectedTab == 3 ? Colors.redAccent.withOpacity(0.18) : AppColors.emeraldPrimary.withOpacity(0.18))
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(9),
                            border: _viewMode == 0
                                ? Border.all(color: AppColors.emeraldPrimary.withOpacity(0.5))
                                : null,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.record_voice_over_outlined,
                                size: 16,
                                color: _viewMode == 0 ? AppColors.emeraldLight : (isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Transcribe',
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: _viewMode == 0 ? AppColors.emeraldLight : (isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: InkWell(
                        onTap: () {
                          setState(() => _viewMode = 1);
                          _loadAnalyticsData();
                        },
                        borderRadius: BorderRadius.circular(9),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 9),
                          decoration: BoxDecoration(
                            color: _viewMode == 1
                                ? const Color(0xFF06B6D4).withOpacity(0.18)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(9),
                            border: _viewMode == 1
                                ? Border.all(color: const Color(0xFF06B6D4).withOpacity(0.5))
                                : null,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.pie_chart_outline,
                                size: 16,
                                color: _viewMode == 1 ? const Color(0xFF38BDF8) : (isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Analytics & Charts',
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: _viewMode == 1 ? const Color(0xFF38BDF8) : (isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),

              // View Mode Content
              if (_viewMode == 0)
                _buildTranscribeContent(isDark)
              else
                _buildAnalyticsContent(isDark),
            ],
          ),
        ),

        // Real-Time Progress Overlay
        if (provider.isTranscribing && provider.currentProgress != null)
          LoadingOverlay(
            progress: provider.currentProgress!,
            onCancel: () {
              provider.cancelProgressTracking();
            },
          ),
      ],
    );
  }

  // ================= VIEW 1: TRANSCRIBE & LIVE MIC =================
  Widget _buildTranscribeContent(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Hero Badge
        Align(
          alignment: Alignment.centerLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: AppColors.emeraldPrimary.withOpacity(0.12),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.emeraldPrimary.withOpacity(0.35)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: AppColors.emeraldLight,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.emeraldGlow,
                        blurRadius: 6,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'Speech-to-Text Intelligence',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.emeraldLight,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),

        // Title
        Text(
          'Transcribe speech to text.',
          style: GoogleFonts.plusJakartaSans(
            fontSize: 23,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.02,
            color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
          ),
        ),
        const SizedBox(height: 4),

        // Subtitle
        Text(
          'Convert audio, video, YouTube, or record live mic audio with automatic speaker identification.',
          style: GoogleFonts.plusJakartaSans(
            fontSize: 12,
            height: 1.45,
            color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
          ),
        ),
        const SizedBox(height: 18),

        // 4 Ingestion Tabs
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _buildTabBtn(0, Icons.audiotrack_outlined, 'Audio File'),
              const SizedBox(width: 8),
              _buildTabBtn(1, Icons.videocam_outlined, 'Video File'),
              const SizedBox(width: 8),
              _buildTabBtn(2, Icons.smart_display_outlined, 'YouTube Link'),
              const SizedBox(width: 8),
              _buildTabBtn(3, Icons.mic_none_outlined, '● Live Mic'),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Ingestion Tab Body
        Container(
          decoration: BoxDecoration(
            color: isDark ? AppColors.darkBgPanel : AppColors.lightBgPanel,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isDark ? AppColors.darkBorderPanel : AppColors.lightBorderPanel,
            ),
          ),
          padding: const EdgeInsets.all(18),
          child: _buildSelectedTabContent(isDark),
        ),
        const SizedBox(height: 18),

        // Options Card
        Container(
          decoration: BoxDecoration(
            color: isDark ? AppColors.darkBgPanel : AppColors.lightBgPanel,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isDark ? AppColors.darkBorderPanel : AppColors.lightBorderPanel,
            ),
          ),
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'TRANSCRIPTION PARAMETERS',
                style: AppTheme.mono(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                ),
              ),
              const SizedBox(height: 14),

              // Language Selector
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Speech Language',
                    style: GoogleFonts.plusJakartaSans(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: isDark ? AppColors.darkBgInput : AppColors.lightBgInput,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isDark ? AppColors.darkBorderInput : AppColors.lightBorderInput,
                      ),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _selectedLanguage,
                        isExpanded: true,
                        dropdownColor: isDark ? AppColors.darkBgPanel : AppColors.lightBgPanel,
                        items: _languages.map((l) {
                          return DropdownMenuItem(
                            value: l,
                            child: Row(
                              children: [
                                Text(l, style: GoogleFonts.plusJakartaSans(fontSize: 13.5, fontWeight: FontWeight.w600)),
                                const Spacer(),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: AppColors.emeraldPrimary.withOpacity(0.12),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    'Speech Recognition',
                                    style: AppTheme.mono(fontSize: 9.5, color: AppColors.emeraldLight),
                                  ),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                        onChanged: (val) {
                          if (val != null) setState(() => _selectedLanguage = val);
                        },
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Diarization Toggle
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Identify Distinct Speakers',
                          style: GoogleFonts.plusJakartaSans(fontSize: 13.5, fontWeight: FontWeight.w600),
                        ),
                        Text(
                          'Uses voice separation and clustering to attribute speakers.',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 11,
                            color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: _diarize,
                    activeColor: AppColors.emeraldPrimary,
                    onChanged: (val) => setState(() => _diarize = val),
                  ),
                ],
              ),

              if (_diarize) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Text(
                      'EXPECTED SPEAKERS:',
                      style: AppTheme.mono(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 90,
                      child: TextField(
                        controller: _numSpeakersController,
                        keyboardType: TextInputType.number,
                        style: AppTheme.mono(fontSize: 12),
                        decoration: const InputDecoration(
                          hintText: 'Auto',
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 22),

        // Submit Button
        ElevatedButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.play_arrow, color: Color(0xFF030712), size: 20),
          label: Text(
            'Start Transcription',
            style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w800, fontSize: 15),
          ),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
        const SizedBox(height: 30),
      ],
    );
  }

  // ================= VIEW 2: ANALYTICS & CHARTS =================
  Widget _buildAnalyticsContent(bool isDark) {
    if (_isLoadingAnalytics && _dashboardStats == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator(color: AppColors.emeraldPrimary)),
      );
    }

    if (_analyticsError != null && _dashboardStats == null) {
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: isDark ? AppColors.darkBgPanel : AppColors.lightBgPanel,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
        ),
        child: Column(
          children: [
            const Icon(Icons.error_outline, size: 40, color: Colors.redAccent),
            const SizedBox(height: 12),
            Text(
              'Could not load telemetry analytics',
              style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700, fontSize: 14),
            ),
            const SizedBox(height: 6),
            Text(
              _analyticsError!,
              textAlign: TextAlign.center,
              style: GoogleFonts.plusJakartaSans(fontSize: 11.5, color: AppColors.darkTextMuted),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadAnalyticsData,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    final kpi = _dashboardStats?.kpi ?? DashboardKpi(
      totalJobs: 0,
      totalSeconds: 0,
      totalMinutes: 0,
      totalHours: 0,
      totalAudioHuman: '0m',
      avgDurationSeconds: 0,
      avgDurationHuman: '0s',
      totalUsers: 0,
      activeContributors: 0,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Controls Row
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'EXECUTIVE TELEMETRY',
              style: AppTheme.mono(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
              ),
            ),
            Row(
              children: [
                // Range dropdown
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: isDark ? AppColors.darkBgInput : AppColors.lightBgInput,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: isDark ? AppColors.darkBorderInput : AppColors.lightBorderInput),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _currentRange,
                      isDense: true,
                      dropdownColor: isDark ? AppColors.darkBgPanel : AppColors.lightBgPanel,
                      items: const [
                        DropdownMenuItem(value: 'all', child: Text('All Time')),
                        DropdownMenuItem(value: '30d', child: Text('30 Days')),
                        DropdownMenuItem(value: '7d', child: Text('7 Days')),
                      ],
                      style: AppTheme.mono(fontSize: 10.5, color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary),
                      onChanged: (val) {
                        if (val != null) {
                          setState(() => _currentRange = val);
                          _loadAnalyticsData();
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 18, color: AppColors.emeraldLight),
                  onPressed: _loadAnalyticsData,
                  tooltip: 'Refresh Analytics',
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),

        // 4 KPI Cards Grid (Direct match to Django)
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 2,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 1.18,
          children: [
            _buildKpiCard(
              title: 'AUDIO VOLUME TRANSCRIBED',
              value: kpi.totalAudioHuman,
              subtext: '${kpi.totalMinutes.toStringAsFixed(0)} mins total',
              pill: 'VOLUME',
              accentColor: AppColors.emeraldPrimary,
              icon: Icons.audiotrack,
              isDark: isDark,
            ),
            _buildKpiCard(
              title: 'TRANSCRIPTIONS PROCESSED',
              value: '${kpi.totalJobs} Jobs',
              subtext: 'Cloud accelerated',
              pill: 'THROUGHPUT',
              accentColor: const Color(0xFF06B6D4),
              icon: Icons.description_outlined,
              isDark: isDark,
            ),
            _buildKpiCard(
              title: 'AVERAGE AUDIO LENGTH',
              value: kpi.avgDurationHuman,
              subtext: 'Per media ingestion',
              pill: 'EFFICIENCY',
              accentColor: const Color(0xFFF59E0B),
              icon: Icons.timer_outlined,
              isDark: isDark,
            ),
            _buildKpiCard(
              title: kpi.isUserFiltered ? 'USER ACCOUNT STATUS' : 'USERS & CONTRIBUTORS',
              value: kpi.isUserFiltered && kpi.targetUser != null
                  ? (kpi.targetUser!['is_active'] == true ? 'Active' : 'Suspended')
                  : '${kpi.totalUsers} Registered',
              subtext: kpi.isUserFiltered && kpi.targetUser != null
                  ? 'Joined: ${kpi.targetUser!['date_joined'] ?? "—"}'
                  : '${kpi.activeContributors} active',
              pill: kpi.isUserFiltered ? 'PER-USER' : 'ADOPTION',
              accentColor: const Color(0xFFA855F7),
              icon: Icons.people_outline,
              isDark: isDark,
            ),
          ],
        ),
        const SizedBox(height: 18),

        // Chart 1: Audio Volume Evolution Chart
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
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Audio Volume Evolution',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                        ),
                      ),
                      Text(
                        'Daily audio processing volume curve',
                        style: GoogleFonts.plusJakartaSans(fontSize: 10.5, color: isDark ? AppColors.darkTextMuted : AppColors.lightTextMuted),
                      ),
                    ],
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: isDark ? AppColors.darkBgInput : AppColors.lightBgInput,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: isDark ? AppColors.darkBorderInput : AppColors.lightBorderInput),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _currentMetric,
                        isDense: true,
                        dropdownColor: isDark ? AppColors.darkBgPanel : AppColors.lightBgPanel,
                        items: const [
                          DropdownMenuItem(value: 'minutes', child: Text('Minutes')),
                          DropdownMenuItem(value: 'jobs', child: Text('Jobs')),
                        ],
                        style: AppTheme.mono(fontSize: 10, color: AppColors.emeraldLight, fontWeight: FontWeight.w700),
                        onChanged: (val) {
                          if (val != null) setState(() => _currentMetric = val);
                        },
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 170,
                child: _buildTimelineChart(isDark),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),

        // Section Title: Category Pie Charts
        Row(
          children: [
            const Icon(Icons.donut_large, size: 16, color: AppColors.emeraldPrimary),
            const SizedBox(width: 8),
            Text(
              'TAXONOMY & CATEGORY BREAKDOWN',
              style: AppTheme.mono(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // PIE CHART 1: Ingestion & Source Modes
        if (_dashboardStats != null) ...[
          TaxonomyPieChart(
            title: 'Ingestion & Source Modes',
            subtitle: 'Audio Uploads, Video Extractions, YouTube Media, Live Mic, and Real-Time Streams.',
            tag: '${_dashboardStats!.sourceModes.length} Modes',
            items: _dashboardStats!.sourceModes,
            isDark: isDark,
          ),
          const SizedBox(height: 14),

          // PIE CHART 2: File Formats / Extensions
          TaxonomyPieChart(
            title: 'File Formats & Extensions',
            subtitle: 'Media extension distribution (.mp3, .wav, .m4a, .mp4, .stream, etc.)',
            tag: '${_dashboardStats!.fileFormats.length} Formats',
            items: _dashboardStats!.fileFormats,
            isDark: isDark,
          ),
          const SizedBox(height: 14),

          // PIE CHART 3: Audio Duration Length Tiers
          TaxonomyPieChart(
            title: 'Audio Duration Length Tiers',
            subtitle: 'Quick (<2m), Short (2-10m), Medium (10-30m), Extended (30m+).',
            tag: '4 Tiers',
            items: _dashboardStats!.lengthTiers,
            isDark: isDark,
          ),
          const SizedBox(height: 14),

          // PIE CHART 4: Language Taxonomy Distribution
          TaxonomyPieChart(
            title: 'Language Taxonomy Distribution',
            subtitle: 'Luganda, English, Swahili, French, Lingala model workloads.',
            tag: '${_dashboardStats!.languages.length} Languages',
            items: _dashboardStats!.languages,
            isDark: isDark,
          ),
          const SizedBox(height: 18),

          // Chart 2: User Growth Evolution
          if (_dashboardStats!.userEvolution.isNotEmpty) ...[
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
                  Text(
                    'User Growth & Adoption Curve',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                    ),
                  ),
                  Text(
                    'Cumulative user accounts and active sessions',
                    style: GoogleFonts.plusJakartaSans(fontSize: 10.5, color: isDark ? AppColors.darkTextMuted : AppColors.lightTextMuted),
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
        ],

        const SizedBox(height: 20),
      ],
    );
  }

  // ================= TAB BUTTON HELPER =================
  Widget _buildTabBtn(int idx, IconData icon, String label) {
    final isSelected = _selectedTab == idx;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final activeColor = idx == 3 ? Colors.redAccent : AppColors.emeraldPrimary;
    final activeTextColor = idx == 3 ? Colors.redAccent : AppColors.emeraldLight;

    return InkWell(
      onTap: () => setState(() => _selectedTab = idx),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? activeColor.withOpacity(0.15)
              : (isDark ? AppColors.darkBgPanel : AppColors.lightBgPanel),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected
                ? activeColor
                : (isDark ? AppColors.darkBorderPanel : AppColors.lightBorderPanel),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: isSelected
                  ? activeTextColor
                  : (isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                color: isSelected
                    ? activeTextColor
                    : (isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ================= INGESTION TAB CONTENT =================
  Widget _buildSelectedTabContent(bool isDark) {
    if (_selectedTab == 0) {
      // Audio File
      return InkWell(
        onTap: _pickAudioFile,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 16),
          decoration: BoxDecoration(
            color: isDark ? Colors.black.withOpacity(0.25) : Colors.grey.withOpacity(0.05),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _selectedAudioName != null
                  ? AppColors.emeraldPrimary
                  : (isDark ? AppColors.darkBorderPanel : AppColors.lightBorderPanel),
            ),
          ),
          child: Column(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.emeraldPrimary.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.audio_file_outlined, color: AppColors.emeraldPrimary, size: 24),
              ),
              const SizedBox(height: 12),
              Text(
                _selectedAudioName ?? 'Tap to browse audio file',
                textAlign: TextAlign.center,
                style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.w700,
                  fontSize: 13.5,
                  color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'MP3, WAV, M4A, AAC, FLAC (MAX 500MB)',
                style: AppTheme.mono(fontSize: 10, color: AppColors.darkTextMuted),
              ),
            ],
          ),
        ),
      );
    } else if (_selectedTab == 1) {
      // Video File
      return InkWell(
        onTap: _pickVideoFile,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 16),
          decoration: BoxDecoration(
            color: isDark ? Colors.black.withOpacity(0.25) : Colors.grey.withOpacity(0.05),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _selectedVideoName != null
                  ? AppColors.emeraldPrimary
                  : (isDark ? AppColors.darkBorderPanel : AppColors.lightBorderPanel),
            ),
          ),
          child: Column(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFF06B6D4).withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.videocam_outlined, color: Color(0xFF38BDF8), size: 24),
              ),
              const SizedBox(height: 12),
              Text(
                _selectedVideoName ?? 'Tap to browse video file',
                textAlign: TextAlign.center,
                style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.w700,
                  fontSize: 13.5,
                  color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'MP4, MKV, AVI, MOV (MAX 500MB)',
                style: AppTheme.mono(fontSize: 10, color: AppColors.darkTextMuted),
              ),
            ],
          ),
        ),
      );
    } else if (_selectedTab == 2) {
      // YouTube Link
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'YOUTUBE VIDEO OR SHORT URL',
            style: AppTheme.mono(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _youtubeController,
            style: AppTheme.mono(
              fontSize: 13,
              color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
            ),
            decoration: const InputDecoration(
              hintText: 'https://www.youtube.com/watch?v=...',
              prefixIcon: Icon(Icons.link, size: 18),
            ),
          ),
        ],
      );
    } else {
      // TAB 3: REAL LIVE MIC RECORDING INTERFACE
      return _buildLiveRecordingTab(isDark);
    }
  }

  // ================= TAB 3: LIVE MIC RECORDING =================
  Widget _buildLiveRecordingTab(bool isDark) {
    if (_isLiveRecording) {
      // State 1: Active recording in progress
      return Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: _isLivePaused ? Colors.amber : Colors.redAccent,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: (_isLivePaused ? Colors.amber : Colors.redAccent).withOpacity(0.6),
                      blurRadius: 8,
                      spreadRadius: 2,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _isLivePaused ? 'RECORDING PAUSED' : 'RECORDING LIVE AUDIO...',
                style: AppTheme.mono(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: _isLivePaused ? Colors.amber : Colors.redAccent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Big Timer
          Text(
            _formatSeconds(_liveRecordSec),
            style: AppTheme.mono(
              fontSize: 32,
              fontWeight: FontWeight.w900,
              color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
            ),
          ),
          const SizedBox(height: 12),

          // Animated Visualizer bars
          if (!_isLivePaused)
            AnimatedBuilder(
              animation: _waveAnimController,
              builder: (context, _) {
                return Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(16, (i) {
                    final val = (_waveAnimController.value + (i * 0.07)) % 1.0;
                    final h = 8.0 + (val * 28.0);
                    return Container(
                      width: 4,
                      height: h,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      decoration: BoxDecoration(
                        color: i % 2 == 0 ? Colors.redAccent : AppColors.emeraldPrimary,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    );
                  }),
                );
              },
            ),
          const SizedBox(height: 18),

          // Controls: Pause/Resume + Stop
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: _pauseResumeLiveRecording,
                icon: Icon(_isLivePaused ? Icons.play_arrow : Icons.pause, size: 18),
                label: Text(_isLivePaused ? 'Resume' : 'Pause'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _isLivePaused ? AppColors.emeraldLight : Colors.white,
                  side: BorderSide(color: isDark ? Colors.white24 : Colors.black26),
                ),
              ),
              const SizedBox(width: 12),
              ElevatedButton.icon(
                onPressed: _stopLiveRecording,
                icon: const Icon(Icons.stop_rounded, color: Colors.white, size: 18),
                label: const Text('Stop & Save'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ],
      );
    } else if (_liveRecordedAudioPath != null) {
      // State 2: Recorded audio is ready for review or transcription
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: AppColors.emeraldPrimary,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'LIVE AUDIO RECORDED',
                style: AppTheme.mono(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: AppColors.emeraldLight,
                ),
              ),
              const Spacer(),
              Text(
                _formatSeconds(_liveRecordSec),
                style: AppTheme.mono(fontSize: 11, color: AppColors.darkTextMuted),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Inline Audio Player Card
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: isDark ? Colors.black.withOpacity(0.35) : Colors.black.withOpacity(0.04),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.emeraldPrimary.withOpacity(0.35)),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        _isPlayingPreview ? Icons.pause_circle_filled : Icons.play_circle_fill,
                        color: AppColors.emeraldPrimary,
                        size: 32,
                      ),
                      onPressed: _togglePreviewPlay,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _selectedAudioName ?? 'live_recording.m4a',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.plusJakartaSans(fontSize: 12.5, fontWeight: FontWeight.w700),
                          ),
                          Text(
                            '${_formatDuration(_previewPosition)} / ${_formatDuration(_previewDuration)}',
                            style: AppTheme.mono(fontSize: 10.5, color: isDark ? AppColors.darkTextMuted : AppColors.lightTextMuted),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 20, color: Colors.redAccent),
                      onPressed: _discardLiveRecording,
                      tooltip: 'Discard & Record Again',
                    ),
                  ],
                ),
                if (_previewDuration.inMilliseconds > 0)
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                      trackHeight: 3,
                    ),
                    child: Slider(
                      value: _previewPosition.inMilliseconds.clamp(0, _previewDuration.inMilliseconds).toDouble(),
                      max: _previewDuration.inMilliseconds.toDouble(),
                      activeColor: AppColors.emeraldPrimary,
                      inactiveColor: isDark ? Colors.white12 : Colors.black12,
                      onChanged: (val) {
                        _previewPlayer.seek(Duration(milliseconds: val.toInt()));
                      },
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: _startLiveRecording,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Record New Take'),
              ),
            ],
          ),
        ],
      );
    } else {
      // State 3: Ready to start recording
      return Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: AppColors.emeraldPrimary,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'LIVE MICROPHONE READY',
                style: AppTheme.mono(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  color: AppColors.emeraldPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          InkWell(
            onTap: _startLiveRecording,
            borderRadius: BorderRadius.circular(50),
            child: Container(
              width: 68,
              height: 68,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.redAccent.withOpacity(0.12),
                border: Border.all(color: Colors.redAccent.withOpacity(0.4), width: 2),
                boxShadow: [
                  BoxShadow(
                    color: Colors.redAccent.withOpacity(0.2),
                    blurRadius: 16,
                  ),
                ],
              ),
              child: const Icon(Icons.mic, color: Colors.redAccent, size: 32),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Tap mic to record audio live',
            style: GoogleFonts.plusJakartaSans(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Recorded audio will be preprocessed and transcribed with full speaker tracking.',
            textAlign: TextAlign.center,
            style: GoogleFonts.plusJakartaSans(
              fontSize: 11,
              color: isDark ? AppColors.darkTextMuted : AppColors.lightTextMuted,
            ),
          ),
        ],
      );
    }
  }

  // ================= KPI CARD HELPER =================
  Widget _buildKpiCard({
    required String title,
    required String value,
    required String subtext,
    required Color accentColor,
    required IconData icon,
    required bool isDark,
    String? pill,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkBgPanel : AppColors.lightBgPanel,
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: accentColor, width: 3.5)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 6,
          ),
        ],
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
                  style: AppTheme.mono(fontSize: 9.5, fontWeight: FontWeight.w700, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
                ),
              ),
              Icon(icon, size: 15, color: accentColor),
            ],
          ),
          Text(
            value,
            style: AppTheme.mono(fontSize: 18, fontWeight: FontWeight.w800, color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  subtext,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.plusJakartaSans(fontSize: 9.5, color: isDark ? AppColors.darkTextMuted : AppColors.lightTextMuted),
                ),
              ),
              if (pill != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: accentColor.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    pill,
                    style: AppTheme.mono(fontSize: 8, fontWeight: FontWeight.w800, color: accentColor),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  // ================= CHARTS =================
  Widget _buildTimelineChart(bool isDark) {
    final timeline = _dashboardStats?.timeline ?? [];
    if (timeline.isEmpty) {
      return Center(
        child: Text('No timeline points recorded', style: AppTheme.mono(fontSize: 11, color: isDark ? AppColors.darkTextMuted : AppColors.lightTextMuted)),
      );
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
                  return Text(timeline[idx].label, style: AppTheme.mono(fontSize: 8.5));
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
    final evo = _dashboardStats?.userEvolution ?? [];
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
