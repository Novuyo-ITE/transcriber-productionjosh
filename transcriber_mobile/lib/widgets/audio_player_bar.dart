import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/transcription_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

class AudioPlayerBar extends StatelessWidget {
  const AudioPlayerBar({super.key});

  String _formatDuration(Duration d) {
    final mins = d.inMinutes;
    final secs = d.inSeconds % 60;
    return '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final provider = context.watch<TranscriptionProvider>();

    final pos = provider.audioPosition;
    final dur = provider.audioDuration;
    final posSec = pos.inSeconds.toDouble();
    final durSec = dur.inSeconds > 0 ? dur.inSeconds.toDouble() : 1.0;
    final currentSliderVal = posSec.clamp(0.0, durSec);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkBgPanelAlpha : AppColors.lightBgPanel,
        border: Border(
          bottom: BorderSide(
            color: isDark ? AppColors.darkBorderPanel : AppColors.lightBorderPanel,
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              // Play / Pause Button
              InkWell(
                onTap: provider.togglePlayPause,
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: AppColors.emeraldPrimary,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.emeraldGlow,
                        blurRadius: 8,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                  child: Icon(
                    provider.isPlaying ? Icons.pause : Icons.play_arrow,
                    color: const Color(0xFF030712),
                    size: 20,
                  ),
                ),
              ),
              const SizedBox(width: 8),

              // -5s button
              IconButton(
                icon: const Icon(Icons.replay_5, size: 20),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () => provider.seekRelative(-5),
                tooltip: '-5 seconds',
                color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
              ),
              const SizedBox(width: 4),

              // +5s button
              IconButton(
                icon: const Icon(Icons.forward_5, size: 20),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () => provider.seekRelative(5),
                tooltip: '+5 seconds',
                color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
              ),
              const SizedBox(width: 8),

              // Position / Duration Label
              Text(
                '${_formatDuration(pos)} / ${_formatDuration(dur)}',
                style: AppTheme.mono(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                ),
              ),

              const Spacer(),

              // Speed selector button
              PopupMenuButton<double>(
                initialValue: provider.playbackSpeed,
                onSelected: provider.setSpeed,
                tooltip: 'Playback Speed',
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                color: isDark ? AppColors.darkBgPanel : AppColors.lightBgPanel,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: isDark ? Colors.white.withOpacity(0.05) : Colors.black.withOpacity(0.04),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: isDark ? AppColors.darkBorderPanel : AppColors.lightBorderPanel,
                    ),
                  ),
                  child: Text(
                    '${provider.playbackSpeed}x',
                    style: AppTheme.mono(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppColors.emeraldPrimary,
                    ),
                  ),
                ),
                itemBuilder: (context) => [0.75, 1.0, 1.25, 1.5, 2.0].map((s) {
                  return PopupMenuItem<double>(
                    value: s,
                    height: 34,
                    child: Text(
                      '${s}x',
                      style: AppTheme.mono(
                        fontSize: 12,
                        fontWeight: s == provider.playbackSpeed ? FontWeight.w800 : FontWeight.w500,
                        color: s == provider.playbackSpeed
                            ? AppColors.emeraldPrimary
                            : (isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
          const SizedBox(height: 4),

          // Slider
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              activeTrackColor: AppColors.emeraldPrimary,
              inactiveTrackColor: isDark ? Colors.white.withOpacity(0.1) : Colors.black.withOpacity(0.1),
              thumbColor: AppColors.emeraldLight,
              overlayColor: AppColors.emeraldGlow,
            ),
            child: Slider(
              value: currentSliderVal,
              min: 0.0,
              max: durSec,
              onChanged: (val) {
                provider.seekAudio(Duration(seconds: val.toInt()));
              },
            ),
          ),
        ],
      ),
    );
  }
}
