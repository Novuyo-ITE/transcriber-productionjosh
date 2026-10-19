import 'dart:async';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import '../models/transcription.dart';
import '../models/portion.dart';
import '../models/progress.dart';
import '../services/api_service.dart';

enum EditorViewMode { auto, portions, raw }

class ChatMessage {
  final bool isAi;
  final String text;
  final DateTime timestamp;

  ChatMessage({
    required this.isAi,
    required this.text,
    required this.timestamp,
  });
}

class TranscriptionProvider extends ChangeNotifier {
  final ApiService _api = ApiService();
  final AudioPlayer _audioPlayer = AudioPlayer();

  AudioPlayer get audioPlayer => _audioPlayer;

  // History & Search
  List<TranscriptionItem> _history = [];
  String _searchQuery = '';
  bool _isLoadingHistory = false;
  String? _historyError;

  List<TranscriptionItem> get history {
    if (_searchQuery.trim().isEmpty) return _history;
    final q = _searchQuery.toLowerCase().trim();
    return _history.where((t) => t.originalName.toLowerCase().contains(q)).toList();
  }

  bool get isLoadingHistory => _isLoadingHistory;
  String? get historyError => _historyError;

  // Active Transcription & Editor
  TranscriptionItem? _currentTranscription;
  List<Portion> _portions = [];
  EditorViewMode _viewMode = EditorViewMode.auto;
  final Set<int> _selectedIndices = {};
  bool _isSaving = false;
  bool _isLoadingDetails = false;

  TranscriptionItem? get currentTranscription => _currentTranscription;
  List<Portion> get portions => _portions;
  List<Portion> get autoTranscript => Portion.buildAutoTranscript(_portions);
  EditorViewMode get viewMode => _viewMode;
  Set<int> get selectedIndices => _selectedIndices;
  bool get isSaving => _isSaving;
  bool get isLoadingDetails => _isLoadingDetails;

  // Raw text
  String get rawText {
    if (_currentTranscription?.transcription != null &&
        _currentTranscription!.transcription!.isNotEmpty) {
      return _currentTranscription!.transcription!;
    }
    return _portions.map((p) => p.content).join('\n\n');
  }

  // Audio Playback
  bool _isPlaying = false;
  Duration _audioPosition = Duration.zero;
  Duration _audioDuration = Duration.zero;
  double _playbackSpeed = 1.0;
  int _activePlayingIndex = -1;

  bool get isPlaying => _isPlaying;
  Duration get audioPosition => _audioPosition;
  Duration get audioDuration => _audioDuration;
  double get playbackSpeed => _playbackSpeed;
  int get activePlayingIndex => _activePlayingIndex;

  // Copilot Chat
  final List<ChatMessage> _chatMessages = [
    ChatMessage(
      isAi: true,
      text: "Welcome to **NOVUscribe Copilot**! I can generate executive summaries, extract action items, break down speaker dialogue, or answer any questions about this transcript.",
      timestamp: DateTime.now(),
    )
  ];
  bool _isCopilotLoading = false;

  List<ChatMessage> get chatMessages => _chatMessages;
  bool get isCopilotLoading => _isCopilotLoading;

  // Active Transcription Job Submission & Progress
  bool _isTranscribing = false;
  ProgressUpdate? _currentProgress;
  Timer? _progressTimer;

  bool get isTranscribing => _isTranscribing;
  ProgressUpdate? get currentProgress => _currentProgress;

  TranscriptionProvider() {
    _initAudioListeners();
  }

  void _initAudioListeners() {
    _audioPlayer.onPlayerStateChanged.listen((state) {
      _isPlaying = state == PlayerState.playing;
      notifyListeners();
    });

    _audioPlayer.onPositionChanged.listen((pos) {
      _audioPosition = pos;
      _updateActivePlayingPortion(pos.inSeconds);
      notifyListeners();
    });

    _audioPlayer.onDurationChanged.listen((dur) {
      _audioDuration = dur;
      notifyListeners();
    });
  }

  void _updateActivePlayingPortion(int currentSec) {
    final activeList = (_viewMode == EditorViewMode.auto) ? autoTranscript : _portions;
    if (activeList.isEmpty) {
      _activePlayingIndex = -1;
      return;
    }

    int foundIdx = -1;
    for (int i = 0; i < activeList.length; i++) {
      final startSec = activeList[i].seconds;
      final nextSec = (i < activeList.length - 1) ? activeList[i + 1].seconds : 999999;
      if (currentSec >= startSec && currentSec < nextSec) {
        foundIdx = i;
        break;
      }
    }

    if (foundIdx != _activePlayingIndex) {
      _activePlayingIndex = foundIdx;
      notifyListeners();
    }
  }

  // ================= HISTORY OPERATIONS =================

  Future<void> fetchHistory() async {
    _isLoadingHistory = true;
    _historyError = null;
    notifyListeners();

    try {
      _history = await _api.getHistory();
    } catch (e) {
      _historyError = e.toString();
    } finally {
      _isLoadingHistory = false;
      notifyListeners();
    }
  }

  void setSearchQuery(String query) {
    _searchQuery = query;
    notifyListeners();
  }

