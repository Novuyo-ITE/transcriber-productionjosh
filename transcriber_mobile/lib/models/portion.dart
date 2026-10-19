class Portion {
  String time;
  String speaker;
  String content;
  bool isSelected;

  Portion({
    required this.time,
    required this.speaker,
    required this.content,
    this.isSelected = false,
  });

  Portion copyWith({
    String? time,
    String? speaker,
    String? content,
    bool? isSelected,
  }) {
    return Portion(
      time: time ?? this.time,
      speaker: speaker ?? this.speaker,
      content: content ?? this.content,
      isSelected: isSelected ?? this.isSelected,
    );
  }

  Map<String, dynamic> toJson() => {
    'time': time,
    'speaker': speaker,
    'content': content,
  };

  factory Portion.fromJson(Map<String, dynamic> json) => Portion(
    time: json['time'] ?? '00:00',
    speaker: json['speaker'] ?? 'Speaker 1',
    content: json['content'] ?? '',
  );

  /// Converts timestamp string like "01:23" or "01:12:45" to total seconds
  int get seconds {
    final cleaned = time.replaceAll(RegExp(r'[\[\]]'), '').trim();
    final parts = cleaned.split(':').map((e) => int.tryParse(e) ?? 0).toList();
    if (parts.length == 3) {
      return parts[0] * 3600 + parts[1] * 60 + parts[2];
    } else if (parts.length == 2) {
      return parts[0] * 60 + parts[1];
    } else if (parts.length == 1) {
      return parts[0];
    }
    return 0;
  }

  /// Parses raw formatted transcription string into a list of structured portions
  /// exactly mimicking the desktop app logic
  static List<Portion> parseFromText(String? sourceText) {
    if (sourceText == null || sourceText.trim().isEmpty) return [];

    final text = sourceText.replaceAll('\r\n', '\n').trim();
    final lines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    final portions = <Portion>[];

    final speakerLineRegex = RegExp(r'^(?:\[?(\d{1,4}:\d{2}(?::\d{2})?)\]?\s+)?([^:\n]+?)\s*:\s*(.*)$');
    final timestampOnlyRegex = RegExp(r'^\[?(\d{1,4}:\d{2}(?::\d{2})?)\]?\s+(.*)$');

    bool foundStructuredLines = false;

    for (final line in lines) {
      final cleanLine = line.replaceAll('**', '').trim();

      // 1. Try matching [MM:SS] Speaker X: Text
      final spkMatch = speakerLineRegex.firstMatch(cleanLine);
      if (spkMatch != null) {
        final timeStr = spkMatch.group(1) ?? '00:00';
        final speakerStr = spkMatch.group(2)!.trim();
        final contentStr = stripPrefixMetadata(spkMatch.group(3)!.trim());

        final lowerSpk = speakerStr.toLowerCase();
        final isLegitSpeaker = speakerStr.isNotEmpty &&
            speakerStr.length < 32 &&
            lowerSpk != 'transcript' &&
            lowerSpk != 'raw transcript' &&
            (lowerSpk.contains('speaker') ||
                lowerSpk.contains('person') ||
                lowerSpk.contains('participant') ||
                lowerSpk.contains('host') ||
                lowerSpk.contains('guest') ||
                lowerSpk.contains('narrator') ||
                RegExp(r'^[a-z0-9\s_-]+$', caseSensitive: false).hasMatch(speakerStr));

        if (isLegitSpeaker) {
          foundStructuredLines = true;
          portions.add(Portion(time: timeStr, speaker: speakerStr, content: contentStr));
          continue;
        } else if (lowerSpk == 'transcript' || lowerSpk == 'raw transcript') {
          foundStructuredLines = true;
          portions.add(Portion(time: timeStr, speaker: 'Speaker 1', content: contentStr));
          continue;
        }
      }

      // 2. Try matching [MM:SS] Raw Text Line
      final tsMatch = timestampOnlyRegex.firstMatch(cleanLine);
      if (tsMatch != null) {
        final timeStr = tsMatch.group(1) ?? '00:00';
        final contentStr = stripPrefixMetadata(tsMatch.group(2)!.trim());
        foundStructuredLines = true;
        portions.add(Portion(time: timeStr, speaker: 'Speaker 1', content: contentStr));
        continue;
      }

      if (portions.isNotEmpty && foundStructuredLines) {
        final addText = stripPrefixMetadata(cleanLine);
        if (addText.isNotEmpty) {
          portions.last.content += '\n$addText';
        }
      }
    }

    if (!foundStructuredLines || portions.isEmpty) {
      return [
        Portion(
          time: '00:00',
          speaker: 'Speaker 1',
          content: stripPrefixMetadata(text),
        )
      ];
    }

    return portions;
  }

  /// Auto-merges consecutive portions that share the same speaker into concise turns
  static List<Portion> buildAutoTranscript(List<Portion> portions) {
    if (portions.isEmpty) return [];

    final result = <Portion>[];
    Portion? current;

    for (final p in portions) {
      if (current == null) {
        current = p.copyWith();
      } else if (current.speaker.toLowerCase().trim() == p.speaker.toLowerCase().trim()) {
        current.content += '\n${p.content}';
      } else {
        result.add(current);
        current = p.copyWith();
      }
    }

    if (current != null) {
      result.add(current);
    }

    return result;
  }

  static String stripPrefixMetadata(String text) {
    String cleaned = text.trim();
    while (true) {
      final prev = cleaned;
      cleaned = cleaned.replaceFirst(RegExp(r'^\[\d{1,4}:\d{2}(?::\d{2})?\]\s*'), '');
      cleaned = cleaned.replaceFirst(RegExp(r'^(?:Speaker\s*\d+|Person\s*\d+|Transcript|Raw Transcript|Guest|Host|[a-zA-Z0-9_-]+)\s*:\s*'), '');
      cleaned = cleaned.replaceFirst(RegExp(r'^\*\*(?:Speaker\s*\d+|Person\s*\d+|Transcript|Raw Transcript|Guest|Host|[a-zA-Z0-9_-]+)\*\*:\s*'), '');
      if (cleaned == prev) break;
    }
    return cleaned.trim();
  }
}
