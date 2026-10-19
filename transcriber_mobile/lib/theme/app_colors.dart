import 'package:flutter/material.dart';

class AppColors {
  // Radiant Mint-Emerald Brand Design System (matching novuscribe_full_logo.png)
  static const Color emeraldPrimary = Color(0xFF01D9A1);
  static const Color emeraldLight = Color(0xFF10F29B);
  static const Color emeraldDark = Color(0xFF00B383);
  static const Color emeraldGlow = Color(0x4001D9A1);

  static const LinearGradient brandGradient = LinearGradient(
    colors: [Color(0xFF10F29B), Color(0xFF01D9A1), Color(0xFF00A87A)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient brandGradientHorizontal = LinearGradient(
    colors: [Color(0xFF10F29B), Color(0xFF01D9A1), Color(0xFF00A87A)],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );

  // Dark Theme Palette
  static const Color darkBgMain = Color(0xFF030712);
  static const Color darkBgSidebar = Color(0xFF161922);
  static const Color darkBgPanel = Color(0xFF111827);
  static const Color darkBgPanelAlpha = Color(0xBF111827);
  static const Color darkBgInput = Color(0xFF12151C);
  static const Color darkBorderPanel = Color(0x14FFFFFF);
  static const Color darkBorderGlow = Color(0x5901D9A1);
  static const Color darkBorderInput = Color(0x1FFFFFFF);
  
  static const Color darkTextPrimary = Color(0xFFF3F4F6);
  static const Color darkTextSecondary = Color(0xFF9CA3AF);
  static const Color darkTextMuted = Color(0xFF6B7280);

  // Light Theme Palette
  static const Color lightBgMain = Color(0xFFF8FAFC);
  static const Color lightBgSidebar = Color(0xFFFFFFFF);
  static const Color lightBgPanel = Color(0xFFFFFFFF);
  static const Color lightBgInput = Color(0xFFF1F5F9);
  static const Color lightBorderPanel = Color(0x14000000);
  static const Color lightBorderGlow = Color(0x5900B383);
  static const Color lightBorderInput = Color(0x1F000000);
  
  static const Color lightTextPrimary = Color(0xFF0F172A);
  static const Color lightTextSecondary = Color(0xFF475569);
  static const Color lightTextMuted = Color(0xFF94A3B8);

  // Dynamic Speaker Colors
  static const List<SpeakerColorStyle> speakerStyles = [
    SpeakerColorStyle(
      text: Color(0xFF34D399),
      bg: Color(0x1F10B981),
      border: Color(0x4D10B981),
    ), // Speaker 1 - Emerald
    SpeakerColorStyle(
      text: Color(0xFF38BDF8),
      bg: Color(0x1F06B6D4),
      border: Color(0x4D06B6D4),
    ), // Speaker 2 - Cyan
    SpeakerColorStyle(
      text: Color(0xFFC084FC),
      bg: Color(0x1FA855F7),
      border: Color(0x4DA855F7),
    ), // Speaker 3 - Purple
    SpeakerColorStyle(
      text: Color(0xFFFBBF24),
      bg: Color(0x1FF59E0B),
      border: Color(0x4DF59E0B),
    ), // Speaker 4 - Amber
    SpeakerColorStyle(
      text: Color(0xFFFB7185),
      bg: Color(0x1FF43F5E),
      border: Color(0x4DF43F5E),
    ), // Speaker 5 - Rose
    SpeakerColorStyle(
      text: Color(0xFF818CF8),
      bg: Color(0x1F6366F1),
      border: Color(0x4D6366F1),
    ), // Speaker 6 - Indigo
    SpeakerColorStyle(
      text: Color(0xFF2DD4BF),
      bg: Color(0x1F14B8A6),
      border: Color(0x4D14B8A6),
    ), // Speaker 7 - Teal
  ];

  static SpeakerColorStyle getSpeakerStyle(String speakerName) {
    if (speakerName.isEmpty) return speakerStyles[0];
    final match = RegExp(r'\d+').firstMatch(speakerName);
    if (match != null) {
      final num = int.tryParse(match.group(0)!) ?? 1;
      return speakerStyles[(num - 1) % speakerStyles.length];
    }
    // Hash speaker name if not numbered
    final hash = speakerName.codeUnits.fold(0, (prev, elem) => prev + elem);
    return speakerStyles[hash % speakerStyles.length];
  }
}

class SpeakerColorStyle {
  final Color text;
  final Color bg;
  final Color border;

  const SpeakerColorStyle({
    required this.text,
    required this.bg,
    required this.border,
  });
}
