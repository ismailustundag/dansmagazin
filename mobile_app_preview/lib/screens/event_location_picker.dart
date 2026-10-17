import 'package:flutter/material.dart';
import '../services/event_locations_api.dart';

Future<EventLocation?> pickEventLocation(
        BuildContext context, EventLocation current) =>
    showDialog<EventLocation>(
        context: context, builder: (_) => _LocationDialog(current: current));

class _LocationDialog extends StatefulWidget {
  final EventLocation current;
  const _LocationDialog({required this.current});
  @override
  State<_LocationDialog> createState() => _LocationDialogState();
}

class _LocationDialogState extends State<_LocationDialog> {
  late final TextEditingController country;
  late final TextEditingController city;
  late Future<EventLocationOptions> options;
  String identity = '';
  final form = GlobalKey<FormState>();
  @override
  void initState() {
    super.initState();
    country = TextEditingController(text: widget.current.countryCode);
    city = TextEditingController(text: widget.current.city);
    identity = widget.current.cityId;
    options = EventLocationsApi.fetch();
  }

  @override
  void dispose() {
    country.dispose();
    city.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Etkinlik konumu'),
        content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
                child: Form(
                    key: form,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      TextFormField(
                          controller: country,
                          textCapitalization: TextCapitalization.characters,
                          decoration: const InputDecoration(
                              labelText: 'Ülke kodu (TR, ES, TH, PL)',
                              helperText: 'Bilinmiyorsa boş bırakın'),
                          validator: (value) => value!.trim().isEmpty ||
                                  RegExp(r'^[A-Za-z]{2}$')
                                      .hasMatch(value.trim())
                              ? null
                              : 'İki harfli ülke kodunu girin',
                          onChanged: (_) => setState(() => identity = '')),
                      TextFormField(
                          controller: city,
                          decoration: const InputDecoration(
                              labelText: 'Şehir / yerleşim'),
                          validator: (value) =>
                              value!.trim().isEmpty ? 'Şehir gerekli' : null,
                          onChanged: (_) => setState(() => identity = '')),
                      FutureBuilder<EventLocationOptions>(
                          future: options,
                          builder: (context, snapshot) {
                            if (snapshot.connectionState !=
                                ConnectionState.done)
                              return const Padding(
                                  padding: EdgeInsets.all(16),
                                  child: CircularProgressIndicator());
                            if (snapshot.hasError)
                              return TextButton.icon(
                                  onPressed: () => setState(() =>
                                      options = EventLocationsApi.fetch()),
                                  icon: const Icon(Icons.refresh),
                                  label: const Text('Konumları tekrar yükle'));
                            final matches = snapshot.data!.cities
                                .where((item) =>
                                    (country.text.trim().isEmpty ||
                                        item.countryCode ==
                                            country.text
                                                .trim()
                                                .toUpperCase()) &&
                                    item.city.toLowerCase().contains(
                                        city.text.trim().toLowerCase()))
                                .take(15);
                            return Column(
                                children: matches
                                    .map((item) => ListTile(
                                          title: Text(item.label),
                                          subtitle: Text(item.cityId),
                                          onTap: () => setState(() {
                                            country.text = item.countryCode;
                                            city.text = item.city;
                                            identity = item.cityId;
                                          }),
                                        ))
                                    .toList());
                          }),
                    ])))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Vazgeç')),
          FilledButton(
              onPressed: () {
                if (form.currentState!.validate())
                  Navigator.pop(
                      context,
                      EventLocation(
                          countryCode: country.text.trim().toUpperCase(),
                          city: city.text.trim(),
                          cityId: identity));
              },
              child: const Text('Seç'))
        ],
      );
}
