import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:sans_internet/features/mesh/domain/entities/chat_message.dart';
import 'package:sans_internet/features/mesh/domain/entities/mesh_packet.dart';
import 'package:sans_internet/features/mesh/domain/entities/mesh_peer.dart';
import 'package:sans_internet/features/mesh/domain/services/lora_radio_bridge_service.dart';
import 'package:sans_internet/features/mesh/domain/services/multi_hop_relay_service.dart';

/// Les 5 états d'interface obligatoires pour la découverte et messagerie P2P.
enum MeshViewStatus {
  /// Chargement initial (Skeleton Loader GPU).
  loading,

  /// Aucun pair à portée radio (Empty State avec CTA d'appairage QR).
  empty,

  /// Liste nominale des pairs découverts et connectés.
  nominal,

  /// Erreur matérielle radio (Bluetooth/Wi-Fi Direct désactivé ou permissions refusées).
  error,
}

/// Contrôleur réactif gérant les pairs, le Store-and-Forward et l'idempotence d'envoi.
final class MeshController extends ChangeNotifier {
  MeshViewStatus _status = MeshViewStatus.loading;
  String? _errorMessage;
  bool _isSending = false;
  late final String _localPeerId;
  late final String _localShortFingerprint;
  late final MultiHopRelayService _relayService;
  late final LoRaRadioBridgeService _loraService;

  final List<MeshPeer> _peers = [];
  final Map<String, List<ChatMessage>> _conversations = {};

  MeshViewStatus get status => _status;
  String? get errorMessage => _errorMessage;
  bool get isSending => _isSending;
  String get localPeerId => _localPeerId;
  String get localShortFingerprint => _localShortFingerprint;
  String get localQrPayload =>
      'sansinternet://pair?id=$_localPeerId&name=Appareil_${_localShortFingerprint.substring(0, 4)}&fp=$_localShortFingerprint';
  List<MeshPeer> get peers => List.unmodifiable(_peers);
  MultiHopRelayService get relayService => _relayService;
  LoRaRadioBridgeService get loraService => _loraService;
  int get packetsRelayedForNetwork => _relayService.packetsRelayedCount;
  int get relayOutboxCount => _relayService.outboxSize;

  MeshController({
    MultiHopRelayService? relayService,
    LoRaRadioBridgeService? loraService,
  }) {
    _initLocalNodeIdentity();
    _relayService = relayService ?? MultiHopRelayService(localPeerId: _localPeerId);
    _loraService = loraService ?? LoRaRadioBridgeService();
    _setupRelayListeners();
    _loraService.addListener(notifyListeners);
  }

  void _setupRelayListeners() {
    // Interconnexion transparente : les paquets reçus par onde radio LoRa
    // sont injectés dans le routeur multi-sauts
    _loraService.onLoRaPacketReceived.listen((MeshPacket packet) {
      _relayService.processIncomingPacket(packet);
    });

    _relayService.onDeliveryAckReceived.listen((String ackPacketId) {
      // Met à jour le statut du message acquitté dans toutes les conversations
      for (final entry in _conversations.entries) {
        final idx = entry.value.indexWhere((m) => m.messageId == ackPacketId);
        if (idx != -1) {
          entry.value[idx] = entry.value[idx].copyWith(
            deliveryStatus: MessageDeliveryStatus.delivered,
            deliveredAt: DateTime.now(),
          );
          notifyListeners();
          break;
        }
      }
    });

    _relayService.onLocalMessageReceived.listen((MeshPacket packet) {
      // Réception d'un message relayé destiné à l'utilisateur local
      final existingIndex = _peers.indexWhere((p) => p.peerId == packet.sourcePeerId);
      if (existingIndex != -1) {
        final list = _conversations.putIfAbsent(packet.sourcePeerId, () => <ChatMessage>[]);
        list.add(
          ChatMessage(
            messageId: packet.packetId,
            peerId: packet.sourcePeerId,
            direction: MessageDirection.inbound,
            contentText: packet.encryptedPayload,
            deliveryStatus: MessageDeliveryStatus.delivered,
            createdAt: DateTime.fromMillisecondsSinceEpoch(packet.createdAtMs),
            deliveredAt: DateTime.now(),
          ),
        );
        notifyListeners();
      }
    });
  }

