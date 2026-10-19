import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../providers/transcription_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

class CopilotSheet extends StatefulWidget {
  const CopilotSheet({super.key});

  @override
  State<CopilotSheet> createState() => _CopilotSheetState();
}

class _CopilotSheetState extends State<CopilotSheet> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _send(String text) {
    final clean = text.trim();
    if (clean.isEmpty) return;
    _inputController.clear();
    final provider = context.read<TranscriptionProvider>();
    provider.sendCopilotMessage(clean);

    Future.delayed(const Duration(milliseconds: 200), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final provider = context.watch<TranscriptionProvider>();

    return Container(
      height: MediaQuery.of(context).size.height * 0.82,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0E131D) : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border.all(color: AppColors.emeraldPrimary.withOpacity(0.35)),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 25, spreadRadius: 5),
        ],
      ),
      child: Column(
        children: [
          // Drag handle
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: isDark ? Colors.white24 : Colors.black26,
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: AppColors.emeraldPrimary.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.emeraldPrimary.withOpacity(0.4)),
                  ),
                  child: const Icon(Icons.auto_awesome, color: AppColors.emeraldPrimary, size: 18),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'AI Assistant',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                        ),
                      ),
                      Text(
                        'Intelligent Dialogue Analysis',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: AppColors.emeraldPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                  color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // Quick Prompts Row
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                _buildQuickPill('📊 Summarize', 'Summarize the key points and executive summary of this transcription'),
                const SizedBox(width: 8),
                _buildQuickPill('📝 Action Items', 'Extract all key takeaways, decisions, and action items from this transcript'),
                const SizedBox(width: 8),
                _buildQuickPill('👥 Speaker Breakdown', 'Provide a breakdown of what each speaker discussed in this conversation'),
                const SizedBox(width: 8),
                _buildQuickPill('💡 Key Topics', 'What are the main topics and questions discussed in this audio?'),
              ],
            ),
          ),
          const Divider(height: 1),

          // Chat Messages
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              itemCount: provider.chatMessages.length,
              itemBuilder: (context, index) {
                final msg = provider.chatMessages[index];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: msg.isAi ? MainAxisAlignment.start : MainAxisAlignment.end,
                    children: [
                      if (msg.isAi) ...[
                        Container(
                          width: 28,
                          height: 28,
                          margin: const EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(
                            color: AppColors.emeraldPrimary.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: AppColors.emeraldPrimary.withOpacity(0.3)),
                          ),
                          alignment: Alignment.center,
                          child: const Text('✨', style: TextStyle(fontSize: 13)),
                        ),
                      ],
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: msg.isAi
                                ? (isDark ? const Color(0xFF141923) : const Color(0xFFF1F5F9))
                                : AppColors.emeraldPrimary,
                            borderRadius: BorderRadius.circular(12),
                            border: msg.isAi
                                ? Border.all(
                                    color: isDark ? AppColors.darkBorderPanel : AppColors.lightBorderPanel,
                                  )
                                : null,
                          ),
                          child: Text(
                            msg.text,
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 13,
                              height: 1.45,
                              color: msg.isAi
                                  ? (isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary)
                                  : const Color(0xFF030712),
                              fontWeight: msg.isAi ? FontWeight.w400 : FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),

          if (provider.isCopilotLoading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.emeraldPrimary),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'AI Assistant is thinking...',
                    style: AppTheme.mono(fontSize: 11, color: AppColors.emeraldLight),
                  ),
                ],
              ),
            ),

          // Input field
          Container(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 18),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF0A0E17) : const Color(0xFFF8FAFC),
              border: Border(
                top: BorderSide(
                  color: isDark ? AppColors.darkBorderPanel : AppColors.lightBorderPanel,
                ),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _inputController,
                    minLines: 1,
                    maxLines: 4,
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 13,
                      color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Ask AI Assistant about this transcript...',
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide(color: isDark ? AppColors.darkBorderInput : AppColors.lightBorderInput),
                      ),
                    ),
                    onSubmitted: _send,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: () => _send(_inputController.text),
                  icon: const Icon(Icons.send_rounded, color: AppColors.emeraldPrimary, size: 20),
                  tooltip: 'Send prompt',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickPill(String title, String prompt) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return ActionChip(
      label: Text(
        title,
        style: GoogleFonts.plusJakartaSans(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
        ),
      ),
      backgroundColor: isDark ? const Color(0xFF141A26) : const Color(0xFFE2E8F0),
      side: BorderSide(
        color: isDark ? Colors.white.withOpacity(0.08) : Colors.black.withOpacity(0.08),
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      onPressed: () => _send(prompt),
    );
  }
}
