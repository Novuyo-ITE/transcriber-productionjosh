import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../providers/transcription_provider.dart';
import '../services/api_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

class StreamMessageItem {
  final String speaker;
  final String text;
  final String timestamp;
  final bool isNewSpeaker;

  StreamMessageItem({
    required this.speaker,
    required this.text,
    required this.timestamp,
    this.isNewSpeaker = false,
  });

  Map<String, dynamic> toJson() => {
    'speaker': speaker,
    'text': text,
    'timestamp': timestamp,
  };
}

class StreamStudioScreen extends StatefulWidget {
  final VoidCallback onSavedToWorkspace;

  const StreamStudioScreen({super.key, required this.onSavedToWorkspace});

  @override
  State<StreamStudioScreen> createState() => _StreamStudioScreenState();
}

class _StreamStudioScreenState extends State<StreamStudioScreen> with SingleTickerProviderStateMixin {
  final AudioRecorder _audioRecorder = AudioRecorder();
  final ScrollController _scrollController = ScrollController();

  bool _isStreaming = false;
  final List<StreamMessageItem> _messages = [];
  late AnimationController _animController;
  Timer? _clockTimer;
  StreamSubscription<Uint8List>? _streamSub;
  final BytesBuilder _pcmAccumulator = BytesBuilder(copy: false);
  bool _isSendingChunk = false;
  int _secondsElapsed = 0;
  String _selectedLanguage = 'Luganda';
  String _sessionId = '';
  int _latencyMs = 0;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    ApiService().streamWarmup();
  }

  @override
  void dispose() {
    _animController.dispose();
    _clockTimer?.cancel();
    _streamSub?.cancel();
    _audioRecorder.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  String _formatTimer(int sec) {
    final m = sec ~/ 60;
    final s = sec % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String get _langCode {
    switch (_selectedLanguage.toLowerCase()) {
      case 'luganda':
        return 'lg';
      case 'english':
        return 'en';
      case 'swahili':
        return 'sw';
      case 'french':
        return 'fr';
      case 'lingala':
        return 'ln';
      default:
        return 'auto';
    }
  }

  Uint8List _encodeWav(Uint8List pcmBytes, {int sampleRate = 16000}) {
    final byteRate = sampleRate * 2;
    final dataLength = pcmBytes.length;
    final buffer = Uint8List(44 + dataLength);
    final bData = ByteData.view(buffer.buffer);

    // RIFF chunk descriptor
    buffer.setRange(0, 4, 'RIFF'.codeUnits);
    bData.setUint32(4, 36 + dataLength, Endian.little);
    buffer.setRange(8, 12, 'WAVE'.codeUnits);

    // FMT sub-chunk
    buffer.setRange(12, 16, 'fmt '.codeUnits);
    bData.setUint32(16, 16, Endian.little);
    bData.setUint16(20, 1, Endian.little); // PCM
    bData.setUint16(22, 1, Endian.little); // Mono
    bData.setUint32(24, sampleRate, Endian.little);
    bData.setUint32(28, byteRate, Endian.little);
    bData.setUint16(32, 2, Endian.little); // Block align
    bData.setUint16(34, 16, Endian.little); // Bits per sample

    // DATA sub-chunk
    buffer.setRange(36, 40, 'data'.codeUnits);
    bData.setUint32(40, dataLength, Endian.little);

    // Payload
    buffer.setRange(44, 44 + dataLength, pcmBytes);
    return buffer;
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _toggleStream() {
    if (_isStreaming) {
      _stopStream();
    } else {
      _startStream();
    }
  }

  Future<void> _startStream() async {
    final status = await Permission.microphone.request();
    if (status != PermissionStatus.granted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Microphone permission is required for live streaming.'),
            backgroundColor: Color(0xFFEF4444),
          ),
        );
      }
      return;
    }

    final hasPerm = await _audioRecorder.hasPermission();
    if (!hasPerm) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Microphone access denied. Please grant permission in Settings.'),
            backgroundColor: Color(0xFFEF4444),
          ),
        );
      }
      return;
    }

    _sessionId = 'stream_${DateTime.now().millisecondsSinceEpoch}';
    _secondsElapsed = 0;
    _pcmAccumulator.clear();

    setState(() {
      _isStreaming = true;
    });

    _clockTimer?.cancel();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() => _secondsElapsed++);
    });

    try {
      final stream = await _audioRecorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );

      _streamSub = stream.listen((chunk) {
        _pcmAccumulator.add(chunk);
        // Slices every ~1.6 seconds (16000 * 2 * 1.6 = 51200 bytes)
        if (_pcmAccumulator.length >= 51200 && !_isSendingChunk) {
          final pcmBytes = _pcmAccumulator.takeBytes();
          final wavBytes = _encodeWav(pcmBytes, sampleRate: 16000);
          _sendChunk(wavBytes, isContinuous: true);
        }
      });
    } catch (e) {
      _stopStream();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start microphone: $e'), backgroundColor: const Color(0xFFEF4444)),
        );
      }
    }
  }

  Future<void> _sendChunk(Uint8List wavBytes, {required bool isContinuous}) async {
    if (_isSendingChunk && isContinuous) return;
    _isSendingChunk = true;
    try {
      final res = await ApiService().streamChunk(
        audioBytes: wavBytes,
        sessionId: _sessionId,
        language: _langCode,
        isContinuous: isContinuous,
        filename: 'turn.wav',
      );

      if (!mounted) return;

      final isSpeech = res['is_speech'] == true;
      final text = res['text']?.toString().trim() ?? '';
      final speaker = res['speaker']?.toString() ?? 'Speaker 1';
      final latency = (res['latency_ms'] as num?)?.toInt() ?? 0;

      if (isSpeech && text.isNotEmpty) {
        setState(() {
          _latencyMs = latency;
          _messages.add(StreamMessageItem(
            speaker: speaker,
            text: text,
            timestamp: _formatTimer(_secondsElapsed),
          ));
        });
        _scrollToBottom();
      }
    } catch (e) {
      debugPrint('[STREAM] Error sending chunk: $e');
    } finally {
      _isSendingChunk = false;
    }
  }

  Future<void> _stopStream() async {
    _clockTimer?.cancel();
    _clockTimer = null;

    try {
      await _streamSub?.cancel();
      _streamSub = null;
      if (await _audioRecorder.isRecording()) {
        await _audioRecorder.stop();
      }
    } catch (e) {
      debugPrint('[STREAM] Error stopping recorder: $e');
    }

    if (_pcmAccumulator.length > 16000 * 2 * 0.4) {
      final remainingPcm = _pcmAccumulator.takeBytes();
      final wavBytes = _encodeWav(remainingPcm, sampleRate: 16000);
      _sendChunk(wavBytes, isContinuous: false);
    } else {
      _pcmAccumulator.clear();
    }

    if (mounted) {
      setState(() => _isStreaming = false);
    }
  }

  Future<void> _saveSession() async {
    if (_messages.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No conversation messages to save.')),
      );
      return;
    }

    final titleController = TextEditingController(
      text: 'Live_Stream_${DateTime.now().hour}${DateTime.now().minute}',
    );

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Save Streaming Session', style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700)),
        content: TextField(
          controller: titleController,
          decoration: const InputDecoration(labelText: 'Session Title'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save to Workspace')),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final id = await ApiService().saveStreamSession(
          title: titleController.text.trim(),
          language: _selectedLanguage,
          messages: _messages.map((m) => m.toJson()).toList(),
        );
        if (mounted) {
          await context.read<TranscriptionProvider>().fetchHistory();
          await context.read<TranscriptionProvider>().loadTranscription(id);
          widget.onSavedToWorkspace();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Stream session saved to workspace!'),
              backgroundColor: AppColors.emeraldPrimary,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error saving session: $e')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      children: [
        // Studio Top Bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF0D121C) : Colors.white,
            border: Border(bottom: BorderSide(color: isDark ? AppColors.darkBorderPanel : AppColors.lightBorderPanel)),
          ),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: AppColors.emeraldPrimary.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.emeraldPrimary.withOpacity(0.4)),
                ),
                child: const Icon(Icons.stream, color: AppColors.emeraldLight, size: 20),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Live Stream Studio',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: _isStreaming ? Colors.red.withOpacity(0.15) : AppColors.emeraldPrimary.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: _isStreaming ? Colors.redAccent : AppColors.emeraldPrimary,
                          ),
                        ),
                        child: Text(
                          _isStreaming ? '● LIVE' : 'READY',
                          style: AppTheme.mono(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w800,
                            color: _isStreaming ? Colors.redAccent : AppColors.emeraldLight,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Text(
                    'Real-Time Faster Whisper & Speaker Tracking',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 11,
                      color: isDark ? AppColors.darkTextMuted : AppColors.lightTextMuted,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              if (_messages.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.save_outlined, color: AppColors.emeraldLight),
                  onPressed: _saveSession,
                  tooltip: 'Save Session',
                ),
            ],
          ),
        ),

        // Live Controls Card
        Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isDark ? AppColors.darkBgPanel : AppColors.lightBgPanel,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: _isStreaming ? AppColors.emeraldPrimary.withOpacity(0.4) : (isDark ? AppColors.darkBorderPanel : AppColors.lightBorderPanel),
            ),
            boxShadow: _isStreaming
                ? [
                    BoxShadow(color: AppColors.emeraldGlow, blurRadius: 16),
                  ]
                : null,
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Timer & Latency
                  Row(
                    children: [
                      Icon(Icons.mic, color: _isStreaming ? Colors.redAccent : AppColors.emeraldPrimary, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        _formatTimer(_secondsElapsed),
                        style: AppTheme.mono(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                        ),
                      ),
                      if (_latencyMs > 0 && _isStreaming) ...[
                        const SizedBox(width: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.06),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '${_latencyMs}ms',
                            style: AppTheme.mono(fontSize: 10, color: AppColors.emeraldLight),
                          ),
                        ),
                      ],
                    ],
                  ),

                  // Language chip
                  DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _selectedLanguage,
                      items: ['Luganda', 'English', 'Swahili', 'French', 'Lingala']
                          .map((l) => DropdownMenuItem(value: l, child: Text(l, style: GoogleFonts.plusJakartaSans(fontSize: 12))))
                          .toList(),
                      onChanged: (val) {
                        if (val != null) setState(() => _selectedLanguage = val);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // Animated wave visualizer
              if (_isStreaming)
                AnimatedBuilder(
                  animation: _animController,
                  builder: (context, child) {
                    return Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(14, (i) {
                        final val = (_animController.value + (i * 0.08)) % 1.0;
                        final h = 10.0 + (val * 32.0);
                        return Container(
                          width: 4,
                          height: h,
                          margin: const EdgeInsets.symmetric(horizontal: 2.5),
                          decoration: BoxDecoration(
                            color: i % 2 == 0 ? AppColors.emeraldPrimary : const Color(0xFF38BDF8),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        );
                      }),
                    );
                  },
                ),
              const SizedBox(height: 14),

              // Action button
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _toggleStream,
                      icon: Icon(_isStreaming ? Icons.stop_rounded : Icons.mic_rounded, color: const Color(0xFF030712)),
                      label: Text(
                        _isStreaming ? 'Stop Streaming' : 'Start Real-Time Stream',
                        style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isStreaming ? const Color(0xFFF87171) : AppColors.emeraldPrimary,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                  if (_messages.isNotEmpty) ...[
                    const SizedBox(width: 10),
                    OutlinedButton(
                      onPressed: () => setState(() => _messages.clear()),
                      child: const Text('Clear'),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),

        // Live Utterance Message Stream
        Expanded(
          child: _messages.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.forum_outlined, size: 48, color: isDark ? AppColors.darkTextMuted : AppColors.lightTextMuted),
                      const SizedBox(height: 12),
                      Text(
                        _isStreaming ? 'Listening to speech...' : 'Live dialogue stream ready',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _isStreaming
                            ? 'Speak into your microphone. Words and speakers will appear in real-time.'
                            : 'Tap "Start Real-Time Stream" to transcribe microphone audio live.',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 11.5,
                          color: isDark ? AppColors.darkTextMuted : AppColors.lightTextMuted,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _messages.length,
                  itemBuilder: (context, idx) {
                    final msg = _messages[idx];
                    final style = AppColors.getSpeakerStyle(msg.speaker);

                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isDark ? AppColors.darkBgPanel : AppColors.lightBgPanel,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: isDark ? AppColors.darkBorderPanel : AppColors.lightBorderPanel),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                                decoration: BoxDecoration(
                                  color: style.bg,
                                  borderRadius: BorderRadius.circular(5),
                                  border: Border.all(color: style.border),
                                ),
                                child: Text(
                                  msg.speaker,
                                  style: AppTheme.mono(fontSize: 10.5, fontWeight: FontWeight.w700, color: style.text),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                msg.timestamp,
                                style: AppTheme.mono(fontSize: 10, color: isDark ? AppColors.darkTextMuted : AppColors.lightTextMuted),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            msg.text,
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 13,
                              height: 1.4,
                              color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
