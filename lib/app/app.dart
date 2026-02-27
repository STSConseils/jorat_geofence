import 'dart:async';

import 'package:flutter/material.dart';

import '../screens/map_screen.dart';
import '../services/tracking_controller.dart';

class JoratApp extends StatefulWidget {
  const JoratApp({super.key});

  @override
  State<JoratApp> createState() => _JoratAppState();
}

class _JoratAppState extends State<JoratApp> with WidgetsBindingObserver {
  final TrackingController _trackingController = TrackingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _trackingController.initialize(autoStart: true);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_trackingController.forceAutoSave());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_trackingController.forceAutoSave());
    _trackingController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Jorat',
      theme: ThemeData(useMaterial3: true),
      home: MapScreen(trackingController: _trackingController),
    );
  }
}
