import 'package:flutter/material.dart';

import 'safety_dashboard.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HerMoveApp());
}

class HerMoveApp extends StatelessWidget {
  const HerMoveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'HERMOVE',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF21D4C2),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF06131F),
      ),
      home: SafetyDashboard(
        onEmergencyApiCall: (payload) async {
          debugPrint('[HERMOVE] Emergency API payload: $payload');
        },
      ),
    );
  }
}