import 'dart:convert';

import 'package:http/http.dart' as http;

import 'error_message.dart';

class StoreSellerItem {
  final int accountId;
  final int slot;
  final String name;
  final String storeTitle;
  final String avatarUrl;
  final bool isVerified;
  final int productCount;
  final String coverImageUrl;

  const StoreSellerItem({
    required this.accountId,
    required this.slot,
    required this.name,
    required this.storeTitle,
    required this.avatarUrl,
    required this.isVerified,
    required this.productCount,
    required this.coverImageUrl,
  });

  factory StoreSellerItem.fromJson(Map<String, dynamic> json) {
    return StoreSellerItem(
      accountId: (json['account_id'] as num?)?.toInt() ?? 0,
      slot: (json['slot'] as num?)?.toInt() ?? 0,
      name: (json['name'] ?? '').toString(),
      storeTitle: (json['store_title'] ?? '').toString(),
      avatarUrl: (json['avatar_url'] ?? '').toString(),
      isVerified: json['is_verified'] == true,
      productCount: (json['product_count'] as num?)?.toInt() ?? 0,
      coverImageUrl: (json['cover_image_url'] ?? '').toString(),
    );
  }
}

class StoreSellerRef {
  final int accountId;
  final String name;
  final String avatarUrl;
  final bool isVerified;

  const StoreSellerRef({
    required this.accountId,
    required this.name,
    required this.avatarUrl,
    required this.isVerified,
  });

  factory StoreSellerRef.fromJson(Map<String, dynamic> json) {
    return StoreSellerRef(
      accountId: (json['account_id'] as num?)?.toInt() ?? 0,
      name: (json['name'] ?? '').toString(),
      avatarUrl: (json['avatar_url'] ?? '').toString(),
      isVerified: json['is_verified'] == true,
    );
  }
}

class StoreProductItem {
  final int id;
  final String title;
  final String description;
  final String imageUrl;
  final String price;
  final String currencyCode;
  final bool isActive;
  final bool isSold;
  final String status;
  final String soldAt;
  final bool isPubliclyVisible;
  final StoreSellerRef seller;

  const StoreProductItem({
    required this.id,
    required this.title,
    required this.description,
    required this.imageUrl,
    required this.price,
    required this.currencyCode,
    required this.isActive,
    required this.isSold,
    required this.status,
    required this.soldAt,
    required this.isPubliclyVisible,
    required this.seller,
  });

