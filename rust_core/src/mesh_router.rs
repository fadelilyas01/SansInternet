#![forbid(unsafe_code)]

//! Module de Routage Maillé Multi-Sauts (Multi-Hop Mesh) & Chiffrement E2EE 0-RTT (`Noise_N`).
//!
//! Permet d'étendre la portée de l'application de quelques dizaines de mètres à plusieurs kilomètres :
//! 1. Par sauts successifs entre smartphones (`TTL`, `hop_count`, déduplication anti-boucle bornée).
//! 2. Par transport sur liaison basse vitesse longue portée (BLE 5.0 Coded PHY S=8 ou LoRa Sub-GHz).
//! 3. Par scellement asymétrique unidirectionnel 0-RTT (`Noise_N_25519_ChaChaPoly_BLAKE2s` + signature `Ed25519`)
//!    traversant N relais aveugles sans nécessiter de handshake interactif avec le destinataire distant.

use crate::framing::{pad_plaintext_block, unpad_plaintext_block, FramingError};
use crate::identity::{compute_peer_id_hex, LocalNodeIdentity};
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use serde::{Deserialize, Serialize};
use snow::Builder;
use std::collections::{HashSet, VecDeque};
use subtle::ConstantTimeEq;
use thiserror::Error;

pub const NOISE_ONEWAY_PATTERN: &str = "Noise_N_25519_ChaChaPoly_BLAKE2s";
pub const DEFAULT_MAX_TTL: u8 = 7;
pub const MAX_DEDUP_CACHE_ENTRIES: usize = 2048;
pub const MESH_HEADER_SIZE: usize = 28;
pub const LORA_SAFE_MTU_BYTES: usize = 200;

#[derive(Error, Debug, Clone, PartialEq, Eq)]
pub enum MeshRoutingError {
    #[error("En-tête Multi-Hop invalide ou tronqué")]
    MalformedRelayEnvelope,
    #[error("Paquet expiré (TTL = 0)")]
    TtlExpired,
    #[error("Paquet déjà vu et relayé (boucle de routage bloquée)")]
    DuplicatePacketDropped,
    #[error("Échec du chiffrement ou déchiffrement E2EE 0-RTT")]
    OneWayCryptoFailed,
    #[error("Signature Ed25519 de l'expéditeur invalide sur le paquet Multi-Hop")]
    InvalidSenderSignature,
    #[error("Erreur de bourrage PKCS#7: {0}")]
    Padding(#[from] FramingError),
}

/// Action décidée par le routeur Multi-Hop à la réception d'une trame radio.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RouteDecision {
    /// Le paquet est destiné au noeud local (consommation et déchiffrement).
    DeliverLocally(MeshRelayEnvelope),
    /// Le paquet est destiné à la fois au noeud local ET doit être relayé (ex: Broadcast).
    DeliverAndForward(MeshRelayEnvelope),
    /// Le paquet est destiné à un pair distant : son TTL a été décrémenté et son `hop_count` incrémenté.
    ForwardToNeighbors(MeshRelayEnvelope),
    /// Le paquet a déjà été vu ou son TTL est épuisé : rejet immédiat (anti-tempête radio).
    Drop(MeshRoutingError),
}

/// Enveloppe binaire de routage Multi-Hop (28 octets d'en-tête fixe + payload chiffré E2EE).
/// Les relais intermédiaires ne voient que cet en-tête et ne peuvent jamais lire `sealed_payload`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MeshRelayEnvelope {
    /// Identifiant unique de paquet sur 64 bits pour la déduplication Gossip/Flooding.
    pub packet_id: u64,
    /// Time-To-Live (décrémenté à chaque saut, paquet détruit à 0).
    pub ttl: u8,
    /// Nombre de sauts déjà effectués depuis l'émetteur initial.
    pub hop_count: u8,
    /// Tag de routage de l'émetteur (8 premiers octets du PeerId).
    pub source_tag: [u8; 8],
    /// Tag de routage du destinataire (8 premiers octets du PeerId, ou `0xFF..FF` pour Broadcast).
    pub destination_tag: [u8; 8],
    /// Payload chiffré de bout en bout (`Noise_N` + signature `Ed25519`).
    pub sealed_payload: Vec<u8>,
}

impl MeshRelayEnvelope {
    /// Extrait le tag de routage de 8 octets depuis un `peer_id_hex` de 64 caractères.
    pub fn tag_from_peer_id_hex(peer_id_hex: &str) -> Result<[u8; 8], MeshRoutingError> {
        if peer_id_hex.len() < 16 {
            return Err(MeshRoutingError::MalformedRelayEnvelope);
        }
        let bytes = hex::decode(&peer_id_hex[0..16])
            .map_err(|_| MeshRoutingError::MalformedRelayEnvelope)?;
        bytes
            .try_into()
            .map_err(|_| MeshRoutingError::MalformedRelayEnvelope)
    }

