#![forbid(unsafe_code)]

//! Module de Framing Binaire, Padding PKCS#7 par blocs de 64 octets et Fenêtre Anti-Rejeu.
//!
//! Format de trame sur le fil (Wire Frame Header - 25 octets fixes + Payload) :
//! - Octets 0..2   : Magic `0x4D53` ("MS" - Mesh Secure)
//! - Octet  2      : Version du protocole (`0x01`)
//! - Octet  3      : Type de paquet (`PacketType`)
//! - Octets 4..8   : Session ID (u32 big-endian)
//! - Octets 8..16  : Sequence Number monotone (u64 big-endian)
//! - Octets 16..18 : Fragment Index (u16 big-endian)
//! - Octets 18..20 : Fragment Total (u16 big-endian)
//! - Octets 20..22 : Payload Length (u16 big-endian)
//! - Octets 22..N  : Payload (Handshake ou Ciphertext Noise AEAD)

use thiserror::Error;

pub const WIRE_MAGIC: u16 = 0x4D53;
pub const PROTOCOL_VERSION: u8 = 0x01;
pub const HEADER_SIZE: usize = 22;
pub const MAX_PAYLOAD_SIZE: usize = 4096;
pub const PADDING_BLOCK_SIZE: usize = 64;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum PacketType {
    HandshakeInit = 0x01,
    HandshakeResp = 0x02,
    HandshakeFin = 0x03,
    DataMessage = 0x10,
    DeliveryAck = 0x11,
    KeepAlivePing = 0x12,
}

impl TryFrom<u8> for PacketType {
    type Error = FramingError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            0x01 => Ok(Self::HandshakeInit),
            0x02 => Ok(Self::HandshakeResp),
            0x03 => Ok(Self::HandshakeFin),
            0x10 => Ok(Self::DataMessage),
            0x11 => Ok(Self::DeliveryAck),
            0x12 => Ok(Self::KeepAlivePing),
            _ => Err(FramingError::UnknownPacketType(value)),
        }
    }
}

#[derive(Error, Debug, Clone, PartialEq, Eq)]
pub enum FramingError {
    #[error("Trame trop courte pour contenir un en-tête valide")]
    FrameTooShort,
    #[error("Signature magique de trame invalide")]
    InvalidMagic,
    #[error("Version de protocole non supportée: {0}")]
    UnsupportedVersion(u8),
    #[error("Type de paquet inconnu: {0:#04x}")]
    UnknownPacketType(u8),
    #[error("Taille du payload excessive ou incohérente")]
    InvalidPayloadLength,
    #[error("Padding PKCS#7 corrompu ou invalide")]
    InvalidPadding,
    #[error("Attaque par rejeu détectée ou paquet hors fenêtre (seq={0})")]
    ReplayDetected(u64),
}

/// Structure d'une trame réseau P2P décodée.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WireFrame {
    pub packet_type: PacketType,
    pub session_id: u32,
    pub sequence_number: u64,
    pub fragment_index: u16,
    pub fragment_total: u16,
    pub payload: Vec<u8>,
}

impl WireFrame {
    /// Sérialise la trame en octets prêts pour l'expédition BLE / Wi-Fi Direct.
    pub fn encode(&self) -> Result<Vec<u8>, FramingError> {
        if self.payload.len() > MAX_PAYLOAD_SIZE || self.fragment_total == 0 {
            return Err(FramingError::InvalidPayloadLength);
        }
        let payload_len = u16::try_from(self.payload.len())
            .map_err(|_| FramingError::InvalidPayloadLength)?;

        let mut buf = Vec::with_capacity(HEADER_SIZE + self.payload.len());
        buf.extend_from_slice(&WIRE_MAGIC.to_be_bytes());
        buf.push(PROTOCOL_VERSION);
        buf.push(self.packet_type as u8);
        buf.extend_from_slice(&self.session_id.to_be_bytes());
        buf.extend_from_slice(&self.sequence_number.to_be_bytes());
        buf.extend_from_slice(&self.fragment_index.to_be_bytes());
        buf.extend_from_slice(&self.fragment_total.to_be_bytes());
        buf.extend_from_slice(&payload_len.to_be_bytes());
        buf.extend_from_slice(&self.payload);
        Ok(buf)
    }