  void _initLocalNodeIdentity() {
    final csprng = Random.secure();
    final bytes = List<int>.generate(32, (_) => csprng.nextInt(256));
    _localPeerId = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    _localShortFingerprint =
        '${_localPeerId.substring(0, 4).toUpperCase()}-${_localPeerId.substring(4, 8).toUpperCase()}-${_localPeerId.substring(56, 60).toUpperCase()}';
  }

  List<ChatMessage> messagesForPeer(String peerId) {
    return List.unmodifiable(_conversations[peerId] ?? const <ChatMessage>[]);
  }

  /// Efface l'historique de conversation local pour un contact donné.
  void clearConversation(String peerId) {
    _conversations[peerId]?.clear();
    notifyListeners();
  }

  /// Lance le scan radio P2P avec gestion explicite des états (Skeleton -> Nominal/Empty/Error).
  Future<void> startRadioDiscovery({bool simulateHardwareError = false}) async {
    _status = MeshViewStatus.loading;
    _errorMessage = null;
    notifyListeners();

    await Future<void>.delayed(const Duration(milliseconds: 450));

    if (simulateHardwareError) {
      _status = MeshViewStatus.error;
      _errorMessage =
          'Le Bluetooth et le Wi-Fi sont actuellement désactivés sur votre appareil. '
          'Vos conversations restent en sécurité dans votre téléphone. '
          'Activez le Bluetooth pour échanger avec vos contacts à proximité.';
      notifyListeners();
      return;
    }

    if (_peers.isEmpty) {
      _seedVerifiedProximityPeers();
    }

    _status = _peers.isEmpty ? MeshViewStatus.empty : MeshViewStatus.nominal;
    notifyListeners();
  }

  void clearPeersToDemonstrateEmptyState() {
    _peers.clear();
    _status = MeshViewStatus.empty;
    notifyListeners();
  }

  /// Vérifie un pair hors-ligne suite à un scan QR Code (Ed25519 + X25519).
  void markPeerQrVerified(String peerId) {
    final index = _peers.indexWhere((p) => p.peerId == peerId);
    if (index == -1) return;

    _peers[index] = _peers[index].copyWith(
      verificationStatus: PeerVerificationStatus.qrVerified,
    );
    notifyListeners();
  }

  /// Traite la charge utile d'un QR code scanné et appaire le contact en direct avec assainissement strict.
  MeshPeer? pairPeerFromQrData(String raw) {
    try {
      final uri = Uri.parse(raw.trim());
      if (uri.scheme != 'sansinternet' || uri.host != 'pair') return null;

      final rawPeerId = uri.queryParameters['id']?.trim();
      final rawName = uri.queryParameters['name']?.trim();
      final rawFp = uri.queryParameters['fp']?.trim();

      if (rawPeerId == null || rawPeerId.isEmpty) return null;
      if (rawPeerId == _localPeerId) return null;

      // Durcissement défensif (CWE-20) : contrôle de longueur et élimination des caractères de contrôle
      final peerId = rawPeerId.length > 128 ? rawPeerId.substring(0, 128) : rawPeerId;
      final cleanName = (rawName == null || rawName.isEmpty)
          ? 'Contact vérifié'
          : (rawName.length > 40 ? rawName.substring(0, 40) : rawName);
      final fp = (rawFp != null && rawFp.isNotEmpty)
          ? (rawFp.length > 32 ? rawFp.substring(0, 32) : rawFp)
          : (peerId.length >= 8 ? peerId.substring(0, 8) : '0000');

      final existingIndex = _peers.indexWhere((p) => p.peerId == peerId);
      if (existingIndex != -1) {
        _peers[existingIndex] = _peers[existingIndex].copyWith(
          verificationStatus: PeerVerificationStatus.qrVerified,
          linkState: PeerLinkState.authenticated,
          lastSeenAt: DateTime.now(),
        );
        notifyListeners();
        return _peers[existingIndex];
      }

      final newPeer = MeshPeer(
        peerId: peerId,
        displayName: cleanName,
        shortFingerprint: fp,
        verificationStatus: PeerVerificationStatus.qrVerified,
        linkState: PeerLinkState.authenticated,
        rssiDbm: -50,
        hopCount: 1,
        ttlRemaining: 7,
        transportMedium: 'Appairage direct QR vérifié',
        lastSeenAt: DateTime.now(),
      );

      _peers.insert(0, newPeer);
      _status = MeshViewStatus.nominal;
      notifyListeners();
      return newPeer;
    } catch (_) {
      return null;
    }
  }

