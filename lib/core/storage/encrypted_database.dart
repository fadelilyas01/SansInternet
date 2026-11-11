import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sans_internet/features/mesh/domain/entities/chat_message.dart';
import 'package:sans_internet/features/mesh/domain/entities/mesh_peer.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

/// Gestionnaire de base de données locale chiffrée via SQLCipher (AES-256).
/// La clé maîtresse (256 bits) est générée par CSPRNG matériel et scellée dans
/// Android Keystore (EncryptedSharedPreferences) / iOS Keychain.
final class EncryptedDatabaseManager {
  static const String _dbFileName = 'sansinternet_vault.db';
  static const String _keyStorageAlias = 'sqlcipher_master_dek_v1';

  final FlutterSecureStorage _secureStorage;
  Database? _database;

  EncryptedDatabaseManager({FlutterSecureStorage? secureStorage})
      : _secureStorage = secureStorage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(
                encryptedSharedPreferences: true,
                resetOnError: false,
              ),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );

  Future<Database> get database async {
    if (_database != null && _database!.isOpen) {
      return _database!;
    }
    _database = await _initDatabase();
    return _database!;
  }

  /// Génère ou récupère la clé de chiffrement SQLCipher (32 octets / 256 bits).
  Future<String> _getOrCreateDatabaseKey() async {
    final existingKey = await _secureStorage.read(key: _keyStorageAlias);
    if (existingKey != null && existingKey.isNotEmpty) {
      return existingKey;
    }

    final csprng = Random.secure();
    final keyBytes = Uint8List.fromList(
      List<int>.generate(32, (_) => csprng.nextInt(256)),
    );
    final base64Key = base64UrlEncode(keyBytes);

    // Effacement immédiat du tampon en mémoire vive Dart
    keyBytes.fillRange(0, keyBytes.length, 0);

    await _secureStorage.write(key: _keyStorageAlias, value: base64Key);
    return base64Key;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final fullPath = p.join(dbPath, _dbFileName);
    final passphrase = await _getOrCreateDatabaseKey();

    return openDatabase(
      fullPath,
      password: passphrase,
      version: 1,
      onConfigure: (Database db) async {
        await db.execute('PRAGMA foreign_keys = ON;');
        await db.execute('PRAGMA secure_delete = ON;');
        await db.execute('PRAGMA journal_mode = WAL;');
      },
      onCreate: (Database db, int version) async {
        await db.execute('''
          CREATE TABLE peers (
            peer_id TEXT PRIMARY KEY NOT NULL,
            display_name TEXT NOT NULL,
            short_fingerprint TEXT NOT NULL,
            verification_status TEXT NOT NULL CHECK(verification_status IN ('tofu', 'qr_verified', 'revoked')),
            last_seen_at INTEGER NOT NULL,
            created_at INTEGER NOT NULL
          ) STRICT;
        ''');

        await db.execute('''
          CREATE TABLE messages (
            message_id TEXT PRIMARY KEY NOT NULL,
            peer_id TEXT NOT NULL,
            direction TEXT NOT NULL CHECK(direction IN ('inbound', 'outbound')),
            content_text TEXT NOT NULL,
            delivery_status TEXT NOT NULL CHECK(delivery_status IN ('queued', 'sent', 'delivered', 'failed')),
            message_type TEXT NOT NULL DEFAULT 'text',
            media_file_path TEXT,
            media_file_name TEXT,
            media_file_size_bytes INTEGER,
            created_at_ms INTEGER NOT NULL,
            delivered_at_ms INTEGER,
            FOREIGN KEY (peer_id) REFERENCES peers(peer_id) ON DELETE CASCADE
          ) STRICT;
        ''');

        await db.execute('''
          CREATE TABLE outbox_queue (
            message_id TEXT PRIMARY KEY NOT NULL,
            recipient_peer_id TEXT NOT NULL,
            serialized_payload BLOB NOT NULL,
            retry_count INTEGER NOT NULL DEFAULT 0,
            next_attempt_at_ms INTEGER NOT NULL,
            created_at_ms INTEGER NOT NULL,
            FOREIGN KEY (message_id) REFERENCES messages(message_id) ON DELETE CASCADE,
            FOREIGN KEY (recipient_peer_id) REFERENCES peers(peer_id) ON DELETE CASCADE
          ) STRICT;
        ''');

        await db.execute(
          'CREATE INDEX idx_messages_peer_time ON messages(peer_id, created_at_ms DESC);',
        );
        await db.execute(
          'CREATE INDEX idx_outbox_recipient ON outbox_queue(recipient_peer_id, next_attempt_at_ms ASC);',
        );
      },
    );
  }

  /// Enregistre ou met à jour un pair de manière chiffrée.
  Future<void> upsertPeer(MeshPeer peer) async {
    final db = await database;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final verificationStr = switch (peer.verificationStatus) {
      PeerVerificationStatus.tofu => 'tofu',
      PeerVerificationStatus.qrVerified => 'qr_verified',
      PeerVerificationStatus.revoked => 'revoked',
    };

    await db.insert(
      'peers',
      <String, Object?>{
        'peer_id': peer.peerId,
        'display_name': peer.displayName,
        'short_fingerprint': peer.shortFingerprint,
        'verification_status': verificationStr,
        'last_seen_at': peer.lastSeenAt.millisecondsSinceEpoch,
        'created_at': nowMs,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Met à jour le statut de vérification d'un pair (suite à scan QR).
  Future<void> updatePeerVerification(String peerId, PeerVerificationStatus status) async {
    final db = await database;
    final verificationStr = switch (status) {
      PeerVerificationStatus.tofu => 'tofu',
      PeerVerificationStatus.qrVerified => 'qr_verified',
      PeerVerificationStatus.revoked => 'revoked',
    };

    await db.update(
      'peers',
      <String, Object?>{'verification_status': verificationStr},
      where: 'peer_id = ?',
      whereArgs: <Object>[peerId],
    );
  }

  /// Charge tous les pairs enregistrés dans le coffre SQLCipher.
  Future<List<MeshPeer>> loadPeers() async {
    final db = await database;
    final rows = await db.query('peers', orderBy: 'last_seen_at DESC');

    return rows.map((row) {
      final statusStr = row['verification_status'] as String;
      final verificationStatus = switch (statusStr) {
        'qr_verified' => PeerVerificationStatus.qrVerified,
        'revoked' => PeerVerificationStatus.revoked,
        _ => PeerVerificationStatus.tofu,
      };

      return MeshPeer(
        peerId: row['peer_id'] as String,
        displayName: row['display_name'] as String,
        shortFingerprint: row['short_fingerprint'] as String,
        verificationStatus: verificationStatus,
        linkState: PeerLinkState.offline,
        rssiDbm: -70,
        transportMedium: 'Enregistré localement',
        lastSeenAt: DateTime.fromMillisecondsSinceEpoch(row['last_seen_at'] as int),
      );
    }).toList();
  }

  /// Sauvegarde un message chiffré dans la base locale SQLCipher.
  Future<void> saveMessage(ChatMessage message) async {
    final db = await database;
    final dirStr = message.direction == MessageDirection.outbound ? 'outbound' : 'inbound';
    final statusStr = switch (message.deliveryStatus) {
      MessageDeliveryStatus.queued => 'queued',
      MessageDeliveryStatus.sent => 'sent',
      MessageDeliveryStatus.delivered => 'delivered',
      MessageDeliveryStatus.failed => 'failed',
    };

    final typeStr = switch (message.messageType) {
      ChatMessageType.text => 'text',
      ChatMessageType.image => 'image',
      ChatMessageType.video => 'video',
      ChatMessageType.file => 'file',
    };

    await db.insert(
      'messages',
      <String, Object?>{
        'message_id': message.messageId,
        'peer_id': message.peerId,
        'direction': dirStr,
        'content_text': message.contentText,
        'delivery_status': statusStr,
        'message_type': typeStr,
        'media_file_path': message.filePath,
        'media_file_name': message.fileName,
        'media_file_size_bytes': message.fileSizeBytes,
        'created_at_ms': message.createdAt.millisecondsSinceEpoch,
        'delivered_at_ms': message.deliveredAt?.millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Met à jour le statut d'acheminement d'un message.
  Future<void> updateMessageDeliveryStatus(
    String messageId,
    MessageDeliveryStatus status, [
    DateTime? deliveredAt,
  ]) async {
    final db = await database;
    final statusStr = switch (status) {
      MessageDeliveryStatus.queued => 'queued',
      MessageDeliveryStatus.sent => 'sent',
      MessageDeliveryStatus.delivered => 'delivered',
      MessageDeliveryStatus.failed => 'failed',
    };

    await db.update(
      'messages',
      <String, Object?>{
        'delivery_status': statusStr,
        'delivered_at_ms': deliveredAt?.millisecondsSinceEpoch,
      },
      where: 'message_id = ?',
      whereArgs: <Object>[messageId],
    );
  }

  /// Charge l'historique d'une conversation pour un pair donné.
  Future<List<ChatMessage>> loadMessagesForPeer(String peerId) async {
    final db = await database;
    final rows = await db.query(
      'messages',
      where: 'peer_id = ?',
      whereArgs: <Object>[peerId],
      orderBy: 'created_at_ms ASC',
    );

    return rows.map((row) {
      final dirStr = row['direction'] as String;
      final statusStr = row['delivery_status'] as String;

      final direction = dirStr == 'outbound' ? MessageDirection.outbound : MessageDirection.inbound;
      final deliveryStatus = switch (statusStr) {
        'queued' => MessageDeliveryStatus.queued,
        'sent' => MessageDeliveryStatus.sent,
        'delivered' => MessageDeliveryStatus.delivered,
        _ => MessageDeliveryStatus.failed,
      };

      final typeStr = (row['message_type'] as String?) ?? 'text';
      final messageType = switch (typeStr) {
        'image' => ChatMessageType.image,
        'video' => ChatMessageType.video,
        'file' => ChatMessageType.file,
        _ => ChatMessageType.text,
      };

      final deliveredAtMs = row['delivered_at_ms'] as int?;

      return ChatMessage(
        messageId: row['message_id'] as String,
        peerId: row['peer_id'] as String,
        direction: direction,
        contentText: row['content_text'] as String,
        deliveryStatus: deliveryStatus,
        messageType: messageType,
        filePath: row['media_file_path'] as String?,
        fileName: row['media_file_name'] as String?,
        fileSizeBytes: row['media_file_size_bytes'] as int?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at_ms'] as int),
        deliveredAt: deliveredAtMs != null ? DateTime.fromMillisecondsSinceEpoch(deliveredAtMs) : null,
      );
    }).toList();
  }

  Future<void> close() async {
    final db = _database;
    if (db != null && db.isOpen) {
      await db.close();
    }
    _database = null;
  }
}