  // ================= SELECTION & LOADING TRANSCRIPTION =================

  Future<void> loadTranscription(String tid) async {
    _isLoadingDetails = true;
    _selectedIndices.clear();
    notifyListeners();

    try {
      _currentTranscription = await _api.getTranscription(tid);
      final formatted = _currentTranscription?.formatted ?? _currentTranscription?.transcription ?? '';
      _portions = Portion.parseFromText(formatted);

      // Setup Audio Player with stream URL
      final audioUrl = _api.getAudioStreamUrl(tid);
      await _audioPlayer.stop();
      _audioPosition = Duration.zero;
      _audioDuration = Duration.zero;
      await _audioPlayer.setSourceUrl(audioUrl);
    } catch (e) {
      debugPrint('Error loading transcription details: $e');
    } finally {
      _isLoadingDetails = false;
      notifyListeners();
    }
  }

  void setViewMode(EditorViewMode mode) {
    _viewMode = mode;
    notifyListeners();
  }

  // ================= AUDIO CONTROLS =================

  Future<void> togglePlayPause() async {
    if (_isPlaying) {
      await _audioPlayer.pause();
    } else {
      await _audioPlayer.resume();
    }
  }

  Future<void> seekAudio(Duration position) async {
    await _audioPlayer.seek(position);
  }

  Future<void> seekRelative(int secondsDelta) async {
    final target = _audioPosition + Duration(seconds: secondsDelta);
    final clamped = Duration(
      seconds: target.inSeconds.clamp(0, _audioDuration.inSeconds),
    );
    await _audioPlayer.seek(clamped);
  }

  Future<void> setSpeed(double speed) async {
    _playbackSpeed = speed;
    await _audioPlayer.setPlaybackRate(speed);
    notifyListeners();
  }

  Future<void> playAtTimestamp(String timestampStr, int? cardIdx) async {
    final seconds = Portion(time: timestampStr, speaker: '', content: '').seconds;
    await _audioPlayer.seek(Duration(seconds: seconds));
    await _audioPlayer.resume();
    if (cardIdx != null) {
      _activePlayingIndex = cardIdx;
      notifyListeners();
    }
  }

  // ================= PORTION EDITING =================

  void updatePortionContent(int index, String newContent) {
    if (index >= 0 && index < _portions.length) {
      _portions[index].content = newContent;
      notifyListeners();
      _debounceSave();
    }
  }

  void updatePortionSpeaker(int index, String newSpeaker) {
    if (index >= 0 && index < _portions.length) {
      _portions[index].speaker = newSpeaker.trim();
      notifyListeners();
      savePortionsToServer();
    }
  }

  void renameSpeakerGlobally(String oldSpeaker, String newSpeaker) {
    final oldClean = oldSpeaker.trim().toLowerCase();
    final newClean = newSpeaker.trim();
    if (newClean.isEmpty || oldClean == newClean.toLowerCase()) return;

    for (final p in _portions) {
      if (p.speaker.trim().toLowerCase() == oldClean) {
        p.speaker = newClean;
      }
    }
    notifyListeners();
    savePortionsToServer();
  }

  void togglePortionSelection(int index) {
    if (_selectedIndices.contains(index)) {
      _selectedIndices.remove(index);
    } else {
      _selectedIndices.add(index);
    }
    notifyListeners();
  }

  void clearSelection() {
    _selectedIndices.clear();
    notifyListeners();
  }

  void splitPortion(int index, int splitOffset) {
    if (index < 0 || index >= _portions.length) return;
    final original = _portions[index];
    final fullText = original.content;
    if (splitOffset <= 0 || splitOffset >= fullText.length) return;

    final firstPart = fullText.substring(0, splitOffset).trim();
    final secondPart = fullText.substring(splitOffset).trim();

    original.content = firstPart;
    _portions.insert(
      index + 1,
      Portion(
        time: original.time,
        speaker: original.speaker,
        content: secondPart,
      ),
    );

    notifyListeners();
    savePortionsToServer();
  }

  void mergeNext(int index) {
    if (index < 0 || index >= _portions.length - 1) return;
    final current = _portions[index];
    final next = _portions[index + 1];

    current.content = '${current.content}\n${next.content}'.trim();
    _portions.removeAt(index + 1);

    notifyListeners();
    savePortionsToServer();
  }

  void mergeWith(int sourceIdx, int targetIdx) {
    if (sourceIdx == targetIdx ||
        sourceIdx < 0 || sourceIdx >= _portions.length ||
        targetIdx < 0 || targetIdx >= _portions.length) return;

    final firstIdx = sourceIdx < targetIdx ? sourceIdx : targetIdx;
    final secondIdx = sourceIdx < targetIdx ? targetIdx : sourceIdx;

    final first = _portions[firstIdx];
    final second = _portions[secondIdx];

    first.content = '${first.content}\n${second.content}'.trim();
    _portions.removeAt(secondIdx);

    notifyListeners();
    savePortionsToServer();
  }

