import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../services/auth_api.dart';
import '../services/app_settings.dart';
import '../services/legal_links.dart';
import '../services/profile_api.dart';

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
  static final Uri _forgotPasswordUri =
      Uri.parse('https://api2.dansmagazin.net/auth/password-reset');
  static const String _buildSha =
      String.fromEnvironment('APP_BUILD_SHA', defaultValue: 'local');
  static const String _googleServerClientId =
      String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID', defaultValue: '');
  static const String _googleServerClientIdFallback =
      '715936767290-0urophgn1ao2e9rsiibhg2lnao96n9af.apps.googleusercontent.com';
  static const String _googleIosClientId =
      String.fromEnvironment('GOOGLE_IOS_CLIENT_ID', defaultValue: '');
  static const String _googleIosClientIdFallback =
      '715936767290-bfqnn4arpk5vkka6f703i0ippnfhr9bs.apps.googleusercontent.com';

  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _passwordAgainCtrl = TextEditingController();

  bool _isRegister = false;
  bool _rememberMe = true;
  bool _obscurePassword = true;
  bool _obscurePasswordAgain = true;
  bool _loading = false;
  bool _acceptedLegal = false;
  String? _error;
  VideoPlayerController? _bgVideoController;
  bool _bgVideoReady = false;
  bool _screenClosed = false;

  String _text(String tr, String en, String es) {
    switch (AppSettings.language.value) {
      case 'en':
        return en;
      case 'es':
        return es;
      default:
        return tr;
    }
  }

  Future<void> _setLanguage(String language) async {
    if (_loading || AppSettings.language.value == language) return;
    await AppSettings.setLanguage(language);
    if (!mounted) return;
    setState(() => _error = null);
  }

  Future<void> _syncSelectedLanguage(String sessionToken) async {
    if (sessionToken.trim().isEmpty) return;
    try {
      await ProfileApi.updateSettings(
        sessionToken: sessionToken,
        language: AppSettings.language.value,
      );
    } catch (_) {
      // Local language selection remains valid if profile sync is temporarily unavailable.
    }
  }

  @override
  void initState() {
    super.initState();
    _initBackgroundVideo();
  }

  Future<void> _initBackgroundVideo() async {
    final controller =
        VideoPlayerController.asset('assets/video/dm_teaser.mp4');
    try {
      await controller.setLooping(true);
      await controller.setVolume(0);
      await controller.initialize();
      if (!mounted || _screenClosed) {
        await controller.dispose();
        return;
      }
      _bgVideoController = controller;
      await controller.play();
      if (!mounted || _screenClosed) {
        if (_bgVideoController == controller) {
          _bgVideoController = null;
        }
        await controller.dispose();
        return;
      }
      setState(() => _bgVideoReady = true);
    } catch (_) {
      if (_bgVideoController == controller) {
        _bgVideoController = null;
      }
      try {
        await controller.dispose();
      } catch (_) {}
      if (!mounted) return;
      setState(() => _bgVideoReady = false);
    }
  }

  @override
  void dispose() {
    _screenClosed = true;
    final bgVideoController = _bgVideoController;
    _bgVideoController = null;
    bgVideoController?.dispose();
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _passwordAgainCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isRegister && !_acceptedLegal) {
      setState(() => _error = _text(
            'Kayıt için yasal metinleri onaylamalısınız',
            'You must accept the legal terms to register',
            'Debes aceptar los textos legales para registrarte',
          ));
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
              email: _emailCtrl.text.trim(),
              password: _passwordCtrl.text,
              rememberMe: _rememberMe,
            );
      await _syncSelectedLanguage(session.sessionToken);
      if (!mounted) return;
      Navigator.of(context).pop(
        AuthResult(
          action: _isRegister ? AuthAction.register : AuthAction.login,
          name: session.name.trim().isEmpty
              ? session.email.split('@').first
              : session.name,
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
      setState(() => _error = _text(
            'Beklenmeyen bir hata oluştu',
            'An unexpected error occurred',
            'Se produjo un error inesperado',
          ));
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _openForgotPassword() async {
    try {
      final ok = await launchUrl(_forgotPasswordUri,
          mode: LaunchMode.inAppBrowserView);
      if (ok) return;
    } catch (_) {}
    if (!mounted) return;
    setState(() => _error = _text(
          'Şifre sıfırlama sayfası açılamadı',
          'The password reset page could not be opened',
          'No se pudo abrir la página para restablecer la contraseña',
        ));
  }

  Future<void> _openGoogleLogin() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final serverClientId = _googleServerClientId.trim().isNotEmpty
          ? _googleServerClientId.trim()
          : _googleServerClientIdFallback;
      final iosClientId = _googleIosClientId.trim().isNotEmpty
          ? _googleIosClientId.trim()
          : _googleIosClientIdFallback;
      final isIOS = Theme.of(context).platform == TargetPlatform.iOS;
      final googleSignIn = GoogleSignIn(
        scopes: const ['email', 'profile'],
        serverClientId: serverClientId,
        clientId: isIOS ? iosClientId : null,
      );
      try {
        await googleSignIn.signOut();
      } catch (_) {}
      final account = await googleSignIn.signIn();
      if (account == null) {
        if (!mounted) return;
        setState(() => _error = _text(
              'Google girişi iptal edildi',
              'Google sign-in was cancelled',
              'Se canceló el acceso con Google',
            ));
        return;
      }
      final auth = await account.authentication;
      final idToken = (auth.idToken ?? '').trim();
      if (idToken.isEmpty) {
        if (!mounted) return;
        setState(() => _error = _text(
              'Google kimlik doğrulama tokenı alınamadı',
              'Google authentication could not be completed',
              'No se pudo completar la autenticación con Google',
            ));
        return;
      }
      final session = await AuthApi.googleNativeLogin(
        idToken: idToken,
        rememberMe: _rememberMe,
      );
      await _syncSelectedLanguage(session.sessionToken);
      if (!mounted) return;
      Navigator.of(context).pop(
        AuthResult(
          action: AuthAction.login,
          name: session.name.trim().isEmpty
              ? session.email.split('@').first
              : session.name,
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
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _text(
            'Google ile giriş başarısız: $e',
            'Google sign-in failed: $e',
            'Error al acceder con Google: $e',
          ));
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _openAppleLogin() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final isAvailable = await SignInWithApple.isAvailable();
      if (!isAvailable) {
        if (!mounted) return;
        setState(() => _error = _text(
              'Apple ile giriş bu cihazda kullanılamıyor',
              'Sign in with Apple is not available on this device',
              'Iniciar sesión con Apple no está disponible en este dispositivo',
            ));
        return;
      }
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: const [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
      );
      final identityToken = (credential.identityToken ?? '').trim();
      if (identityToken.isEmpty) {
        if (!mounted) return;
        setState(() => _error = _text(
              'Apple kimlik doğrulama tokenı alınamadı',
              'Apple authentication could not be completed',
              'No se pudo completar la autenticación con Apple',
            ));
        return;
      }

      final givenName = (credential.givenName ?? '').trim();
      final familyName = (credential.familyName ?? '').trim();
      final fullName = [givenName, familyName]
          .where((part) => part.isNotEmpty)
          .join(' ')
          .trim();

      final session = await AuthApi.appleNativeLogin(
        identityToken: identityToken,
        appleUser: (credential.userIdentifier ?? '').trim(),
        email: (credential.email ?? '').trim(),
        name: fullName,
        rememberMe: _rememberMe,
      );
      await _syncSelectedLanguage(session.sessionToken);
      if (!mounted) return;
      Navigator.of(context).pop(
        AuthResult(
          action: AuthAction.login,
          name: session.name.trim().isEmpty
              ? session.email.split('@').first
              : session.name,
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
    } on SignInWithAppleAuthorizationException catch (e) {
      if (!mounted) return;
      final message = e.code == AuthorizationErrorCode.canceled
          ? _text('Apple girişi iptal edildi', 'Apple sign-in was cancelled',
              'Se canceló el acceso con Apple')
          : _text(
              'Apple ile giriş başarısız: ${e.message ?? e.code.name}',
              'Apple sign-in failed: ${e.message ?? e.code.name}',
              'Error al acceder con Apple: ${e.message ?? e.code.name}',
            );
      setState(() => _error = message);
    } on AuthApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _text(
            'Apple ile giriş başarısız: $e',
            'Apple sign-in failed: $e',
            'Error al acceder con Apple: $e',
          ));
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _openLegalLink(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.inAppBrowserView);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = _text(
            'Yasal bağlantı açılamadı',
            'The legal document could not be opened',
            'No se pudo abrir el documento legal',
          ));
    }
  }

  InputDecoration _inputDecoration({
    required String hint,
    Widget? suffixIcon,
  }) {
    final fillColor = Colors.white;
    final hintColor = const Color(0xFF6B7280);

    return InputDecoration(
      hintText: hint,
      hintStyle: GoogleFonts.manrope(
        color: hintColor,
        fontSize: 13,
        fontWeight: FontWeight.w500,
      ),
      filled: true,
      fillColor: fillColor,
      suffixIcon: suffixIcon,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: Colors.white.withOpacity(0.10)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFF8B5CF6)),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: Colors.redAccent.withOpacity(0.75)),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: Colors.redAccent.withOpacity(0.75)),
      ),
      errorStyle: GoogleFonts.manrope(
        color: const Color(0xFFFFB4B4),
        fontSize: 11,
        fontWeight: FontWeight.w700,
      ),
    );
  }

  Widget _buildInputField({
    required TextEditingController controller,
    required String hint,
    String? label,
    String? Function(String?)? validator,
    bool obscureText = false,
    TextInputType? keyboardType,
    Widget? suffixIcon,
  }) {
    const textColor = Color(0xFF171717);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null) ...[
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 5),
            child: Text(
              label,
              style: GoogleFonts.manrope(
                color: Colors.white.withOpacity(0.70),
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.5,
              ),
            ),
          ),
        ],
        TextFormField(
          controller: controller,
          validator: validator,
          obscureText: obscureText,
          keyboardType: keyboardType,
          onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
          style: GoogleFonts.manrope(
            color: textColor,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
          decoration: _inputDecoration(hint: hint, suffixIcon: suffixIcon),
        ),
      ],
    );
  }

  Widget _buildActionButton({
    required String label,
    required VoidCallback? onTap,
  }) {
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: const LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [Color(0xFF8B5CF6), Color(0xFFEC4899)],
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF8B5CF6).withOpacity(0.22),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ElevatedButton(
          onPressed: onTap,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.transparent,
            shadowColor: Colors.transparent,
            foregroundColor: Colors.white,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          ),
          child: _loading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : Text(
                  label,
                  style: GoogleFonts.epilogue(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
        ),
      ),
    );
  }

  Widget _buildSocialButton({
    required Widget icon,
    required String label,
    required VoidCallback? onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          height: 50,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withOpacity(0.10)),
            color: Colors.white.withOpacity(0.02),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              icon,
              const SizedBox(width: 8),
              Text(
                label,
                style: GoogleFonts.manrope(
                  color: Colors.white.withOpacity(0.82),
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDivider() {
    return Row(
      children: [
        Expanded(
            child:
                Divider(color: Colors.white.withOpacity(0.24), thickness: 1)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text(
            _text('VEYA', 'OR', 'O'),
            style: GoogleFonts.manrope(
              color: Colors.white.withOpacity(0.56),
              fontSize: 10,
              fontWeight: FontWeight.w900,
              letterSpacing: 2.0,
            ),
          ),
        ),
        Expanded(
            child:
                Divider(color: Colors.white.withOpacity(0.24), thickness: 1)),
      ],
    );
  }

  Widget _buildLanguageSelector() {
    const languages = <(String, String, String)>[
      ('tr', '🇹🇷', 'Türkiye, Türkçe'),
      ('en', '🇬🇧', 'United Kingdom, English'),
      ('es', '🇪🇸', 'España, Español'),
    ];
    final selected = AppSettings.language.value;
    return Semantics(
      label: _text('Dil seçimi', 'Language selection', 'Selección de idioma'),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 9),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.30),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withOpacity(0.18)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF59E0B).withOpacity(0.16),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: const Icon(
                    Icons.language_rounded,
                    color: Color(0xFFFBBF24),
                    size: 18,
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _text(
                          'Uygulama dilini seçin',
                          'Choose app language',
                          'Elige el idioma',
                        ),
                        style: GoogleFonts.manrope(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        'Dil • Language • Idioma',
                        style: GoogleFonts.manrope(
                          color: Colors.white.withOpacity(0.55),
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 9),
            Row(
              children: [
                for (var index = 0; index < languages.length; index++) ...[
                  if (index > 0) const SizedBox(width: 6),
                  Expanded(
                    child: Builder(
                      builder: (context) {
                        final language = languages[index];
                        final isSelected = selected == language.$1;
                        return Semantics(
                          button: true,
                          selected: isSelected,
                          label: language.$3,
                          child: Material(
                            color: isSelected
                                ? const Color(0xFFF59E0B).withOpacity(0.18)
                                : Colors.white.withOpacity(0.055),
                            borderRadius: BorderRadius.circular(12),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: _loading
                                  ? null
                                  : () => _setLanguage(language.$1),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                height: 54,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: isSelected
                                        ? const Color(0xFFFBBF24)
                                        : Colors.white.withOpacity(0.12),
                                    width: isSelected ? 1.4 : 1,
                                  ),
                                ),
                                child: Stack(
                                  children: [
                                    Align(
                                      alignment: Alignment.center,
                                      child: Text(
                                        language.$2,
                                        style: const TextStyle(fontSize: 28),
                                      ),
                                    ),
                                    if (isSelected)
                                      const Align(
                                        alignment: Alignment.topRight,
                                        child: Icon(
                                          Icons.check_circle_rounded,
                                          color: Color(0xFFFBBF24),
                                          size: 15,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorBox() {
    if (_error == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF5A1220).withOpacity(0.36),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.redAccent.withOpacity(0.28)),
      ),
      child: Text(
        _error!,
        style: GoogleFonts.manrope(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildLoginForm(bool showAppleSignIn) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildInputField(
          controller: _emailCtrl,
          hint:
              _text('e-posta@adresiniz.com', 'your@email.com', 'tu@correo.com'),
          label: _text('E-POSTA', 'EMAIL', 'CORREO'),
          keyboardType: TextInputType.emailAddress,
          validator: (v) {
            final value = (v ?? '').trim();
            if (value.isEmpty || !value.contains('@')) {
              return _text('Geçerli e-posta girin', 'Enter a valid email',
                  'Introduce un correo válido');
            }
            return null;
          },
        ),
        const SizedBox(height: 12),
        _buildInputField(
          controller: _passwordCtrl,
          hint: '••••••••',
          label: _text('ŞİFRE', 'PASSWORD', 'CONTRASEÑA'),
          obscureText: _obscurePassword,
          suffixIcon: IconButton(
            onPressed: () =>
                setState(() => _obscurePassword = !_obscurePassword),
            icon: Icon(
              _obscurePassword
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              color: const Color(0xFF6B7280),
              size: 20,
            ),
          ),
          validator: (v) => (v ?? '').length < 6
              ? _text(
                  'Şifre en az 6 karakter olmalı',
                  'Password must be at least 6 characters',
                  'La contraseña debe tener al menos 6 caracteres',
                )
              : null,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Checkbox(
                    value: _rememberMe,
                    onChanged: _loading
                        ? null
                        : (v) => setState(() => _rememberMe = v ?? true),
                    visualDensity: VisualDensity.compact,
                  ),
                  Flexible(
                    child: Text(
                      _text('Beni Hatırla', 'Remember me', 'Recordarme'),
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.manrope(
                        color: Colors.white.withOpacity(0.74),
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: _loading ? null : _openForgotPassword,
              style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6)),
              child: Text(
                _text('Şifremi Unuttum', 'Forgot password',
                    'Olvidé mi contraseña'),
                style: GoogleFonts.manrope(
                  color: Colors.white.withOpacity(0.42),
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                ),
              ),
            ),
          ],
        ),
        _buildErrorBox(),
        if (_error != null) const SizedBox(height: 12),
        _buildActionButton(
          label: _text('Giriş Yap', 'Sign in', 'Iniciar sesión'),
          onTap: _loading ? null : _submit,
        ),
        const SizedBox(height: 16),
        _buildDivider(),
        const SizedBox(height: 14),
        Row(
          children: [
            if (showAppleSignIn) ...[
              Expanded(
                child: _buildSocialButton(
                  icon: const Icon(Icons.apple, color: Colors.white, size: 20),
                  label: 'Apple',
                  onTap: _loading ? null : _openAppleLogin,
                ),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: _buildSocialButton(
                icon: _googleAuthBadge(),
                label: 'Google',
                onTap: _loading ? null : _openGoogleLogin,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildRegisterForm(bool showAppleSignIn) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildInputField(
          controller: _nameCtrl,
          hint: _text('AD SOYAD', 'FULL NAME', 'NOMBRE COMPLETO'),
          validator: (v) => (v ?? '').trim().isEmpty
              ? _text('Ad soyad zorunlu', 'Full name is required',
                  'El nombre completo es obligatorio')
              : null,
        ),
        const SizedBox(height: 10),
        _buildInputField(
          controller: _emailCtrl,
          hint: _text('E-POSTA', 'EMAIL', 'CORREO'),
          keyboardType: TextInputType.emailAddress,
          validator: (v) {
            final value = (v ?? '').trim();
            if (value.isEmpty || !value.contains('@')) {
              return _text('Geçerli e-posta girin', 'Enter a valid email',
                  'Introduce un correo válido');
            }
            return null;
          },
        ),
        const SizedBox(height: 10),
        _buildInputField(
          controller: _passwordCtrl,
          hint: _text('ŞİFRE', 'PASSWORD', 'CONTRASEÑA'),
          obscureText: _obscurePassword,
          suffixIcon: IconButton(
            onPressed: () =>
                setState(() => _obscurePassword = !_obscurePassword),
            icon: const Icon(
              Icons.visibility_outlined,
              color: Color(0xFF6B7280),
              size: 20,
            ),
          ),
          validator: (v) => (v ?? '').length < 6
              ? _text(
                  'Şifre en az 6 karakter olmalı',
                  'Password must be at least 6 characters',
                  'La contraseña debe tener al menos 6 caracteres',
                )
              : null,
        ),
        const SizedBox(height: 10),
        _buildInputField(
          controller: _passwordAgainCtrl,
          hint: _text('ŞİFRE TEKRAR', 'REPEAT PASSWORD', 'REPETIR CONTRASEÑA'),
          obscureText: _obscurePasswordAgain,
          suffixIcon: IconButton(
            onPressed: () =>
                setState(() => _obscurePasswordAgain = !_obscurePasswordAgain),
            icon: const Icon(
              Icons.visibility_outlined,
              color: Color(0xFF6B7280),
              size: 20,
            ),
          ),
          validator: (v) => v != _passwordCtrl.text
              ? _text('Şifreler eşleşmiyor', 'Passwords do not match',
                  'Las contraseñas no coinciden')
              : null,
        ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: _acceptedLegal,
              onChanged: _loading
                  ? null
                  : (v) => setState(() => _acceptedLegal = v ?? false),
              visualDensity: VisualDensity.compact,
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text.rich(
                  TextSpan(
                    text: _text(
                      'Yasal metinleri okudum ve kabul ettim. ',
                      'I have read and accept the legal terms. ',
                      'He leído y acepto los textos legales. ',
                    ),
                    style: GoogleFonts.manrope(
                      color: Colors.white.withOpacity(0.52),
                      fontSize: 11,
                      height: 1.4,
                      fontWeight: FontWeight.w600,
                    ),
                    children: [
                      _legalLinkSpan(_text('Gizlilik', 'Privacy', 'Privacidad'),
                          LegalLinks.privacyPolicy),
                      const TextSpan(text: ', '),
                      _legalLinkSpan('KVKK', LegalLinks.kvkkNotice),
                      TextSpan(text: _text(' ve ', ' and ', ' y ')),
                      _legalLinkSpan(
                        _text('Kullanım Şartları', 'Terms of Use',
                            'Términos de uso'),
                        LegalLinks.terms,
                      ),
                      const TextSpan(text: '.'),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        _buildErrorBox(),
        if (_error != null) const SizedBox(height: 12),
        _buildActionButton(
          label: _text('Hesap Oluştur', 'Create account', 'Crear cuenta'),
          onTap: _loading ? null : _submit,
        ),
        const SizedBox(height: 14),
        _buildDivider(),
        const SizedBox(height: 12),
        Row(
          children: [
            if (showAppleSignIn) ...[
              Expanded(
                child: _buildSocialButton(
                  icon: const Icon(Icons.apple, color: Colors.white, size: 20),
                  label: 'Apple',
                  onTap: _loading ? null : _openAppleLogin,
                ),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: _buildSocialButton(
                icon: _googleAuthBadge(),
                label: 'Google',
                onTap: _loading ? null : _openGoogleLogin,
              ),
            ),
          ],
        ),
      ],
    );
  }

  InlineSpan _legalLinkSpan(String label, String url) {
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: GestureDetector(
        onTap: () => _openLegalLink(url),
        child: Text(
          label,
          style: GoogleFonts.manrope(
            color: const Color(0xFF8B5CF6),
            fontSize: 11,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final showAppleSignIn = Theme.of(context).platform == TargetPlatform.iOS;
    final bgVideo = _bgVideoController;

    return Scaffold(
      backgroundColor: const Color(0xFF0F0717),
      resizeToAvoidBottomInset: true,
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (bgVideo != null && _bgVideoReady && bgVideo.value.isInitialized)
              FittedBox(
                fit: BoxFit.cover,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: bgVideo.value.size.width,
                  height: bgVideo.value.size.height,
                  child: VideoPlayer(bgVideo),
                ),
              )
            else
              const ColoredBox(color: Color(0xFF0F0717)),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x552D1B4E),
                    Color(0xB20F0717),
                    Color(0xE60F0717),
                  ],
                ),
              ),
            ),
            Positioned(
              top: -120,
              right: -80,
              child: _BlurOrb(
                size: 280,
                colors: [
                  const Color(0xFF8B5CF6).withOpacity(0.20),
                  Colors.transparent,
                ],
              ),
            ),
            Positioned(
              bottom: -120,
              left: -60,
              child: _BlurOrb(
                size: 240,
                colors: [
                  const Color(0xFFEC4899).withOpacity(0.14),
                  Colors.transparent,
                ],
              ),
            ),
            SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 410),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(32),
                        color: Colors.white.withOpacity(0.08),
                        border:
                            Border.all(color: Colors.white.withOpacity(0.16)),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.34),
                            blurRadius: 36,
                            offset: const Offset(0, 16),
                          ),
                        ],
                      ),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildLanguageSelector(),
                            const SizedBox(height: 14),
                            Text(
                              _text(
                                'Sahne senin, Biz seninleyiz',
                                'Your stage, your community',
                                'Tu escenario, tu comunidad',
                              ),
                              textAlign: TextAlign.center,
                              style: GoogleFonts.epilogue(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w400,
                                letterSpacing: -0.2,
                              ),
                            ),
                            const SizedBox(height: 14),
                            Container(
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.04),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                    color: Colors.white.withOpacity(0.10)),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: _ModeTab(
                                      label:
                                          _text('Giriş', 'Sign in', 'Acceder'),
                                      selected: !_isRegister,
                                      onTap: _loading
                                          ? null
                                          : () => setState(
                                              () => _isRegister = false),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: _ModeTab(
                                      label: _text(
                                          'Kayıt', 'Register', 'Registro'),
                                      selected: _isRegister,
                                      onTap: _loading
                                          ? null
                                          : () => setState(
                                              () => _isRegister = true),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 14),
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 220),
                              switchInCurve: Curves.easeOut,
                              switchOutCurve: Curves.easeIn,
                              child: _isRegister
                                  ? KeyedSubtree(
                                      key: const ValueKey('register-form'),
                                      child:
                                          _buildRegisterForm(showAppleSignIn),
                                    )
                                  : KeyedSubtree(
                                      key: const ValueKey('login-form'),
                                      child: _buildLoginForm(showAppleSignIn),
                                    ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Build: $_buildSha',
                              textAlign: TextAlign.center,
                              style: GoogleFonts.manrope(
                                color: Colors.white.withOpacity(0.22),
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _googleAuthBadge() {
    return const SizedBox(
      width: 22,
      height: 22,
      child: CustomPaint(
        painter: _GoogleLogoPainter(),
      ),
    );
  }
}

class _ModeTab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  const _ModeTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: selected
                ? const LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [Color(0xFF8B5CF6), Color(0xFFEC4899)],
                  )
                : null,
            color: selected ? null : Colors.transparent,
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: GoogleFonts.manrope(
              color: Colors.white.withOpacity(selected ? 1 : 0.66),
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    );
  }
}

class _BlurOrb extends StatelessWidget {
  final double size;
  final List<Color> colors;

  const _BlurOrb({
    required this.size,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: colors),
        ),
      ),
    );
  }
}

class _GoogleLogoPainter extends CustomPainter {
  const _GoogleLogoPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final strokeWidth = size.width * 0.18;
    final rect = Rect.fromLTWH(
      strokeWidth / 2,
      strokeWidth / 2,
      size.width - strokeWidth,
      size.height - strokeWidth,
    );

    void drawArc(Color color, double startDeg, double sweepDeg) {
      canvas.drawArc(
        rect,
        math.pi * startDeg / 180,
        math.pi * sweepDeg / 180,
        false,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeCap = StrokeCap.round,
      );
    }

    drawArc(const Color(0xFFEA4335), 210, 88);
    drawArc(const Color(0xFFFBBC05), 140, 70);
    drawArc(const Color(0xFF34A853), 52, 92);
    drawArc(const Color(0xFF4285F4), -34, 94);

    final barPaint = Paint()
      ..color = const Color(0xFF4285F4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    final midY = size.height * 0.52;
    canvas.drawLine(
      Offset(size.width * 0.56, midY),
      Offset(size.width * 0.91, midY),
      barPaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
