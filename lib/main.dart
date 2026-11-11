import 'dart:math';
import 'package:flutter/material.dart';
import 'package:sans_internet/core/storage/encrypted_database.dart';
import 'package:sans_internet/core/theme/mesh_design_tokens.dart';
import 'package:sans_internet/features/mesh/data/dart_crypto_session_bridge.dart';
import 'package:sans_internet/features/mesh/data/p2p_transport_service.dart';
import 'package:sans_internet/features/mesh/presentation/controllers/mesh_controller.dart';
import 'package:sans_internet/features/mesh/presentation/pages/mesh_radar_page.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialisation sécurisée du coffre SQLCipher (AES-256)
  Database? db;
  try {
    final dbManager = EncryptedDatabaseManager();
    db = await dbManager.database;
  } catch (_) {
    // Mode Fail-Safe si environnement sans SQLite natif
  }

  // Génération de l'identifiant local cryptographique (CSPRNG 256 bits)
  final csprng = Random.secure();
  final idBytes = List<int>.generate(32, (_) => csprng.nextInt(256));
  final localPeerId =
      idBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  // Pont cryptographique pur Dart (X25519 + ChaCha20-Poly1305 + HKDF)
  final cryptoBridge = DartCryptoSessionBridge();

  // Service de transport radio natif (BLE L2CAP / GATT / Nearby)
  final transportService = P2PTransportService(
    db: db,
    crypto: cryptoBridge,
    localPeerId: localPeerId,
  );

  final controller = MeshController(transportService: transportService);
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
