class ProgressUpdate {
  final String stage;
  final String statusText;
  final String subtext;
  final double progressPct;
  final double currentSec;
  final double totalSec;
  final double speedRatio;
  final String etaStr;
  final String? resultId;
  final double? processingTime;
  final String? error;

  ProgressUpdate({
    required this.stage,
    required this.statusText,
    required this.subtext,
    required this.progressPct,
    this.currentSec = 0.0,
    this.totalSec = 0.0,
    this.speedRatio = 0.0,
    this.etaStr = '',
    this.resultId,
    this.processingTime,
    this.error,
  });

  factory ProgressUpdate.fromJson(Map<String, dynamic> json) {
    return ProgressUpdate(
      stage: json['stage']?.toString() ?? 'processing',
      statusText: json['status_text']?.toString() ?? 'Processing media...',
      subtext: json['subtext']?.toString() ?? '',
      progressPct: (json['progress_pct'] as num?)?.toDouble() ?? 5.0,
      currentSec: (json['current_sec'] as num?)?.toDouble() ?? 0.0,
      totalSec: (json['total_sec'] as num?)?.toDouble() ?? 0.0,
      speedRatio: (json['speed_ratio'] as num?)?.toDouble() ?? 0.0,
      etaStr: json['eta_str']?.toString() ?? '',
      resultId: json['result_id']?.toString(),
      processingTime: (json['processing_time'] as num?)?.toDouble(),
      error: json['error']?.toString(),
    );
  }

  bool get isComplete => stage == 'complete' && resultId != null;
  bool get isError => stage == 'error' || error != null;
}
