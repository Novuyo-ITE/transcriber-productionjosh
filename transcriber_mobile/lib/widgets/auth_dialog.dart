import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/transcription_provider.dart';
import '../theme/app_colors.dart';

class AuthDialog extends StatefulWidget {
  final bool initialRegister;

  const AuthDialog({super.key, this.initialRegister = false});

  @override
  State<AuthDialog> createState() => _AuthDialogState();
}

class _AuthDialogState extends State<AuthDialog> {
  late bool _isRegister;
  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _isRegister = widget.initialRegister;
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final user = _usernameController.text.trim();
    final pass = _passwordController.text.trim();
    final email = _emailController.text.trim();

    if (user.isEmpty || pass.isEmpty) {
      setState(() => _errorMessage = 'Username and password are required');
      return;
    }

    setState(() => _errorMessage = null);

    final auth = context.read<AuthProvider>();
    bool success = false;

    if (_isRegister) {
      success = await auth.register(user, email, pass);
    } else {
      success = await auth.login(user, pass);
    }

    if (success) {
      if (mounted) {
        context.read<TranscriptionProvider>().fetchHistory();
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Welcome, ${auth.username}!'),
            backgroundColor: AppColors.emeraldPrimary,
          ),
        );
      }
    } else {
      if (mounted) {
        setState(() => _errorMessage = 'Authentication failed. Please check credentials.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final auth = context.watch<AuthProvider>();

    return Dialog(
      backgroundColor: isDark ? AppColors.darkBgPanel : AppColors.lightBgPanel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: AppColors.emeraldPrimary.withOpacity(0.35)),
      ),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 380),
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Brand Logo & Header
            Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: AppColors.emeraldPrimary,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.center,
                  child: const Text(
                    'N',
                    style: TextStyle(
                      color: Color(0xFF030712),
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  _isRegister ? 'Create Novuscribe Account' : 'Sign In to Novuscribe',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),

            // Toggle Tabs
            Container(
              decoration: BoxDecoration(
                color: isDark ? Colors.white.withOpacity(0.04) : Colors.black.withOpacity(0.04),
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.all(3),
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () => setState(() {
                        _isRegister = false;
                        _errorMessage = null;
                      }),
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        decoration: BoxDecoration(
                          color: !_isRegister
                              ? (isDark ? AppColors.darkBgPanel : AppColors.lightBgPanel)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(6),
                          boxShadow: !_isRegister
                              ? [const BoxShadow(color: Colors.black26, blurRadius: 4)]
                              : null,
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          'Sign In',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: !_isRegister
                                ? AppColors.emeraldPrimary
                                : (isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: InkWell(
                      onTap: () => setState(() {
                        _isRegister = true;
                        _errorMessage = null;
                      }),
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        decoration: BoxDecoration(
                          color: _isRegister
                              ? (isDark ? AppColors.darkBgPanel : AppColors.lightBgPanel)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(6),
                          boxShadow: _isRegister
                              ? [const BoxShadow(color: Colors.black26, blurRadius: 4)]
                              : null,
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          'Sign Up',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: _isRegister
                                ? AppColors.emeraldPrimary
                                : (isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),

            if (_errorMessage != null)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.withOpacity(0.3)),
                ),
                child: Text(
                  _errorMessage!,
                  style: GoogleFonts.plusJakartaSans(fontSize: 12, color: const Color(0xFFF87171)),
                ),
              ),

            // Username
            TextField(
              controller: _usernameController,
              decoration: const InputDecoration(
                labelText: 'Username',
                hintText: 'Enter username (e.g. gideoni)',
                prefixIcon: Icon(Icons.person_outline, size: 18),
              ),
            ),
            const SizedBox(height: 12),

            // Email (if registration)
            if (_isRegister) ...[
              TextField(
                controller: _emailController,
                decoration: const InputDecoration(
                  labelText: 'Email Address (Optional)',
                  hintText: 'user@example.com',
                  prefixIcon: Icon(Icons.email_outlined, size: 18),
                ),
              ),
              const SizedBox(height: 12),
            ],

            // Password
            TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Password',
                hintText: '••••••••',
                prefixIcon: Icon(Icons.lock_outline, size: 18),
              ),
            ),
            const SizedBox(height: 20),

            // Submit Button
            ElevatedButton(
              onPressed: auth.isLoading ? null : _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.emeraldPrimary,
                foregroundColor: const Color(0xFF030712),
                padding: const EdgeInsets.symmetric(vertical: 13),
              ),
              child: auth.isLoading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF030712)),
                    )
                  : Text(
                      _isRegister ? 'Create Account' : 'Sign In',
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
