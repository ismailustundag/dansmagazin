import 'dart:convert';

import 'package:http/http.dart' as http;

class CommerceVariation {
  final String sourceId;
  final String name;
  final double price;
  final String currency;

  const CommerceVariation({
    required this.sourceId,
    required this.name,
    required this.price,
    required this.currency,
  });

  factory CommerceVariation.fromJson(Map<String, dynamic> json) {
    return CommerceVariation(
      sourceId: '${json['source_variation_id'] ?? json['id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      price: double.tryParse('${json['price'] ?? 0}') ?? 0,
      currency: '${json['currency'] ?? 'TRY'}',
    );
  }
}

class CommerceProduct {
  final int id;
  final String sourceType;
  final String sourceId;
  final String name;
  final String description;
  final String imageUrl;
  final List<CommerceVariation> variations;

  const CommerceProduct({
    required this.id,
    required this.sourceType,
    required this.sourceId,
    required this.name,
    required this.description,
    required this.imageUrl,
    required this.variations,
  });

  factory CommerceProduct.fromJson(Map<String, dynamic> json) {
    final rawVariations = json['variations'];
    return CommerceProduct(
      id: (json['id'] as num?)?.toInt() ?? 0,
      sourceType: '${json['source_type'] ?? ''}',
      sourceId: '${json['source_product_id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      description: '${json['description'] ?? ''}',
      imageUrl: '${json['image_url'] ?? ''}',
      variations: rawVariations is List
          ? rawVariations
              .whereType<Map<String, dynamic>>()
              .map(CommerceVariation.fromJson)
              .toList(growable: false)
          : const [],
    );
  }
}

class CommerceApi {
  static const String _base = 'https://api2.dansmagazin.net';

  static Future<List<CommerceProduct>> getActiveInternalProducts({http.Client? client}) async {
    final response = await (client?.get(Uri.parse('$_base/commerce/products')) ??
        http.get(Uri.parse('$_base/commerce/products')))
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw Exception('Dans Magazin ürünleri yüklenemedi');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic> || decoded['items'] is! List) {
      throw const FormatException('Ürün listesi geçersiz');
    }
    return (decoded['items'] as List)
        .whereType<Map<String, dynamic>>()
        .map(CommerceProduct.fromJson)
        .where((product) => product.id > 0 &&
            product.sourceType == 'internal' &&
            product.variations.isNotEmpty)
        .toList(growable: false);
  }

  static Future<CommerceProduct?> getProductBySource(String sourceId) async {
    final id = sourceId.trim();
    if (id.isEmpty) return null;
    try {
      final response = await http
          .get(Uri.parse(
              '$_base/commerce/products/source/${Uri.encodeComponent(id)}'))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) return null;
      return CommerceProduct.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  static Future<CommerceProduct?> getProductForEvent(int submissionId) async {
    if (submissionId <= 0) return null;
    try {
      final response = await http
          .get(Uri.parse('$_base/commerce/products/event/$submissionId'))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) return null;
      return CommerceProduct.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }
}
