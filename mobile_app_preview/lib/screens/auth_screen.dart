import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../services/auth_api.dart';
import '../services/legal_links.dart';
import '../theme/app_theme.dart';

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

  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _passwordAgainCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _initBackgroundVideo();
  }

  Future<void> _initBackgroundVideo() async {
    final controller = VideoPlayerController.asset('assets/video/dm_teaser.mp4');
    try {
      await controller.setLooping(true);
      await controller.setVolume(0);
      await controller.initialize();
      if (!mounted || _screenClosed) {
        if (_bgVideoController == controller) _bgVideoController = null;
        await controller.dispose();
        return;
      }
      _bgVideoController = controller;
      await controller.play();
      if (!mounted || _screenClosed) {
        if (_bgVideoController == controller) _bgVideoController = null;
        await controller.dispose();
        return;
      }
      setState(() => _bgVideoReady = true);
    } catch (_) {
      if (_bgVideoController == controller) _bgVideoController = null;
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
      final ok = await launchUrl(_forgotPasswordUri, mode: LaunchMode.externalApplication);
      if (ok) return;
    } catch (_) {
    }
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
        // iOS dışında clientId gönderilirse Android'de sign_in_failed (code 10) oluşabiliyor.
        clientId: isIOS ? iosClientId : null,
      );
      // Farkli hesapla giris yapabilmek icin onceki Google oturumunu temizle.
      // Boylece Android tarafinda son hesapla otomatik giris yerine hesap secimi acilir.
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
    } on PlatformException catch (e) {
      if (!mounted) return;
      final raw = '${e.code}: ${e.message ?? ''}'.trim();
      final looksLikeCode10 = raw.contains(': 10') || raw.contains('10:') || raw.toLowerCase().contains('sign_in_failed');
      setState(
        () => _error = looksLikeCode10
            ? 'Google Android yapılandırması eksik/uyuşmuyor (SHA-1 + server client id).'
            : 'Google ile giriş başarısız: $raw',
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

  @override
  Widget build(BuildContext context) {
    final bgVideo = _bgVideoController;
    final theme = Theme.of(context);
    return Scaffold(
      body: Stack(
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
            const ColoredBox(color: AppTheme.bgPrimary),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  AppTheme.bgDeep.withOpacity(0.24),
                  AppTheme.bgPrimary.withOpacity(0.82),
                  AppTheme.bgDeep,
                ],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0, -0.9),
                radius: 1.15,
                colors: [
                  AppTheme.violet.withOpacity(0.22),
                  AppTheme.pink.withOpacity(0.1),
                  Colors.transparent,
                ],
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Container(
                    decoration: AppTheme.glassPanel(tone: AppTone.discover, radius: 28),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Center(
                              child: Container(
                                width: 84,
                                height: 84,
                                padding: const EdgeInsets.all(10),
                                decoration: AppTheme.glowCircle(tone: AppTone.discover, radius: 24),
                                child: Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(22),
                                    color: AppTheme.bgDeep.withOpacity(0.94),
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(16),
                                    child: Image.asset(
                                      'assets/icons/dm.png',
                                      fit: BoxFit.cover,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 14),
                            Text(
                              'Dansmagazin',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontSize: 28,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _isRegister ? 'Topluluğa katıl ve ritmi içeriden yaşa' : 'Dans gündemine, gecelere ve fotoğraflara bağlan',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: AppTheme.textSecondary,
                                fontSize: 13,
                                height: 1.4,
                              ),
                            ),
                            const SizedBox(height: 18),
                            Container(
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                color: AppTheme.surfacePrimary.withOpacity(0.92),
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(color: AppTheme.borderSoft),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: _modePill(
                                      label: 'Giriş Yap',
                                      selected: !_isRegister,
                                      onTap: () => setState(() => _isRegister = false),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: _modePill(
                                      label: 'Kayıt Ol',
                                      selected: _isRegister,
                                      onTap: () => setState(() => _isRegister = true),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 18),
                            if (_isRegister) ...[
                              _field(
                                _nameCtrl,
                                label: 'Ad Soyad',
                                validator: (v) => (v ?? '').trim().isEmpty ? 'Ad soyad zorunlu' : null,
                              ),
                              const SizedBox(height: 12),
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
                            const SizedBox(height: 12),
                            _field(
                              _passwordCtrl,
                              label: 'Şifre',
                              obscureText: _obscurePassword,
                              suffixIcon: IconButton(
                                onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                                icon: Icon(
                                  _obscurePassword ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                                  color: AppTheme.textSecondary,
                                ),
                              ),
                              validator: (v) => (v ?? '').length < 6 ? 'Şifre en az 6 karakter olmalı' : null,
                            ),
                            if (_isRegister) ...[
                              const SizedBox(height: 12),
                              _field(
                                _passwordAgainCtrl,
                                label: 'Şifre Tekrar',
                                obscureText: _obscurePasswordAgain,
                                suffixIcon: IconButton(
                                  onPressed: () => setState(() => _obscurePasswordAgain = !_obscurePasswordAgain),
                                  icon: Icon(
                                    _obscurePasswordAgain
                                        ? Icons.visibility_off_rounded
                                        : Icons.visibility_rounded,
                                    color: AppTheme.textSecondary,
                                  ),
                                ),
                                validator: (v) => v != _passwordCtrl.text ? 'Şifreler eşleşmiyor' : null,
                              ),
                            ],
                            const SizedBox(height: 8),
                            if (_error != null) ...[
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                decoration: AppTheme.panel(tone: AppTone.danger, radius: 16, subtle: true),
                                child: Text(
                                  _error!,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: AppTheme.textPrimary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 10),
                            ],
                            Row(
                              children: [
                                Checkbox(
                                  value: _rememberMe,
                                  onChanged: (v) => setState(() => _rememberMe = v ?? true),
                                  visualDensity: VisualDensity.compact,
                                ),
                                Text(
                                  'Beni hatırla',
                                  style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
                                ),
                                const Spacer(),
                                if (!_isRegister)
                                  TextButton(
                                    onPressed: _loading ? null : _openForgotPassword,
                                    child: const Text('Şifremi Unuttum'),
                                  ),
                              ],
                            ),
                            if (_isRegister) ...[
                              const SizedBox(height: 2),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Checkbox(
                                    value: _acceptedLegal,
                                    onChanged: (v) => setState(() => _acceptedLegal = v ?? false),
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  Expanded(
                                    child: Text(
                                      'Yasal metinleri okudum ve kabul ediyorum',
                                      style: theme.textTheme.bodySmall?.copyWith(
                                        color: AppTheme.textSecondary,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              Wrap(
                                spacing: 4,
                                runSpacing: 0,
                                alignment: WrapAlignment.center,
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
                            const SizedBox(height: 8),
                            SizedBox(
                              height: 54,
                              child: ElevatedButton(
                                onPressed: _loading ? null : _submit,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppTheme.violet,
                                  foregroundColor: AppTheme.textPrimary,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                                ),
                                child: _loading
                                    ? const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                      )
                                    : Text(
                                        _isRegister ? 'Kayıt Ol' : 'Giriş Yap',
                                        style: theme.textTheme.labelLarge?.copyWith(fontSize: 16),
                                      ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            SizedBox(
                              height: 54,
                              child: OutlinedButton.icon(
                                onPressed: _loading ? null : _openAppleLogin,
                                style: OutlinedButton.styleFrom(
                                  backgroundColor: AppTheme.surfacePrimary.withOpacity(0.92),
                                  side: BorderSide(color: AppTheme.borderStrong.withOpacity(0.9)),
                                ),
                                icon: const Icon(Icons.apple),
                                label: const Text(
                                  'Apple ile Giriş Yap',
                                  style: TextStyle(fontWeight: FontWeight.w700),
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            SizedBox(
                              height: 54,
                              child: OutlinedButton.icon(
                                onPressed: _loading ? null : _openGoogleLogin,
                                style: OutlinedButton.styleFrom(
                                  backgroundColor: AppTheme.surfacePrimary.withOpacity(0.92),
                                  side: BorderSide(color: AppTheme.borderStrong.withOpacity(0.9)),
                                ),
                                icon: const Icon(Icons.login_rounded),
                                label: const Text(
                                  'Google ile Giriş Yap',
                                  style: TextStyle(fontWeight: FontWeight.w700),
                                ),
                              ),
                            ),
                            if (widget.allowGuest) ...[
                              const SizedBox(height: 10),
                              SizedBox(
                                width: double.infinity,
                                height: 54,
                                child: ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppTheme.surfaceElevated,
                                    foregroundColor: AppTheme.textPrimary,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(18),
                                      side: BorderSide(color: AppTheme.borderStrong.withOpacity(0.8)),
                                    ),
                                  ),
                                  onPressed: _loading
                                      ? null
                                      : () {
                                          Navigator.of(context).pop(
                                            const AuthResult(action: AuthAction.guest),
                                          );
                                        },
                                  icon: const Icon(Icons.explore_outlined),
                                  label: const Text(
                                    'Kayıt Olmadan Devam Et',
                                    style: TextStyle(fontWeight: FontWeight.w700),
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 10),
                            Text(
                              'Build: $_buildSha',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: AppTheme.textTertiary,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
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
          ),
        ],
      ),
    );
  }

  Widget _modePill({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: selected
              ? const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [AppTheme.pink, AppTheme.violet],
                )
              : null,
          color: selected ? null : Colors.transparent,
          border: selected ? null : Border.all(color: Colors.transparent),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: selected ? AppTheme.textPrimary : AppTheme.textSecondary,
            fontWeight: FontWeight.w800,
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
      style: const TextStyle(
        color: AppTheme.textPrimary,
        fontWeight: FontWeight.w600,
      ),
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: suffixIcon,
      ),
    );
  }
}
