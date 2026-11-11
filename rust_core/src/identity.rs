#![forbid(unsafe_code)]

//! Module de gestion des identités cryptographiques long-terme et de vérification Out-Of-Band (QR Code).
//!
//! Chaque noeud dispose :
//! - D'une paire de clés Ed25519 pour la signature d'identité et la dérivation du `PeerId` (BLAKE2s-256).
//! - D'une paire de clés statiques X25519 utilisée lors du handshake `Noise_XX_25519_ChaChaPoly_BLAKE2s`.
//!
//! Toutes les clés privées sont automatiquement purgées de la mémoire vive via `zeroize::ZeroizeOnDrop`.

use blake2::{Blake2s256, Digest};
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use rand::rngs::OsRng;
use serde::{Deserialize, Serialize};
use snow::Builder;
use subtle::ConstantTimeEq;
use thiserror::Error;
use zeroize::{Zeroize, ZeroizeOnDrop};

pub const NOISE_PATTERN: &str = "Noise_XX_25519_ChaChaPoly_BLAKE2s";

#[derive(Error, Debug, PartialEq, Eq)]
pub enum IdentityError {
    #[error("Échec de génération de clé cryptographique matérielle")]
    KeyGenerationFailed,
    #[error("Signature cryptographique Ed25519 ou empreinte d'identité invalide")]
    InvalidIdentitySignature,
    #[error("Le PeerId calculé ne correspond pas à la clé publique fournie")]
    PeerIdMismatch,
    #[error("Format de bundle d'identité QR invalide")]
    MalformedBundle,
}

/// Certificat d'identité publique échangeable hors-ligne (QR Code ou annonce authentifiée).
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PublicIdentityBundle {
    pub peer_id_hex: String,
    pub ed25519_public: [u8; 32],
    pub x25519_static_public: [u8; 32],
    pub signature_hex: String,
}

/// Identité locale contenant les clés secrètes protégées en RAM par ZeroizeOnDrop.
#[derive(Zeroize, ZeroizeOnDrop)]
pub struct LocalNodeIdentity {
    ed25519_secret: [u8; 32],
    #[zeroize(skip)]
    ed25519_public: [u8; 32],
    x25519_private: [u8; 32],
    #[zeroize(skip)]
    x25519_public: [u8; 32],
}

impl LocalNodeIdentity {
    /// Génère une nouvelle identité complète à partir du CSPRNG de l'OS (`OsRng`).
    pub fn generate() -> Result<Self, IdentityError> {
        let signing_key = SigningKey::generate(&mut OsRng);
        let verifying_key = signing_key.verifying_key();

        let params = NOISE_PATTERN
            .parse()
            .map_err(|_| IdentityError::KeyGenerationFailed)?;
        let builder = Builder::new(params);
        let dh_kp = builder
            .generate_keypair()
            .map_err(|_| IdentityError::KeyGenerationFailed)?;

        let mut x_priv = [0u8; 32];
        let mut x_pub = [0u8; 32];
        x_priv.copy_from_slice(&dh_kp.private);
        x_pub.copy_from_slice(&dh_kp.public);

        Ok(Self {
            ed25519_secret: signing_key.to_bytes(),
            ed25519_public: verifying_key.to_bytes(),
            x25519_private: x_priv,
            x25519_public: x_pub,
        })
    }

    /// Restaure une identité depuis des octets secrets stockés dans le Keystore/Keychain matériel.
    pub fn from_secret_bytes(
        ed25519_secret: [u8; 32],
        x25519_private: [u8; 32],
        x25519_public: [u8; 32],
    ) -> Self {
        let signing_key = SigningKey::from_bytes(&ed25519_secret);
        let ed25519_public = signing_key.verifying_key().to_bytes();
        Self {
            ed25519_secret,
            ed25519_public,
            x25519_private,
            x25519_public,
        }
    }

    /// Retourne la clé privée statique X25519 pour initialiser l'automate Noise.
    pub(crate) fn noise_private_key(&self) -> &[u8; 32] {
        &self.x25519_private
    }

    /// Retourne la clé publique statique X25519.
    pub fn noise_public_key(&self) -> &[u8; 32] {
        &self.x25519_public
    }

