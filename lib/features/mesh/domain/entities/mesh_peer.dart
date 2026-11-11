/// Niveau de confiance cryptographique attribué à un pair découvert.
enum PeerVerificationStatus {
  /// Trust On First Use : Clé statique enregistrée lors du premier contact radio.
  tofu,

  /// Identité vérifiée hors-ligne par scan réciproque de QR Code (Ed25519 + X25519).
  qrVerified,

  /// Pair révoqué suite à une anomalie de clé ou décision explicite de l'utilisateur.
  revoked,
}

/// État temps réel de la liaison radio et du tunnel Noise XX avec le pair.
enum PeerLinkState {
  /// Pair hors de portée radio (les messages envoyés seront placés dans l'Outbox).
  offline,

  /// Signal radio détecté (BLE / Wi-Fi Direct), handshake Noise XX en cours.
  handshaking,

  /// Tunnel E2EE Noise XX authentifié et actif (1 saut direct).
  authenticated,

  /// Pair joignable à longue portée via N sauts intermédiaires (`Multi-Hop 0-RTT Noise_N`).
  multiHopRelay,
}

/// Entité métier immuable représentant un pair du réseau maillé.
final class MeshPeer {
  final String peerId;
  final String displayName;
  final String shortFingerprint;
  final PeerVerificationStatus verificationStatus;
  final PeerLinkState linkState;
  final int rssiDbm;
  final int hopCount;
  final int ttlRemaining;
  final String transportMedium;
  final DateTime lastSeenAt;

  const MeshPeer({
    required this.peerId,
    required this.displayName,
    required this.shortFingerprint,
    required this.verificationStatus,
    required this.linkState,
    required this.rssiDbm,
    this.hopCount = 1,
    this.ttlRemaining = 7,
    required this.transportMedium,
    required this.lastSeenAt,
  });

  MeshPeer copyWith({
    String? displayName,
    PeerVerificationStatus? verificationStatus,
    PeerLinkState? linkState,
    int? rssiDbm,
    int? hopCount,
    int? ttlRemaining,
    String? transportMedium,
    DateTime? lastSeenAt,
  }) {
    return MeshPeer(
      peerId: peerId,
      displayName: displayName ?? this.displayName,
      shortFingerprint: shortFingerprint,
      verificationStatus: verificationStatus ?? this.verificationStatus,
      linkState: linkState ?? this.linkState,
      rssiDbm: rssiDbm ?? this.rssiDbm,
      hopCount: hopCount ?? this.hopCount,
      ttlRemaining: ttlRemaining ?? this.ttlRemaining,
      transportMedium: transportMedium ?? this.transportMedium,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
    );
  }
}
