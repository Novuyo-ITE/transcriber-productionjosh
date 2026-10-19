import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';

class ThemeProvider extends ChangeNotifier {
  bool _isDark = true;
  String _serverUrl = ApiService().baseUrl;

  bool get isDark => _isDark;
  String get serverUrl => _serverUrl;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _isDark = prefs.getBool('is_dark_mode') ?? true;
    _serverUrl = ApiService().baseUrl;
    notifyListeners();
  }

  Future<void> toggleTheme() async {
    _isDark = !_isDark;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_dark_mode', _isDark);
    notifyListeners();
  }

  Future<void> updateServerUrl(String newUrl) async {
    await ApiService().setBaseUrl(newUrl);
    _serverUrl = ApiService().baseUrl;
    notifyListeners();
  }
}
