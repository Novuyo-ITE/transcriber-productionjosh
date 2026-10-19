import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';

class AuthProvider extends ChangeNotifier {
  bool _isAuthenticated = false;
  String _username = '';
  String _email = '';
  bool _isAdmin = false;
  bool _isLoading = false;
  String? _authError;

  bool get isAuthenticated => _isAuthenticated;
  String get username => _username;
  String get email => _email;
  bool get isAdmin => _isAdmin;
  bool get isLoading => _isLoading;
  String? get authError => _authError;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _isAuthenticated = prefs.getBool('auth_authenticated') ?? false;
    _username = prefs.getString('auth_username') ?? '';
    _email = prefs.getString('auth_email') ?? '';
    _isAdmin = _username.toLowerCase() == 'gideoni';

    // Seamless auto-redirect to login if Django session expires
    ApiService().onUnauthorized = forceLogout;

    notifyListeners();
  }

  void forceLogout() {
    if (!_isAuthenticated) return;
    _isAuthenticated = false;
    _username = '';
    _email = '';
    _isAdmin = false;
    _authError = 'Session expired. Please sign in to continue.';
    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool('auth_authenticated', false);
      prefs.remove('auth_username');
      prefs.remove('auth_email');
    });
    notifyListeners();
  }

  Future<bool> login(String user, String pass) async {
    _isLoading = true;
    _authError = null;
    notifyListeners();

    try {
      final res = await ApiService().login(user, pass);
      if (res['success'] == true) {
        _isAuthenticated = true;
        _username = res['username'] ?? user;
        _email = res['email'] ?? '';
        _isAdmin = _username.toLowerCase() == 'gideoni';
        _authError = null;

        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('auth_authenticated', true);
        await prefs.setString('auth_username', _username);
        await prefs.setString('auth_email', _email);

        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        _authError = res['error'] ?? 'Invalid username or password';
      }
    } catch (e) {
      debugPrint('Login error: $e');
      _authError = 'Connection error: $e';
    }

    _isLoading = false;
    notifyListeners();
    return false;
  }

  Future<bool> register(String user, String em, String pass) async {
    _isLoading = true;
    _authError = null;
    notifyListeners();

    try {
      final res = await ApiService().register(user, em, pass);
      if (res['success'] == true) {
        _isAuthenticated = true;
        _username = res['username'] ?? user;
        _email = res['email'] ?? em;
        _isAdmin = _username.toLowerCase() == 'gideoni';
        _authError = null;

        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('auth_authenticated', true);
        await prefs.setString('auth_username', _username);
        await prefs.setString('auth_email', _email);

        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        _authError = res['error'] ?? 'Registration failed';
      }
    } catch (e) {
      debugPrint('Registration error: $e');
      _authError = 'Connection error: $e';
    }

    _isLoading = false;
    notifyListeners();
    return false;
  }

  Future<void> logout() async {
    await ApiService().logout();
    _isAuthenticated = false;
    _username = '';
    _email = '';
    _isAdmin = false;
    _authError = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_authenticated');
    await prefs.remove('auth_username');
    await prefs.remove('auth_email');

    notifyListeners();
  }
}
