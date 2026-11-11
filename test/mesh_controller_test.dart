import 'package:flutter_test/flutter_test.dart';
import 'package:sans_internet/features/mesh/domain/entities/chat_message.dart';
import 'package:sans_internet/features/mesh/domain/entities/lora_gateway_node.dart';
import 'package:sans_internet/features/mesh/domain/entities/mesh_packet.dart';
import 'package:sans_internet/features/mesh/domain/entities/mesh_peer.dart';
import 'package:sans_internet/features/mesh/domain/services/lora_radio_bridge_service.dart';
import 'package:sans_internet/features/mesh/domain/services/multi_hop_relay_service.dart';
import 'package:sans_internet/features/mesh/presentation/controllers/mesh_controller.dart';
import 'package:sans_internet/main.dart';

void main() {
  testWidgets(
    'Vérifie le cycle complet des états UI, du Store-and-Forward Outbox et de la certification QR',
    (WidgetTester tester) async {
      final controller = MeshController();
      await tester.pumpWidget(SansInternetApp(controller: controller));

      // 1. État Loading initial (Skeleton GPU)
      expect(controller.status, equals(MeshViewStatus.loading));

      // Exécute le postFrameCallback puis avance l'horloge au-delà du délai de découverte
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      // 2. État Nominal avec les pairs découverts
      expect(controller.status, equals(MeshViewStatus.nominal));
      expect(controller.peers.length, equals(3));
      expect(find.textContaining('Dr. Clara Vance'), findsOneWidget);
      expect(find.textContaining('Relais Logistique Nord'), findsOneWidget);
      expect(find.textContaining('Poste Secours Vallée'), findsOneWidget);

      // 3. Test du Store-and-Forward sur le pair hors-portée (Relais Logistique Nord)
      final offlinePeer = controller.peers[1];
      expect(offlinePeer.linkState, equals(PeerLinkState.offline));

      await controller.sendMessage(
        peerId: offlinePeer.peerId,
        rawText: 'Message mis en file Outbox pendant la coupure radio',
      );

      final queuedMessages = controller.messagesForPeer(offlinePeer.peerId);
      expect(
        queuedMessages.last.deliveryStatus,
        equals(MessageDeliveryStatus.queued),
      );

      // Simulation du retour à portée radio : l'Outbox doit se vider et passer à delivered
      final toggleFuture = controller.togglePeerLinkState(offlinePeer.peerId);
      await tester.pump(const Duration(milliseconds: 600));
      await toggleFuture;

      final syncedMessages = controller.messagesForPeer(offlinePeer.peerId);
      expect(
        syncedMessages.last.deliveryStatus,
        equals(MessageDeliveryStatus.delivered),
      );
    },
  );

  test('Vérifie le moteur de routage multi-sauts et la déduplication DTN', () async {
    final relay = MultiHopRelayService(localPeerId: 'local_node_123');

    // 1. Paquet destiné à un tiers : le téléphone doit le relayer et incrémenter les sauts
    final packetForBob = MeshPacket.create(
      sourcePeerId: 'alice_001',
      destinationPeerId: 'bob_999',
      packetType: MeshPacketType.dataMessage,
      encryptedPayload: 'ENCRYPTED_PAYLOAD_ABC',
      maxHops: 5,
    );

    final result1 = relay.processIncomingPacket(packetForBob);
    expect(result1, equals(PacketProcessResult.relayedForPeer));
    expect(relay.packetsRelayedCount, equals(1));
    expect(relay.outboxSize, equals(1));

    // Compteur de saut incrémenté
    final queued = relay.pendingRelayPackets.first;
    expect(queued.hopCount, equals(1));

    // 2. Déduplication stricte : si le même paquet est reçu à nouveau, il doit être ignoré
    final resultDuplicate = relay.processIncomingPacket(packetForBob);
    expect(resultDuplicate, equals(PacketProcessResult.duplicate));
    expect(relay.packetsRelayedCount, equals(1)); // Pas d'incrément supplémentaire

    // 3. Paquet destiné à ce téléphone : il doit être délivré localement
    final packetForMe = MeshPacket.create(
      sourcePeerId: 'carol_777',
      destinationPeerId: 'local_node_123',
      packetType: MeshPacketType.dataMessage,
      encryptedPayload: 'Bonjour en direct !',
    );

    MeshPacket? deliveredPacket;
    final sub = relay.onLocalMessageReceived.listen((p) => deliveredPacket = p);

    final resultLocal = relay.processIncomingPacket(packetForMe);
    expect(resultLocal, equals(PacketProcessResult.deliveredLocally));

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(deliveredPacket, isNotNull);
    expect(deliveredPacket?.encryptedPayload, equals('Bonjour en direct !'));

    await sub.cancel();
    relay.dispose();
  });

  test('Vérifie la passerelle LoRa Sub-GHz et le couplage de modulation', () async {
    final lora = LoRaRadioBridgeService();
    expect(lora.isConnected, isFalse);

    // Connexion au boîtier
    await lora.connectToDevice(deviceName: 'Heltec V3 (SX1262)');
    expect(lora.isConnected, isTrue);
    expect(lora.node.nodeName, equals('Heltec V3 (SX1262)'));
    expect(lora.node.batteryPercent, equals(96));

    // Changement de bande de fréquence (Europe 868 -> Amériques 915)
    lora.setFrequencyBand(LoRaFrequencyBand.us915);
    expect(lora.node.frequencyBand, equals(LoRaFrequencyBand.us915));
    expect(lora.node.frequencyBand.frequencyMhz, equals(915.0));

    // Changement de préréglage de modulation (Ultra Longue Portée 30 km)
    lora.setModulationPreset(LoRaModulationPreset.extremeLongRange);
    expect(lora.node.modulationPreset.spreadingFactor, equals(12));

    // Transmission d'un paquet
    final packet = MeshPacket.create(
      sourcePeerId: 'node_a',
      destinationPeerId: 'node_b',
      packetType: MeshPacketType.dataMessage,
      encryptedPayload: 'HELLO_LORA',
    );

    final sent = await lora.transmitMeshPacket(packet);
    expect(sent, isTrue);
    expect(lora.node.packetsTransmitted, equals(1));

    lora.disconnectDevice();
    expect(lora.isConnected, isFalse);
    lora.dispose();
  });
}
