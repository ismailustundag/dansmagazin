import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_app_preview/services/commerce_api.dart';

void main() {
  test('shop catalog shows active internal products, not mirrored Woo products', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/commerce/products');
      return http.Response(jsonEncode({
        'items': [
          {
            'id': 3,
            'source_type': 'internal',
            'source_product_id': 'codex-test-1tl-20261013',
            'name': 'Codex Test Ürünü - 1 TL',
            'description': 'Deneme ürünü',
            'image_url': 'https://example.com/test.jpg',
            'variations': [
              {'id': 25, 'name': 'Standart - Test', 'price': 1, 'currency': 'TRY'}
            ]
          },
          {
            'id': 2,
            'source_type': 'woo',
            'name': 'B-FEST',
            'variations': [
              {'id': 24, 'name': 'Fullpass', 'price': 1000}
            ]
          },
          {'id': 4, 'source_type': 'internal', 'name': 'Empty', 'variations': []}
        ]
      }), 200);
    });

    final products = await CommerceApi.getActiveInternalProducts(client: client);
    expect(products, hasLength(1));
    expect(products.single.id, 3);
    expect(products.single.name, 'Codex Test Ürünü - 1 TL');
    expect(products.single.variations.single.price, 1);
    client.close();
  });
}