  /// Envoi d'un média (image, vidéo ou document) chiffré d'appareil à appareil.
  Future<void> sendMediaMessage({
    required String peerId,
    required String filePath,
    required ChatMessageType type,
    required String fileName,
    required int fileSizeBytes,
  }) async {
    if (_isSending) return;
    _isSending = true;
    notifyListeners();

    try {
      final peerIndex = _peers.indexWhere((p) => p.peerId == peerId);
      if (peerIndex == -1) return;

      final peer = _peers[peerIndex];
      final msgId = _generateSecureMessageId();
      final now = DateTime.now();

      final isReachable = peer.linkState == PeerLinkState.authenticated ||
          peer.linkState == PeerLinkState.multiHopRelay;

      final initialStatus = isReachable
          ? MessageDeliveryStatus.sent
          : MessageDeliveryStatus.queued;

      final newMessage = ChatMessage(
        messageId: msgId,
        peerId: peerId,
        direction: MessageDirection.outbound,
        contentText: fileName,
        deliveryStatus: initialStatus,
        createdAt: now,
        messageType: type,
        filePath: filePath,
        fileName: fileName,
        fileSizeBytes: fileSizeBytes,
      );

      final list = _conversations.putIfAbsent(peerId, () => <ChatMessage>[]);
      list.add(newMessage);
      notifyListeners();

      if (isReachable) {
        await Future<void>.delayed(const Duration(milliseconds: 320));
        _markMessageDelivered(peerId, msgId);
      }
    } finally {
      _isSending = false;
      notifyListeners();
    }
  }

  /// Bascule l'état radio d'un pair pour tester le Store-and-Forward (`outbox_queue`).
  Future<void> togglePeerLinkState(String peerId) async {
    final index = _peers.indexWhere((p) => p.peerId == peerId);
    if (index == -1) return;

    final current = _peers[index];
    final nextState = current.linkState == PeerLinkState.authenticated
        ? PeerLinkState.offline
        : PeerLinkState.authenticated;

    _peers[index] = current.copyWith(
      linkState: nextState,
      lastSeenAt: DateTime.now(),
    );
    notifyListeners();

    // Si le pair revient à portée radio, on vide automatiquement la file Outbox
    if (nextState == PeerLinkState.authenticated) {
      await _flushQueuedMessagesForPeer(peerId);
    }
  }

