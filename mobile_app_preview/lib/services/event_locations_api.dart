import 'dart:convert';
import 'package:http/http.dart' as http;

class EventLocation {
  final String countryCode;
  final String cityId;
  final String city;
  const EventLocation(
      {this.countryCode = '', this.cityId = '', this.city = ''});
  String get key =>
      '${countryCode.isEmpty ? '__unknown__' : countryCode}|$cityId';
  String get label => countryCode.isEmpty ? city : '$city ($countryCode)';
  factory EventLocation.fromJson(Map<String, dynamic> json) => EventLocation(
        countryCode: (json['country_code'] ?? '').toString(),
        cityId: (json['city_id'] ?? '').toString(),
        city: (json['city'] ?? '').toString(),
      );
}

class EventLocationOptions {
  final List<EventLocation> cities;
  final Map<String, String> countries;
  const EventLocationOptions({required this.cities, required this.countries});
  String label(String key) {
    final matches = cities.where((city) => city.key == key);
    return matches.isEmpty ? 'Seçili şehir' : matches.first.label;
  }

  String choiceLabel(EventLocation value) {
    final duplicates = cities.where((city) =>
        city.city == value.city && city.countryCode == value.countryCode);
    return duplicates.length > 1
        ? '${value.label} · ${value.cityId}'
        : value.label;
  }

  List<EventLocation> forCountry(String code) => cities
      .where((city) =>
          code.isEmpty ||
          (city.countryCode.isEmpty ? '__unknown__' : city.countryCode) == code)
      .toList();
}

class EventLocationsApi {
  static Future<EventLocationOptions> fetch({http.Client? client}) async {
    final ownClient = client == null;
    final transport = client ?? http.Client();
    try {
      final response = await transport
          .get(Uri.parse('https://api2.dansmagazin.net/events/filter-options'))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200)
        throw Exception('Konum seçenekleri yüklenemedi');
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return EventLocationOptions(
        cities: (data['cities'] as List)
            .map((row) =>
                EventLocation.fromJson(Map<String, dynamic>.from(row as Map)))
            .toList(),
        countries: {
          for (final row in data['countries'] as List)
            row['code'] as String: row['name'] as String
        },
      );
    } finally {
      if (ownClient) transport.close();
    }
  }
}
