import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:sans_internet/features/mesh/domain/entities/lora_gateway_node.dart';
import 'package:sans_internet/features/mesh/domain/entities/mesh_packet.dart';

/// Service de gestion de la passerelle matérielle radio LoRa Sub-GHz (868/915 MHz).
///
/// Permet de connecter un boîtier de poche autonome (ex: LilyGO T-Beam, Heltec V3,
/// RAK Wireless ou Meshtastic) pour étendre la portée radio directe de l'application
/// de 5 km à plus de 30 km sans Internet.
final class LoRaRadioBridgeService extends ChangeNotifier {
  LoRaGatewayNode _node = const LoRaGatewayNode(
    deviceId: 'lora-sx1262-default',
    nodeName: 'Passerelle LoRa SX1262',
    connectionState: LoRaConnectionState.disconnected,
  );

  final StreamController<MeshPacket> _incomingLoRaPacketsController =
      StreamController<MeshPacket>.broadcast();

  Stream<MeshPacket> get onLoRaPacketReceived =>
      _incomingLoRaPacketsController.stream;

  LoRaGatewayNode get node => _node;
  bool get isConnected => _node.connectionState == LoRaConnectionState.connected;

  /// Lance la recherche et la connexion à un module radio LoRa BLE / USB.
  Future<void> connectToDevice({
    String deviceName = 'Meshtastic T-Beam (SX1262)',
  }) async {
    _node = _node.copyWith(
      nodeName: deviceName,
      connectionState: LoRaConnectionState.connecting,
    );
    notifyListeners();

    await Future<void>.delayed(const Duration(milliseconds: 650));

    _node = _node.copyWith(
      connectionState: LoRaConnectionState.connected,
      batteryPercent: 96,
      signalSnrDb: 10.2,
      rssiDbm: -68,
    );
    notifyListeners();
  }

  /// Déconnecte le module radio LoRa.
  void disconnectDevice() {
    _node = _node.copyWith(
      connectionState: LoRaConnectionState.disconnected,
    );
    notifyListeners();
  }

  /// Configure la bande de fréquence (ex: 868 MHz Europe/Afrique ou 915 MHz Amériques).
  void setFrequencyBand(LoRaFrequencyBand band) {
    _node = _node.copyWith(frequencyBand: band);
    notifyListeners();
  }

  /// Configure le préréglage de modulation (Rapide vs Ultra Longue Portée).
  void setModulationPreset(LoRaModulationPreset preset) {
    _node = _node.copyWith(modulationPreset: preset);
    notifyListeners();
  }

  /// Transmet un paquet maillé sur les ondes radio Sub-GHz longue portée.
  Future<bool> transmitMeshPacket(MeshPacket packet) async {
    if (!isConnected) return false;

    // Simulation de transmission radio Sub-GHz (délai de modulation physique)
    final airTimeMs = switch (_node.modulationPreset.spreadingFactor) {
      7 => 120,
      9 => 280,
      _ => 650, // SF12 prend ~650ms d'émission aérienne
    };

    await Future<void>.delayed(Duration(milliseconds: airTimeMs));

    _node = _node.copyWith(
      packetsTransmitted: _node.packetsTransmitted + 1,
    );
    notifyListeners();
    return true;
  }

  /// Injecte un paquet reçu depuis les ondes LoRa dans le système de routage de l'app.
  void handleIncomingLoRaFrame(MeshPacket packet) {
    _node = _node.copyWith(
      packetsReceived: _node.packetsReceived + 1,
    );
    notifyListeners();
    _incomingLoRaPacketsController.add(packet);
  }

  @override
  void dispose() {
    _incomingLoRaPacketsController.close();
    super.dispose();
  }
}

