import 'package:flutter/material.dart';

String normalizedProfileGender(String? gender) {
  final value = (gender ?? '').trim().toLowerCase();
  if (value == 'female' || value == 'male') return value;
  return 'unspecified';
}

class ProfileCardPalette {
  final List<Color> cardGradient;
  final List<Color> placeholderGradient;
  final Color surfaceTint;
  final Color surfaceBorder;
  final Color buttonFill;
  final Color buttonForeground;

  const ProfileCardPalette({
    required this.cardGradient,
    required this.placeholderGradient,
    required this.surfaceTint,
    required this.surfaceBorder,
    required this.buttonFill,
    required this.buttonForeground,
  });

  factory ProfileCardPalette.fromGender(String? gender) {
    switch (normalizedProfileGender(gender)) {
      case 'female':
        return const ProfileCardPalette(
          cardGradient: [
            Color(0xFF9C2F61),
            Color(0xFF7D1E56),
            Color(0xFF571339),
          ],
          placeholderGradient: [
            Color(0xFFE58BB7),
            Color(0xFF9C2F61),
          ],
          surfaceTint: Color(0x1FFCE8F2),
          surfaceBorder: Color(0x38FFD8E8),
          buttonFill: Color(0xFFFBE6F0),
          buttonForeground: Color(0xFF7D1E56),
        );
      case 'male':
        return const ProfileCardPalette(
          cardGradient: [
            Color(0xFF244C8F),
            Color(0xFF173569),
            Color(0xFF0D1F45),
          ],
          placeholderGradient: [
            Color(0xFF7BA4E6),
            Color(0xFF244C8F),
          ],
          surfaceTint: Color(0x1FEAF2FF),
          surfaceBorder: Color(0x384F78B8),
          buttonFill: Color(0xFFE8F0FF),
          buttonForeground: Color(0xFF173569),
        );
      default:
        return const ProfileCardPalette(
          cardGradient: [
            Color(0xFF8A57C4),
            Color(0xFF4E79CB),
            Color(0xFFC25E96),
          ],
          placeholderGradient: [
            Color(0xFFC49BE2),
            Color(0xFF6B6FD4),
          ],
          surfaceTint: Color(0x1EF4EEFF),
          surfaceBorder: Color(0x386F87DD),
          buttonFill: Color(0xFFF0E9FF),
          buttonForeground: Color(0xFF5F58B8),
        );
    }
  }
}
