/// Direction du message par rapport au noeud local.
enum MessageDirection { inbound, outbound }

/// Type de contenu du message.
enum ChatMessageType { text, image, video, file }

/// Statut d'acheminement Store-and-Forward et accusé de réception E2EE.
enum MessageDeliveryStatus {
  /// Stocké de manière chiffrée dans `outbox_queue` en attente de portée radio.
  queued,

  /// Trame AEAD transmise sur le lien radio P2P.
  sent,

  /// Accusé de réception cryptographique (`DELIVERY_ACK`) reçu et vérifié.
  delivered,

  /// Échec de transmission après expiration des tentatives.
  failed,
}

/// Entité immuable représentant un message (texte, image, vidéo ou fichier)
/// horodaté et chiffré de bout en bout.
final class ChatMessage {
  final String messageId;
  final String peerId;
  final MessageDirection direction;
  final String contentText;
  final MessageDeliveryStatus deliveryStatus;
  final DateTime createdAt;
  final DateTime? deliveredAt;
  final ChatMessageType messageType;
  final String? filePath;
  final String? fileName;
  final int? fileSizeBytes;

  const ChatMessage({
    required this.messageId,
    required this.peerId,
    required this.direction,
    required this.contentText,
    required this.deliveryStatus,
    required this.createdAt,
    this.deliveredAt,
    this.messageType = ChatMessageType.text,
    this.filePath,
    this.fileName,
    this.fileSizeBytes,
  });

  ChatMessageType get type => messageType;
  String? get mediaFilePath => filePath;
  String? get mediaFileName => fileName;
  int? get mediaFileSizeBytes => fileSizeBytes;

  ChatMessage copyWith({
    MessageDeliveryStatus? deliveryStatus,
    DateTime? deliveredAt,
    String? contentText,
    String? filePath,
  }) {
    return ChatMessage(
      messageId: messageId,
      peerId: peerId,
      direction: direction,
      contentText: contentText ?? this.contentText,
      deliveryStatus: deliveryStatus ?? this.deliveryStatus,
      createdAt: createdAt,
      deliveredAt: deliveredAt ?? this.deliveredAt,
      messageType: messageType,
      filePath: filePath ?? this.filePath,
      fileName: fileName,
      fileSizeBytes: fileSizeBytes,
    );
  }
}
