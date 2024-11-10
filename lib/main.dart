import 'dart:async';

import 'package:flutter/material.dart';
import 'connection_app_screen.dart';
import 'logger.dart';

void main() async {
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();

      runApp(MyApp());
    },
    (error, stackTrace) {
      talker.handle(error, stackTrace, 'Uncaught app exception');
    },
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      debugShowCheckedModeBanner: false,
      home: ConnectionStatusApp(),
    );
  }
}