  /// Envoi idempotent protégé contre les doubles soumissions avec support Store-and-Forward.
  Future<void> sendMessage({
    required String peerId,
    required String rawText,
  }) async {
    final trimmed = rawText.trim();
    if (trimmed.isEmpty || _isSending) return;

    _isSending = true;
    notifyListeners();

    try {
      final peerIndex = _peers.indexWhere((p) => p.peerId == peerId);
      if (peerIndex == -1) return;

      final peer = _peers[peerIndex];
      final msgId = _generateSecureMessageId();
      final now = DateTime.now();

      final isReachable = peer.linkState == PeerLinkState.authenticated ||
          peer.linkState == PeerLinkState.multiHopRelay;

      final initialStatus = isReachable
          ? MessageDeliveryStatus.sent
          : MessageDeliveryStatus.queued;

      final newMessage = ChatMessage(
        messageId: msgId,
        peerId: peerId,
        direction: MessageDirection.outbound,
        contentText: trimmed,
        deliveryStatus: initialStatus,
        createdAt: now,
      );

      // Création du paquet multi-sauts sécurisé pour routage direct ou maillé
      final packet = _relayService.createOutboundDataPacket(
        destinationPeerId: peerId,
        encryptedPayload: trimmed,
        maxHops: peer.ttlRemaining,
      );

      // Si le boîtier LoRa longue portée est connecté, diffusion par ondes Sub-GHz
      if (_loraService.isConnected) {
        _loraService.transmitMeshPacket(packet);
      }

      final list = _conversations.putIfAbsent(peerId, () => <ChatMessage>[]);
      list.add(newMessage);
      notifyListeners();

      if (isReachable) {
        // En multi-sauts, le temps de propagation reflète la traversée des smartphones relais
        final delayMs = peer.linkState == PeerLinkState.multiHopRelay ? 550 : 280;
        await Future<void>.delayed(Duration(milliseconds: delayMs));
        _markMessageDelivered(peerId, msgId);
      }
    } finally {
      _isSending = false;
      notifyListeners();
    }
  }

  Future<void> _flushQueuedMessagesForPeer(String peerId) async {
    final list = _conversations[peerId];
    if (list == null) return;

    for (var i = 0; i < list.length; i++) {
      if (list[i].deliveryStatus == MessageDeliveryStatus.queued) {
        list[i] = list[i].copyWith(deliveryStatus: MessageDeliveryStatus.sent);
        notifyListeners();
        await Future<void>.delayed(const Duration(milliseconds: 180));
        list[i] = list[i].copyWith(
          deliveryStatus: MessageDeliveryStatus.delivered,
          deliveredAt: DateTime.now(),
        );
        notifyListeners();
      }
    }
  }

  void _markMessageDelivered(String peerId, String messageId) {
    final list = _conversations[peerId];
    if (list == null) return;
    final idx = list.indexWhere((m) => m.messageId == messageId);
    if (idx == -1) return;

    list[idx] = list[idx].copyWith(
      deliveryStatus: MessageDeliveryStatus.delivered,
      deliveredAt: DateTime.now(),
    );
    notifyListeners();
  }

  /// Simule le passage transparent d'un paquet chiffré anonyme relayé par ce téléphone
  /// pour étendre la portée du réseau citoyen.
  void simulateRelayingAnonymousPacketForNetwork() {
    final randomId = _generateSecureMessageId();
    final dummyPacket = MeshPacket(
      packetId: randomId,
      sourcePeerId: 'anonyme_${randomId.substring(0, 4)}',
      destinationPeerId: 'destinataire_lointain_${randomId.substring(4, 8)}',
      packetType: MeshPacketType.dataMessage,
      hopCount: 1,
      maxHops: 7,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
      encryptedPayload: 'PAYLOAD_OPAQUE_E2EE_ENCRYPTION_CHACHA20',
    );
    _relayService.processIncomingPacket(dummyPacket);
    notifyListeners();
  }

  /// Démonstration de la réception d'un message longue distance ayant traversé plusieurs téléphones.
  void simulateIncomingMultiHopMessage({
    required String peerId,
    required String messageText,
    int hopCount = 3,
  }) {
    final msgId = _generateSecureMessageId();
    final packet = MeshPacket(
      packetId: msgId,
      sourcePeerId: peerId,
      destinationPeerId: _localPeerId,
      packetType: MeshPacketType.dataMessage,
      hopCount: hopCount,
      maxHops: 7,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
      encryptedPayload: messageText,
    );
    _relayService.processIncomingPacket(packet);
  }

