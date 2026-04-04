import 'package:flutter/material.dart';

import '../services/i18n.dart';
import 'events_screen.dart';
import 'store_screen.dart';

class EventsStoreHubScreen extends StatelessWidget {
  final String sessionToken;
  final bool canCreateEvent;
  final bool canAddToFeed;

  const EventsStoreHubScreen({
    super.key,
    required this.sessionToken,
    required this.canCreateEvent,
    required this.canAddToFeed,
  });

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: const Color(0xFF080B14),
        appBar: AppBar(
          backgroundColor: const Color(0xFF0F172A),
          automaticallyImplyLeading: false,
          toolbarHeight: 0,
          bottom: TabBar(
            tabs: [
              Tab(icon: const Icon(Icons.event), text: I18n.t('events')),
              Tab(icon: const Icon(Icons.storefront), text: I18n.t('store')),
            ],
          ),
        ),
        body: TabBarView(
          physics: const NeverScrollableScrollPhysics(),
          children: [
            EventsScreen(
              sessionToken: sessionToken,
              canCreateEvent: canCreateEvent,
              canAddToFeed: canAddToFeed,
            ),
            StoreScreen(
              sessionToken: sessionToken,
              canAddToFeed: canAddToFeed,
            ),
          ],
        ),
      ),
    );
  }
}
