import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
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
  static final Uri _forgotPasswordUri = Uri.parse('https://dansmagazin.net/hesabim/lost-password/');
  static const String _buildSha = String.fromEnvironment('APP_BUILD_SHA', defaultValue: 'local');
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
              email: _emailCtrl.text.trim(),
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
      final ok = await launchUrl(_forgotPasswordUri, mode: LaunchMode.externalApplication);
      if (ok) return;
    } catch (_) {}
    if (!mounted) return;
    setState(() => _error = 'Şifre sıfırlama sayfası açılamadı');
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
      final iosClientId =
          _googleIosClientId.trim().isNotEmpty ? _googleIosClientId.trim() : _googleIosClientIdFallback;
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
        setState(() => _error = 'Google girişi iptal edildi');
        return;
      }
      final auth = await account.authentication;
      final idToken = (auth.idToken ?? '').trim();
      if (idToken.isEmpty) {
        if (!mounted) return;
        setState(() => _error = 'Google kimlik doğrulama tokenı alınamadı');
        return;
      }
      final session = await AuthApi.googleNativeLogin(
        idToken: idToken,
        rememberMe: _rememberMe,
      );
      if (!mounted) return;
      Navigator.of(context).pop(
        AuthResult(
          action: AuthAction.login,
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
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Google ile giriş başarısız: $e');
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
        setState(() => _error = 'Apple ile giriş bu cihazda kullanılamıyor');
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
        setState(() => _error = 'Apple kimlik doğrulama tokenı alınamadı');
        return;
      }

      final givenName = (credential.givenName ?? '').trim();
      final familyName = (credential.familyName ?? '').trim();
      final fullName = [givenName, familyName].where((part) => part.isNotEmpty).join(' ').trim();

      final session = await AuthApi.appleNativeLogin(
        identityToken: identityToken,
        appleUser: (credential.userIdentifier ?? '').trim(),
        email: (credential.email ?? '').trim(),
        name: fullName,
        rememberMe: _rememberMe,
      );
      if (!mounted) return;
      Navigator.of(context).pop(
        AuthResult(
          action: AuthAction.login,
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
    } on SignInWithAppleAuthorizationException catch (e) {
      if (!mounted) return;
      final message = e.code == AuthorizationErrorCode.canceled
          ? 'Apple girişi iptal edildi'
          : 'Apple ile giriş başarısız: ${e.message ?? e.code.name}';
      setState(() => _error = message);
    } on AuthApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Apple ile giriş başarısız: $e');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
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

  InputDecoration _inputDecoration({
    required String hint,
    Widget? suffixIcon,
  }) {
    final fillColor = _isRegister ? Colors.white : Colors.white.withOpacity(0.05);
    final textColor = _isRegister ? const Color(0xFF1A1A1A) : Colors.white;
    final hintColor = _isRegister ? const Color(0xFF6B7280) : Colors.white.withOpacity(0.20);

    return InputDecoration(
      hintText: hint,
      hintStyle: GoogleFonts.manrope(
        color: hintColor,
        fontSize: 14,
        fontWeight: FontWeight.w500,
      ),
      filled: true,
      fillColor: fillColor,
      suffixIcon: suffixIcon,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: Colors.white.withOpacity(0.10)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: const Color(0xFF8B5CF6).withOpacity(0.75)),
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
    final textColor = _isRegister ? const Color(0xFF171717) : Colors.white;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null) ...[
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Text(
              label,
              style: GoogleFonts.manrope(
                color: Colors.white.withOpacity(0.72),
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.6,
              ),
            ),
          ),
        ],
        TextFormField(
          controller: controller,
          validator: validator,
          obscureText: obscureText,
          keyboardType: keyboardType,
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
      height: 58,
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
              color: const Color(0xFF8B5CF6).withOpacity(0.24),
              blurRadius: 22,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: ElevatedButton(
          onPressed: onTap,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.transparent,
            shadowColor: Colors.transparent,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          ),
          child: _loading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : Text(
                  label,
                  style: GoogleFonts.epilogue(
                    fontSize: 19,
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
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          height: 54,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
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
        Expanded(child: Divider(color: Colors.white.withOpacity(0.28), thickness: 1)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            'VEYA',
            style: GoogleFonts.manrope(
              color: Colors.white.withOpacity(0.60),
              fontSize: 10,
              fontWeight: FontWeight.w900,
              letterSpacing: 2.4,
            ),
          ),
        ),
        Expanded(child: Divider(color: Colors.white.withOpacity(0.28), thickness: 1)),
      ],
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
          hint: 'e-posta@adresiniz.com',
          label: 'E-POSTA',
          keyboardType: TextInputType.emailAddress,
          validator: (v) {
            final value = (v ?? '').trim();
            if (value.isEmpty || !value.contains('@')) return 'Geçerli e-posta girin';
            return null;
          },
        ),
        const SizedBox(height: 16),
        _buildInputField(
          controller: _passwordCtrl,
          hint: '••••••••',
          label: 'ŞİFRE',
          obscureText: _obscurePassword,
          suffixIcon: IconButton(
            onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
            icon: Icon(
              _obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
              color: Colors.white.withOpacity(0.32),
              size: 20,
            ),
          ),
          validator: (v) => (v ?? '').length < 6 ? 'Şifre en az 6 karakter olmalı' : null,
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            InkWell(
              onTap: _loading ? null : () => setState(() => _rememberMe = !_rememberMe),
              child: Row(
                children: [
                  Checkbox(
                    value: _rememberMe,
                    onChanged: _loading ? null : (v) => setState(() => _rememberMe = v ?? true),
                    visualDensity: VisualDensity.compact,
                  ),
                  Text(
                    'Beni Hatırla',
                    style: GoogleFonts.manrope(
                      color: Colors.white.withOpacity(0.74),
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ),
            ),
            const Spacer(),
            TextButton(
              onPressed: _loading ? null : _openForgotPassword,
              child: Text(
                'Şifremi Unuttum',
                style: GoogleFonts.manrope(
                  color: Colors.white.withOpacity(0.42),
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.1,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        _buildErrorBox(),
        if (_error != null) const SizedBox(height: 14),
        _buildActionButton(
          label: 'Giriş Yap',
          onTap: _loading ? null : _submit,
        ),
        const SizedBox(height: 28),
        _buildDivider(),
        const SizedBox(height: 24),
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
              const SizedBox(width: 12),
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
        const SizedBox(height: 26),
        Text.rich(
          TextSpan(
            text: 'Henüz bir hesabın yok mu? ',
            style: GoogleFonts.manrope(
              color: Colors.white.withOpacity(0.42),
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
            children: [
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: GestureDetector(
                  onTap: _loading ? null : () => setState(() => _isRegister = true),
                  child: Text(
                    'Hesap oluştur',
                    style: GoogleFonts.manrope(
                      color: const Color(0xFF8B5CF6),
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ],
          ),
          textAlign: TextAlign.center,
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
          hint: 'AD SOYAD',
          validator: (v) => (v ?? '').trim().isEmpty ? 'Ad soyad zorunlu' : null,
        ),
        const SizedBox(height: 10),
        _buildInputField(
          controller: _emailCtrl,
          hint: 'E-POSTA',
          keyboardType: TextInputType.emailAddress,
          validator: (v) {
            final value = (v ?? '').trim();
            if (value.isEmpty || !value.contains('@')) return 'Geçerli e-posta girin';
            return null;
          },
        ),
        const SizedBox(height: 10),
        _buildInputField(
          controller: _passwordCtrl,
          hint: 'ŞİFRE',
          obscureText: _obscurePassword,
          suffixIcon: IconButton(
            onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
            icon: const Icon(
              Icons.visibility_outlined,
              color: Color(0xFF6B7280),
              size: 20,
            ),
          ),
          validator: (v) => (v ?? '').length < 6 ? 'Şifre en az 6 karakter olmalı' : null,
        ),
        const SizedBox(height: 10),
        _buildInputField(
          controller: _passwordAgainCtrl,
          hint: 'ŞİFRE TEKRAR',
          obscureText: _obscurePasswordAgain,
          suffixIcon: IconButton(
            onPressed: () => setState(() => _obscurePasswordAgain = !_obscurePasswordAgain),
            icon: const Icon(
              Icons.visibility_outlined,
              color: Color(0xFF6B7280),
              size: 20,
            ),
          ),
          validator: (v) => v != _passwordCtrl.text ? 'Şifreler eşleşmiyor' : null,
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: _acceptedLegal,
              onChanged: _loading ? null : (v) => setState(() => _acceptedLegal = v ?? false),
              visualDensity: VisualDensity.compact,
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text.rich(
                  TextSpan(
                    text: 'Yasal metinleri okudum ve kabul ettim. ',
                    style: GoogleFonts.manrope(
                      color: Colors.white.withOpacity(0.52),
                      fontSize: 11,
                      height: 1.45,
                      fontWeight: FontWeight.w600,
                    ),
                    children: [
                      _legalLinkSpan('Gizlilik', LegalLinks.privacyPolicy),
                      const TextSpan(text: ', '),
                      _legalLinkSpan('KVKK', LegalLinks.kvkkNotice),
                      const TextSpan(text: ' ve '),
                      _legalLinkSpan('Kullanım Şartları', LegalLinks.terms),
                      const TextSpan(text: '.'),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _buildErrorBox(),
        if (_error != null) const SizedBox(height: 14),
        _buildActionButton(
          label: 'Hesap Oluştur',
          onTap: _loading ? null : _submit,
        ),
        const SizedBox(height: 22),
        _buildDivider(),
        const SizedBox(height: 18),
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
              const SizedBox(width: 12),
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
        const SizedBox(height: 20),
        Text.rich(
          TextSpan(
            text: 'Zaten bir hesabın var mı? ',
            style: GoogleFonts.manrope(
              color: Colors.white.withOpacity(0.42),
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
            children: [
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: GestureDetector(
                  onTap: _loading ? null : () => setState(() => _isRegister = false),
                  child: Text(
                    'Giriş yap',
                    style: GoogleFonts.manrope(
                      color: const Color(0xFF8B5CF6),
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ],
          ),
          textAlign: TextAlign.center,
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

  Widget _guestButton() {
    return TextButton.icon(
      onPressed: _loading
          ? null
          : () {
              Navigator.of(context).pop(const AuthResult(action: AuthAction.guest));
            },
      icon: const Icon(Icons.explore_outlined, color: Colors.white70, size: 18),
      label: Text(
        'Kayıt olmadan devam et',
        style: GoogleFonts.manrope(
          color: Colors.white.withOpacity(0.68),
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final showAppleSignIn = Theme.of(context).platform == TargetPlatform.iOS;
    return Scaffold(
      backgroundColor: const Color(0xFF0F0717),
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.topLeft,
            radius: 1.35,
            colors: [
              Color(0xFF2D1B4E),
              Color(0xFF0F0717),
            ],
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              top: -120,
              right: -80,
              child: _BlurOrb(
                size: 280,
                colors: [
                  const Color(0xFF8B5CF6).withOpacity(0.22),
                  Colors.transparent,
                ],
              ),
            ),
            Positioned(
              bottom: -120,
              left: -60,
              child: _BlurOrb(
                size: 260,
                colors: [
                  const Color(0xFFEC4899).withOpacity(0.16),
                  Colors.transparent,
                ],
              ),
            ),
            SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(24, 30, 24, 22),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(40),
                        color: Colors.white.withOpacity(0.03),
                        border: Border.all(color: Colors.white.withOpacity(0.10)),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.34),
                            blurRadius: 40,
                            offset: const Offset(0, 18),
                          ),
                        ],
                      ),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              _isRegister ? 'Hesap Oluştur' : 'Giriş Yap',
                              textAlign: TextAlign.center,
                              style: GoogleFonts.epilogue(
                                color: Colors.white,
                                fontSize: 34,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -1.2,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _isRegister
                                  ? 'Topluluğa katıl ve ritmi içeriden yaşa.'
                                  : 'Etkinliklerin, biletlerin ve akışın için hemen giriş yap.',
                              textAlign: TextAlign.center,
                              style: GoogleFonts.manrope(
                                color: Colors.white.withOpacity(0.56),
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                height: 1.5,
                              ),
                            ),
                            const SizedBox(height: 28),
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 240),
                              switchInCurve: Curves.easeOut,
                              switchOutCurve: Curves.easeIn,
                              child: _isRegister
                                  ? KeyedSubtree(
                                      key: const ValueKey('register-form'),
                                      child: _buildRegisterForm(showAppleSignIn),
                                    )
                                  : KeyedSubtree(
                                      key: const ValueKey('login-form'),
                                      child: _buildLoginForm(showAppleSignIn),
                                    ),
                            ),
                            if (widget.allowGuest) ...[
                              const SizedBox(height: 12),
                              Center(child: _guestButton()),
                            ],
                            const SizedBox(height: 8),
                            Text(
                              'Build: $_buildSha',
                              textAlign: TextAlign.center,
                              style: GoogleFonts.manrope(
                                color: Colors.white.withOpacity(0.24),
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