    /// Sérialise l'enveloppe Multi-Hop en format binaire compact.
    pub fn encode(&self) -> Result<Vec<u8>, MeshRoutingError> {
        let len_u16 = u16::try_from(self.sealed_payload.len())
            .map_err(|_| MeshRoutingError::MalformedRelayEnvelope)?;

        let mut out = Vec::with_capacity(MESH_HEADER_SIZE + self.sealed_payload.len());
        out.extend_from_slice(&self.packet_id.to_be_bytes());
        out.push(self.ttl);
        out.push(self.hop_count);
        out.extend_from_slice(&self.source_tag);
        out.extend_from_slice(&self.destination_tag);
        out.extend_from_slice(&len_u16.to_be_bytes());
        out.extend_from_slice(&self.sealed_payload);
        Ok(out)
    }

    /// Désérialise une enveloppe Multi-Hop depuis les octets reçus en BLE Coded PHY / Wi-Fi / LoRa.
    pub fn decode(raw: &[u8]) -> Result<Self, MeshRoutingError> {
        if raw.len() < MESH_HEADER_SIZE {
            return Err(MeshRoutingError::MalformedRelayEnvelope);
        }

        let packet_id = u64::from_be_bytes([
            raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
        ]);
        let ttl = raw[8];
        let hop_count = raw[9];

        let mut source_tag = [0u8; 8];
        source_tag.copy_from_slice(&raw[10..18]);

        let mut destination_tag = [0u8; 8];
        destination_tag.copy_from_slice(&raw[18..26]);

        let payload_len = usize::from(u16::from_be_bytes([raw[26], raw[27]]));
        if raw.len() != MESH_HEADER_SIZE + payload_len {
            return Err(MeshRoutingError::MalformedRelayEnvelope);
        }

        Ok(Self {
            packet_id,
            ttl,
            hop_count,
            source_tag,
            destination_tag,
            sealed_payload: raw[MESH_HEADER_SIZE..].to_vec(),
        })
    }
}

/// Structure interne signée avant chiffrement asymétrique 0-RTT (`Noise_N`).
#[derive(Serialize, Deserialize, Debug, PartialEq, Eq)]
pub struct SignedInnerMessage {
    pub sender_ed25519_public: [u8; 32],
    pub sender_x25519_public: [u8; 32],
    pub timestamp_ms: u64,
    pub plaintext_body: Vec<u8>,
    pub ed25519_signature_hex: String,
}

/// Scelle un message en 0-RTT (`Noise_N_25519_ChaChaPoly_BLAKE2s`) à destination de la clé
/// statique X25519 distante, permettant au paquet de traverser N relais intermédiaires ou des mules DTN.
pub fn seal_multihop_0rtt(
    sender_identity: &LocalNodeIdentity,
    recipient_x25519_static_pub: &[u8; 32],
    timestamp_ms: u64,
    plaintext: &[u8],
) -> Result<Vec<u8>, MeshRoutingError> {
    // 1. Signature Ed25519 du transcript par l'expéditeur pour authentifier l'origine
    let signing_key = SigningKey::from_bytes(sender_identity.ed25519_secret_key());
    let mut to_sign = Vec::with_capacity(72 + plaintext.len());
    to_sign.extend_from_slice(b"SANSINTERNET_0RTT_V1:");
    to_sign.extend_from_slice(recipient_x25519_static_pub);
    to_sign.extend_from_slice(&timestamp_ms.to_be_bytes());
    to_sign.extend_from_slice(plaintext);
    let signature = signing_key.sign(&to_sign);

    let inner = SignedInnerMessage {
        sender_ed25519_public: *sender_identity.ed25519_public_key(),
        sender_x25519_public: *sender_identity.noise_public_key(),
        timestamp_ms,
        plaintext_body: plaintext.to_vec(),
        ed25519_signature_hex: hex::encode(signature.to_bytes()),
    };

    let serialized_inner =
        serde_json::to_vec(&inner).map_err(|_| MeshRoutingError::OneWayCryptoFailed)?;
    let padded_inner = pad_plaintext_block(&serialized_inner);

    // 2. Scellement Noise_N (X25519 éphémère -> X25519 statique du destinataire + ChaCha20-Poly1305)
    let params = NOISE_ONEWAY_PATTERN
        .parse()
        .map_err(|_| MeshRoutingError::OneWayCryptoFailed)?;
    let mut initiator = Builder::new(params)
        .remote_public_key(recipient_x25519_static_pub)
        .build_initiator()
        .map_err(|_| MeshRoutingError::OneWayCryptoFailed)?;

    let mut cipher_buf = vec![0u8; padded_inner.len() + 64];
    let written = initiator
        .write_message(&padded_inner, &mut cipher_buf)
        .map_err(|_| MeshRoutingError::OneWayCryptoFailed)?;
    cipher_buf.truncate(written);

    Ok(cipher_buf)
}

