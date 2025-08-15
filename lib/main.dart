import 'package:flutter/material.dart';
import 'screens/home_screen.dart';

void main() {
  // Dica de diagnóstico: mude o valor ao buildar
  // debugPrint('build-tag: 2025-08-15_12h v0.1.3');
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Saldo via Pluggy',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFF2E7D32)),
      home: const HomeScreen(),
    );
  }
}
