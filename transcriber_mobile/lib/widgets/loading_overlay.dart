import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/progress.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

class LoadingOverlay extends StatefulWidget {
  final ProgressUpdate progress;
  final VoidCallback onCancel;

  const LoadingOverlay({
    super.key,
    required this.progress,
    required this.onCancel,
  });

  @override
  State<LoadingOverlay> createState() => _LoadingOverlayState();
}

class _LoadingOverlayState extends State<LoadingOverlay> {
  late Stopwatch _stopwatch;
  late Timer _timer;

  @override
  void initState() {
    super.initState();
    _stopwatch = Stopwatch()..start();
    _timer = Timer.periodic(const Duration(milliseconds: 100), (t) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    _stopwatch.stop();
    super.dispose();
  }

  String _formatElapsed() {
    final m = _stopwatch.elapsed.inMinutes;
    final s = _stopwatch.elapsed.inSeconds % 60;
    final ms = (_stopwatch.elapsedMilliseconds % 1000) ~/ 100;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}.$ms';
  }

  int _getActivePhaseIndex(double pct) {
    if (pct < 30.0) return 0;
    if (pct < 65.0) return 1;
    if (pct < 88.0) return 2;
    return 3;
  }

  @override
  Widget build(BuildContext context) {
    final pct = widget.progress.progressPct.clamp(0.0, 100.0);
    final activePhase = _getActivePhaseIndex(pct);

    final phases = [
      {'title': 'Ingest & Prep', 'icon': Icons.cloud_upload_outlined},
      {'title': 'Transcribe', 'icon': Icons.record_voice_over_outlined},
      {'title': 'Diarize', 'icon': Icons.groups_outlined},
      {'title': 'Finalize', 'icon': Icons.task_alt_outlined},
    ];

    return Container(
      color: Colors.black.withOpacity(0.85),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 22),
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 24),
          decoration: BoxDecoration(
            color: const Color(0xFF0D121F),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppColors.emeraldPrimary.withOpacity(0.4)),
            boxShadow: [
              BoxShadow(
                color: AppColors.emeraldGlow,
                blurRadius: 30,
                spreadRadius: 2,
              ),
              const BoxShadow(
                color: Colors.black,
                blurRadius: 40,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Spinning Tech Indicator
              SizedBox(
                width: 44,
                height: 44,
                child: CircularProgressIndicator(
                  strokeWidth: 3.5,
                  valueColor: const AlwaysStoppedAnimation<Color>(AppColors.emeraldPrimary),
                  backgroundColor: AppColors.emeraldPrimary.withOpacity(0.15),
                ),
              ),
              const SizedBox(height: 14),

              // Timer Badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.white.withOpacity(0.1)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.timer_outlined, size: 14, color: AppColors.emeraldLight),
                    const SizedBox(width: 6),
                    Text(
                      _formatElapsed(),
                      style: AppTheme.mono(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.darkTextPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Animated Progress Bar (glides smoothly between updates)
              TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0.0, end: pct / 100.0),
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeOutCubic,
                builder: (context, animatedVal, _) {
                  return Column(
                    children: [
                      Container(
                        height: 7,
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: animatedVal.clamp(0.0, 1.0),
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: AppColors.brandGradientHorizontal,
                              borderRadius: BorderRadius.circular(4),
                              boxShadow: [
                                BoxShadow(
                                  color: AppColors.emeraldGlow,
                                  blurRadius: 8,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),

                      // Percentage & ETA Row
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '${(animatedVal * 100).toStringAsFixed(0)}%',
                            style: AppTheme.mono(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: AppColors.emeraldPrimary,
                            ),
                          ),
                          Text(
                            widget.progress.etaStr.isNotEmpty
                                ? 'Est. Remaining: ${widget.progress.etaStr}'
                                : 'Estimating ETA...',
                            style: AppTheme.mono(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: AppColors.darkTextSecondary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 16),

              // Phase Stepper Cards (Phase 1, 2, 3, 4)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.03),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white.withOpacity(0.06)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: List.generate(phases.length, (idx) {
                    final isDone = idx < activePhase;
                    final isCurrent = idx == activePhase;
                    final phase = phases[idx];

                    final Color iconColor = isDone
                        ? AppColors.emeraldLight
                        : (isCurrent ? AppColors.emeraldPrimary : Colors.white24);
                    final Color textColor = isDone || isCurrent
                        ? AppColors.darkTextPrimary
                        : AppColors.darkTextMuted;

                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isDone
                                ? AppColors.emeraldPrimary.withOpacity(0.2)
                                : (isCurrent
                                    ? AppColors.emeraldPrimary.withOpacity(0.15)
                                    : Colors.white.withOpacity(0.04)),
                            border: Border.all(
                              color: isCurrent
                                  ? AppColors.emeraldPrimary
                                  : (isDone
                                      ? AppColors.emeraldPrimary.withOpacity(0.5)
                                      : Colors.white12),
                            ),
                          ),
                          child: Icon(
                            isDone ? Icons.check : (phase['icon'] as IconData),
                            size: 14,
                            color: iconColor,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          phase['title'] as String,
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 9.5,
                            fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                            color: textColor,
                          ),
                        ),
                      ],
                    );
                  }),
                ),
              ),
              const SizedBox(height: 16),

              // Status Title
              Text(
                widget.progress.statusText,
                textAlign: TextAlign.center,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.darkTextPrimary,
                ),
              ),
              const SizedBox(height: 6),

              // Subtext
              if (widget.progress.subtext.isNotEmpty)
                Text(
                  widget.progress.subtext,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 12,
                    color: AppColors.darkTextMuted,
                  ),
                ),
              const SizedBox(height: 18),

              // Cancel button
              OutlinedButton(
                onPressed: widget.onCancel,
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: Colors.white.withOpacity(0.12)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                ),
                child: Text(
                  'Dismiss Overlay',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.darkTextSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
