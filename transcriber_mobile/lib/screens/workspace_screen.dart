import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../providers/transcription_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../widgets/audio_player_bar.dart';
import '../widgets/copilot_sheet.dart';
import '../widgets/speaker_naming_modal.dart';

class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({super.key});

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen> {
  final ScrollController _scrollController = ScrollController();
  int? _lastScrolledIndex;
  final Map<int, GlobalKey> _itemKeys = {};

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _openCopilot() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const CopilotSheet(),
    );
  }

  void _openSpeakerNaming() {
    showDialog(
      context: context,
      builder: (_) => const SpeakerNamingModal(),
    );
  }

  void _exportText(bool isRaw) {
    final provider = context.read<TranscriptionProvider>();
    final text = isRaw ? provider.rawText : provider.portions.map((p) => '[${p.time}] ${p.speaker}: ${p.content}').join('\n\n');
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(isRaw ? 'Raw transcript copied to clipboard!' : 'Formatted transcript copied to clipboard!'),
        backgroundColor: AppColors.emeraldPrimary,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final provider = context.watch<TranscriptionProvider>();
    final current = provider.currentTranscription;

    final activePlayingIndex = provider.activePlayingIndex;
    if (activePlayingIndex >= 0 && activePlayingIndex != _lastScrolledIndex) {
      _lastScrolledIndex = activePlayingIndex;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final key = _itemKeys[activePlayingIndex];
        if (key?.currentContext != null) {
          Scrollable.ensureVisible(
            key!.currentContext!,
            alignment: 0.5,
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeInOut,
          );
        }
      });
    }

    if (provider.isLoadingDetails) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.emeraldPrimary),
      );
    }

    if (current == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.article_outlined, size: 54, color: isDark ? AppColors.darkTextMuted : AppColors.lightTextMuted),
            const SizedBox(height: 14),
            Text(
              'No Active Transcription',
              style: GoogleFonts.plusJakartaSans(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Select a transcription from the History tab or transcribe a new file.',
              style: GoogleFonts.plusJakartaSans(
                fontSize: 12.5,
                color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        // Workspace Top Info Bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: isDark ? AppColors.darkBgSidebar : AppColors.lightBgSidebar,
            border: Border(
              bottom: BorderSide(
                color: isDark ? AppColors.darkBorderPanel : AppColors.lightBorderPanel,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      current.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),

                  // Name Speakers button
                  OutlinedButton.icon(
                    onPressed: _openSpeakerNaming,
                    icon: const Icon(Icons.people_alt_outlined, size: 14),
                    label: const Text('Name Speakers'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      side: BorderSide(color: isDark ? Colors.white24 : Colors.black26),
                      textStyle: GoogleFonts.plusJakartaSans(fontSize: 11, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 6),

                  // AI Assistant button
                  IconButton(
                    onPressed: _openCopilot,
                    tooltip: 'AI Assistant',
                    icon: const Icon(Icons.auto_awesome, color: AppColors.emeraldPrimary, size: 20),
                  ),

                  // Export Menu
                  PopupMenuButton<String>(
                    tooltip: 'Export',
                    icon: Icon(Icons.download_rounded, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary, size: 20),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    color: isDark ? AppColors.darkBgPanel : AppColors.lightBgPanel,
                    onSelected: (val) {
                      if (val == 'formatted') _exportText(false);
                      if (val == 'raw') _exportText(true);
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'formatted',
                        child: Row(
                          children: [
                            const Icon(Icons.description_outlined, size: 16, color: AppColors.emeraldLight),
                            const SizedBox(width: 8),
                            Text('Copy Formatted Text', style: GoogleFonts.plusJakartaSans(fontSize: 12.5)),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'raw',
                        child: Row(
                          children: [
                            const Icon(Icons.notes_outlined, size: 16, color: Color(0xFF38BDF8)),
                            const SizedBox(width: 8),
                            Text('Copy Raw Text', style: GoogleFonts.plusJakartaSans(fontSize: 12.5)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.emeraldPrimary.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      current.language,
                      style: AppTheme.mono(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.emeraldLight),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    current.createdAt,
                    style: AppTheme.mono(fontSize: 10.5, color: isDark ? AppColors.darkTextMuted : AppColors.lightTextMuted),
                  ),
                  const Spacer(),
                  if (provider.isSaving)
                    Row(
                      children: [
                        const SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5, color: AppColors.emeraldPrimary)),
                        const SizedBox(width: 6),
                        Text('Saving...', style: AppTheme.mono(fontSize: 10, color: AppColors.emeraldLight)),
                      ],
                    ),
                ],
              ),
            ],
          ),
        ),

        // Sticky Audio Player Bar
        const AudioPlayerBar(),

        // Portions Toolbar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: isDark ? AppColors.darkBgMain : AppColors.lightBgMain,
            border: Border(
              bottom: BorderSide(
                color: isDark ? AppColors.darkBorderPanel : AppColors.lightBorderPanel,
              ),
            ),
          ),
          child: Row(
            children: [
              // 3 View Modes: Auto-Transcript (Default), Portions, Raw Text
              Container(
                decoration: BoxDecoration(
                  color: isDark ? Colors.white.withOpacity(0.04) : Colors.black.withOpacity(0.04),
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.all(2),
                child: Row(
                  children: [
                    _buildViewModeBtn(EditorViewMode.auto, 'Auto-Transcript'),
                    _buildViewModeBtn(EditorViewMode.portions, 'Portions'),
                    _buildViewModeBtn(EditorViewMode.raw, 'Raw Text'),
                  ],
                ),
              ),

              const Spacer(),

              // Merge Selected Button
              if (provider.selectedIndices.length >= 2)
                ElevatedButton.icon(
                  onPressed: provider.mergeSelected,
                  icon: const Icon(Icons.merge_type_rounded, size: 14),
                  label: Text('Merge Selected (${provider.selectedIndices.length})'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.emeraldPrimary.withOpacity(0.18),
                    foregroundColor: AppColors.emeraldLight,
                    side: const BorderSide(color: AppColors.emeraldPrimary),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    textStyle: GoogleFonts.plusJakartaSans(fontSize: 11, fontWeight: FontWeight.w700),
                  ),
                ),
            ],
          ),
        ),

        // Body Content Views
        Expanded(
          child: _buildCurrentViewBody(isDark, provider),
        ),
      ],
    );
  }

  Widget _buildViewModeBtn(EditorViewMode mode, String label) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final provider = context.watch<TranscriptionProvider>();
    final isSelected = provider.viewMode == mode;

    return InkWell(
      onTap: () {
        _itemKeys.clear();
        _lastScrolledIndex = null;
        provider.setViewMode(mode);
      },
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? (isDark ? AppColors.darkBgPanel : AppColors.lightBgPanel)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          boxShadow: isSelected ? [const BoxShadow(color: Colors.black26, blurRadius: 4)] : null,
        ),
        child: Text(
          label,
          style: GoogleFonts.plusJakartaSans(
            fontSize: 11.5,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
            color: isSelected
                ? AppColors.emeraldPrimary
                : (isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
          ),
        ),
      ),
    );
  }

  Widget _buildCurrentViewBody(bool isDark, TranscriptionProvider provider) {
    if (provider.viewMode == EditorViewMode.raw) {
      // Raw Textarea View
      return Padding(
        padding: const EdgeInsets.all(16),
        child: TextField(
          controller: TextEditingController(text: provider.rawText),
          maxLines: null,
          expands: true,
          style: AppTheme.mono(
            fontSize: 13,
            color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
          ),
          decoration: InputDecoration(
            hintText: 'Raw transcription text...',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      );
    }

    final portions = provider.viewMode == EditorViewMode.auto
        ? provider.autoTranscript
        : provider.portions;

    if (portions.isEmpty) {
      return Center(
        child: Text(
          'No dialogue portions available.',
          style: GoogleFonts.plusJakartaSans(
            fontSize: 13,
            color: isDark ? AppColors.darkTextMuted : AppColors.lightTextMuted,
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(16),
      itemCount: portions.length,
      itemBuilder: (context, index) {
        final portion = portions[index];
        final isSelected = provider.selectedIndices.contains(index);
        final isPlayingActive = provider.activePlayingIndex == index;
        final style = AppColors.getSpeakerStyle(portion.speaker);
        final itemKey = _itemKeys.putIfAbsent(index, () => GlobalKey());

        return Container(
          key: itemKey,
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: isSelected
                ? AppColors.emeraldPrimary.withOpacity(0.08)
                : (isDark ? AppColors.darkBgPanel : AppColors.lightBgPanel),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isPlayingActive
                  ? AppColors.emeraldPrimary
                  : (isSelected
                      ? AppColors.emeraldPrimary
                      : (isDark ? AppColors.darkBorderPanel : AppColors.lightBorderPanel)),
              width: isPlayingActive ? 1.8 : 1.0,
            ),
            boxShadow: isPlayingActive
                ? [
                    BoxShadow(
                      color: AppColors.emeraldGlow,
                      blurRadius: 14,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Portion Card Header
              Row(
                children: [
                  // Select Checkbox (Portions mode only)
                  if (provider.viewMode == EditorViewMode.portions) ...[
                    SizedBox(
                      width: 22,
                      height: 22,
                      child: Checkbox(
                        value: isSelected,
                        activeColor: AppColors.emeraldPrimary,
                        checkColor: const Color(0xFF030712),
                        onChanged: (_) => provider.togglePortionSelection(index),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],

                  // Portion index number
                  Text(
                    '#${index + 1}',
                    style: AppTheme.mono(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: isDark ? AppColors.darkTextMuted : AppColors.lightTextMuted,
                    ),
                  ),
                  const SizedBox(width: 8),

                  // Play Button with clickable timestamp
                  InkWell(
                    onTap: () => provider.playAtTimestamp(portion.time, index),
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: isDark ? Colors.white.withOpacity(0.05) : Colors.black.withOpacity(0.05),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: isDark ? AppColors.darkBorderPanel : AppColors.lightBorderPanel,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.play_arrow_rounded, size: 12, color: AppColors.emeraldLight),
                          const SizedBox(width: 4),
                          Text(
                            portion.time,
                            style: AppTheme.mono(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),

                  // Speaker Tag Badge
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: style.bg,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: style.border),
                    ),
                    child: Text(
                      portion.speaker,
                      style: AppTheme.mono(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: style.text,
                      ),
                    ),
                  ),

                  const Spacer(),

                  // Actions menu
                  PopupMenuButton<String>(
                    icon: Icon(Icons.more_horiz, size: 18, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    color: isDark ? AppColors.darkBgPanel : AppColors.lightBgPanel,
                    onSelected: (val) {
                      if (val == 'copy') {
                        Clipboard.setData(ClipboardData(text: portion.content));
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Portion text copied!')));
                      } else if (val == 'merge_next') {
                        provider.mergeNext(index);
                      } else if (val == 'delete') {
                        provider.deletePortion(index);
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'copy',
                        child: Text('Copy Text', style: GoogleFonts.plusJakartaSans(fontSize: 12.5)),
                      ),
                      if (index < portions.length - 1)
                        PopupMenuItem(
                          value: 'merge_next',
                          child: Text('Merge Next', style: GoogleFonts.plusJakartaSans(fontSize: 12.5)),
                        ),
                      PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete Portion', style: GoogleFonts.plusJakartaSans(fontSize: 12.5, color: Colors.redAccent)),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // Content text area
              TextFormField(
                initialValue: portion.content,
                maxLines: null,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 13.5,
                  height: 1.5,
                  color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                ),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                ),
                onChanged: (val) {
                  provider.updatePortionContent(index, val);
                },
              ),
            ],
          ),
        );
      },
    );
  }
}
