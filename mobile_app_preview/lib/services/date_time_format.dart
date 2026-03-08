import 'package:intl/intl.dart';

bool _looksLikeNaiveDateTime(String raw) {
  final v = raw.trim();
  if (v.isEmpty) return false;
  final hasDateTime = RegExp(r'^\d{4}-\d{1,2}-\d{1,2}[ T]\d{1,2}:\d{1,2}').hasMatch(v);
  if (!hasDateTime) return false;
  final hasExplicitZone = RegExp(r'(Z|[+\-]\d{2}:\d{2})$').hasMatch(v);
  return !hasExplicitZone;
}

DateTime? _parseFlexible(String raw) {
  final v = raw.trim();
  if (v.isEmpty) return null;

  final normalized = v.replaceAll(' ', 'T');
  final direct = DateTime.tryParse(v) ?? DateTime.tryParse(normalized);
  if (direct != null) {
    // Backend cogu alanda timezone eklemeden UTC timestamp donuyor.
    // Bu durumda cihaz local saat diye yorumlamasin; UTC kabul edip locale cevir.
    if (_looksLikeNaiveDateTime(v)) {
      return DateTime.utc(
        direct.year,
        direct.month,
        direct.day,
        direct.hour,
        direct.minute,
        direct.second,
        direct.millisecond,
        direct.microsecond,
      );
    }
    return direct;
  }

  final ddMmYyyy = RegExp(r'^(\d{1,2})[-\.](\d{1,2})[-\.](\d{4})$').firstMatch(v);
  if (ddMmYyyy != null) {
    final d = int.tryParse(ddMmYyyy.group(1)!);
    final m = int.tryParse(ddMmYyyy.group(2)!);
    final y = int.tryParse(ddMmYyyy.group(3)!);
    if (d != null && m != null && y != null) return DateTime(y, m, d);
  }

  final yMd = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(v);
  if (yMd != null) {
    final y = int.tryParse(yMd.group(1)!);
    final m = int.tryParse(yMd.group(2)!);
    final d = int.tryParse(yMd.group(3)!);
    if (d != null && m != null && y != null) return DateTime(y, m, d);
  }
  return null;
}

String formatDateDdMmYyyy(String raw, {String fallback = '-'}) {
  final dt = _parseFlexible(raw);
  if (dt == null) return raw.trim().isEmpty ? fallback : raw.trim();
  return DateFormat('dd.MM.yyyy').format(dt.toLocal());
}

String formatDateTimeDdMmYyyyHmDot(String raw, {String fallback = '-'}) {
  final v = raw.trim();
  final onlyDate = RegExp(r'^\d{4}-\d{1,2}-\d{1,2}$').hasMatch(v) ||
      RegExp(r'^\d{1,2}[-\.]\d{1,2}[-\.]\d{4}$').hasMatch(v);
  if (onlyDate) return formatDateDdMmYyyy(v, fallback: fallback);
  final dt = _parseFlexible(raw);
  if (dt == null) return raw.trim().isEmpty ? fallback : raw.trim().replaceAll('T', ' ');
  return DateFormat('dd.MM.yyyy HH.mm').format(dt.toLocal());
}
