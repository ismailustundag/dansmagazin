import 'package:flutter/material.dart';

import 'events_screen.dart';
import 'store_screen.dart';

class EventsStoreHubScreen extends StatelessWidget {
  final String sessionToken;
  final bool canCreateEvent;

  const EventsStoreHubScreen({
    super.key,
    required this.sessionToken,
    required this.canCreateEvent,
  });

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: const Color(0xFF080B14),
        appBar: AppBar(
          backgroundColor: const Color(0xFF0F172A),
          title: const Text('Dansmagazin'),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.event), text: 'Etkinlikler'),
              Tab(icon: Icon(Icons.storefront), text: 'Mağaza'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            EventsScreen(
              sessionToken: sessionToken,
              canCreateEvent: canCreateEvent,
            ),
            const StoreScreen(),
          ],
        ),
      ),
    );
  }
}