  factory StoreProductItem.fromJson(Map<String, dynamic> json) {
    return StoreProductItem(
      id: (json['id'] as num?)?.toInt() ?? 0,
      title: (json['title'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      imageUrl: (json['image_url'] ?? '').toString(),
      price: (json['price'] ?? '').toString(),
      currencyCode: (json['currency_code'] ?? 'TRY').toString(),
      isActive: json['is_active'] != false,
      isSold: json['is_sold'] == true,
      status: (json['status'] ?? '').toString(),
      soldAt: (json['sold_at'] ?? '').toString(),
      isPubliclyVisible: json['is_publicly_visible'] == true,
      seller: StoreSellerRef.fromJson((json['seller'] as Map?)?.cast<String, dynamic>() ?? const {}),
    );
  }

  String get formattedPrice {
    final code = currencyCode.trim().toUpperCase();
    final suffix = code == 'TRY' ? '₺' : code;
    return '${price.trim()} $suffix'.trim();
  }
}

class StoreSettings {
  final bool storeEnabled;
  final String storeTitle;
  final String effectiveStoreTitle;

  const StoreSettings({
    required this.storeEnabled,
    required this.storeTitle,
    required this.effectiveStoreTitle,
  });

  factory StoreSettings.fromJson(Map<String, dynamic> json) {
    return StoreSettings(
      storeEnabled: json['store_enabled'] == true,
      storeTitle: (json['store_title'] ?? '').toString(),
      effectiveStoreTitle: (json['effective_store_title'] ?? '').toString(),
    );
  }
}

class SellerStoreDetail {
  final StoreSellerItem seller;
  final List<StoreProductItem> products;

  const SellerStoreDetail({required this.seller, required this.products});
}

class StoreApi {
  static const _base = 'https://api2.dansmagazin.net';

  static Future<List<StoreSellerItem>> sellers({int limit = 100}) async {
    final normalized = limit < 1 ? 1 : (limit > 300 ? 300 : limit);
    final resp = await http.get(Uri.parse('$_base/store/sellers?limit=$normalized'));
    if (resp.statusCode != 200) {
      throw Exception(parseApiErrorBody(resp.body, fallback: 'Mağazalar yüklenemedi'));
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['items'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(StoreSellerItem.fromJson)
        .toList(growable: false);
  }

  static Future<List<StoreSellerItem>> featuredSellers() async {
    final resp = await http.get(Uri.parse('$_base/store/featured'));
    if (resp.statusCode != 200) {
      throw Exception(parseApiErrorBody(resp.body, fallback: 'Öne çıkan mağazalar yüklenemedi'));
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['items'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(StoreSellerItem.fromJson)
        .toList(growable: false);
  }

  static Future<SellerStoreDetail> sellerStore(int sellerAccountId) async {
    final resp = await http.get(Uri.parse('$_base/store/sellers/$sellerAccountId'));
    if (resp.statusCode != 200) {
      throw Exception(parseApiErrorBody(resp.body, fallback: 'Mağaza yüklenemedi'));
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return SellerStoreDetail(
      seller: StoreSellerItem.fromJson((body['seller'] as Map?)?.cast<String, dynamic>() ?? const {}),
      products: (body['products'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(StoreProductItem.fromJson)
          .toList(growable: false),
    );
  }

  static Future<StoreProductItem> product(int productId) async {
    final resp = await http.get(Uri.parse('$_base/store/products/$productId'));
    if (resp.statusCode != 200) {
      throw Exception(parseApiErrorBody(resp.body, fallback: 'Ürün yüklenemedi'));
    }
    return StoreProductItem.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  static Future<StoreSettings> mySettings(String sessionToken) async {
    final resp = await http.get(
      Uri.parse('$_base/store/me/settings'),
      headers: {'Authorization': 'Bearer ${sessionToken.trim()}'},
    );
    if (resp.statusCode != 200) {
      throw Exception(parseApiErrorBody(resp.body, fallback: 'Mağaza ayarları yüklenemedi'));
    }
    return StoreSettings.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  static Future<List<StoreProductItem>> myProducts(String sessionToken) async {
    final resp = await http.get(
      Uri.parse('$_base/store/my/products'),
      headers: {'Authorization': 'Bearer ${sessionToken.trim()}'},
    );
    if (resp.statusCode != 200) {
      throw Exception(parseApiErrorBody(resp.body, fallback: 'Ürünler yüklenemedi'));
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['items'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(StoreProductItem.fromJson)
        .toList(growable: false);
  }

  static Future<StoreSettings> updateMySettings({
    required String sessionToken,
    required String storeTitle,
  }) async {
    final resp = await http.put(
      Uri.parse('$_base/store/me/settings'),
      headers: {
        'Authorization': 'Bearer ${sessionToken.trim()}',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'store_title': storeTitle.trim()}),
    );
    if (resp.statusCode != 200) {
      throw Exception(parseApiErrorBody(resp.body, fallback: 'Mağaza ayarları güncellenemedi'));
    }
    return StoreSettings.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  static Future<void> createProduct({
    required String sessionToken,
    required String title,
    required String description,
    required String price,
    required String imagePath,
  }) async {
    final req = http.MultipartRequest('POST', Uri.parse('$_base/store/products'))
      ..headers['Authorization'] = 'Bearer ${sessionToken.trim()}'
      ..fields['title'] = title.trim()
      ..fields['description'] = description.trim()
      ..fields['price'] = price.trim()
      ..files.add(await http.MultipartFile.fromPath('image', imagePath));
    final streamed = await req.send();
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode != 200) {
      throw Exception(parseApiErrorBody(body, fallback: 'Ürün oluşturulamadı'));
    }
  }

  static Future<void> openStore(String sessionToken) async {
    final resp = await http.post(
      Uri.parse('$_base/store/me/open'),
      headers: {'Authorization': 'Bearer ${sessionToken.trim()}'},
    );
    if (resp.statusCode != 200) {
      throw Exception(parseApiErrorBody(resp.body, fallback: 'Mağaza açılamadı'));
    }
  }

  static Future<List<StoreSellerItem>> saveFeaturedSellers(
    String sessionToken, {
    required List<int> accountIds,
  }) async {
    final resp = await http.put(
      Uri.parse('$_base/store/featured/admin'),
      headers: {
        'Authorization': 'Bearer ${sessionToken.trim()}',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'account_ids': accountIds}),
    );
    if (resp.statusCode != 200) {
      throw Exception(parseApiErrorBody(resp.body, fallback: 'Öne çıkan mağazalar kaydedilemedi'));
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['items'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(StoreSellerItem.fromJson)
        .toList(growable: false);
  }
}
