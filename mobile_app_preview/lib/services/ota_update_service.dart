import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shorebird_code_push/shorebird_code_push.dart';

class OtaUpdateService {
  OtaUpdateService._();

  static final ShorebirdUpdater _updater = ShorebirdUpdater();
  static bool _checking = false;

  static bool get _isSupportedPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<void> checkAndDownload() async {
    if (_checking || !_isSupportedPlatform || !_updater.isAvailable) return;
    _checking = true;
    try {
      final status = await _updater.checkForUpdate();
      if (status == UpdateStatus.outdated) {
        await _updater.update();
      }
    } on UpdateException catch (error) {
      debugPrint('OTA update failed: ${error.message}');
    } catch (error) {
      debugPrint('OTA update check failed: $error');
    } finally {
      _checking = false;
    }
  }

  static void scheduleStartupCheck() {
    unawaited(
      Future<void>.delayed(
        const Duration(seconds: 4),
        checkAndDownload,
      ),
    );
  }
}
