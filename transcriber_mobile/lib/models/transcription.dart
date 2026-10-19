class TranscriptionItem {
  final String id;
  final String originalName;
  final String language;
  final String createdAt;
  final String? audioPath;
  final String? transcription;
  final String? formatted;

  TranscriptionItem({
    required this.id,
    required this.originalName,
    required this.language,
    required this.createdAt,
    this.audioPath,
    this.transcription,
    this.formatted,
  });

  factory TranscriptionItem.fromJson(Map<String, dynamic> json) {
    return TranscriptionItem(
      id: json['id']?.toString() ?? '',
      originalName: json['original_name']?.toString() ?? 'Untitled Transcription',
      language: json['language']?.toString() ?? 'English',
      createdAt: json['created_at']?.toString() ?? '',
      audioPath: json['audio_path']?.toString(),
      transcription: json['transcription']?.toString(),
      formatted: json['formatted']?.toString(),
    );
  }

  bool get isLiveRecording => originalName.toLowerCase().contains('live_recording');
  bool get isStreamRecording => originalName.toLowerCase().contains('stream');

  String get displayTitle {
    if (isLiveRecording) {
      return 'Waveform • $createdAt';
    }
    if (isStreamRecording) {
      return 'Stream • $createdAt';
    }
    return originalName;
  }
}
