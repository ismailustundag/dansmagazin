<?php
/**
 * Plugin Name: Dansmagazin Mobile SSO Bridge
 * Description: Mobil backend tarafindan uretilen imzali SSO token ile WP oturumu acar ve urun sayfasina yonlendirir.
 * Version: 1.0.0
 */

if (!defined('ABSPATH')) {
    exit;
}

add_action('init', function () {
    if (!isset($_GET['mobile_sso'])) {
        return;
    }

    $token = isset($_GET['sso']) ? trim((string) $_GET['sso']) : '';
    if ($token === '') {
        wp_die('SSO token eksik.', 'Mobile SSO', ['response' => 400]);
    }

    if (!defined('DANS_MOBILE_SSO_SECRET') || !DANS_MOBILE_SSO_SECRET) {
        wp_die('SSO secret tanimli degil.', 'Mobile SSO', ['response' => 500]);
    }

    $parts = explode('.', $token, 2);
    if (count($parts) !== 2) {
        wp_die('Gecersiz SSO token.', 'Mobile SSO', ['response' => 401]);
    }

    [$body_b64, $sig_b64] = $parts;

    $decode_b64url = static function (string $in) {
        $raw = strtr($in, '-_', '+/');
        $pad = strlen($raw) % 4;
        if ($pad > 0) {
            $raw .= str_repeat('=', 4 - $pad);
        }
        return base64_decode($raw, true);
    };

    $calc = hash_hmac('sha256', $body_b64, DANS_MOBILE_SSO_SECRET, true);
    $sig = $decode_b64url($sig_b64);
    if ($sig === false || !hash_equals($calc, $sig)) {
        wp_die('SSO imza dogrulanamadi.', 'Mobile SSO', ['response' => 401]);
    }

    $json = $decode_b64url($body_b64);
    if ($json === false) {
        wp_die('SSO payload gecersiz.', 'Mobile SSO', ['response' => 401]);
    }

    $payload = json_decode($json, true);
    if (!is_array($payload)) {
        wp_die('SSO payload okunamadi.', 'Mobile SSO', ['response' => 401]);
    }

    $now = time();
    $exp = isset($payload['exp']) ? intval($payload['exp']) : 0;
    $uid = isset($payload['wp_user_id']) ? intval($payload['wp_user_id']) : 0;
    $email = isset($payload['email']) ? strtolower(trim((string) $payload['email'])) : '';
    $redirect = isset($payload['redirect']) ? trim((string) $payload['redirect']) : '';

    if ($exp <= $now || $uid <= 0 || $redirect === '') {
        wp_die('SSO suresi dolmus veya payload eksik.', 'Mobile SSO', ['response' => 401]);
    }

    $user = get_user_by('id', $uid);
    if (!$user) {
        wp_die('Kullanici bulunamadi.', 'Mobile SSO', ['response' => 404]);
    }

    if ($email !== '' && strtolower((string) $user->user_email) !== $email) {
        wp_die('Kullanici bilgisi uyusmuyor.', 'Mobile SSO', ['response' => 401]);
    }

    $home_host = parse_url(home_url('/'), PHP_URL_HOST);
    $redir_host = parse_url($redirect, PHP_URL_HOST);
    if (!$home_host || !$redir_host || strtolower($home_host) !== strtolower($redir_host)) {
        wp_die('Gecersiz yonlendirme adresi.', 'Mobile SSO', ['response' => 400]);
    }

    wp_set_current_user($uid);
    wp_set_auth_cookie($uid, true, is_ssl());
    do_action('wp_login', $user->user_login, $user);
    wp_safe_redirect($redirect);
    exit;
});