    /// Désérialise et valide rigoureusement une trame binaire entrante.
    pub fn decode(raw: &[u8]) -> Result<Self, FramingError> {
        if raw.len() < HEADER_SIZE {
            return Err(FramingError::FrameTooShort);
        }

        let magic = u16::from_be_bytes([raw[0], raw[1]]);
        if magic != WIRE_MAGIC {
            return Err(FramingError::InvalidMagic);
        }

        let version = raw[2];
        if version != PROTOCOL_VERSION {
            return Err(FramingError::UnsupportedVersion(version));
        }

        let packet_type = PacketType::try_from(raw[3])?;
        let session_id = u32::from_be_bytes([raw[4], raw[5], raw[6], raw[7]]);
        let sequence_number = u64::from_be_bytes([
            raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15],
        ]);
        let fragment_index = u16::from_be_bytes([raw[16], raw[17]]);
        let fragment_total = u16::from_be_bytes([raw[18], raw[19]]);
        let payload_len = usize::from(u16::from_be_bytes([raw[20], raw[21]]));

        if fragment_total == 0
            || fragment_index >= fragment_total
            || payload_len > MAX_PAYLOAD_SIZE
            || raw.len() != HEADER_SIZE + payload_len
        {
            return Err(FramingError::InvalidPayloadLength);
        }

        Ok(Self {
            packet_type,
            session_id,
            sequence_number,
            fragment_index,
            fragment_total,
            payload: raw[HEADER_SIZE..].to_vec(),
        })
    }
}

/// Applique un bourrage PKCS#7 par blocs de 64 octets afin de masquer la taille exacte des messages.
pub fn pad_plaintext_block(plaintext: &[u8]) -> Vec<u8> {
    let rem = plaintext.len() % PADDING_BLOCK_SIZE;
    let pad_len = PADDING_BLOCK_SIZE - rem;
    let pad_byte = pad_len as u8;

    let mut out = Vec::with_capacity(plaintext.len() + pad_len);
    out.extend_from_slice(plaintext);
    out.resize(plaintext.len() + pad_len, pad_byte);
    out
}

/// Retire et vérifie le bourrage PKCS#7 en temps constant logique après déchiffrement AEAD.
pub fn unpad_plaintext_block(padded: &[u8]) -> Result<Vec<u8>, FramingError> {
    if padded.is_empty() || !padded.len().is_multiple_of(PADDING_BLOCK_SIZE) {
        return Err(FramingError::InvalidPadding);
    }

    let pad_len = usize::from(padded[padded.len() - 1]);
    if pad_len == 0 || pad_len > PADDING_BLOCK_SIZE || pad_len > padded.len() {
        return Err(FramingError::InvalidPadding);
    }

    let start_pad = padded.len() - pad_len;
    let mut mismatch: u8 = 0;
    for &b in &padded[start_pad..] {
        mismatch |= b ^ (pad_len as u8);
    }

    if mismatch != 0 {
        return Err(FramingError::InvalidPadding);
    }

    Ok(padded[..start_pad].to_vec())
}

/// Fenêtre glissante anti-rejeu sur 64 numéros de séquence (inspirée de RFC 6479 / WireGuard).
#[derive(Debug, Clone, Default)]
pub struct SlidingReplayWindow {
    highest_seq: u64,
    bitmap: u64,
}

impl SlidingReplayWindow {
    pub fn new() -> Self {
        Self {
            highest_seq: 0,
            bitmap: 0,
        }
    }

    /// Vérifie si `seq` est valide et met à jour la fenêtre atomiquement.
    pub fn accept(&mut self, seq: u64) -> Result<(), FramingError> {
        if seq == 0 {
            return Err(FramingError::ReplayDetected(0));
        }

        if seq > self.highest_seq {
            let diff = seq - self.highest_seq;
            if diff >= 64 {
                self.bitmap = 1;
            } else {
                self.bitmap = (self.bitmap << diff) | 1;
            }
            self.highest_seq = seq;
            return Ok(());
        }

        let diff = self.highest_seq - seq;
        if diff >= 64 {
            return Err(FramingError::ReplayDetected(seq));
        }

        let mask = 1u64 << diff;
        if (self.bitmap & mask) != 0 {
            return Err(FramingError::ReplayDetected(seq));
        }

        self.bitmap |= mask;
        Ok(())
    }
}
