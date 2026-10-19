import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../providers/transcription_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

class HistoryScreen extends StatefulWidget {
  final VoidCallback onSelectTranscription;

  const HistoryScreen({super.key, required this.onSelectTranscription});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _openRenameDialog(String tid, String currentName) async {
    final ctrl = TextEditingController(text: currentName);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          'Rename Transcription',
          style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'New Title'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (newName != null && newName.isNotEmpty && mounted) {
      await context.read<TranscriptionProvider>().renameCurrentTranscription(newName);
    }
  }

  Future<void> _confirmDelete(String tid, String title) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          'Delete Transcription',
          style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700),
        ),
        content: Text(
          'Are you sure you want to permanently delete "$title"? This removes the audio record and transcription.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await context.read<TranscriptionProvider>().deleteCurrentTranscription();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final transcriptionProv = context.watch<TranscriptionProvider>();
    final items = transcriptionProv.history;

    return RefreshIndicator(
      color: AppColors.emeraldPrimary,
      backgroundColor: isDark ? AppColors.darkBgPanel : AppColors.lightBgPanel,
      onRefresh: () => transcriptionProv.fetchHistory(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header Strip
          Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
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
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            gradient: AppColors.brandGradient,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          alignment: Alignment.center,
                          child: const Icon(
                            Icons.history_rounded,
                            size: 18,
                            color: Color(0xFF030712),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'Transcriptions',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                          ),
                        ),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3.5),
                      decoration: BoxDecoration(
                        color: AppColors.emeraldPrimary.withOpacity(0.14),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: AppColors.emeraldPrimary.withOpacity(0.35)),
                      ),
                      child: Text(
                        '${items.length} RECORDED',
                        style: AppTheme.mono(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: AppColors.emeraldLight,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // Search Bar
                TextField(
                  controller: _searchCtrl,
                  onChanged: (q) => transcriptionProv.setSearchQuery(q),
                  style: GoogleFonts.plusJakartaSans(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Search by title, speaker or date...',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    suffixIcon: _searchCtrl.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.close, size: 16),
                            onPressed: () {
                              _searchCtrl.clear();
                              transcriptionProv.setSearchQuery('');
                            },
                          )
                        : null,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                ),
              ],
            ),
          ),

          // Body List
          Expanded(
            child: transcriptionProv.isLoadingHistory
                ? const Center(
                    child: CircularProgressIndicator(
                      color: AppColors.emeraldPrimary,
                      strokeWidth: 2.5,
                    ),
                  )
                : items.isEmpty
                    ? Center(
                        child: SingleChildScrollView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.queue_music_outlined,
                                size: 54,
                                color: isDark ? AppColors.darkTextMuted : AppColors.lightTextMuted,
                              ),
                              const SizedBox(height: 14),
                              Text(
                                _searchCtrl.text.isNotEmpty
                                    ? 'No Matching Transcriptions'
                                    : 'No Transcriptions Yet',
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                _searchCtrl.text.isNotEmpty
                                    ? 'Try a different search keyword.'
                                    : 'Upload an audio file or start live recording to transcribe.',
                                textAlign: TextAlign.center,
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 12,
                                  color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    : ListView.builder(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        itemCount: items.length,
                        itemBuilder: (context, idx) {
                          final item = items[idx];
                          final isSelected = transcriptionProv.currentTranscription?.id == item.id;

                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            decoration: BoxDecoration(
                              color: isDark ? AppColors.darkBgPanel : AppColors.lightBgPanel,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isSelected
                                    ? AppColors.emeraldPrimary.withOpacity(0.6)
                                    : (isDark ? AppColors.darkBorderPanel : AppColors.lightBorderPanel),
                                width: isSelected ? 1.5 : 1.0,
                              ),
                            ),
                            child: Material(
                              color: Colors.transparent,
                              borderRadius: BorderRadius.circular(12),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onTap: () {
                                  transcriptionProv.loadTranscription(item.id);
                                  widget.onSelectTranscription();
                                },
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                  child: Row(
                                    children: [
                                      // Type Icon
                                      Container(
                                        width: 38,
                                        height: 38,
                                        decoration: BoxDecoration(
                                          color: item.isStreamRecording
                                              ? const Color(0xFF38BDF8).withOpacity(0.15)
                                              : (item.isLiveRecording
                                                  ? Colors.amber.withOpacity(0.15)
                                                  : AppColors.emeraldPrimary.withOpacity(0.15)),
                                          borderRadius: BorderRadius.circular(9),
                                        ),
                                        alignment: Alignment.center,
                                        child: Icon(
                                          item.isStreamRecording
                                              ? Icons.stream_rounded
                                              : (item.isLiveRecording
                                                  ? Icons.graphic_eq_rounded
                                                  : Icons.article_outlined),
                                          size: 20,
                                          color: item.isStreamRecording
                                              ? const Color(0xFF38BDF8)
                                              : (item.isLiveRecording
                                                  ? Colors.amber
                                                  : AppColors.emeraldPrimary),
                                        ),
                                      ),
                                      const SizedBox(width: 12),

                                      // Title & metadata
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              item.displayTitle,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: GoogleFonts.plusJakartaSans(
                                                fontSize: 13.5,
                                                fontWeight: FontWeight.w700,
                                                color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                                              ),
                                            ),
                                            const SizedBox(height: 3),
                                            Row(
                                              children: [
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                                  decoration: BoxDecoration(
                                                    color: isDark ? Colors.white10 : Colors.black12,
                                                    borderRadius: BorderRadius.circular(4),
                                                  ),
                                                  child: Text(
                                                    item.language.toUpperCase(),
                                                    style: AppTheme.mono(
                                                      fontSize: 8.5,
                                                      fontWeight: FontWeight.w700,
                                                      color: AppColors.emeraldLight,
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 6),
                                                Text(
                                                  item.createdAt,
                                                  style: AppTheme.mono(
                                                    fontSize: 10,
                                                    color: isDark ? AppColors.darkTextMuted : AppColors.lightTextMuted,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),

                                      // Actions (Rename, Delete)
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            tooltip: 'Rename',
                                            icon: const Icon(Icons.edit_outlined, size: 16),
                                            color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                                            onPressed: () => _openRenameDialog(item.id, item.originalName),
                                          ),
                                          IconButton(
                                            tooltip: 'Delete',
                                            icon: const Icon(Icons.delete_outline, size: 16, color: Colors.redAccent),
                                            onPressed: () => _confirmDelete(item.id, item.displayTitle),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
