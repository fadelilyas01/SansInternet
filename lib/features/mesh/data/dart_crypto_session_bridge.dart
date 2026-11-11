import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:sans_internet/features/mesh/data/p2p_transport_service.dart';

/// Implémentation cryptographique pure Dart de `CryptoSessionBridge`
/// utilisant X25519 (ECDH), HKDF-SHA256 et ChaCha20-Poly1305 (AEAD).
/// Conforme au Zero-Vulnerability Standard et aux recommandations de l'ANSSI / NIST.
final class DartCryptoSessionBridge implements CryptoSessionBridge {
  final X25519 _x25519 = X25519();
  final Chacha20 _aead = Chacha20.poly1305Aead();
  final Hkdf _hkdf = Hkdf(
    hmac: Hmac.sha256(),
    outputLength: 32,
  );

  static const List<int> _hkdfInfo = <int>[
    0x53, 0x61, 0x6e, 0x73, 0x49, 0x6e, 0x74, 0x65, 0x72, 0x6e, 0x65, 0x74, // SansInternet
    0x5f, 0x50, 0x32, 0x50, 0x5f, 0x76, 0x31,                                 // _P2P_v1
  ];

  final Map<String, SimpleKeyPair> _ephemeralKeyPairs = {};
  final Map<String, SecretKey> _sessionKeys = {};
  final Map<String, bool> _established = {};

  @override
  Future<Uint8List> createHandshakeInit(String endpointId) async {
    // Génère une paire de clés éphémère X25519 pour l'initiateur
    final keyPair = await _x25519.newKeyPair();
    _ephemeralKeyPairs[endpointId] = keyPair;
    final publicKey = await keyPair.extractPublicKey();
    return Uint8List.fromList(publicKey.bytes);
  }

  @override
  Future<Uint8List?> processHandshakeStep(
    String endpointId,
    Uint8List incomingFrame,
  ) async {
    if (incomingFrame.length < 32) {
      throw const FormatException('Trame de poignée de main X25519 trop courte');
    }

    final remotePkBytes = incomingFrame.sublist(0, 32);
    final remotePublicKey = SimplePublicKey(
      remotePkBytes,
      type: KeyPairType.x25519,
    );

    var localKeyPair = _ephemeralKeyPairs[endpointId];

    if (localKeyPair == null) {
      // Nous sommes le répondeur (Bob) : générer une paire de clés éphémère
      localKeyPair = await _x25519.newKeyPair();
      _ephemeralKeyPairs[endpointId] = localKeyPair;

      // Calcul du secret partagé ECDH
      final sharedSecret = await _x25519.sharedSecretKey(
        keyPair: localKeyPair,
        remotePublicKey: remotePublicKey,
      );

      // Dérivation de la clé symétrique ChaCha20-Poly1305 via HKDF-SHA256
      final derivedKey = await _hkdf.deriveKey(
        secretKey: sharedSecret,
        nonce: _hkdfInfo,
        info: _hkdfInfo,
      );

      _sessionKeys[endpointId] = derivedKey;
      _established[endpointId] = true;

      // Renvoie la clé publique éphémère du répondeur
      final localPk = await localKeyPair.extractPublicKey();
      return Uint8List.fromList(localPk.bytes);
    } else {
      // Nous sommes l'initiateur (Alice) recevant la réponse de Bob
      final sharedSecret = await _x25519.sharedSecretKey(
        keyPair: localKeyPair,
        remotePublicKey: remotePublicKey,
      );

      final derivedKey = await _hkdf.deriveKey(
        secretKey: sharedSecret,
        nonce: _hkdfInfo,
        info: _hkdfInfo,
      );

      _sessionKeys[endpointId] = derivedKey;
      _established[endpointId] = true;

      // Purge de la paire éphémère de la RAM
      _ephemeralKeyPairs.remove(endpointId);
      return null;
    }
  }

  @override
  Future<bool> isSessionEstablished(String endpointId) async {
    return _established[endpointId] == true && _sessionKeys.containsKey(endpointId);
  }

  @override
  Future<Uint8List> sealPayload(String endpointId, Uint8List plaintext) async {
    final sessionKey = _sessionKeys[endpointId];
    if (sessionKey == null || _established[endpointId] != true) {
      throw StateError('Impossible de sceller : session cryptographique non établie pour $endpointId');
    }

    // CSPRNG : Nonce aléatoire de 12 octets (96 bits) pour ChaCha20-Poly1305
    final csprng = Random.secure();
    final nonceBytes = Uint8List.fromList(
      List<int>.generate(12, (_) => csprng.nextInt(256)),
    );

    final secretBox = await _aead.encrypt(
      plaintext,
      secretKey: sessionKey,
      nonce: nonceBytes,
    );

    // Format filaire : [Nonce 12B] + [Ciphertext] + [MAC 16B]
    final sealed = Uint8List(12 + secretBox.cipherText.length + 16);
    sealed.setRange(0, 12, nonceBytes);
    sealed.setRange(12, 12 + secretBox.cipherText.length, secretBox.cipherText);
    sealed.setRange(12 + secretBox.cipherText.length, sealed.length, secretBox.mac.bytes);

    return sealed;
  }

  @override
  Future<Uint8List> openPayload(String endpointId, Uint8List frame) async {
    final sessionKey = _sessionKeys[endpointId];
    if (sessionKey == null || _established[endpointId] != true) {
      throw StateError('Impossible de déchiffrer : session cryptographique non établie pour $endpointId');
    }

    if (frame.length < 28) {
      throw const FormatException('Trame chiffrée trop courte pour ChaCha20-Poly1305');
    }

    final nonce = frame.sublist(0, 12);
    final macBytes = frame.sublist(frame.length - 16);
    final cipherText = frame.sublist(12, frame.length - 16);

    final secretBox = SecretBox(
      cipherText,
      nonce: nonce,
      mac: Mac(macBytes),
    );

    final clearBytes = await _aead.decrypt(
      secretBox,
      secretKey: sessionKey,
    );

    return Uint8List.fromList(clearBytes);
  }

  @override
  Future<void> destroySession(String endpointId) async {
    _ephemeralKeyPairs.remove(endpointId);
    _sessionKeys.remove(endpointId);
    _established.remove(endpointId);
  }
}

