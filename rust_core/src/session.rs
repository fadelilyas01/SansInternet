#![forbid(unsafe_code)]

//! Machine à états du Handshake Noise `XX` (`Noise_XX_25519_ChaChaPoly_BLAKE2s`)
//! et tunnel de transport AEAD bidirectionnel avec protection anti-rejeu.

use crate::framing::{
    pad_plaintext_block, unpad_plaintext_block, FramingError, PacketType, SlidingReplayWindow,
    WireFrame, MAX_PAYLOAD_SIZE,
};
use crate::identity::{
    verify_public_bundle, IdentityError, LocalNodeIdentity, PublicIdentityBundle, NOISE_PATTERN,
};
use snow::{Builder, HandshakeState, TransportState};
use std::collections::HashMap;
use std::sync::Mutex;
use thiserror::Error;

#[derive(Error, Debug)]
pub enum SessionError {
    #[error("Erreur cryptographique interne lors du protocole Noise")]
    NoiseProtocolFailure,
    #[error("Identité du pair rejetée: {0}")]
    IdentityRejected(#[from] IdentityError),
    #[error("Erreur de trame réseau: {0}")]
    Framing(#[from] FramingError),
    #[error("État de session invalide pour cette opération")]
    InvalidSessionState,
    #[error("Session pair introuvable")]
    SessionNotFound,
}

enum SessionPhase {
    Transitioning,
    Handshaking {
        state: Box<HandshakeState>,
        is_initiator: bool,
        step: u8,
        remote_bundle: Option<PublicIdentityBundle>,
    },
    Established {
        transport: Box<TransportState>,
        remote_bundle: PublicIdentityBundle,
        tx_seq: u64,
        replay_window: SlidingReplayWindow,
    },
}

/// Session sécurisée par pair avec identifiant de session aléatoire.
pub struct PeerCryptoSession {
    session_id: u32,
    phase: SessionPhase,
}

impl PeerCryptoSession {
    /// Initialise une session en mode Initiateur (`-> e`).
    pub fn new_initiator(
        session_id: u32,
        identity: &LocalNodeIdentity,
    ) -> Result<(Self, WireFrame), SessionError> {
        let params = NOISE_PATTERN
            .parse()
            .map_err(|_| SessionError::NoiseProtocolFailure)?;
        let mut hs = Builder::new(params)
            .local_private_key(identity.noise_private_key())
            .build_initiator()
            .map_err(|_| SessionError::NoiseProtocolFailure)?;

        let mut buf = vec![0u8; 256];
        let len = hs
            .write_message(&[], &mut buf)
            .map_err(|_| SessionError::NoiseProtocolFailure)?;
        buf.truncate(len);

        let frame = WireFrame {
            packet_type: PacketType::HandshakeInit,
            session_id,
            sequence_number: 1,
            fragment_index: 0,
            fragment_total: 1,
            payload: buf,
        };

        let session = Self {
            session_id,
            phase: SessionPhase::Handshaking {
                state: Box::new(hs),
                is_initiator: true,
                step: 1,
                remote_bundle: None,
            },
        };

        Ok((session, frame))
    }

    /// Initialise une session en mode Répondeur (en attente de `-> e`).
    pub fn new_responder(
        session_id: u32,
        identity: &LocalNodeIdentity,
    ) -> Result<Self, SessionError> {
        let params = NOISE_PATTERN
            .parse()
            .map_err(|_| SessionError::NoiseProtocolFailure)?;
        let hs = Builder::new(params)
            .local_private_key(identity.noise_private_key())
            .build_responder()
            .map_err(|_| SessionError::NoiseProtocolFailure)?;

        Ok(Self {
            session_id,
            phase: SessionPhase::Handshaking {
                state: Box::new(hs),
                is_initiator: false,
                step: 0,
                remote_bundle: None,
            },
        })
    }

    /// Traite une trame de handshake entrante et renvoie éventuellement la trame de réponse.
    pub fn process_handshake_frame(
        &mut self,
        identity: &LocalNodeIdentity,
        incoming: &WireFrame,
    ) -> Result<Option<WireFrame>, SessionError> {
        // Extraction atomique de l'état pour permettre la transition propre vers Established
        let current_phase = std::mem::replace(&mut self.phase, SessionPhase::Transitioning);

        let SessionPhase::Handshaking {
            mut state,
            is_initiator,
            step,
            remote_bundle: _,
        } = current_phase
        else {
            return Err(SessionError::InvalidSessionState);
        };

        // Répondeur reçoit l'étape 1 (`HandshakeInit`: `-> e`) et répond par l'étape 2 (`<- e, ee, s, es`)
        if !is_initiator && step == 0 && incoming.packet_type == PacketType::HandshakeInit {
            let mut read_buf = vec![0u8; MAX_PAYLOAD_SIZE];
            state
                .read_message(&incoming.payload, &mut read_buf)
                .map_err(|_| SessionError::NoiseProtocolFailure)?;

            let local_bundle_bytes = serde_json::to_vec(&identity.export_public_bundle())
                .map_err(|_| SessionError::NoiseProtocolFailure)?;
            let mut write_buf = vec![0u8; MAX_PAYLOAD_SIZE];
            let written = state
                .write_message(&local_bundle_bytes, &mut write_buf)
                .map_err(|_| SessionError::NoiseProtocolFailure)?;
            write_buf.truncate(written);

            self.phase = SessionPhase::Handshaking {
                state,
                is_initiator: false,
                step: 2,
                remote_bundle: None,
            };

            return Ok(Some(WireFrame {
                packet_type: PacketType::HandshakeResp,
                session_id: self.session_id,
                sequence_number: 1,
                fragment_index: 0,
                fragment_total: 1,
                payload: write_buf,
            }));
        }

        // Initiateur reçoit l'étape 2 (`HandshakeResp`: `<- e, ee, s, es`) et répond par l'étape 3 (`-> s, se`)
        if is_initiator && step == 1 && incoming.packet_type == PacketType::HandshakeResp {
            let mut read_buf = vec![0u8; MAX_PAYLOAD_SIZE];
            let read_len = state
                .read_message(&incoming.payload, &mut read_buf)
                .map_err(|_| SessionError::NoiseProtocolFailure)?;
            read_buf.truncate(read_len);

            let peer_bundle: PublicIdentityBundle = serde_json::from_slice(&read_buf)
                .map_err(|_| SessionError::IdentityRejected(IdentityError::MalformedBundle))?;

            let remote_static_slice = state
                .get_remote_static()
                .ok_or(SessionError::NoiseProtocolFailure)?;
            let remote_static: [u8; 32] = remote_static_slice
                .try_into()
                .map_err(|_| SessionError::NoiseProtocolFailure)?;

            // Vérification cryptographique Ed25519 + Constant-Time Eq sur la clé statique X25519
            verify_public_bundle(&peer_bundle, &remote_static)?;

            let local_bundle_bytes = serde_json::to_vec(&identity.export_public_bundle())
                .map_err(|_| SessionError::NoiseProtocolFailure)?;
            let mut write_buf = vec![0u8; MAX_PAYLOAD_SIZE];
            let written = state
                .write_message(&local_bundle_bytes, &mut write_buf)
                .map_err(|_| SessionError::NoiseProtocolFailure)?;
            write_buf.truncate(written);

            let transport = (*state)
                .into_transport_mode()
                .map_err(|_| SessionError::NoiseProtocolFailure)?;

            self.phase = SessionPhase::Established {
                transport: Box::new(transport),
                remote_bundle: peer_bundle,
                tx_seq: 0,
                replay_window: SlidingReplayWindow::new(),
            };

            return Ok(Some(WireFrame {
                packet_type: PacketType::HandshakeFin,
                session_id: self.session_id,
                sequence_number: 2,
                fragment_index: 0,
                fragment_total: 1,
                payload: write_buf,
            }));
        }

        // Répondeur reçoit l'étape 3 (`HandshakeFin`: `-> s, se`) et passe en mode Transport
        if !is_initiator && step == 2 && incoming.packet_type == PacketType::HandshakeFin {
            let mut read_buf = vec![0u8; MAX_PAYLOAD_SIZE];
            let read_len = state
                .read_message(&incoming.payload, &mut read_buf)
                .map_err(|_| SessionError::NoiseProtocolFailure)?;
            read_buf.truncate(read_len);

            let peer_bundle: PublicIdentityBundle = serde_json::from_slice(&read_buf)
                .map_err(|_| SessionError::IdentityRejected(IdentityError::MalformedBundle))?;

            let remote_static_slice = state
                .get_remote_static()
                .ok_or(SessionError::NoiseProtocolFailure)?;
            let remote_static: [u8; 32] = remote_static_slice
                .try_into()
                .map_err(|_| SessionError::NoiseProtocolFailure)?;

            verify_public_bundle(&peer_bundle, &remote_static)?;

            let transport = (*state)
                .into_transport_mode()
                .map_err(|_| SessionError::NoiseProtocolFailure)?;

            self.phase = SessionPhase::Established {
                transport: Box::new(transport),
                remote_bundle: peer_bundle,
                tx_seq: 0,
                replay_window: SlidingReplayWindow::new(),
            };

            return Ok(None);
        }

        Err(SessionError::InvalidSessionState)
    }

    /// Indique si le tunnel E2EE est authentifié et prêt au transport de messages.
    pub fn is_established(&self) -> bool {
        matches!(self.phase, SessionPhase::Established { .. })
    }

    /// Retourne le certificat d'identité authentifié du pair distant.
    pub fn remote_identity(&self) -> Option<&PublicIdentityBundle> {
        match &self.phase {
            SessionPhase::Established { remote_bundle, .. } => Some(remote_bundle),
            SessionPhase::Handshaking { remote_bundle, .. } => remote_bundle.as_ref(),
            SessionPhase::Transitioning => None,
        }
    }

    /// Applique le padding PKCS#7 (64 octets), chiffre avec ChaCha20-Poly1305 et encapsule dans un `WireFrame`.
    pub fn seal_frame(
        &mut self,
        packet_type: PacketType,
        plaintext: &[u8],
    ) -> Result<WireFrame, SessionError> {
        let SessionPhase::Established {
            transport, tx_seq, ..
        } = &mut self.phase
        else {
            return Err(SessionError::InvalidSessionState);
        };

        let padded = pad_plaintext_block(plaintext);
        if padded.len() + 16 > MAX_PAYLOAD_SIZE {
            return Err(SessionError::Framing(FramingError::InvalidPayloadLength));
        }

        *tx_seq = tx_seq
            .checked_add(1)
            .ok_or(SessionError::NoiseProtocolFailure)?;

        let mut cipher_buf = vec![0u8; padded.len() + 16];
        let written = transport
            .write_message(&padded, &mut cipher_buf)
            .map_err(|_| SessionError::NoiseProtocolFailure)?;
        cipher_buf.truncate(written);

        Ok(WireFrame {
            packet_type,
            session_id: self.session_id,
            sequence_number: *tx_seq,
            fragment_index: 0,
            fragment_total: 1,
            payload: cipher_buf,
        })
    }

    /// Vérifie la fenêtre anti-rejeu, déchiffre la trame AEAD et retire le padding PKCS#7.
    pub fn open_frame(&mut self, frame: &WireFrame) -> Result<Vec<u8>, SessionError> {
        let SessionPhase::Established {
            transport,
            replay_window,
            ..
        } = &mut self.phase
        else {
            return Err(SessionError::InvalidSessionState);
        };

        // 1. Validation anti-rejeu avant ou après déchiffrement
        replay_window.accept(frame.sequence_number)?;

        // 2. Déchiffrement et vérification du tag Poly1305
        let mut padded_buf = vec![0u8; frame.payload.len()];
        let len = transport
            .read_message(&frame.payload, &mut padded_buf)
            .map_err(|_| SessionError::NoiseProtocolFailure)?;
        padded_buf.truncate(len);

        // 3. Suppression du padding PKCS#7
        let unpadded = unpad_plaintext_block(&padded_buf)?;
        Ok(unpadded)
    }
}

/// Registre thread-safe de toutes les sessions P2P actives, destiné à être exposé via FFI à Flutter.
pub struct MeshSessionRegistry {
    identity: LocalNodeIdentity,
    sessions: Mutex<HashMap<String, PeerCryptoSession>>,
}

impl MeshSessionRegistry {
    pub fn new(identity: LocalNodeIdentity) -> Self {
        Self {
            identity,
            sessions: Mutex::new(HashMap::new()),
        }
    }

    pub fn local_public_bundle(&self) -> PublicIdentityBundle {
        self.identity.export_public_bundle()
    }

    pub fn initiate_session(
        &self,
        endpoint_id: &str,
        session_id: u32,
    ) -> Result<Vec<u8>, SessionError> {
        let (session, init_frame) = PeerCryptoSession::new_initiator(session_id, &self.identity)?;
        let encoded = init_frame.encode()?;
        let mut guard = self
            .sessions
            .lock()
            .map_err(|_| SessionError::InvalidSessionState)?;
        guard.insert(endpoint_id.to_string(), session);
        Ok(encoded)
    }

    pub fn handle_handshake_bytes(
        &self,
        endpoint_id: &str,
        raw_frame: &[u8],
    ) -> Result<Option<Vec<u8>>, SessionError> {
        let frame = WireFrame::decode(raw_frame)?;
        let mut guard = self
            .sessions
            .lock()
            .map_err(|_| SessionError::InvalidSessionState)?;

        if !guard.contains_key(endpoint_id) && frame.packet_type == PacketType::HandshakeInit {
            let responder = PeerCryptoSession::new_responder(frame.session_id, &self.identity)?;
            guard.insert(endpoint_id.to_string(), responder);
        }

        let session = guard
            .get_mut(endpoint_id)
            .ok_or(SessionError::SessionNotFound)?;

        let maybe_resp = session.process_handshake_frame(&self.identity, &frame)?;
        match maybe_resp {
            Some(resp_frame) => Ok(Some(resp_frame.encode()?)),
            None => Ok(None),
        }
    }

    pub fn is_session_ready(&self, endpoint_id: &str) -> bool {
        self.sessions
            .lock()
            .ok()
            .and_then(|g| g.get(endpoint_id).map(PeerCryptoSession::is_established))
            .unwrap_or(false)
    }

    pub fn seal_for_endpoint(
        &self,
        endpoint_id: &str,
        packet_type: PacketType,
        plaintext: &[u8],
    ) -> Result<Vec<u8>, SessionError> {
        let mut guard = self
            .sessions
            .lock()
            .map_err(|_| SessionError::InvalidSessionState)?;
        let session = guard
            .get_mut(endpoint_id)
            .ok_or(SessionError::SessionNotFound)?;
        let frame = session.seal_frame(packet_type, plaintext)?;
        Ok(frame.encode()?)
    }

    pub fn open_from_endpoint(
        &self,
        endpoint_id: &str,
        raw_frame: &[u8],
    ) -> Result<(PacketType, Vec<u8>), SessionError> {
        let frame = WireFrame::decode(raw_frame)?;
        let mut guard = self
            .sessions
            .lock()
            .map_err(|_| SessionError::InvalidSessionState)?;
        let session = guard
            .get_mut(endpoint_id)
            .ok_or(SessionError::SessionNotFound)?;
        let plaintext = session.open_frame(&frame)?;
        Ok((frame.packet_type, plaintext))
    }

    pub fn remove_session(&self, endpoint_id: &str) {
        if let Ok(mut guard) = self.sessions.lock() {
            guard.remove(endpoint_id);
        }
    }
}
