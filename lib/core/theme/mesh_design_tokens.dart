import 'package:flutter/material.dart';

/// Tokens de design de la palette "Deep Obsidian & Electric Teal" pour messagerie P2P Mesh,
/// respectant une grille stricte de 8pt et les ratios de contraste WCAG AA/AAA.
abstract final class MeshDesignTokens {
  // Grille d'espacement 8pt
  static const double spaceMicro = 4.0;
  static const double spaceCompact = 8.0;
  static const double spaceMedium = 12.0;
  static const double spaceGutter = 16.0;
  static const double spaceSection = 24.0;
  static const double spaceDock = 32.0;

  // Cible tactile minimale stricte (Loi de Fitts - 48x48 dp)
  static const double minTouchTarget = 48.0;

  // Rayons de bordure sobres
  static const BorderRadius radiusCard = BorderRadius.all(Radius.circular(12.0));
  static const BorderRadius radiusBubble = BorderRadius.all(Radius.circular(16.0));
  static const BorderRadius radiusPill = BorderRadius.all(Radius.circular(24.0));

  // Palette Officielle "Deep Obsidian & Electric Teal"
  /// Background — Deep Obsidian (`#0F141C`)
  static const Color backgroundDeepObsidian = Color(0xFF0F141C);

  /// Surface / Card — Midnight Slate (`#1B2432`)
  static const Color surfaceMidnightSlate = Color(0xFF1B2432);

  /// Primary Accent — Electric Teal (`#00D2B4`)
  static const Color primaryElectricTeal = Color(0xFF00D2B4);

  /// Sent Bubble — Dark Petrol Teal (`#084C59`)
  static const Color sentBubblePetrolTeal = Color(0xFF084C59);

  /// Received Bubble — Slate Gray (`#1F2937`)
  static const Color receivedBubbleSlateGray = Color(0xFF1F2937);

  /// Status: Online / Verified — Node Green (`#10B981`)
  static const Color statusNodeGreen = Color(0xFF10B981);

  /// Status: Pending / Hop — Mesh Amber (`#F59E0B`)
  static const Color statusMeshAmber = Color(0xFFF59E0B);

  /// Text Primary — Crisp Off-White (`#F8FAFC`)
  static const Color textCrispOffWhite = Color(0xFFF8FAFC);

  /// Text Muted — Signal Gray (`#94A3B8`)
  static const Color textSignalGray = Color(0xFF94A3B8);

  /// Bordure de séparation subtile dérivée de Midnight Slate / Signal Gray
  static const Color borderSlate = Color(0xFF283548);

  /// État d'erreur / révocation
  static const Color statusDangerCrimson = Color(0xFFEF4444);

  // Alias sémantiques utilisés par les composants
  static const Color accentPrimary = primaryElectricTeal;
  static const Color statusVerifiedEmerald = statusNodeGreen;
  static const Color statusPendingAmber = statusMeshAmber;

  // Courbe d'animation GPU Apple HIG Ease-Out Expo
  static const Curve gpuCurve = Cubic(0.16, 1.0, 0.3, 1.0);
  static const Duration microDuration = Duration(milliseconds: 220);

  /// Thème principal basé sur la charte Deep Obsidian & Electric Teal.
  static ThemeData buildMeshTheme() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: backgroundDeepObsidian,
      colorScheme: const ColorScheme.dark(
        surface: surfaceMidnightSlate,
        primary: primaryElectricTeal,
        onPrimary: backgroundDeepObsidian,
        secondary: statusNodeGreen,
        onSecondary: backgroundDeepObsidian,
        error: statusDangerCrimson,
        onSurface: textCrispOffWhite,
        outline: borderSlate,
      ),
      cardTheme: const CardThemeData(
        color: surfaceMidnightSlate,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: radiusCard,
          side: BorderSide(color: borderSlate, width: 1.0),
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: surfaceMidnightSlate,
        foregroundColor: textCrispOffWhite,
        elevation: 0,
        centerTitle: false,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primaryElectricTeal,
          foregroundColor: backgroundDeepObsidian,
          textStyle: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 14,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primaryElectricTeal,
          side: const BorderSide(color: primaryElectricTeal, width: 1.2),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: backgroundDeepObsidian,
        hintStyle: TextStyle(color: textSignalGray, fontSize: 14),
      ),
    );
  }

  static ThemeData buildLightTheme() => buildMeshTheme();
  static ThemeData buildDarkTheme() => buildMeshTheme();
}
