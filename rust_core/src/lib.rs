#![forbid(unsafe_code)]

//! Point d'entrée de la bibliothèque cryptographique `sansinternet_core`.
//! Contient les modules d'identité, de framing binaire anti-rejeu et de session Noise `XX`,
//! ainsi que la suite complète de tests unitaires et d'intégration cryptographique.

pub mod framing;
pub mod identity;
pub mod mesh_router;
pub mod session;

#[cfg(test)]
mod tests {
    use super::framing::{
        pad_plaintext_block, unpad_plaintext_block, FramingError, PacketType, SlidingReplayWindow,
        WireFrame,
    };
    use super::identity::{verify_public_bundle, IdentityError, LocalNodeIdentity};
    use super::mesh_router::{
        open_multihop_0rtt, seal_multihop_0rtt, MeshRelayEnvelope, MeshRoutingError,
        MultiHopMeshRouter, RouteDecision, DEFAULT_MAX_TTL,
    };
    use super::session::{MeshSessionRegistry, SessionError};

    #[test]
    fn test_identity_generation_and_constant_time_verification() {
        let alice = LocalNodeIdentity::generate().expect("Génération identité Alice");
        let bob = LocalNodeIdentity::generate().expect("Génération identité Bob");

        let alice_bundle = alice.export_public_bundle();
        assert_eq!(alice_bundle.peer_id_hex.len(), 64);

        // Vérification nominale avec la vraie clé statique X25519
        assert!(verify_public_bundle(&alice_bundle, alice.noise_public_key()).is_ok());

        // Tentative d'usurpation avec la clé X25519 de Bob (rejet ConstantTimeEq)
        assert_eq!(
            verify_public_bundle(&alice_bundle, bob.noise_public_key()),
            Err(IdentityError::InvalidIdentitySignature)
        );
    }

    #[test]
    fn test_pkcs7_padding_and_wire_framing() {
        let msg = b"Coordonnees GPS: 48.8566, 2.3522";
        let padded = pad_plaintext_block(msg);
        assert_eq!(padded.len(), 64);

        let unpadded = unpad_plaintext_block(&padded).expect("Unpad valide");
        assert_eq!(unpadded, msg);

        let frame = WireFrame {
            packet_type: PacketType::DataMessage,
            session_id: 0xCAFE_BABE,
            sequence_number: 42,
            fragment_index: 0,
            fragment_total: 1,
            payload: padded,
        };

        let raw = frame.encode().expect("Encodage trame");
        let decoded = WireFrame::decode(&raw).expect("Décodage trame");
        assert_eq!(decoded, frame);
    }

    #[test]
    fn test_sliding_replay_window_rejects_duplicates_and_old_packets() {
        let mut window = SlidingReplayWindow::new();

        // Séquence 0 interdite
        assert_eq!(window.accept(0), Err(FramingError::ReplayDetected(0)));

        // Séquences dans l'ordre et hors-ordre dans la fenêtre de 64
        assert!(window.accept(1).is_ok());
        assert!(window.accept(5).is_ok());
        assert!(window.accept(3).is_ok());

        // Rejeu direct de la séquence 3 ou 5
        assert_eq!(window.accept(3), Err(FramingError::ReplayDetected(3)));
        assert_eq!(window.accept(5), Err(FramingError::ReplayDetected(5)));

        // Saut à la séquence 100 : la séquence 10 est maintenant hors de la fenêtre de 64 paquets
        assert!(window.accept(100).is_ok());
        assert_eq!(window.accept(10), Err(FramingError::ReplayDetected(10)));
        assert!(window.accept(99).is_ok());
    }

    #[test]
    fn test_full_noise_xx_handshake_and_bidirectional_e2ee_transport() {
        let alice_id = LocalNodeIdentity::generate().expect("Identité Alice");
        let bob_id = LocalNodeIdentity::generate().expect("Identité Bob");

        let alice_registry = MeshSessionRegistry::new(alice_id);
        let bob_registry = MeshSessionRegistry::new(bob_id);

        let endpoint_alice_to_bob = "ep_bob_01";
        let endpoint_bob_to_alice = "ep_alice_01";

        // Étape 1 : Alice initie le handshake (-> e)
        let msg1 = alice_registry
            .initiate_session(endpoint_alice_to_bob, 9001)
            .expect("Init handshake Alice");

        // Étape 2 : Bob traite msg1 et répond (<- e, ee, s, es + Certificat Ed25519 Bob)
        let msg2 = bob_registry
            .handle_handshake_bytes(endpoint_bob_to_alice, &msg1)
            .expect("Bob traite msg1")
            .expect("Bob génère msg2");

        // Étape 3 : Alice traite msg2, vérifie l'identité de Bob, passe en transport et génère msg3 (-> s, se + Certificat Alice)
        let msg3 = alice_registry
            .handle_handshake_bytes(endpoint_alice_to_bob, &msg2)
            .expect("Alice traite msg2")
            .expect("Alice génère msg3");
        assert!(alice_registry.is_session_ready(endpoint_alice_to_bob));

        // Étape 4 : Bob traite msg3, vérifie l'identité d'Alice et passe en transport
        let msg4 = bob_registry
            .handle_handshake_bytes(endpoint_bob_to_alice, &msg3)
            .expect("Bob traite msg3");
        assert!(msg4.is_none());
        assert!(bob_registry.is_session_ready(endpoint_bob_to_alice));

        // Transport E2EE : Alice envoie un message chiffré à Bob
        let secret_payload = br#"{"v":1,"id":"msg-001","body":"Canal P2P hors-ligne operationnel"}"#;
        let wire_packet = alice_registry
            .seal_for_endpoint(endpoint_alice_to_bob, PacketType::DataMessage, secret_payload)
            .expect("Alice chiffre le message");

        let (pkt_type, decrypted) = bob_registry
            .open_from_endpoint(endpoint_bob_to_alice, &wire_packet)
            .expect("Bob déchiffre le message");
        assert_eq!(pkt_type, PacketType::DataMessage);
        assert_eq!(decrypted, secret_payload);

        // Tentative d'attaque par rejeu du même paquet sur le canal de Bob
        let replay_attempt = bob_registry.open_from_endpoint(endpoint_bob_to_alice, &wire_packet);
        assert!(matches!(
            replay_attempt,
            Err(SessionError::Framing(FramingError::ReplayDetected(1)))
        ));
    }

