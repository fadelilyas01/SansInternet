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

  test('Vérifie la rotation du QR code éphémère (15 min) et la persistance des contacts appairés', () async {
    final alice = MeshController();
    final bob = MeshController();

    // 1. Génération du premier QR code d'Alice
    final qrPayload1 = alice.localQrPayload;
    expect(qrPayload1, contains('epoch='));
    expect(qrPayload1, contains('tk='));
    expect(alice.secondsUntilNextQrRotation, inInclusiveRange(1, 15 * 60));

    // 2. Bob scanne le QR code d'Alice et s'appaire avec succès
    final pairedPeer = bob.pairPeerFromQrData(qrPayload1);
    expect(pairedPeer, isNotNull);
    expect(pairedPeer?.peerId, equals(alice.localPeerId));
    expect(pairedPeer?.verificationStatus, equals(PeerVerificationStatus.qrVerified));
    expect(pairedPeer?.linkState, equals(PeerLinkState.authenticated));

    // 3. Alice renouvelle son QR code (rotation manuelle ou écoulement des 15 minutes)
    alice.rotateQrCodeNow();
    final qrPayload2 = alice.localQrPayload;
    expect(qrPayload2, isNot(equals(qrPayload1))); // Le QR code a bien changé

    // 4. Bob a toujours Alice dans ses contacts, inchangée et authentifiée
    final bobContactIndex = bob.peers.indexWhere((p) => p.peerId == alice.localPeerId);
    expect(bobContactIndex, isNot(equals(-1)));
    expect(bob.peers[bobContactIndex].verificationStatus, equals(PeerVerificationStatus.qrVerified));

    // 5. Un tiers tente de scanner un QR code expiré de plus de 24h (100 époques) : Rejet strict anti-rejeu
    final expiredQr =
        'sansinternet://pair?id=malicious_node_999&name=Attaque&fp=DEAD-BEEF&epoch=${alice.currentQrEpoch - 100}&tk=12345678';
    final resultExpired = bob.pairPeerFromQrData(expiredQr);
    expect(resultExpired, isNull); // Rejeté car périmé !
  });
}
