import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'photo_flow_api.dart';

class ContentSharePayload {
  final String categoryLabel;
  final String title;
  final String subtitle;
  final String description;
  final String imageUrl;
  final String feedText;
  final String shareUrl;
  final Color accentColor;

  const ContentSharePayload({
    required this.categoryLabel,
    required this.title,
    required this.subtitle,
    required this.description,
    required this.imageUrl,
    required this.feedText,
    this.shareUrl = '',
    required this.accentColor,
  });
}

class ContentShareService {
  static Future<void> shareAsImage(
    BuildContext context, {
    required ContentSharePayload payload,
  }) async {
    final file = await _buildCardFile(payload);
    final box = context.findRenderObject() as RenderBox?;
    final shareText = [
      payload.title.trim(),
      payload.shareUrl.trim(),
    ].where((e) => e.isNotEmpty).join('\n');
    await Share.shareXFiles(
      [XFile(file.path)],
      subject: payload.title,
      text: shareText.isEmpty ? null : shareText,
      sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
    );
  }

  static Future<void> addToFeed({
    required String sessionToken,
    required ContentSharePayload payload,
  }) async {
    final file = await _buildCardFile(payload);
    await PhotoFlowApi.createPost(
      sessionToken,
      text: payload.feedText.trim(),
      imagePath: file.path,
    );
  }

  static Future<File> _buildCardFile(ContentSharePayload payload) async {
    final imageBytes = await _tryDownloadImage(payload.imageUrl);
    final pngBytes = await _renderCard(payload, imageBytes);
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/dm_share_${DateTime.now().millisecondsSinceEpoch}_${payload.categoryLabel.toLowerCase().replaceAll(' ', '_')}.png',
    );
    await file.writeAsBytes(pngBytes, flush: true);
    return file;
  }

  static Future<Uint8List?> _tryDownloadImage(String imageUrl) async {
    final url = imageUrl.trim();
    if (url.isEmpty || !(url.startsWith('http://') || url.startsWith('https://'))) {
      return null;
    }
    try {
      final resp = await http.get(Uri.parse(url));
      if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
        return resp.bodyBytes;
      }
    } catch (_) {}
    return null;
  }

  static Future<ui.Image?> _decodeImage(Uint8List? bytes) async {
    if (bytes == null || bytes.isEmpty) return null;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      return frame.image;
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List> _renderCard(
    ContentSharePayload payload,
    Uint8List? imageBytes,
  ) async {
    const width = 1080.0;
    const height = 1920.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, width, height));
    final rect = const Rect.fromLTWH(0, 0, width, height);

    final bgPaint = Paint()
      ..shader = ui.Gradient.linear(
        const Offset(0, 0),
        Offset(width, height),
        [
          const Color(0xFF07101F),
          payload.accentColor.withOpacity(0.82),
          const Color(0xFF10182E),
        ],
      );
    canvas.drawRect(rect, bgPaint);

    final glowPaint = Paint()
      ..shader = ui.Gradient.radial(
        Offset(width * 0.22, height * 0.22),
        width * 0.52,
        [
          payload.accentColor.withOpacity(0.30),
          Colors.transparent,
        ],
      );
    canvas.drawCircle(Offset(width * 0.22, height * 0.22), width * 0.52, glowPaint);

    final panelRect = RRect.fromRectAndRadius(
      const Rect.fromLTWH(54, 60, width - 108, height - 120),
      const Radius.circular(46),
    );
    canvas.drawRRect(
      panelRect,
      Paint()..color = Colors.white.withOpacity(0.08),
    );
    canvas.drawRRect(
      panelRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white.withOpacity(0.12),
    );

    final ui.Image? heroImage = await _decodeImage(imageBytes);
    final imageRect = RRect.fromRectAndRadius(
      const Rect.fromLTWH(94, 184, width - 188, 860),
      const Radius.circular(40),
    );
    if (heroImage != null) {
      canvas.save();
      canvas.clipRRect(imageRect);
      paintImage(
        canvas: canvas,
        rect: imageRect.outerRect,
        image: heroImage,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.high,
      );
      canvas.restore();
    } else {
      final imageBg = Paint()
        ..shader = ui.Gradient.linear(
          imageRect.outerRect.topLeft,
          imageRect.outerRect.bottomRight,
          [
            payload.accentColor.withOpacity(0.45),
            const Color(0xFF101A33),
          ],
        );
      canvas.drawRRect(imageRect, imageBg);
      _paintText(
        canvas,
        payload.categoryLabel.toUpperCase(),
        rect: Rect.fromLTWH(imageRect.left + 40, imageRect.top + 42, imageRect.width - 80, 80),
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 34,
          fontWeight: FontWeight.w700,
          letterSpacing: 2,
        ),
      );
    }

    final chipRect = RRect.fromRectAndRadius(
      const Rect.fromLTWH(96, 96, 260, 66),
      const Radius.circular(999),
    );
    canvas.drawRRect(
      chipRect,
      Paint()..color = Colors.black.withOpacity(0.34),
    );
    _paintText(
      canvas,
      payload.categoryLabel,
      rect: chipRect.outerRect,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 28,
        fontWeight: FontWeight.w800,
      ),
      align: TextAlign.center,
      maxLines: 1,
    );

    _paintText(
      canvas,
      payload.title,
      rect: const Rect.fromLTWH(94, 1096, width - 188, 210),
      style: const TextStyle(
        color: Colors.white,
        fontSize: 62,
        fontWeight: FontWeight.w900,
        height: 1.05,
      ),
      maxLines: 3,
    );

    if (payload.subtitle.trim().isNotEmpty) {
      _paintText(
        canvas,
        payload.subtitle.trim(),
        rect: const Rect.fromLTWH(94, 1326, width - 188, 88),
        style: TextStyle(
          color: payload.accentColor.computeLuminance() > 0.55
              ? const Color(0xFF1F2937)
              : const Color(0xFFFFE7B3),
          fontSize: 30,
          fontWeight: FontWeight.w700,
        ),
        maxLines: 2,
      );
    }

    if (payload.description.trim().isNotEmpty) {
      _paintText(
        canvas,
        payload.description.trim(),
        rect: const Rect.fromLTWH(94, 1438, width - 188, 248),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 34,
          fontWeight: FontWeight.w500,
          height: 1.25,
        ),
        maxLines: 5,
      );
    }

    _paintText(
      canvas,
      'Dansmagazin',
      rect: Rect.fromLTWH(94, height - 174, width - 188, 60),
      style: TextStyle(
        color: Colors.white.withOpacity(0.86),
        fontSize: 30,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.2,
      ),
      maxLines: 1,
    );

    final picture = recorder.endRecording();
    final image = await picture.toImage(width.toInt(), height.toInt());
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  static void _paintText(
    Canvas canvas,
    String text, {
    required Rect rect,
    required TextStyle style,
    TextAlign align = TextAlign.left,
    int maxLines = 2,
  }) {
    final span = TextSpan(text: text, style: style);
    final tp = TextPainter(
      text: span,
      textAlign: align,
      textDirection: TextDirection.ltr,
      maxLines: maxLines,
      ellipsis: '…',
    )..layout(maxWidth: rect.width);
    final dx = align == TextAlign.center ? rect.left + (rect.width - tp.width) / 2 : rect.left;
    tp.paint(canvas, Offset(dx, rect.top));
  }
}