    #[test]
    fn test_long_range_multihop_3_hops_routing_and_0rtt_e2ee() {
        // Scénario Longue Portée : Alice -> Relais 1 -> Relais 2 -> Bob (hors de portée directe d'Alice)
        let alice = LocalNodeIdentity::generate().expect("Identité Alice");
        let relay1 = LocalNodeIdentity::generate().expect("Identité Relais 1");
        let relay2 = LocalNodeIdentity::generate().expect("Identité Relais 2");
        let bob = LocalNodeIdentity::generate().expect("Identité Bob");

        let alice_tag =
            MeshRelayEnvelope::tag_from_peer_id_hex(&alice.peer_id_hex()).expect("Tag Alice");
        let relay1_tag =
            MeshRelayEnvelope::tag_from_peer_id_hex(&relay1.peer_id_hex()).expect("Tag Relais 1");
        let relay2_tag =
            MeshRelayEnvelope::tag_from_peer_id_hex(&relay2.peer_id_hex()).expect("Tag Relais 2");
        let bob_tag = MeshRelayEnvelope::tag_from_peer_id_hex(&bob.peer_id_hex()).expect("Tag Bob");

        let mut router_relay1 = MultiHopMeshRouter::new(relay1_tag);
        let mut router_relay2 = MultiHopMeshRouter::new(relay2_tag);
        let mut router_bob = MultiHopMeshRouter::new(bob_tag);

        // 1. Alice scelle un paquet E2EE 0-RTT pour Bob avec Noise_N + Signature Ed25519
        let msg_clear = b"Alerte longue portee via 2 relais intermediaires (Hop=2)";
        let sealed_for_bob = seal_multihop_0rtt(
            &alice,
            bob.noise_public_key(),
            1_762_795_000_000,
            msg_clear,
        )
        .expect("Scellement 0-RTT Noise_N");

        let initial_envelope = MeshRelayEnvelope {
            packet_id: 0xDEAD_BEEF_CAFE_0001,
            ttl: DEFAULT_MAX_TTL, // 7
            hop_count: 0,
            source_tag: alice_tag,
            destination_tag: bob_tag,
            sealed_payload: sealed_for_bob,
        };

        let wire_hop0 = initial_envelope.encode().expect("Encodage Hop 0");

        // 2. Saut 1 : Relais 1 reçoit la trame radio d'Alice
        let env_at_r1 = MeshRelayEnvelope::decode(&wire_hop0).expect("Décodage R1");
        let RouteDecision::ForwardToNeighbors(forwarded_by_r1) =
            router_relay1.evaluate_incoming(env_at_r1)
        else {
            panic!("Relais 1 devait relayer le paquet");
        };
        assert_eq!(forwarded_by_r1.ttl, 6);
        assert_eq!(forwarded_by_r1.hop_count, 1);

        // Si Relais 1 ré-entend le même paquet en écho radio, il le bloque immédiatement (anti-boucle)
        let echo_copy = MeshRelayEnvelope::decode(&wire_hop0).expect("Décodage écho");
        assert_eq!(
            router_relay1.evaluate_incoming(echo_copy),
            RouteDecision::Drop(MeshRoutingError::DuplicatePacketDropped)
        );

        // 3. Saut 2 : Relais 2 reçoit la trame de Relais 1 et la relaie vers Bob
        let wire_hop1 = forwarded_by_r1.encode().expect("Encodage Hop 1");
        let env_at_r2 = MeshRelayEnvelope::decode(&wire_hop1).expect("Décodage R2");
        let RouteDecision::ForwardToNeighbors(forwarded_by_r2) =
            router_relay2.evaluate_incoming(env_at_r2)
        else {
            panic!("Relais 2 devait relayer le paquet");
        };
        assert_eq!(forwarded_by_r2.ttl, 5);
        assert_eq!(forwarded_by_r2.hop_count, 2);

        // 4. Saut 3 : Bob reçoit la trame de Relais 2, reconnaît son tag et déchiffre le message d'Alice
        let wire_hop2 = forwarded_by_r2.encode().expect("Encodage Hop 2");
        let env_at_bob = MeshRelayEnvelope::decode(&wire_hop2).expect("Décodage Bob");
        let RouteDecision::DeliverLocally(delivered_env) =
            router_bob.evaluate_incoming(env_at_bob)
        else {
            panic!("Bob devait consommer le paquet localement");
        };
        assert_eq!(delivered_env.hop_count, 2);

        let (verified_sender_peer_id, inner_msg) =
            open_multihop_0rtt(&bob, &delivered_env.sealed_payload)
                .expect("Bob déchiffre et vérifie la signature Ed25519 d'Alice");

        assert_eq!(verified_sender_peer_id, alice.peer_id_hex());
        assert_eq!(inner_msg.plaintext_body, msg_clear);
    }
}
