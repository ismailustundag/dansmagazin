import 'dart:io';

import 'package:add_2_calendar/add_2_calendar.dart';
import 'package:android_intent_plus/android_intent.dart';

class CalendarService {
  static Future<void> addEvent(Event event) async {
    if (Platform.isAndroid) {
      try {
        final intent = AndroidIntent(
          action: 'android.intent.action.INSERT',
          data: 'content://com.android.calendar/events',
          arguments: <String, dynamic>{
            'title': event.title,
            'description': event.description,
            'eventLocation': event.location,
            'beginTime': event.startDate.millisecondsSinceEpoch,
            'endTime': event.endDate.millisecondsSinceEpoch,
            'allDay': event.allDay,
          },
        );
        await intent.launch();
        return;
      } catch (_) {
        // Fallback below for vendor-specific calendar app behavior.
      }
    }
    await Add2Calendar.addEvent2Cal(event);
  }
}
