import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:sans_internet/features/mesh/domain/entities/mesh_packet.dart';

/// Résultat du traitement d'un paquet multi-sauts reçu par le smartphone.
enum PacketProcessResult {
  /// Le paquet a déjà été vu (déduplication active, rejeté).
  duplicate,

  /// Le paquet est destiné au smartphone local et a été délivré.
  deliveredLocally,

  /// Accusé de réception (ACK) reçu pour un message émis par ce smartphone.
  ackProcessed,

  /// Le paquet est destiné à un autre contact et a été mis en mémoire pour relais.
  relayedForPeer,

  /// Le paquet a atteint son nombre maximal de sauts (TTL expiré).
  ttlExpired,
}

/// Moteur de relais multi-sauts décentralisé (Store-and-Forward / DTN).
///
/// Permet à chaque smartphone exécutant SansInternet de servir de relais sécurisé
/// passif et anonyme pour étendre la portée de communication à toute une ville
/// ou région sans connexion Internet.
final class MultiHopRelayService extends ChangeNotifier {
  final String _localPeerId;
  final int _maxCachedIds;
  final int _maxOutboxCapacity;

  /// Cache LRU d'identifiants de paquets déjà vus pour déduplication stricte.
  final LinkedHashSet<String> _seenPacketIds = LinkedHashSet<String>();

  /// File d'attente Store-and-Forward des paquets en transit portés par ce téléphone.
  final List<MeshPacket> _relayOutbox = [];

  /// Compteur de paquets anonymes relayés avec succès pour étendre la portée du réseau.
  int _packetsRelayedCount = 0;

  /// Flux d'événements pour les messages reçus destinés à l'utilisateur local.
  final StreamController<MeshPacket> _localIncomingDataController =
      StreamController<MeshPacket>.broadcast();

  /// Flux d'accusés de réception pour les messages émis par l'utilisateur local.
  final StreamController<String> _deliveryAckController =
      StreamController<String>.broadcast();

  Stream<MeshPacket> get onLocalMessageReceived =>
      _localIncomingDataController.stream;

  Stream<String> get onDeliveryAckReceived =>
      _deliveryAckController.stream;

  int get packetsRelayedCount => _packetsRelayedCount;
  int get outboxSize => _relayOutbox.length;
  List<MeshPacket> get pendingRelayPackets => List.unmodifiable(_relayOutbox);

  MultiHopRelayService({
    required String localPeerId,
    int maxCachedIds = 2000,
    int maxOutboxCapacity = 200,
  })  : _localPeerId = localPeerId,
        _maxCachedIds = maxCachedIds,
        _maxOutboxCapacity = maxOutboxCapacity;

  /// Traite un paquet reçu depuis les ondes (Bluetooth BLE, Wi-Fi Direct ou LoRa).
  PacketProcessResult processIncomingPacket(MeshPacket packet) {
    // 1. Déduplication stricte (anti-boucle réseau)
    if (_seenPacketIds.contains(packet.packetId)) {
      return PacketProcessResult.duplicate;
    }

    _recordSeenPacketId(packet.packetId);

    // 2. Vérification de la destination : est-ce pour nous ?
    if (packet.destinationPeerId == _localPeerId || packet.destinationPeerId == '*') {
      if (packet.packetType == MeshPacketType.deliveryAck) {
        if (packet.ackTargetPacketId != null) {
          _deliveryAckController.add(packet.ackTargetPacketId!);
        }
        return PacketProcessResult.ackProcessed;
      }

      // Message destiné à l'utilisateur local
      _localIncomingDataController.add(packet);

      // Si c'est un message direct individuel, générer automatiquement un ACK
      if (packet.destinationPeerId == _localPeerId) {
        _queueDeliveryAck(packet.packetId, packet.sourcePeerId);
      }

      return PacketProcessResult.deliveredLocally;
    }

    // 3. Le message est pour un tiers : agir en relais citoyen sécurisé (Store-and-Forward)
    if (!packet.canBeRelayed) {
      return PacketProcessResult.ttlExpired;
    }

    // Incrémente le compteur de sauts
    final forwardedPacket = packet.incrementHop();
    _enqueueForRelay(forwardedPacket);
    _packetsRelayedCount++;
    notifyListeners();

    return PacketProcessResult.relayedForPeer;
  }

  /// Crée et prépare un paquet sortant initial émis par l'utilisateur local.
  MeshPacket createOutboundDataPacket({
    required String destinationPeerId,
    required String encryptedPayload,
    int maxHops = 7,
  }) {
    final packet = MeshPacket.create(
      sourcePeerId: _localPeerId,
      destinationPeerId: destinationPeerId,
      packetType: MeshPacketType.dataMessage,
      encryptedPayload: encryptedPayload,
      maxHops: maxHops,
    );

    _recordSeenPacketId(packet.packetId);
    _enqueueForRelay(packet);
    return packet;
  }

  /// Génère un accusé de réception cryptographique pour confirmer la remise d'un paquet.
  void _queueDeliveryAck(String originalPacketId, String originPeerId) {
    final ackPacket = MeshPacket.create(
      sourcePeerId: _localPeerId,
      destinationPeerId: originPeerId,
      packetType: MeshPacketType.deliveryAck,
      encryptedPayload: '',
      ackTargetPacketId: originalPacketId,
      maxHops: 7,
    );

    _recordSeenPacketId(ackPacket.packetId);
    _enqueueForRelay(ackPacket);
  }

  /// Synchronise les paquets en attente avec un pair qui entre à portée radio.
  Future<int> flushOutboxToPeer(
    String peerId,
    Future<bool> Function(MeshPacket packet) transmitCallback,
  ) async {
    if (_relayOutbox.isEmpty) return 0;

    int transmittedCount = 0;
    final toRemove = <MeshPacket>[];

    for (final packet in List<MeshPacket>.from(_relayOutbox)) {
      // Ne pas renvoyer le paquet à son émetteur initial
      if (packet.sourcePeerId == peerId) continue;

      try {
        final success = await transmitCallback(packet);
        if (success) {
          transmittedCount++;
          // Si le pair était la destination finale, retirer de la file de relais locale
          if (packet.destinationPeerId == peerId) {
            toRemove.add(packet);
          }
        }
      } catch (_) {
        // En cas d'erreur de transmission radio, conserver dans l'Outbox pour le prochain pair
      }
    }

    if (toRemove.isNotEmpty) {
      _relayOutbox.removeWhere(toRemove.contains);
      notifyListeners();
    }

    return transmittedCount;
  }

  void _enqueueForRelay(MeshPacket packet) {
    // Si la capacité maximale est atteinte, purge du plus ancien (politique FIFO DTN)
    if (_relayOutbox.length >= _maxOutboxCapacity) {
      _relayOutbox.removeAt(0);
    }
    _relayOutbox.add(packet);
  }

  void _recordSeenPacketId(String packetId) {
    if (_seenPacketIds.length >= _maxCachedIds) {
      _seenPacketIds.remove(_seenPacketIds.first);
    }
    _seenPacketIds.add(packetId);
  }

  @override
  void dispose() {
    _localIncomingDataController.close();
    _deliveryAckController.close();
    super.dispose();
  }
}