  void mergeSelected() {
    if (_selectedIndices.length < 2) return;
    final sorted = _selectedIndices.toList()..sort();
    final firstIdx = sorted.first;
    final firstPortion = _portions[firstIdx];

    final mergedContent = StringBuffer(firstPortion.content);
    for (int i = 1; i < sorted.length; i++) {
      mergedContent.write('\n');
      mergedContent.write(_portions[sorted[i]].content);
    }
    firstPortion.content = mergedContent.toString().trim();

    // Remove others in reverse order
    for (int i = sorted.length - 1; i >= 1; i--) {
      _portions.removeAt(sorted[i]);
    }

    _selectedIndices.clear();
    notifyListeners();
    savePortionsToServer();
  }

  void deletePortion(int index) {
    if (index < 0 || index >= _portions.length) return;
    _portions.removeAt(index);
    _selectedIndices.remove(index);
    notifyListeners();
    savePortionsToServer();
  }

  Timer? _saveDebounceTimer;
  void _debounceSave() {
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = Timer(const Duration(milliseconds: 1500), () {
      savePortionsToServer();
    });
  }

  Future<void> savePortionsToServer() async {
    if (_currentTranscription == null) return;
    _isSaving = true;
    notifyListeners();

    final formattedLines = _portions.map((p) => '[${p.time}] ${p.speaker}: ${p.content}').join('\n\n');
    final rawLines = _portions.map((p) => p.content).join('\n\n');

    try {
      await _api.updateTranscription(
        _currentTranscription!.id,
        formatted: formattedLines,
        rawTranscription: rawLines,
      );
    } catch (e) {
      debugPrint('Save error: $e');
    } finally {
      _isSaving = false;
      notifyListeners();
    }
  }

  Future<void> renameCurrentTranscription(String newName) async {
    if (_currentTranscription == null) return;
    await _api.renameTranscription(_currentTranscription!.id, newName);
    await fetchHistory();
    await loadTranscription(_currentTranscription!.id);
  }

  Future<void> deleteCurrentTranscription() async {
    if (_currentTranscription == null) return;
    await _audioPlayer.stop();
    await _api.deleteTranscription(_currentTranscription!.id);
    _currentTranscription = null;
    _portions = [];
    await fetchHistory();
    notifyListeners();
  }

  // ================= COPILOT CHAT =================

  Future<void> sendCopilotMessage(String prompt, {String selectedText = ''}) async {
    if (_currentTranscription == null || prompt.trim().isEmpty) return;

    _chatMessages.add(ChatMessage(isAi: false, text: prompt, timestamp: DateTime.now()));
    _isCopilotLoading = true;
    notifyListeners();

    try {
      final reply = await _api.chatCoPilot(
        tid: _currentTranscription!.id,
        prompt: prompt,
        selectedText: selectedText,
      );
      _chatMessages.add(ChatMessage(isAi: true, text: reply, timestamp: DateTime.now()));
    } catch (e) {
      _chatMessages.add(ChatMessage(
        isAi: true,
        text: '❌ Co-Pilot Error: ${e.toString()}',
        timestamp: DateTime.now(),
      ));
    } finally {
      _isCopilotLoading = false;
      notifyListeners();
    }
  }

  // ================= TRANSCRIPTION JOB SUBMISSION & POLLING =================

  Future<void> submitAndTrackJob({
    required String sourceType,
    required String language,
    required bool diarize,
    int? numSpeakers,
    String? audioFilePath,
    String? videoFilePath,
    String? youtubeUrl,
    bool isLiveRec = false,
    required VoidCallback onComplete,
    required Function(String) onError,
  }) async {
    _isTranscribing = true;
    _currentProgress = ProgressUpdate(
      stage: 'ingest',
      statusText: 'Acquiring Media...',
      subtext: 'Phase 1: Ingesting & preparing stream...',
      progressPct: 8.0,
    );
    notifyListeners();

    try {
      final jobId = await _api.submitTranscriptionJob(
        sourceType: sourceType,
        language: language,
        diarize: diarize,
        numSpeakers: numSpeakers,
        audioFilePath: audioFilePath,
        videoFilePath: videoFilePath,
        youtubeUrl: youtubeUrl,
        isLiveRec: isLiveRec,
      );

      _progressTimer?.cancel();
      _progressTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) async {
        try {
          final prog = await _api.pollProgress(jobId);
          _currentProgress = prog;
          notifyListeners();

          if (prog.isComplete) {
            timer.cancel();
            _isTranscribing = false;
            await fetchHistory();
            if (prog.resultId != null) {
              await loadTranscription(prog.resultId!);
            }
            notifyListeners();
            onComplete();
          } else if (prog.isError) {
            timer.cancel();
            _isTranscribing = false;
            notifyListeners();
            onError(prog.error ?? 'Transcription failed');
          }
        } catch (e) {
          debugPrint('Progress poll error: $e');
        }
      });
    } catch (e) {
      _isTranscribing = false;
      notifyListeners();
      onError(e.toString());
    }
  }

  void cancelProgressTracking() {
    _progressTimer?.cancel();
    _isTranscribing = false;
    _currentProgress = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    _saveDebounceTimer?.cancel();
    _audioPlayer.dispose();
    super.dispose();
  }
}
