<?php
/**
 * Plugin Name: Dansmagazin Mobile Ticket Webhook Bridge
 * Description: Woo siparis durumlarini mobil backend'e gonderir.
 * Version: 1.0.0
 */

if (!defined('ABSPATH')) {
    exit;
}

if (!defined('DMZ_MOBILE_API_ORDER_WEBHOOK_URL')) {
    define('DMZ_MOBILE_API_ORDER_WEBHOOK_URL', 'https://api2.dansmagazin.net/admin/events/woo/order-paid');
}

if (!defined('DMZ_WOO_SYNC_SECRET')) {
    // wp-config.php icinde tanimlanmasi onerilir.
    define('DMZ_WOO_SYNC_SECRET', '');
}

function dmz_send_order_to_mobile_backend($order_id) {
    if (!$order_id) {
        return;
    }

    $order = wc_get_order($order_id);
    if (!$order) {
        return;
    }

    $line_items = [];
    foreach ($order->get_items() as $item_id => $item) {
        if (!is_a($item, 'WC_Order_Item_Product')) {
            continue;
        }
        $product_id = (int) $item->get_product_id();
        $qty = (int) $item->get_quantity();
        if ($product_id <= 0 || $qty <= 0) {
            continue;
        }
        $line_items[] = [
            'id' => (string) $item_id,
            'product_id' => (string) $product_id,
            'quantity' => $qty,
        ];
    }

    $payload = [
        'order_id' => (string) $order->get_id(),
        'status' => (string) $order->get_status(),
        'billing_email' => (string) $order->get_billing_email(),
        'customer_id' => (int) $order->get_customer_id(),
        'line_items' => $line_items,
    ];

    $headers = ['Content-Type' => 'application/json'];
    if (defined('DMZ_WOO_SYNC_SECRET') && DMZ_WOO_SYNC_SECRET !== '') {
        $headers['x-woo-sync-secret'] = DMZ_WOO_SYNC_SECRET;
    }

    wp_remote_post(
        DMZ_MOBILE_API_ORDER_WEBHOOK_URL,
        [
            'timeout' => 15,
            'headers' => $headers,
            'body' => wp_json_encode($payload),
        ]
    );
}

// Siparis olusunca (pending dahil) ilk ticket kaydi olussun.
add_action('woocommerce_checkout_order_processed', 'dmz_send_order_to_mobile_backend', 20, 1);

// Durum degisimlerinde ticket status guncellensin.
add_action('woocommerce_order_status_pending', 'dmz_send_order_to_mobile_backend', 20, 1);
add_action('woocommerce_order_status_on-hold', 'dmz_send_order_to_mobile_backend', 20, 1);
add_action('woocommerce_order_status_processing', 'dmz_send_order_to_mobile_backend', 20, 1);
add_action('woocommerce_order_status_completed', 'dmz_send_order_to_mobile_backend', 20, 1);
add_action('woocommerce_order_status_cancelled', 'dmz_send_order_to_mobile_backend', 20, 1);
add_action('woocommerce_order_status_failed', 'dmz_send_order_to_mobile_backend', 20, 1);
add_action('woocommerce_order_status_refunded', 'dmz_send_order_to_mobile_backend', 20, 1);
