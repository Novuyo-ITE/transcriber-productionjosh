import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/transcription.dart';
import '../models/progress.dart';
import '../models/analytics.dart';

class ApiService {
  static const String defaultRailwayUrl = 'https://novuscribe.up.railway.app';

  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  // Default base URL points to Railway production deployment
  String _baseUrl = defaultRailwayUrl;
  Map<String, String> _cookies = {};
  String? _csrfToken;

  String get baseUrl => _baseUrl;
  bool get hasSession => _cookies.containsKey('sessionid');

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final savedUrl = prefs.getString('api_base_url');
    if (savedUrl != null && savedUrl.isNotEmpty && !savedUrl.contains('transcriber-production.up.railway.app')) {
      _baseUrl = savedUrl;
    } else {
      // Default to live Railway URL and persist it
      _baseUrl = defaultRailwayUrl;
      await prefs.setString('api_base_url', _baseUrl);
    }

    // Load persisted cookies
    final savedCookieJson = prefs.getString('saved_cookies_json');
    if (savedCookieJson != null && savedCookieJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(savedCookieJson) as Map<String, dynamic>;
        _cookies = decoded.map((k, v) => MapEntry(k, v.toString()));
      } catch (_) {}
    } else {
      // Backwards compatibility with raw session_cookie
      final legacyCookie = prefs.getString('session_cookie');
      if (legacyCookie != null && legacyCookie.isNotEmpty) {
        _parseRawCookieString(legacyCookie);
      }
    }

    _csrfToken = prefs.getString('csrf_token') ?? _cookies['csrftoken'];
  }

  Future<void> setBaseUrl(String newUrl) async {
    String formatted = newUrl.trim();
    if (formatted.endsWith('/')) {
      formatted = formatted.substring(0, formatted.length - 1);
    }
    _baseUrl = formatted;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_base_url', _baseUrl);
  }

  void Function()? onUnauthorized;

  Map<String, String> _buildHeaders({bool isJson = true}) {
    final headers = <String, String>{};
    if (isJson) {
      headers['Content-Type'] = 'application/json';
    }
    if (_cookies.isNotEmpty) {
      headers['Cookie'] = _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
    }
    if (_csrfToken != null && _csrfToken!.isNotEmpty) {
      headers['X-CSRFToken'] = _csrfToken!;
    }
    return headers;
  }

  void _parseRawCookieString(String raw) {
    final sessionMatch = RegExp(r'sessionid=([^;,\s]+)').firstMatch(raw);
    if (sessionMatch != null) {
      _cookies['sessionid'] = sessionMatch.group(1)!.replaceAll('"', '').replaceAll("'", '');
    }
    final csrfMatch = RegExp(r'csrftoken=([^;,\s]+)').firstMatch(raw);
    if (csrfMatch != null) {
      final token = csrfMatch.group(1)!.replaceAll('"', '').replaceAll("'", '');
      _cookies['csrftoken'] = token;
      _csrfToken = token;
    }
  }

  void _extractCookies(http.Response response) {
    final rawCookie = response.headers['set-cookie'];
    if (rawCookie != null && rawCookie.isNotEmpty) {
      _parseRawCookieString(rawCookie);
      _persistCookies();
    }
    if (response.statusCode == 401) {
      onUnauthorized?.call();
    }
  }

  Future<void> _persistCookies() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('saved_cookies_json', jsonEncode(_cookies));
      if (_csrfToken != null) {
        await prefs.setString('csrf_token', _csrfToken!);
      }
      if (_cookies.isNotEmpty) {
        await prefs.setString('session_cookie', _cookies.entries.map((e) => '${e.key}=${e.value}').join('; '));
      }
    } catch (_) {}
  }

  /// Live connection and latency health check to the Railway backend
  Future<Map<String, dynamic>> checkConnection() async {
    final stopwatch = Stopwatch()..start();
    try {
      final uri = Uri.parse('$_baseUrl/api/stream_warmup/');
      final response = await http
          .get(uri, headers: _buildHeaders(isJson: false))
          .timeout(const Duration(seconds: 10));
      stopwatch.stop();
      _extractCookies(response);

      final isSuccess = response.statusCode >= 200 && response.statusCode < 400;
      return {
        'success': isSuccess,
        'statusCode': response.statusCode,
        'latencyMs': stopwatch.elapsedMilliseconds,
        'url': _baseUrl,
        'message': isSuccess
            ? 'Connected successfully (${stopwatch.elapsedMilliseconds}ms)'
            : 'Server error (HTTP ${response.statusCode})',
      };
    } catch (e) {
      stopwatch.stop();
      return {
        'success': false,
        'statusCode': 0,
        'latencyMs': stopwatch.elapsedMilliseconds,
        'url': _baseUrl,
        'message': 'Cannot reach server: $e',
      };
    }
  }

  // ===================== AUTHENTICATION =====================

  Future<Map<String, dynamic>> login(String username, String password) async {
    try {
      final uri = Uri.parse('$_baseUrl/api/login/');
      final response = await http.post(
        uri,
        headers: _buildHeaders(isJson: true),
        body: jsonEncode({'username': username, 'password': password}),
      ).timeout(const Duration(seconds: 15));
      _extractCookies(response);
      try {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (response.statusCode != 200 && data['error'] == null) {
          data['error'] = 'Server error (${response.statusCode})';
        }
        return data;
      } catch (_) {
        return {
          'success': false,
          'error': 'Server error (${response.statusCode}): ${response.body.length > 80 ? response.body.substring(0, 80) : response.body}'
        };
      }
    } catch (e) {
      return {'success': false, 'error': 'Connection failed: $e'};
    }
  }

  Future<Map<String, dynamic>> register(String username, String email, String password) async {
    try {
      final uri = Uri.parse('$_baseUrl/api/register/');
      final response = await http.post(
        uri,
        headers: _buildHeaders(isJson: true),
        body: jsonEncode({
          'username': username,
          'email': email,
          'password': password,
        }),
      ).timeout(const Duration(seconds: 15));
      _extractCookies(response);
      try {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (response.statusCode != 200 && data['error'] == null) {
          data['error'] = 'Server error (${response.statusCode})';
        }
        return data;
      } catch (_) {
        return {
          'success': false,
          'error': 'Server error (${response.statusCode}): ${response.body.length > 80 ? response.body.substring(0, 80) : response.body}'
        };
      }
    } catch (e) {
      return {'success': false, 'error': 'Connection failed: $e'};
    }
  }

  Future<void> logout() async {
    try {
      final uri = Uri.parse('$_baseUrl/api/logout/');
      await http.post(uri, headers: _buildHeaders(isJson: true));
    } catch (_) {}
    _cookies.clear();
    _csrfToken = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('saved_cookies_json');
    await prefs.remove('session_cookie');
    await prefs.remove('csrf_token');
  }

  // ===================== TRANSCRIPTION WORKSPACE =====================

  Future<List<TranscriptionItem>> getHistory() async {
    final uri = Uri.parse('$_baseUrl/api/history/');
    final response = await http.get(uri, headers: _buildHeaders(isJson: false));
    _extractCookies(response);
    if (response.statusCode == 401) {
      throw Exception('UNAUTHENTICATED');
    }
    if (response.statusCode != 200) {
      throw Exception('Failed to load history (${response.statusCode})');
    }
    final data = jsonDecode(response.body);
    final list = (data['history'] as List? ?? [])
        .map((item) => TranscriptionItem.fromJson(item))
        .toList();
    return list;
  }

  Future<TranscriptionItem> getTranscription(String tid) async {
    final uri = Uri.parse('$_baseUrl/api/transcription/$tid/');
    final response = await http.get(uri, headers: _buildHeaders(isJson: false));
    _extractCookies(response);
    if (response.statusCode != 200) {
      throw Exception('Failed to load transcription ($tid)');
    }
    final data = jsonDecode(response.body);
    return TranscriptionItem.fromJson(data);
  }

  Future<String> submitTranscriptionJob({
    required String sourceType,
    required String language,
    required bool diarize,
    int? numSpeakers,
    String? audioFilePath,
    String? videoFilePath,
    String? youtubeUrl,
    bool isLiveRec = false,
  }) async {
    final uri = Uri.parse('$_baseUrl/api/transcribe/');
    final request = http.MultipartRequest('POST', uri);

    final headers = _buildHeaders(isJson: false);
    request.headers.addAll(headers);

    final clientJobId = 'job_${DateTime.now().millisecondsSinceEpoch}';
    request.fields['job_id'] = clientJobId;
    request.fields['source_type'] = sourceType;
    request.fields['language'] = language;
    request.fields['diarize'] = diarize ? 'true' : 'false';
    request.fields['is_live_rec'] = isLiveRec ? 'true' : 'false';
    if (numSpeakers != null && numSpeakers > 0) {
      request.fields['num_speakers'] = numSpeakers.toString();
    }

    if (sourceType == 'audio_file' && audioFilePath != null) {
      final file = File(audioFilePath);
      final filename = file.uri.pathSegments.last;
      final ext = filename.split('.').last.toLowerCase();
      MediaType? contentType;
      if (ext == 'wav') {
        contentType = MediaType('audio', 'wav');
      } else if (ext == 'mp3') {
        contentType = MediaType('audio', 'mpeg');
      } else if (ext == 'm4a') {
        contentType = MediaType('audio', 'mp4');
      }
      request.files.add(await http.MultipartFile.fromPath(
        'audio_file',
        audioFilePath,
        filename: filename,
        contentType: contentType,
      ));
    } else if (sourceType == 'video_file' && videoFilePath != null) {
      final file = File(videoFilePath);
      final filename = file.uri.pathSegments.last;
      request.files.add(await http.MultipartFile.fromPath(
        'video_file',
        videoFilePath,
        filename: filename,
      ));
    } else if (sourceType == 'youtube_url' && youtubeUrl != null) {
      request.fields['youtube_url'] = youtubeUrl;
    }

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);
    _extractCookies(response);

    if (response.statusCode == 401) {
      throw Exception('UNAUTHENTICATED');
    }

    final data = jsonDecode(response.body);
    if (data['error'] != null) {
      throw Exception(data['error']);
    }

    final jobId = data['job_id']?.toString();
    if (jobId == null || jobId.isEmpty) {
      throw Exception('Server did not return a valid job ID');
    }
    return jobId;
  }

  Future<ProgressUpdate> pollProgress(String jobId) async {
    final uri = Uri.parse('$_baseUrl/api/progress/$jobId/');
    final response = await http.get(uri, headers: _buildHeaders(isJson: false));
    _extractCookies(response);
    if (response.statusCode != 200) {
      return ProgressUpdate(
        stage: 'processing',
        statusText: 'Processing...',
        subtext: '',
        progressPct: 10.0,
      );
    }
    final data = jsonDecode(response.body);
    return ProgressUpdate.fromJson(data);
  }

  Future<void> updateTranscription(String tid, {String? formatted, String? rawTranscription}) async {
    final uri = Uri.parse('$_baseUrl/api/update/$tid/');
    final body = <String, dynamic>{};
    if (formatted != null) body['formatted'] = formatted;
    if (rawTranscription != null) body['transcription'] = rawTranscription;

    final response = await http.post(
      uri,
      headers: _buildHeaders(isJson: true),
      body: jsonEncode(body),
    );
    _extractCookies(response);
    if (response.statusCode != 200) {
      throw Exception('Failed to update transcription');
    }
  }

  Future<Map<String, dynamic>> diarizeTranscription(String tid, {int? numSpeakers}) async {
    final uri = Uri.parse('$_baseUrl/api/diarize/$tid/');
    final body = numSpeakers != null && numSpeakers > 0 ? {'num_speakers': numSpeakers} : {};
    final response = await http.post(
      uri,
      headers: _buildHeaders(isJson: true),
      body: jsonEncode(body),
    );
    _extractCookies(response);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<String> chatCoPilot({
    required String tid,
    required String prompt,
    String selectedText = '',
  }) async {
    final uri = Uri.parse('$_baseUrl/api/chat/');
    final response = await http.post(
      uri,
      headers: _buildHeaders(isJson: true),
      body: jsonEncode({
        'id': tid,
        'prompt': prompt,
        'selected_text': selectedText,
      }),
    );
    _extractCookies(response);
    if (response.statusCode != 200) {
      final errData = jsonDecode(response.body);
      throw Exception(errData['error'] ?? 'Copilot request failed');
    }
    final data = jsonDecode(response.body);
    return data['reply']?.toString() ?? 'No response';
  }

  Future<void> renameTranscription(String tid, String newName) async {
    final uri = Uri.parse('$_baseUrl/api/rename/$tid/');
    final response = await http.post(
      uri,
      headers: _buildHeaders(isJson: true),
      body: jsonEncode({'new_name': newName}),
    );
    _extractCookies(response);
    if (response.statusCode != 200) {
      throw Exception('Failed to rename transcription');
    }
  }

  Future<void> deleteTranscription(String tid) async {
    final uri = Uri.parse('$_baseUrl/api/delete/$tid/');
    final response = await http.post(uri, headers: _buildHeaders(isJson: true));
    _extractCookies(response);
    if (response.statusCode != 200) {
      throw Exception('Failed to delete transcription');
    }
  }

  String getAudioStreamUrl(String tid) {
    return '$_baseUrl/api/stream_audio/$tid/';
  }

  // ===================== REAL-TIME STREAMING =====================

  Future<void> streamWarmup() async {
    try {
      final uri = Uri.parse('$_baseUrl/api/stream_warmup/');
      await http.get(uri, headers: _buildHeaders(isJson: false));
    } catch (_) {}
  }

  Future<Map<String, dynamic>> streamChunk({
    required List<int> audioBytes,
    required String sessionId,
    String language = 'Luganda',
    bool isContinuous = false,
    String filename = 'chunk.m4a',
  }) async {
    final uri = Uri.parse('$_baseUrl/api/stream_transcribe_chunk/');
    final request = http.MultipartRequest('POST', uri);
    request.headers.addAll(_buildHeaders(isJson: false));

    request.fields['session_id'] = sessionId;
    request.fields['language'] = language;
    request.fields['is_continuous'] = isContinuous ? 'true' : 'false';

    final mediaType = filename.endsWith('.wav')
        ? MediaType('audio', 'wav')
        : MediaType('audio', 'mp4');

    request.files.add(http.MultipartFile.fromBytes(
      'audio_chunk',
      audioBytes,
      filename: filename,
      contentType: mediaType,
    ));

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<String> saveStreamSession({
    required String title,
    required String language,
    required List<Map<String, dynamic>> messages,
  }) async {
    final uri = Uri.parse('$_baseUrl/api/save_stream_session/');
    final response = await http.post(
      uri,
      headers: _buildHeaders(isJson: true),
      body: jsonEncode({
        'title': title,
        'language': language,
        'messages': messages,
      }),
    );
    final data = jsonDecode(response.body);
    if (data['success'] != true) {
      throw Exception(data['error'] ?? 'Failed to save stream session');
    }
    return data['id']?.toString() ?? '';
  }

  // ===================== ANALYTICS & USER MANAGEMENT =====================

  Future<DashboardStats> getDashboardStats({String range = 'all', String userId = 'all'}) async {
    final uri = Uri.parse('$_baseUrl/api/dashboard/stats/?range=$range&user_id=$userId');
    final response = await http.get(uri, headers: _buildHeaders(isJson: false));
    if (response.statusCode == 403) {
      throw Exception('ADMIN_REQUIRED');
    }
    if (response.statusCode != 200) {
      throw Exception('Failed to load analytics (${response.statusCode})');
    }
    final data = jsonDecode(response.body);
    return DashboardStats.fromJson(data);
  }

  Future<List<DashboardUserItem>> getDashboardUsers() async {
    final uri = Uri.parse('$_baseUrl/api/dashboard/users/');
    final response = await http.get(uri, headers: _buildHeaders(isJson: false));
    if (response.statusCode == 403) {
      throw Exception('ADMIN_REQUIRED');
    }
    final data = jsonDecode(response.body);
    final list = (data['users'] as List? ?? [])
        .map((u) => DashboardUserItem.fromJson(u))
        .toList();
    return list;
  }

  Future<void> createDashboardUser(String username, String email, String password, bool isAdmin) async {
    final uri = Uri.parse('$_baseUrl/api/dashboard/users/create/');
    final response = await http.post(
      uri,
      headers: _buildHeaders(isJson: true),
      body: jsonEncode({
        'username': username,
        'email': email,
        'password': password,
        'is_admin': isAdmin,
      }),
    );
    final data = jsonDecode(response.body);
    if (data['success'] != true) {
      throw Exception(data['error'] ?? 'Failed to create user');
    }
  }

  Future<void> toggleUserStatus(int userId) async {
    final uri = Uri.parse('$_baseUrl/api/dashboard/users/toggle_status/$userId/');
    await http.post(uri, headers: _buildHeaders(isJson: true));
  }

  Future<void> toggleUserRole(int userId) async {
    final uri = Uri.parse('$_baseUrl/api/dashboard/users/toggle_role/$userId/');
    await http.post(uri, headers: _buildHeaders(isJson: true));
  }

  Future<void> deleteDashboardUser(int userId) async {
    final uri = Uri.parse('$_baseUrl/api/dashboard/users/delete/$userId/');
    await http.post(uri, headers: _buildHeaders(isJson: true));
  }
}
