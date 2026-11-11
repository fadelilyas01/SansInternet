import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

/// Événement radio reçu depuis le pont natif (Nearby Connections / Multipeer / BLE L2CAP).
sealed class RadioEvent {
  const RadioEvent();
}

final class PeerDiscoveredEvent extends RadioEvent {
  final String endpointId;
  final String advertisedPeerId;
  final String displayName;
  final int rssiDbm;
  final String medium;

  const PeerDiscoveredEvent({
    required this.endpointId,
    required this.advertisedPeerId,
    required this.displayName,
    required this.rssiDbm,
    required this.medium,
  });
}

final class PeerDisconnectedEvent extends RadioEvent {
  final String endpointId;
  const PeerDisconnectedEvent({required this.endpointId});
}

final class RawFrameReceivedEvent extends RadioEvent {
  final String endpointId;
  final Uint8List frameBytes;
  const RawFrameReceivedEvent({
    required this.endpointId,
    required this.frameBytes,
  });
}

/// Contrat d'abstraction vers le moteur cryptographique Rust (`sansinternet_core`).
abstract interface class CryptoSessionBridge {
  Future<Uint8List> createHandshakeInit(String endpointId);
  Future<Uint8List?> processHandshakeStep(
    String endpointId,
    Uint8List incomingFrame,
  );
  Future<bool> isSessionEstablished(String endpointId);
  Future<Uint8List> sealPayload(String endpointId, Uint8List plaintext);
  Future<Uint8List> openPayload(String endpointId, Uint8List frame);
  Future<void> destroySession(String endpointId);
}

/// Service d'orchestration du transport P2P, du Handshake Noise XX et du Store-and-Forward.
final class P2PTransportService {
  static const MethodChannel _controlChannel =
      MethodChannel('com.sansinternet.p2p/control');
  static const EventChannel _eventChannel =
      EventChannel('com.sansinternet.p2p/events');

  static const int _typeHandshakeInit = 0x01;
  static const int _typeHandshakeResp = 0x02;
  static const int _typeHandshakeFin = 0x03;
  static const int _typeDataMessage = 0x10;
  static const int _typeDeliveryAck = 0x11;

  final Database? _db;
  final CryptoSessionBridge _crypto;
  final String _localPeerId;

  StreamSubscription<dynamic>? _radioSubscription;
  final Map<String, String> _endpointToPeerId = {};
  final Map<String, String> _peerIdToEndpoint = {};
  final Set<String> _authenticatedEndpoints = {};

  final StreamController<Map<String, dynamic>> _incomingMessagesController =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<PeerDiscoveredEvent> _peerDiscoveredController =
      StreamController<PeerDiscoveredEvent>.broadcast();
  final StreamController<String> _peerDisconnectedController =
      StreamController<String>.broadcast();
  final StreamController<String> _peerAuthenticatedController =
      StreamController<String>.broadcast();

  Stream<Map<String, dynamic>> get incomingMessages =>
      _incomingMessagesController.stream;
  Stream<PeerDiscoveredEvent> get onPeerDiscovered =>
      _peerDiscoveredController.stream;
  Stream<String> get onPeerDisconnected =>
      _peerDisconnectedController.stream;
  Stream<String> get onPeerAuthenticated =>
      _peerAuthenticatedController.stream;

  P2PTransportService({
    Database? db,
    required CryptoSessionBridge crypto,
    required String localPeerId,
  })  : _db = db,
        _crypto = crypto,
        _localPeerId = localPeerId;

  /// Démarre l'annonce (Advertising) et la découverte (Scanning) simultanées.
  Future<void> startMeshNetwork() async {
    try {
      await _radioSubscription?.cancel();
      _radioSubscription = _eventChannel
          .receiveBroadcastStream()
          .map(_parseNativeEvent)
          .listen(_handleRadioEvent, onError: (_) {
        // Mode Fail-Secure : fermeture immédiate des sessions éphémères en cas d'anomalie radio
        unawaited(_purgeAllActiveSessions());
      });

      await _controlChannel
          .invokeMethod<void>('startMesh', <String, dynamic>{
            'localPeerId': _localPeerId,
            'serviceUuid': '0000FD9A-0000-1000-8000-00805F9B34FB',
          })
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      // Tolérance fail-secure en environnement restreint
    }
  }

  /// Arrête proprement les radios et nettoie toutes les clés de session en RAM.
  Future<void> dispose() async {
    await _radioSubscription?.cancel();
    _radioSubscription = null;
    await _purgeAllActiveSessions();
    await _incomingMessagesController.close();
    await _peerDiscoveredController.close();
    await _peerDisconnectedController.close();
    await _peerAuthenticatedController.close();
    try {
      await _controlChannel.invokeMethod<void>('stopMesh');
    } catch (_) {}
  }

