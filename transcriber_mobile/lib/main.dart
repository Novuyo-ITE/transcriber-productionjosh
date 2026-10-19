import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'providers/auth_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/transcription_provider.dart';
import 'services/api_service.dart';
import 'theme/app_theme.dart';
import 'screens/main_shell.dart';
import 'screens/auth_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Set system navigation overlay styling
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF030712),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  // Initialize persistent API cookies and base URL
  await ApiService().init();

  final themeProvider = ThemeProvider();
  await themeProvider.init();

  final authProvider = AuthProvider();
  await authProvider.init();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: themeProvider),
        ChangeNotifierProvider.value(value: authProvider),
        ChangeNotifierProvider(create: (_) => TranscriptionProvider()),
      ],
      child: const NovuscribeApp(),
    ),
  );
}

class NovuscribeApp extends StatelessWidget {
  const NovuscribeApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeProv = context.watch<ThemeProvider>();
    final authProv = context.watch<AuthProvider>();

    return MaterialApp(
      title: 'Novuscribe',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeProv.isDark ? ThemeMode.dark : ThemeMode.light,
      home: authProv.isAuthenticated ? const MainShell() : const AuthScreen(),
    );
  }
}
