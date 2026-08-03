import 'package:flutter/material.dart';

import 'package:tl_chat/pages/home_page.dart';
import 'package:tl_chat/theme/telegram_theme.dart';

class ChatApp extends StatefulWidget {
  const ChatApp({super.key});

  @override
  State<ChatApp> createState() => _ChatAppState();
}

class _ChatAppState extends State<ChatApp> {
  bool _dark = false;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TL Chat',
      debugShowCheckedModeBanner: false,
      theme: telegramLightTheme(),
      darkTheme: telegramDarkTheme(),
      themeMode: _dark ? ThemeMode.dark : ThemeMode.light,
      home: HomePage(
        dark: _dark,
        onToggleTheme: () {
          setState(() => _dark = !_dark);
        },
      ),
    );
  }
}
