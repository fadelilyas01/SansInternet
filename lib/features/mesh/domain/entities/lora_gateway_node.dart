/// Bande de fréquence radio Sub-GHz configurée pour le module LoRa.
enum LoRaFrequencyBand {
  /// 868 MHz : Bande libre standard pour l'Europe et l'Afrique.
  eu868(name: '868 MHz (Europe / Afrique)', frequencyMhz: 868.1),

  /// 915 MHz : Bande libre standard pour les Amériques et l'Océanie.
  us915(name: '915 MHz (Amériques)', frequencyMhz: 915.0),

  /// 433 MHz : Bande d'urgence et secours internationale.
  intl433(name: '433 MHz (Secours & Urgence)', frequencyMhz: 433.175);

  final String name;
  final double frequencyMhz;

  const LoRaFrequencyBand({required this.name, required this.frequencyMhz});
}

/// Préréglage de modulation radio pour adapter le compromis Portée vs Vitesse.
enum LoRaModulationPreset {
  /// Spreading Factor 7 : Plus rapide, portée urbaine ~5 km.
  fastShortRange(
    label: 'Rapide (~5 km)',
    spreadingFactor: 7,
    bandwidthKhz: 250,
    description: 'Idéal pour transferts rapides de photos en zone urbaine dense',
  ),

  /// Spreading Factor 9 : Portée équilibrée standard ~15 km.
  balancedMediumRange(
    label: 'Standard (~15 km)',
    spreadingFactor: 9,
    bandwidthKhz: 125,
    description: 'Compromis parfait entre débit et pénétration à travers les obstacles',
  ),

  /// Spreading Factor 12 : Sensibilité maximale, portée extrême ~30+ km.
  extremeLongRange(
    label: 'Ultra Longue Portée (~30 km)',
    spreadingFactor: 12,
    bandwidthKhz: 125,
    description: 'Portée maximale à travers les collines, forêts et vallées',
  );

  final String label;
  final int spreadingFactor;
  final int bandwidthKhz;
  final String description;

  const LoRaModulationPreset({
    required this.label,
    required this.spreadingFactor,
    required this.bandwidthKhz,
    required this.description,
  });
}

/// État de connexion avec le module radio LoRa externe.
enum LoRaConnectionState {
  disconnected,
  scanning,
  connecting,
  connected,
}

/// Entité représentant un boîtier radio externe LoRa (Meshtastic / SX1262 / Heltec / LilyGO).
final class LoRaGatewayNode {
  final String deviceId;
  final String nodeName;
  final LoRaConnectionState connectionState;
  final LoRaFrequencyBand frequencyBand;
  final LoRaModulationPreset modulationPreset;
  final int batteryPercent;
  final double signalSnrDb;
  final int rssiDbm;
  final int packetsTransmitted;
  final int packetsReceived;

  const LoRaGatewayNode({
    required this.deviceId,
    required this.nodeName,
    required this.connectionState,
    this.frequencyBand = LoRaFrequencyBand.eu868,
    this.modulationPreset = LoRaModulationPreset.balancedMediumRange,
    this.batteryPercent = 95,
    this.signalSnrDb = 9.5,
    this.rssiDbm = -78,
    this.packetsTransmitted = 0,
    this.packetsReceived = 0,
  });

  LoRaGatewayNode copyWith({
    String? nodeName,
    LoRaConnectionState? connectionState,
    LoRaFrequencyBand? frequencyBand,
    LoRaModulationPreset? modulationPreset,
    int? batteryPercent,
    double? signalSnrDb,
    int? rssiDbm,
    int? packetsTransmitted,
    int? packetsReceived,
  }) {
    return LoRaGatewayNode(
      deviceId: deviceId,
      nodeName: nodeName ?? this.nodeName,
      connectionState: connectionState ?? this.connectionState,
      frequencyBand: frequencyBand ?? this.frequencyBand,
      modulationPreset: modulationPreset ?? this.modulationPreset,
      batteryPercent: batteryPercent ?? this.batteryPercent,
      signalSnrDb: signalSnrDb ?? this.signalSnrDb,
      rssiDbm: rssiDbm ?? this.rssiDbm,
      packetsTransmitted: packetsTransmitted ?? this.packetsTransmitted,
      packetsReceived: packetsReceived ?? this.packetsReceived,
    );
  }
}

