import 'package:characters/characters.dart';
import 'package:flutter/material.dart';

bool _isEmojiCluster(String cluster) {
  for (final rune in cluster.runes) {
    if (rune == 0x200D || rune == 0xFE0F) return true;
    if ((rune >= 0x1F000 && rune <= 0x1FAFF) ||
        (rune >= 0x2600 && rune <= 0x27BF) ||
        (rune >= 0x2300 && rune <= 0x23FF)) {
      return true;
    }
  }
  return false;
}

List<InlineSpan> buildEmojiTextSpans(
  String text,
  TextStyle baseStyle, {
  double emojiScale = 1.22,
}) {
  if (text.isEmpty) {
    return <InlineSpan>[TextSpan(text: '', style: baseStyle)];
  }
  final spans = <InlineSpan>[];
  final buffer = StringBuffer();
  bool? bufferIsEmoji;

  void flush() {
    if (buffer.isEmpty || bufferIsEmoji == null) return;
    final chunk = buffer.toString();
    final style = bufferIsEmoji!
        ? baseStyle.copyWith(
            fontSize: (baseStyle.fontSize ?? 14) * emojiScale,
          )
        : baseStyle;
    spans.add(TextSpan(text: chunk, style: style));
    buffer.clear();
  }

  for (final cluster in text.characters) {
    final isEmoji = _isEmojiCluster(cluster);
    if (bufferIsEmoji == null) {
      bufferIsEmoji = isEmoji;
      buffer.write(cluster);
      continue;
    }
    if (bufferIsEmoji == isEmoji) {
      buffer.write(cluster);
      continue;
    }
    flush();
    bufferIsEmoji = isEmoji;
    buffer.write(cluster);
  }
  flush();
  return spans;
}

List<InlineSpan> buildVerifiedNameSpans(
  String name,
  TextStyle baseStyle, {
  required bool isVerified,
  double emojiScale = 1.22,
  double badgeScale = 1.46,
}) {
  final spans = <InlineSpan>[
    ...buildEmojiTextSpans(name, baseStyle, emojiScale: emojiScale),
  ];
  if (isVerified) {
    if (name.trim().isNotEmpty) {
      spans.add(TextSpan(text: ' ', style: baseStyle));
    }
    spans.add(
      TextSpan(
        text: '⭐️',
        style: baseStyle.copyWith(
          fontSize: (baseStyle.fontSize ?? 14) * badgeScale,
        ),
      ),
    );
  }
  return spans;
}

class EmojiText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final double emojiScale;
  final TextAlign textAlign;
  final TextOverflow overflow;
  final int? maxLines;
  final bool softWrap;

  const EmojiText(
    this.text, {
    super.key,
    this.style,
    this.emojiScale = 1.22,
    this.textAlign = TextAlign.start,
    this.overflow = TextOverflow.clip,
    this.maxLines,
    this.softWrap = true,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveStyle = DefaultTextStyle.of(context).style.merge(style);
    return RichText(
      textScaler: MediaQuery.textScalerOf(context),
      textAlign: textAlign,
      overflow: overflow,
      maxLines: maxLines,
      softWrap: softWrap,
      text: TextSpan(
        style: effectiveStyle,
        children: buildEmojiTextSpans(
          text,
          effectiveStyle,
          emojiScale: emojiScale,
        ),
      ),
    );
  }
}

class VerifiedNameText extends StatelessWidget {
  final String name;
  final bool isVerified;
  final TextStyle? style;
  final double emojiScale;
  final double badgeScale;
  final TextAlign textAlign;
  final TextOverflow overflow;
  final int? maxLines;
  final bool softWrap;

  const VerifiedNameText(
    this.name, {
    super.key,
    required this.isVerified,
    this.style,
    this.emojiScale = 1.22,
    this.badgeScale = 1.46,
    this.textAlign = TextAlign.start,
    this.overflow = TextOverflow.clip,
    this.maxLines,
    this.softWrap = true,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveStyle = DefaultTextStyle.of(context).style.merge(style);
    return RichText(
      textScaler: MediaQuery.textScalerOf(context),
      textAlign: textAlign,
      overflow: overflow,
      maxLines: maxLines,
      softWrap: softWrap,
      text: TextSpan(
        style: effectiveStyle,
        children: buildVerifiedNameSpans(
          name,
          effectiveStyle,
          isVerified: isVerified,
          emojiScale: emojiScale,
          badgeScale: badgeScale,
        ),
      ),
    );
  }
}