/// Déchiffre un paquet Multi-Hop 0-RTT (`Noise_N`) et vérifie la signature `Ed25519` de l'émetteur.
pub fn open_multihop_0rtt(
    recipient_identity: &LocalNodeIdentity,
    sealed_payload: &[u8],
) -> Result<(String, SignedInnerMessage), MeshRoutingError> {
    let params = NOISE_ONEWAY_PATTERN
        .parse()
        .map_err(|_| MeshRoutingError::OneWayCryptoFailed)?;
    let mut responder = Builder::new(params)
        .local_private_key(recipient_identity.noise_private_key())
        .build_responder()
        .map_err(|_| MeshRoutingError::OneWayCryptoFailed)?;

    let mut padded_buf = vec![0u8; sealed_payload.len()];
    let read_len = responder
        .read_message(sealed_payload, &mut padded_buf)
        .map_err(|_| MeshRoutingError::OneWayCryptoFailed)?;
    padded_buf.truncate(read_len);

    let unpadded = unpad_plaintext_block(&padded_buf)?;
    let inner: SignedInnerMessage =
        serde_json::from_slice(&unpadded).map_err(|_| MeshRoutingError::OneWayCryptoFailed)?;

    // Vérification cryptographique de la signature Ed25519 de l'expéditeur
    let sig_vec = hex::decode(&inner.ed25519_signature_hex)
        .map_err(|_| MeshRoutingError::InvalidSenderSignature)?;
    let sig_bytes: [u8; 64] = sig_vec
        .try_into()
        .map_err(|_| MeshRoutingError::InvalidSenderSignature)?;

    let verifying_key = VerifyingKey::from_bytes(&inner.sender_ed25519_public)
        .map_err(|_| MeshRoutingError::InvalidSenderSignature)?;
    let signature = Signature::from_bytes(&sig_bytes);

    let mut expected_transcript = Vec::with_capacity(72 + inner.plaintext_body.len());
    expected_transcript.extend_from_slice(b"SANSINTERNET_0RTT_V1:");
    expected_transcript.extend_from_slice(recipient_identity.noise_public_key());
    expected_transcript.extend_from_slice(&inner.timestamp_ms.to_be_bytes());
    expected_transcript.extend_from_slice(&inner.plaintext_body);

    verifying_key
        .verify(&expected_transcript, &signature)
        .map_err(|_| MeshRoutingError::InvalidSenderSignature)?;

    let sender_peer_id =
        compute_peer_id_hex(&inner.sender_ed25519_public, &inner.sender_x25519_public);

    Ok((sender_peer_id, inner))
}

/// Routeur Multi-Hop avec cache FIFO/LRU borné anti-boucle pour le relayage de proche en proche.
pub struct MultiHopMeshRouter {
    local_routing_tag: [u8; 8],
    seen_order: VecDeque<u64>,
    seen_set: HashSet<u64>,
    max_entries: usize,
}

impl MultiHopMeshRouter {
    pub fn new(local_routing_tag: [u8; 8]) -> Self {
        Self {
            local_routing_tag,
            seen_order: VecDeque::with_capacity(MAX_DEDUP_CACHE_ENTRIES),
            seen_set: HashSet::with_capacity(MAX_DEDUP_CACHE_ENTRIES),
            max_entries: MAX_DEDUP_CACHE_ENTRIES,
        }
    }

    /// Enregistre un `packet_id` émis localement pour ne pas le relayer s'il nous revient en écho radio.
    pub fn register_local_packet(&mut self, packet_id: u64) {
        self.insert_seen(packet_id);
    }

    fn insert_seen(&mut self, packet_id: u64) -> bool {
        if self.seen_set.contains(&packet_id) {
            return false;
        }
        if self.seen_order.len() >= self.max_entries {
            if let Some(oldest) = self.seen_order.pop_front() {
                self.seen_set.remove(&oldest);
            }
        }
        self.seen_order.push_back(packet_id);
        self.seen_set.insert(packet_id);
        true
    }

    /// Évalue une enveloppe Multi-Hop entrante en temps constant sur le tag de destination
    /// et décide s'il faut la livrer localement, la relayer aux voisins ou la détruire.
    pub fn evaluate_incoming(&mut self, mut env: MeshRelayEnvelope) -> RouteDecision {
        // 1. Filtrage immédiat des doublons (anti-boucle Gossip)
        if !self.insert_seen(env.packet_id) {
            return RouteDecision::Drop(MeshRoutingError::DuplicatePacketDropped);
        }

        // 2. Comparaison en temps constant du tag de destination avec notre tag local
        let is_for_us = env
            .destination_tag
            .ct_eq(&self.local_routing_tag)
            .unwrap_u8()
            == 1;
        let is_broadcast = env.destination_tag.ct_eq(&[0xFF; 8]).unwrap_u8() == 1;

        if is_for_us {
            return RouteDecision::DeliverLocally(env);
        }

        // 3. Vérification et décrémentation du TTL avant relayage
        if env.ttl <= 1 {
            return if is_broadcast {
                RouteDecision::DeliverLocally(env)
            } else {
                RouteDecision::Drop(MeshRoutingError::TtlExpired)
            };
        }

        env.ttl -= 1;
        env.hop_count = env.hop_count.saturating_add(1);

        if is_broadcast {
            RouteDecision::DeliverAndForward(env)
        } else {
            RouteDecision::ForwardToNeighbors(env)
        }
    }
}
