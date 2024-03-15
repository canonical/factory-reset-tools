import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:yaru/yaru.dart';
import 'package:yaru_widgets/yaru_widgets.dart';
import 'dart:async';
import 'pages/home.dart';
import 'package:ubuntu_localizations/ubuntu_localizations.dart';

const int minimumRequiredDiskSize = 12 << 30;

Future<void> main() async {
  await YaruWindowTitleBar.ensureInitialized();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return YaruTheme(
      builder: (context, yaru, child) {
        return MaterialApp(
          title: 'Yaru',
          theme: yaru.theme,
          darkTheme: yaru.darkTheme,
          highContrastTheme: yaruHighContrastLight,
          highContrastDarkTheme: yaruHighContrastDark,
          home: const Home(),
          scrollBehavior: const MaterialScrollBehavior().copyWith(
            dragDevices: {
              PointerDeviceKind.mouse,
              PointerDeviceKind.touch,
              PointerDeviceKind.stylus,
              PointerDeviceKind.unknown,
              PointerDeviceKind.trackpad,
            },
          ),
          localizationsDelegates: UbuntuLocalizations.localizationsDelegates,
          supportedLocales: UbuntuLocalizations.supportedLocales,
        );
      },
    );
  }
}