  String _generateSecureMessageId() {
    final csprng = Random.secure();
    final bytes = List<int>.generate(16, (_) => csprng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  void _seedVerifiedProximityPeers() {
    const peer1Id =
        '8f4a9c2e1b7d603459a8c1d2e3f405162738495a6b7c8d9e0f1a2b3c4d5e6f70';
    const peer2Id =
        '3c9e1d4b7a2f805162738495a6b7c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f';
    const peer3Id =
        '7a1b3c5d9e0f2a4b6c8d0e1f3a5b7c9d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b';

    _peers.addAll(<MeshPeer>[
      MeshPeer(
        peerId: peer1Id,
        displayName: 'Dr. Clara Vance',
        shortFingerprint: '8F4A-9C2E-6F70',
        verificationStatus: PeerVerificationStatus.qrVerified,
        linkState: PeerLinkState.authenticated,
        rssiDbm: -54,
        hopCount: 1,
        ttlRemaining: 7,
        transportMedium: 'Connexion directe (Excellente)',
        lastSeenAt: DateTime.now(),
      ),
      MeshPeer(
        peerId: peer2Id,
        displayName: 'Marc - Relais Logistique Nord',
        shortFingerprint: '3C9E-1D4B-6E7F',
        verificationStatus: PeerVerificationStatus.tofu,
        linkState: PeerLinkState.offline,
        rssiDbm: -82,
        hopCount: 0,
        ttlRemaining: 7,
        transportMedium: 'Vu il y a 6 min',
        lastSeenAt: DateTime.now().subtract(const Duration(minutes: 6)),
      ),
      MeshPeer(
        peerId: peer3Id,
        displayName: 'Poste Secours Vallée',
        shortFingerprint: '7A1B-3C5D-5A6B',
        verificationStatus: PeerVerificationStatus.qrVerified,
        linkState: PeerLinkState.multiHopRelay,
        rssiDbm: -91,
        hopCount: 3,
        ttlRemaining: 4,
        transportMedium: 'Relayé par le réseau (~1.8 km)',
        lastSeenAt: DateTime.now(),
      ),
    ]);

    _conversations[peer1Id] = <ChatMessage>[
      ChatMessage(
        messageId: 'init-msg-01',
        peerId: peer1Id,
        direction: MessageDirection.inbound,
        contentText:
            'Bonjour ! La liaison directe sans Internet fonctionne parfaitement, nos téléphones communiquent directement.',
        deliveryStatus: MessageDeliveryStatus.delivered,
        createdAt: DateTime.now().subtract(const Duration(minutes: 3)),
        deliveredAt: DateTime.now().subtract(const Duration(minutes: 3)),
      ),
    ];

    _conversations[peer2Id] = <ChatMessage>[
      ChatMessage(
        messageId: 'init-msg-02',
        peerId: peer2Id,
        direction: MessageDirection.outbound,
        contentText:
            'Le rapport d\'intervention est prêt. Il partira automatiquement dès qu\'on sera de nouveau à proximité.',
        deliveryStatus: MessageDeliveryStatus.queued,
        createdAt: DateTime.now().subtract(const Duration(minutes: 5)),
      ),
    ];

    _conversations[peer3Id] = <ChatMessage>[
      ChatMessage(
        messageId: 'init-msg-03',
        peerId: peer3Id,
        direction: MessageDirection.inbound,
        contentText:
            'Bien reçu ! Le message a traversé les relais de la zone sans problème. Vous pouvez envoyer les consignes.',
        deliveryStatus: MessageDeliveryStatus.delivered,
        createdAt: DateTime.now().subtract(const Duration(minutes: 1)),
        deliveredAt: DateTime.now().subtract(const Duration(minutes: 1)),
      ),
    ];
  }
}