  RadioEvent _parseNativeEvent(dynamic raw) {
    final map = Map<String, dynamic>.from(raw as Map);
    final type = map['event'] as String;
    final endpointId = map['endpointId'] as String;

    return switch (type) {
      'peer_discovered' => PeerDiscoveredEvent(
          endpointId: endpointId,
          advertisedPeerId: map['peerId'] as String,
          displayName: (map['displayName'] as String?) ?? 'Pair Anonyme',
          rssiDbm: (map['rssiDbm'] as int?) ?? -65,
          medium: (map['medium'] as String?) ?? 'BLE L2CAP',
        ),
      'peer_disconnected' => PeerDisconnectedEvent(endpointId: endpointId),
      'frame_received' => RawFrameReceivedEvent(
          endpointId: endpointId,
          frameBytes: map['bytes'] as Uint8List,
        ),
      _ => throw const FormatException('Événement radio non reconnu'),
    };
  }

  Future<void> _handleRadioEvent(RadioEvent event) async {
    switch (event) {
      case PeerDiscoveredEvent(:final endpointId, :final advertisedPeerId):
        _endpointToPeerId[endpointId] = advertisedPeerId;
        _peerIdToEndpoint[advertisedPeerId] = endpointId;
        _peerDiscoveredController.add(event);

        // Prévention déterministe du Glare : le PeerId lexicographiquement inférieur initie Noise XX
        if (_localPeerId.compareTo(advertisedPeerId) < 0) {
          final initFrame = await _crypto.createHandshakeInit(endpointId);
          await _sendWireFrame(endpointId, _typeHandshakeInit, initFrame);
        }

      case PeerDisconnectedEvent(:final endpointId):
        final peerId = _endpointToPeerId.remove(endpointId);
        if (peerId != null) {
          _peerIdToEndpoint.remove(peerId);
          _peerDisconnectedController.add(peerId);
        }
        _authenticatedEndpoints.remove(endpointId);
        await _crypto.destroySession(endpointId);

      case RawFrameReceivedEvent(:final endpointId, :final frameBytes):
        if (frameBytes.length < 2) return;
        final packetType = frameBytes[0];
        final body = Uint8List.sublistView(frameBytes, 1);

        if (packetType == _typeHandshakeInit ||
            packetType == _typeHandshakeResp ||
            packetType == _typeHandshakeFin) {
          await _handleHandshakeFrame(endpointId, packetType, body);
        } else if (packetType == _typeDataMessage ||
            packetType == _typeDeliveryAck) {
          await _handleEncryptedFrame(endpointId, packetType, body);
        }
    }
  }

  Future<void> _handleHandshakeFrame(
    String endpointId,
    int packetType,
    Uint8List handshakeBytes,
  ) async {
    try {
      final responseBytes =
          await _crypto.processHandshakeStep(endpointId, handshakeBytes);

      if (responseBytes != null) {
        final nextType = packetType == _typeHandshakeInit
            ? _typeHandshakeResp
            : _typeHandshakeFin;
        await _sendWireFrame(endpointId, nextType, responseBytes);
      }

      final established = await _crypto.isSessionEstablished(endpointId);
      if (established) {
        _authenticatedEndpoints.add(endpointId);
        final peerId = _endpointToPeerId[endpointId];
        if (peerId != null) {
          _peerAuthenticatedController.add(peerId);
          await _flushOutboxForPeer(peerId, endpointId);
        }
      }
    } catch (_) {
      // Fail-Secure : destruction immédiate de la session si la signature Ed25519 ou Noise échoue
      _authenticatedEndpoints.remove(endpointId);
      await _crypto.destroySession(endpointId);
    }
  }

