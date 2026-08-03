// Telegram-style design system (light + dark), palette ported from the
// Telegram mobile app: blue accent #3390ec, light-gray-blue chat canvas,
// white incoming / pale-green outgoing bubbles; dark variant with
// #0e1621 canvas, #182533 incoming, #2b5278 outgoing.

import 'package:flutter/material.dart';

abstract final class Tg {
  // ─── Light theme ────────────────────────────────────────────────────
  static const blue = Color(0xff3390ec); // Telegram action blue
  static const lightChatBg = Color(0xffe7ebf0); // chat canvas
  static const lightPanel = Color(0xffffffff);
  static const lightIncoming = Color(0xffffffff);
  static const lightOutgoing = Color(0xffeffdde);
  static const lightText = Color(0xff0f0f0f);
  static const lightSubtext = Color(0xff7d8a93);
  static const lightHairline = Color(0xffdfe5ea);

  // ─── Dark theme ─────────────────────────────────────────────────────
  static const darkChatBg = Color(0xff0e1621);
  static const darkPanel = Color(0xff17212b);
  static const darkElevated = Color(
    0xff1c2733,
  ); // one step up from panel (sheets/dialogs)
  static const darkIncoming = Color(0xff182533);
  static const darkOutgoing = Color(0xff2b5278);
  static const darkText = Color(0xfff5f5f5);
  static const darkSubtext = Color(0xff708499);
  static const darkHairline = Color(0xff101921);

  // ─── Shared ─────────────────────────────────────────────────────────
  static const online = Color(0xff4fae4e);
  static const sent = Color(0xff83939c); // checkmark gray
  static const read = Color(0xff4d9de0); // double-check blue
  static const error = Color(0xffff5c5c);

  /// Telegram's avatar color palette (per-user deterministic hue).
  static const avatarPalette = <Color>[
    Color(0xffe17076), // red
    Color(0xfffaa774), // orange
    Color(0xffa695e7), // violet
    Color(0xff7bc862), // green
    Color(0xff6ec9cb), // cyan
    Color(0xff65aadd), // blue
    Color(0xffee7aae), // pink
  ];

  /// Deterministic avatar color for [seed] (node id / room id).
  static Color avatarFor(String seed) {
    if (seed.isEmpty) return avatarPalette.first;
    var h = 0;
    for (final c in seed.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return avatarPalette[h % avatarPalette.length];
  }
}

/// Theme-adaptive accessor: `Tg.of(context).chatBg` etc.
class TgPalette {
  const TgPalette({required this.dark});

  final bool dark;

  Color get chatBg => dark ? Tg.darkChatBg : Tg.lightChatBg;
  Color get panel => dark ? Tg.darkPanel : Tg.lightPanel;
  Color get elevated => dark ? Tg.darkElevated : Tg.lightPanel;
  Color get incoming => dark ? Tg.darkIncoming : Tg.lightIncoming;
  Color get outgoing => dark ? Tg.darkOutgoing : Tg.lightOutgoing;
  Color get text => dark ? Tg.darkText : Tg.lightText;
  Color get subtext => dark ? Tg.darkSubtext : Tg.lightSubtext;
  Color get hairline => dark ? Tg.darkHairline : Tg.lightHairline;

  static TgPalette of(BuildContext context) =>
      TgPalette(dark: Theme.of(context).brightness == Brightness.dark);
}

/// Telegram-style circular avatar: deterministic color from [Tg.avatarFor],
/// an initial letter (or `#` for rooms), and an optional online dot.
class TgAvatar extends StatelessWidget {
  const TgAvatar({
    super.key,
    required this.id,
    required this.size,
    required this.title,
    this.online = false,
    this.isRoom = false,
  });

  final String id;
  final double size;
  final String title;
  final bool online;
  final bool isRoom;

  @override
  Widget build(BuildContext context) {
    final initial = isRoom
        ? '#'
        : (title.isNotEmpty ? title[0].toUpperCase() : '?');
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Tg.avatarFor(id),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Text(
            initial,
            style: TextStyle(
              color: Colors.white,
              fontSize: size * 0.42,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (online)
            Positioned(
              right: -1,
              bottom: -1,
              child: Container(
                width: size * 0.28,
                height: size * 0.28,
                decoration: BoxDecoration(
                  color: Tg.online,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: TgPalette.of(context).panel,
                    width: 2,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

ThemeData telegramLightTheme() => _buildTheme(dark: false);

ThemeData telegramDarkTheme() => _buildTheme(dark: true);

ThemeData _buildTheme({required bool dark}) {
  final palette = TgPalette(dark: dark);
  final scheme = ColorScheme.fromSeed(
    seedColor: Tg.blue,
    brightness: dark ? Brightness.dark : Brightness.light,
    primary: Tg.blue,
    surface: palette.panel,
    onSurface: palette.text,
    error: Tg.error,
  );

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: palette.panel,
    fontFamily: 'Roboto',
  );

  return base.copyWith(
    textTheme: base.textTheme.copyWith(
      titleLarge: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: palette.text,
      ),
      titleMedium: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: palette.text,
      ),
      titleSmall: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: palette.text,
      ),
      bodyMedium: TextStyle(fontSize: 15, height: 1.4, color: palette.text),
      bodySmall: TextStyle(fontSize: 13, height: 1.4, color: palette.subtext),
      labelMedium: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      labelSmall: const TextStyle(fontSize: 12, letterSpacing: 0.2),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: palette.panel,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      iconTheme: IconThemeData(color: Tg.blue),
      titleTextStyle: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: palette.text,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xff242f3d) : const Color(0xfff1f3f5),
      hintStyle: TextStyle(color: palette.subtext),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Tg.blue, width: 1.4),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Tg.blue,
        foregroundColor: Colors.white,
        disabledBackgroundColor: Tg.blue.withValues(alpha: 0.4),
        disabledForegroundColor: Colors.white70,
        minimumSize: const Size(64, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: palette.hairline,
      thickness: 0.6,
      space: 0.6,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: palette.elevated,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: palette.elevated,
      surfaceTintColor: Colors.transparent,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: dark ? const Color(0xff2b3949) : const Color(0xff333333),
      contentTextStyle: const TextStyle(color: Colors.white),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
