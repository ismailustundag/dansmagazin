import 'package:flutter/material.dart';

import '../services/auth_api.dart';

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

  const AuthResult({
    required this.action,
    this.name = '',
    this.email = '',
    this.rememberMe = false,
    this.sessionToken = '',
    this.accountId = 0,
    this.wpUserId,
    this.wpRoles = const [],
  });
}

class AuthScreen extends StatefulWidget {
  final bool allowGuest;

  const AuthScreen({super.key, this.allowGuest = true});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  bool _isRegister = false;
  bool _rememberMe = true;
  bool _loading = false;
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
                  borderRadius: BorderRadius.circular(16),
                  side: const BorderSide(color: Colors.white12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'Dansmagazin',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
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
                          obscureText: true,
                          validator: (v) => (v ?? '').length < 6 ? 'Şifre en az 6 karakter olmalı' : null,
                        ),
                        if (_isRegister) ...[
                          const SizedBox(height: 10),
                          _field(
                            _passwordAgainCtrl,
                            label: 'Şifre Tekrar',
                            obscureText: true,
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
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _rememberMe,
                          onChanged: (v) => setState(() => _rememberMe = v ?? true),
                          title: const Text('Beni hatırla'),
                          controlAffinity: ListTileControlAffinity.leading,
                        ),
                        ElevatedButton(
                          onPressed: _loading ? null : _submit,
                          child: _loading
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Text(_isRegister ? 'Kayıt Ol' : 'Giriş Yap'),
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
      ),
    );
  }
}
