import 'dart:convert';
import 'dart:math';

/// Type de paquet circulant à travers le réseau maillé multi-sauts.
enum MeshPacketType {
  /// Message chiffré de bout en bout (texte, photo, vidéo, fichier).
  dataMessage,

  /// Accusé de réception cryptographique (ACK) renvoyé à l'émetteur initial.
  deliveryAck,

  /// Annonce de présence et découverte de routes entre pairs.
  beaconRoute,
}

/// Paquet maillé multi-sauts (Store-and-Forward / DTN).
///
/// L'enveloppe extérieure contient les informations de routage (TTL, sauts, ID).
/// La charge utile ([encryptedPayload]) est opaque et scellée de bout en bout :
/// les téléphones intermédiaires qui relaient ce paquet NE PEUVENT PAS la lire.
final class MeshPacket {
  /// Identifiant unique cryptographique (CSPRNG 128-bit).
  final String packetId;

  /// Identifiant du nœud d'origine (émetteur).
  final String sourcePeerId;

  /// Identifiant du nœud destinataire final ('*' pour diffusion/beacon).
  final String destinationPeerId;

  /// Type de paquet.
  final MeshPacketType packetType;

  /// Nombre de sauts effectués à travers d'autres smartphones.
  final int hopCount;

  /// Nombre maximal de sauts autorisés avant expiration (Time-To-Live).
  final int maxHops;

  /// Horodatage de création (epoch millisecondes).
  final int createdAtMs;

  /// Charge utile opaque chiffrée de bout en bout (Base64 ou JSON scellé).
  final String encryptedPayload;

  /// En cas d'ACK, identifiant du paquet initial acquitté.
  final String? ackTargetPacketId;

  const MeshPacket({
    required this.packetId,
    required this.sourcePeerId,
    required this.destinationPeerId,
    required this.packetType,
    this.hopCount = 0,
    this.maxHops = 7,
    required this.createdAtMs,
    required this.encryptedPayload,
    this.ackTargetPacketId,
  });

  /// Crée un nouveau paquet généré localement avec identifiant sécurisé CSPRNG.
  factory MeshPacket.create({
    required String sourcePeerId,
    required String destinationPeerId,
    required MeshPacketType packetType,
    required String encryptedPayload,
    int maxHops = 7,
    String? ackTargetPacketId,
  }) {
    final csprng = Random.secure();
    final bytes = List<int>.generate(16, (_) => csprng.nextInt(256));
    final packetId = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    return MeshPacket(
      packetId: packetId,
      sourcePeerId: sourcePeerId,
      destinationPeerId: destinationPeerId,
      packetType: packetType,
      hopCount: 0,
      maxHops: maxHops,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
      encryptedPayload: encryptedPayload,
      ackTargetPacketId: ackTargetPacketId,
    );
  }

  /// Retourne une copie du paquet avec le compteur de sauts incrémenté.
  MeshPacket incrementHop() {
    return MeshPacket(
      packetId: packetId,
      sourcePeerId: sourcePeerId,
      destinationPeerId: destinationPeerId,
      packetType: packetType,
      hopCount: hopCount + 1,
      maxHops: maxHops,
      createdAtMs: createdAtMs,
      encryptedPayload: encryptedPayload,
      ackTargetPacketId: ackTargetPacketId,
    );
  }

  /// Indique si le paquet peut encore être relayé.
  bool get canBeRelayed => hopCount < maxHops;

  /// Sérialise le paquet en format JSON pour transmission radio (BLE/Nearby/Wi-Fi).
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'pid': packetId,
      'src': sourcePeerId,
      'dst': destinationPeerId,
      'typ': packetType.name,
      'hop': hopCount,
      'max': maxHops,
      'ts': createdAtMs,
      'payload': encryptedPayload,
      if (ackTargetPacketId != null) 'ack_for': ackTargetPacketId,
    };
  }

  /// Désérialise un paquet reçu depuis les airs avec validation défensive (Zero-Vulnerability).
  factory MeshPacket.fromMap(Map<String, dynamic> map) {
    final rawPid = map['pid'] as String? ?? '';
    final rawSrc = map['src'] as String? ?? '';
    final rawDst = map['dst'] as String? ?? '';
    final typStr = map['typ'] as String? ?? 'dataMessage';
    final rawPayload = (map['payload'] as String?) ?? '';

    // Durcissement Zero-Vulnerability : limitation de longueur pour parer le déni de service (CWE-400)
    final packetId = rawPid.length > 64 ? rawPid.substring(0, 64) : rawPid;
    final sourcePeerId = rawSrc.length > 128 ? rawSrc.substring(0, 128) : rawSrc;
    final destinationPeerId = rawDst.length > 128 ? rawDst.substring(0, 128) : rawDst;

    // Plafonne la taille du payload pour bloquer toute attaque par saturation mémoire
    final encryptedPayload = rawPayload.length > 1024 * 1024
        ? rawPayload.substring(0, 1024 * 1024)
        : rawPayload;

    final packetType = switch (typStr) {
      'deliveryAck' => MeshPacketType.deliveryAck,
      'beaconRoute' => MeshPacketType.beaconRoute,
      _ => MeshPacketType.dataMessage,
    };

    final rawHop = (map['hop'] as int?) ?? 0;
    final rawMax = (map['max'] as int?) ?? 7;

    // Plafonnement strict du TTL entre 1 et 15 sauts (norme DTN décentralisée)
    final hopCount = rawHop.clamp(0, 30);
    final maxHops = rawMax.clamp(1, 15);

    return MeshPacket(
      packetId: packetId,
      sourcePeerId: sourcePeerId,
      destinationPeerId: destinationPeerId,
      packetType: packetType,
      hopCount: hopCount,
      maxHops: maxHops,
      createdAtMs: (map['ts'] as int?) ?? DateTime.now().millisecondsSinceEpoch,
      encryptedPayload: encryptedPayload,
      ackTargetPacketId: map['ack_for'] as String?,
    );
  }

  String toJson() => jsonEncode(toMap());

  factory MeshPacket.fromJson(String jsonStr) {
    return MeshPacket.fromMap(jsonDecode(jsonStr) as Map<String, dynamic>);
  }
}

