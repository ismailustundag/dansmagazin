import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_app_preview/services/event_locations_api.dart';

void main() {
  test('server catalog is uncapped, refreshed, and country scoped', () async {
    var requests = 0;
    final client = MockClient((request) async {
      expect(request.url.path, '/events/filter-options');
      expect(request.url.queryParameters.containsKey('limit'), false);
      requests++;
      return http.Response(
          jsonEncode({
            'countries': [
              {'code': 'TR', 'name': 'Türkiye'},
              {'code': 'ES', 'name': 'İspanya'}
            ],
            'cities': [
              for (var i = 0; i < 650; i++)
                {'city': 'Place $i', 'city_id': 'geo:$i', 'country_code': 'TR'},
              {
                'city': 'Valencia',
                'city_id': 'geo:valencia',
                'country_code': 'ES'
              },
              {
                'city': 'Massanassa / Valencia',
                'city_id': 'text:massanassa',
                'country_code': ''
              },
              if (requests > 1)
                {
                  'city': 'Bangkok',
                  'city_id': 'geo:bangkok',
                  'country_code': 'TH'
                },
            ]
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });
    final first = await EventLocationsApi.fetch(client: client);
    expect(first.cities.length, 652);
    expect(first.forCountry('ES').single.city, 'Valencia');
    expect(
        first.forCountry('__unknown__').single.city, 'Massanassa / Valencia');
    final second = await EventLocationsApi.fetch(client: client);
    expect(second.forCountry('TH').single.city, 'Bangkok');
    client.close();
  });
  test('same name in different countries has distinct selection keys', () {
    const first =
        EventLocation(city: 'Valencia', countryCode: 'ES', cityId: 'geo:1');
    const second =
        EventLocation(city: 'Valencia', countryCode: 'VE', cityId: 'geo:1');
    expect(first.key, isNot(second.key));
  });
  test('request failure is not reported as an empty catalog', () async {
    final client = MockClient((_) async => http.Response('unavailable', 503));
    await expectLater(EventLocationsApi.fetch(client: client), throwsException);
    client.close();
  });
}