    /// Retourne la clé publique Ed25519.
    pub fn ed25519_public_key(&self) -> &[u8; 32] {
        &self.ed25519_public
    }

    /// Retourne la clé secrète Ed25519 pour la signature de paquets Multi-Hop 0-RTT.
    pub(crate) fn ed25519_secret_key(&self) -> &[u8; 32] {
        &self.ed25519_secret
    }

    /// Calcule le `PeerId` canonique (hash BLAKE2s-256 de la clé publique Ed25519 et X25519).
    pub fn peer_id_hex(&self) -> String {
        compute_peer_id_hex(&self.ed25519_public, &self.x25519_public)
    }

    /// Exporte le bundle public signé prêt à être encodé en QR Code ou transmis dans le payload Noise.
    pub fn export_public_bundle(&self) -> PublicIdentityBundle {
        let signing_key = SigningKey::from_bytes(&self.ed25519_secret);
        let msg_to_sign = build_signed_transcript(&self.ed25519_public, &self.x25519_public);
        let signature = signing_key.sign(&msg_to_sign);

        PublicIdentityBundle {
            peer_id_hex: self.peer_id_hex(),
            ed25519_public: self.ed25519_public,
            x25519_static_public: self.x25519_public,
            signature_hex: hex::encode(signature.to_bytes()),
        }
    }
}

/// Calcule le `PeerId` déterministe en hexadécimal (64 caractères) à partir des clés publiques.
pub fn compute_peer_id_hex(ed25519_pub: &[u8; 32], x25519_pub: &[u8; 32]) -> String {
    let mut hasher = Blake2s256::new();
    hasher.update(b"SANSINTERNET_PEER_ID_V1:");
    hasher.update(ed25519_pub);
    hasher.update(x25519_pub);
    hex::encode(hasher.finalize())
}

fn build_signed_transcript(ed25519_pub: &[u8; 32], x25519_pub: &[u8; 32]) -> [u8; 88] {
    let mut transcript = [0u8; 88];
    transcript[0..24].copy_from_slice(b"SANSINTERNET_KEYBIND_V1:");
    transcript[24..56].copy_from_slice(ed25519_pub);
    transcript[56..88].copy_from_slice(x25519_pub);
    transcript
}

/// Vérifie rigoureusement un `PublicIdentityBundle` et s'assure que la clé statique X25519
/// négociée dans le tunnel Noise correspond en temps constant (`ConstantTimeEq`) au certificat.
pub fn verify_public_bundle(
    bundle: &PublicIdentityBundle,
    negotiated_x25519_remote: &[u8; 32],
) -> Result<(), IdentityError> {
    // 1. Comparaison en temps constant de la clé statique X25519 négociée via Noise
    if bundle
        .x25519_static_public
        .ct_eq(negotiated_x25519_remote)
        .unwrap_u8()
        == 0
    {
        return Err(IdentityError::InvalidIdentitySignature);
    }

    // 2. Vérification en temps constant du PeerId dérivé
    let expected_peer_id =
        compute_peer_id_hex(&bundle.ed25519_public, &bundle.x25519_static_public);
    if expected_peer_id
        .as_bytes()
        .ct_eq(bundle.peer_id_hex.as_bytes())
        .unwrap_u8()
        == 0
    {
        return Err(IdentityError::PeerIdMismatch);
    }

    // 3. Vérification cryptographique de la signature Ed25519 liant Ed25519 <-> X25519
    let sig_vec = hex::decode(&bundle.signature_hex).map_err(|_| IdentityError::MalformedBundle)?;
    let sig_bytes: [u8; 64] = sig_vec
        .try_into()
        .map_err(|_| IdentityError::MalformedBundle)?;

    let verifying_key = VerifyingKey::from_bytes(&bundle.ed25519_public)
        .map_err(|_| IdentityError::InvalidIdentitySignature)?;
    let signature = Signature::from_bytes(&sig_bytes);
    let transcript = build_signed_transcript(&bundle.ed25519_public, &bundle.x25519_static_public);

    verifying_key
        .verify(&transcript, &signature)
        .map_err(|_| IdentityError::InvalidIdentitySignature)
}
