import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/auth_api.dart';
import '../services/legal_links.dart';

enum AuthAction { login, register, guest }

class AuthResult {
  final AuthAction action;
  final String name;
  final String email;
  final bool rememberMe;
  final String sessionToken;
  final int accountId;
  final int? wpUserId;
  final List<String> wpRoles;
  final String appRole;
  final bool canCreateMobileEvent;

  const AuthResult({
    required this.action,
    this.name = '',
    this.email = '',
    this.rememberMe = false,
    this.sessionToken = '',
    this.accountId = 0,
    this.wpUserId,
    this.wpRoles = const [],
    this.appRole = 'customer',
    this.canCreateMobileEvent = false,
  });
}

class AuthScreen extends StatefulWidget {
  final bool allowGuest;

  const AuthScreen({super.key, this.allowGuest = true});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  static final Uri _forgotPasswordUri = Uri.parse('https://dansmagazin.net/my-account/lost-password/');
  static const String _buildSha = String.fromEnvironment('APP_BUILD_SHA', defaultValue: 'local');
  final _formKey = GlobalKey<FormState>();
  bool _isRegister = false;
  bool _rememberMe = true;
  bool _obscurePassword = true;
  bool _obscurePasswordAgain = true;
  bool _loading = false;
  bool _acceptedLegal = false;
  String? _error;

  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _passwordAgainCtrl = TextEditingController();

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _passwordAgainCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isRegister && !_acceptedLegal) {
      setState(() => _error = 'Kayıt için yasal metinleri onaylamalısınız');
      return;
    }
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final session = _isRegister
          ? await AuthApi.register(
              email: _emailCtrl.text.trim(),
              password: _passwordCtrl.text,
              name: _nameCtrl.text.trim(),
              rememberMe: _rememberMe,
            )
          : await AuthApi.login(
              usernameOrEmail: _emailCtrl.text.trim(),
              password: _passwordCtrl.text,
              rememberMe: _rememberMe,
            );
      if (!mounted) return;
      Navigator.of(context).pop(
        AuthResult(
          action: _isRegister ? AuthAction.register : AuthAction.login,
          name: session.name.trim().isEmpty ? session.email.split('@').first : session.name,
          email: session.email,
          rememberMe: _rememberMe,
          sessionToken: session.sessionToken,
          accountId: session.accountId,
          wpUserId: session.wpUserId,
          wpRoles: session.wpRoles,
          appRole: session.appRole,
          canCreateMobileEvent: session.canCreateMobileEvent,
        ),
      );
    } on AuthApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Beklenmeyen bir hata oluştu');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _openForgotPassword() async {
    try {
      await launchUrl(_forgotPasswordUri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Şifre sıfırlama sayfası açılamadı');
    }
  }

  Future<void> _openGoogleLogin() async {
    if (_loading) return;
    setState(() => _error = null);
    try {
      final url = await AuthApi.googleLoginUrl(callbackUrl: 'https://www.dansmagazin.net/mobil-donus?mobile=1');
      final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        setState(() => _error = 'Google giriş sayfası açılamadı');
      }
    } on AuthApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Google giriş sayfası açılamadı');
    }
  }

  Future<void> _openLegalLink(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Yasal bağlantı açılamadı');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080B14),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
                child: Card(
                  color: const Color(0xFF121826),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                    side: const BorderSide(color: Colors.white12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: Image.asset(
                              'assets/icons/dm.png',
                              width: 72,
                              height: 72,
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Dansmagazin',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _isRegister ? 'Yeni hesap oluştur' : 'Giriş yap',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white.withOpacity(0.8)),
                        ),
                        const SizedBox(height: 16),
                        if (_isRegister) ...[
                          _field(
                            _nameCtrl,
                            label: 'Ad Soyad',
                            validator: (v) => (v ?? '').trim().isEmpty ? 'Ad soyad zorunlu' : null,
                          ),
                          const SizedBox(height: 10),
                        ],
                        _field(
                          _emailCtrl,
                          label: 'E-posta',
                          keyboardType: TextInputType.emailAddress,
                          validator: (v) {
                            final value = (v ?? '').trim();
                            if (value.isEmpty || !value.contains('@')) return 'Geçerli e-posta girin';
                            return null;
                          },
                        ),
                        const SizedBox(height: 10),
                        _field(
                          _passwordCtrl,
                          label: 'Şifre',
                          obscureText: _obscurePassword,
                          suffixIcon: IconButton(
                            onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                            icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                          ),
                          validator: (v) => (v ?? '').length < 6 ? 'Şifre en az 6 karakter olmalı' : null,
                        ),
                        if (_isRegister) ...[
                          const SizedBox(height: 10),
                          _field(
                            _passwordAgainCtrl,
                            label: 'Şifre Tekrar',
                            obscureText: _obscurePasswordAgain,
                            suffixIcon: IconButton(
                              onPressed: () => setState(() => _obscurePasswordAgain = !_obscurePasswordAgain),
                              icon: Icon(_obscurePasswordAgain ? Icons.visibility_off : Icons.visibility),
                            ),
                            validator: (v) => v != _passwordCtrl.text ? 'Şifreler eşleşmiyor' : null,
                          ),
                        ],
                        const SizedBox(height: 6),
                        if (_error != null) ...[
                          Text(
                            _error!,
                            style: const TextStyle(color: Colors.redAccent),
                          ),
                          const SizedBox(height: 8),
                        ],
                        Row(
                          children: [
                            Checkbox(
                              value: _rememberMe,
                              onChanged: (v) => setState(() => _rememberMe = v ?? true),
                              visualDensity: VisualDensity.compact,
                            ),
                            const Text('Beni hatırla'),
                            const Spacer(),
                            if (!_isRegister)
                              TextButton(
                                onPressed: _loading ? null : _openForgotPassword,
                                child: const Text('Şifremi Unuttum'),
                              ),
                          ],
                        ),
                        if (_isRegister) ...[
                          const SizedBox(height: 4),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Checkbox(
                                value: _acceptedLegal,
                                onChanged: (v) => setState(() => _acceptedLegal = v ?? false),
                                visualDensity: VisualDensity.compact,
                              ),
                              const Expanded(
                                child: Text(
                                  'Yasal metinleri okudum ve kabul ediyorum',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                          Wrap(
                            spacing: 8,
                            runSpacing: 0,
                            children: [
                              TextButton(
                                onPressed: () => _openLegalLink(LegalLinks.privacyPolicy),
                                child: const Text('Gizlilik'),
                              ),
                              TextButton(
                                onPressed: () => _openLegalLink(LegalLinks.kvkkNotice),
                                child: const Text('KVKK'),
                              ),
                              TextButton(
                                onPressed: () => _openLegalLink(LegalLinks.terms),
                                child: const Text('Kullanım Şartları'),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Expanded(
                              child: SizedBox(
                                height: 52,
                                child: ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFFE53935),
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  ),
                                  onPressed: _loading ? null : _submit,
                                  child: _loading
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                        )
                                      : Text(
                                          _isRegister ? 'Kayıt Ol' : 'Giriş Yap',
                                          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                                        ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: SizedBox(
                                height: 52,
                                child: OutlinedButton.icon(
                                  onPressed: _loading ? null : _openGoogleLogin,
                                  icon: const Icon(Icons.login),
                                  label: const Text(
                                    'Google',
                                    style: TextStyle(fontWeight: FontWeight.w700),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Build: $_buildSha',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.55),
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        TextButton(
                          onPressed: _loading ? null : () => setState(() => _isRegister = !_isRegister),
                          child: Text(_isRegister ? 'Hesabım var, giriş yap' : 'Hesabın yok mu? Kayıt ol'),
                        ),
                        if (widget.allowGuest) ...[
                          const SizedBox(height: 4),
                          OutlinedButton(
                            onPressed: _loading
                                ? null
                                : () {
                              Navigator.of(context).pop(
                                const AuthResult(action: AuthAction.guest),
                              );
                            },
                            child: const Text('Kayıt olmadan devam et'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController controller, {
    required String label,
    String? Function(String?)? validator,
    bool obscureText = false,
    TextInputType? keyboardType,
    Widget? suffixIcon,
  }) {
    return TextFormField(
      controller: controller,
      validator: validator,
      obscureText: obscureText,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        filled: true,
        fillColor: const Color(0xFF0F172A),
        suffixIcon: suffixIcon,
      ),
    );
  }
}