  Future<void> _handleEncryptedFrame(
    String endpointId,
    int packetType,
    Uint8List cipherFrame,
  ) async {
    if (!_authenticatedEndpoints.contains(endpointId)) {
      return;
    }

    try {
      final decryptedBytes = await _crypto.openPayload(endpointId, cipherFrame);
      final jsonMap =
          jsonDecode(utf8.decode(decryptedBytes)) as Map<String, dynamic>;

      if (packetType == _typeDataMessage) {
        final msgId = jsonMap['id'] as String;
        final senderId = jsonMap['sender'] as String;
        final text = jsonMap['body'] as String;
        final timestamp = jsonMap['ts'] as int;

        await _db?.insert(
          'messages',
          <String, Object?>{
            'message_id': msgId,
            'peer_id': senderId,
            'direction': 'inbound',
            'content_text': text,
            'delivery_status': 'delivered',
            'created_at_ms': timestamp,
            'delivered_at_ms': DateTime.now().millisecondsSinceEpoch,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );

        _incomingMessagesController.add(jsonMap);

        final ackPayload = utf8.encode(jsonEncode(<String, Object>{
          'v': 1,
          't': 'ack',
          'msg_id': msgId,
          'status': 'delivered',
          'ts': DateTime.now().millisecondsSinceEpoch,
        }));
        final sealedAck = await _crypto.sealPayload(
          endpointId,
          Uint8List.fromList(ackPayload),
        );
        await _sendWireFrame(endpointId, _typeDeliveryAck, sealedAck);
      } else if (packetType == _typeDeliveryAck) {
        final ackedMsgId = jsonMap['msg_id'] as String;
        final deliveredAt = jsonMap['ts'] as int;

        await _db?.transaction((txn) async {
          await txn.update(
            'messages',
            <String, Object?>{
              'delivery_status': 'delivered',
              'delivered_at_ms': deliveredAt,
            },
            where: 'message_id = ?',
            whereArgs: <Object>[ackedMsgId],
          );
          await txn.delete(
            'outbox_queue',
            where: 'message_id = ?',
            whereArgs: <Object>[ackedMsgId],
          );
        });
      }
    } catch (_) {
      // Rejet Fail-Secure des trames altérées ou en rejeu
    }
  }

  /// Envoie un message chiffré ou le place dans la file Store-and-Forward (`outbox_queue`).
  Future<void> sendMessage({
    required String messageId,
    required String recipientPeerId,
    required String contentText,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final clearPayload = Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, Object?>{
          'v': 1,
          'id': messageId,
          't': 'txt',
          'sender': _localPeerId,
          'ts': nowMs,
          'body': contentText,
        }),
      ),
    );

    await _db?.transaction((txn) async {
      await txn.insert(
        'messages',
        <String, Object?>{
          'message_id': messageId,
          'peer_id': recipientPeerId,
          'direction': 'outbound',
          'content_text': contentText,
          'delivery_status': 'queued',
          'created_at_ms': nowMs,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      await txn.insert(
        'outbox_queue',
        <String, Object?>{
          'message_id': messageId,
          'recipient_peer_id': recipientPeerId,
          'serialized_payload': clearPayload,
          'retry_count': 0,
          'next_attempt_at_ms': nowMs,
          'created_at_ms': nowMs,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });

    final endpointId = _peerIdToEndpoint[recipientPeerId];
    if (endpointId != null && _authenticatedEndpoints.contains(endpointId)) {
      await _transmitPayloadToEndpoint(
        messageId: messageId,
        endpointId: endpointId,
        clearPayload: clearPayload,
      );
    }
  }

  Future<void> _flushOutboxForPeer(String peerId, String endpointId) async {
    final pendingRows = await _db?.query(
      'outbox_queue',
      where: 'recipient_peer_id = ?',
      whereArgs: <Object>[peerId],
      orderBy: 'created_at_ms ASC',
    ) ?? const <Map<String, Object?>>[];

    for (final row in pendingRows) {
      if (!_authenticatedEndpoints.contains(endpointId)) break;
      final messageId = row['message_id'] as String;
      final clearPayload = row['serialized_payload'] as Uint8List;

      await _transmitPayloadToEndpoint(
        messageId: messageId,
        endpointId: endpointId,
        clearPayload: clearPayload,
      );
    }
  }

  Future<void> _transmitPayloadToEndpoint({
    required String messageId,
    required String endpointId,
    required Uint8List clearPayload,
  }) async {
    try {
      final sealedBytes = await _crypto.sealPayload(endpointId, clearPayload);
      await _sendWireFrame(endpointId, _typeDataMessage, sealedBytes);

      await _db?.update(
        'messages',
        <String, Object?>{'delivery_status': 'sent'},
        where: 'message_id = ? AND delivery_status = ?',
        whereArgs: <Object>[messageId, 'queued'],
      );
    } catch (_) {
      // Conservation dans outbox_queue pour nouvelle tentative lors du prochain contact radio
    }
  }

  Future<void> _sendWireFrame(
    String endpointId,
    int packetType,
    Uint8List payload,
  ) async {
    final wireBytes = Uint8List(1 + payload.length);
    wireBytes[0] = packetType;
    wireBytes.setRange(1, wireBytes.length, payload);

    await _controlChannel
        .invokeMethod<void>('sendRawFrame', <String, dynamic>{
          'endpointId': endpointId,
          'bytes': wireBytes,
        })
        .timeout(const Duration(seconds: 5));
  }

  Future<void> _purgeAllActiveSessions() async {
    final endpoints = List<String>.from(_endpointToPeerId.keys);
    _endpointToPeerId.clear();
    _peerIdToEndpoint.clear();
    _authenticatedEndpoints.clear();
    for (final ep in endpoints) {
      await _crypto.destroySession(ep);
    }
  }
}
