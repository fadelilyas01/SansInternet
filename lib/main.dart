import 'package:flutter/material.dart';
import 'package:sans_internet/core/theme/mesh_design_tokens.dart';
import 'package:sans_internet/features/mesh/presentation/controllers/mesh_controller.dart';
import 'package:sans_internet/features/mesh/presentation/pages/mesh_radar_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = MeshController();
  runApp(SansInternetApp(controller: controller));
}

/// Application principale de messagerie hors-ligne sécurisée (Zero-Server P2P Mesh).
class SansInternetApp extends StatelessWidget {
  final MeshController controller;

  const SansInternetApp({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SansInternet P2P E2EE',
      debugShowCheckedModeBanner: false,
      theme: MeshDesignTokens.buildMeshTheme(),
      darkTheme: MeshDesignTokens.buildMeshTheme(),
      themeMode: ThemeMode.dark,
      home: MeshRadarPage(controller: controller),
    );
  }
}
