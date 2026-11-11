import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:sans_internet/core/theme/mesh_design_tokens.dart';
import 'package:sans_internet/features/mesh/domain/entities/lora_gateway_node.dart';
import 'package:sans_internet/features/mesh/domain/entities/mesh_peer.dart';
import 'package:sans_internet/features/mesh/presentation/controllers/mesh_controller.dart';
import 'package:sans_internet/features/mesh/presentation/pages/secure_chat_page.dart';

/// Écran principal de la messagerie hors-ligne avec maillage multi-sauts,
/// scanner caméra, QR code dynamique et passerelle radio LoRa Sub-GHz.
class MeshRadarPage extends StatefulWidget {
  final MeshController controller;

  const MeshRadarPage({super.key, required this.controller});

  @override
  State<MeshRadarPage> createState() => _MeshRadarPageState();
}

class _MeshRadarPageState extends State<MeshRadarPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.startRadioDiscovery();
    });
  }

  /// Ouvre la caméra pour scanner le QR code d'un autre contact et établir la liaison.
  Future<void> _openCameraScanner(BuildContext context) async {
    await HapticFeedback.mediumImpact();
    if (!context.mounted) return;

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext scannerContext) {
          bool hasHandled = false;
          return Scaffold(
            appBar: AppBar(
              title: const Text('Scanner le code d\'un contact'),
              actions: const <Widget>[],
            ),
            body: Stack(
              children: <Widget>[
                MobileScanner(
                  onDetect: (BarcodeCapture capture) async {
                    if (hasHandled) return;
                    for (final barcode in capture.barcodes) {
                      final raw = barcode.rawValue;
                      if (raw != null && raw.startsWith('sansinternet://pair')) {
                        hasHandled = true;
                        await HapticFeedback.heavyImpact();
                        final newPeer = widget.controller.pairPeerFromQrData(raw);

                        if (!scannerContext.mounted) return;
                        Navigator.of(scannerContext).pop();

                        if (newPeer != null) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Liaison sécurisée établie avec ${newPeer.displayName} !'),
                              backgroundColor: MeshDesignTokens.statusNodeGreen,
                              duration: const Duration(seconds: 3),
                            ),
                          );
                          await Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => SecureChatPage(
                                controller: widget.controller,
                                peerId: newPeer.peerId,
                              ),
                            ),
                          );
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Code QR déjà utilisé ou invalide.'),
                            ),
                          );
                        }
                        break;
                      }
                    }
                  },
                ),
                Center(
                  child: Container(
                    width: 250,
                    height: 250,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: MeshDesignTokens.primaryElectricTeal,
                        width: 3,
                      ),
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
                Positioned(
                  bottom: 40,
                  left: 20,
                  right: 20,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.75),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Text(
                      'Pointez l\'appareil vers le QR code affiché sur le téléphone de votre contact.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Affiche le QR code réel de cet appareil pour qu'un proche le scanne.
  Future<void> _openQrIdentitySheet(BuildContext context) async {
    await HapticFeedback.mediumImpact();
    if (!context.mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (BuildContext sheetContext) {
        return StatefulBuilder(
          builder: (BuildContext innerContext, StateSetter setSheetState) {
            final remainingSec = widget.controller.secondsUntilNextQrRotation;
            final minutes = remainingSec ~/ 60;
            final seconds = (remainingSec % 60).toString().padLeft(2, '0');

            return SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(MeshDesignTokens.spaceSection),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        const Expanded(
                          child: Text(
                            'Mon code d\'invitation sécurisé',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.of(sheetContext).pop(),
                        ),
                      ],
                    ),
                    const SizedBox(height: MeshDesignTokens.spaceCompact),
                    Text(
                      'Faites scanner ce code par l\'autre téléphone pour établir une liaison directe et sécurisée.',
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.4,
                        color: Theme.of(sheetContext)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.75),
                      ),
                    ),
                    const SizedBox(height: MeshDesignTokens.spaceSection),
                    Center(
                      child: Container(
                        padding: const EdgeInsets.all(MeshDesignTokens.spaceGutter),
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          borderRadius: MeshDesignTokens.radiusCard,
                        ),
                        child: Column(
                          children: <Widget>[
                            QrImageView(
                              data: widget.controller.localQrPayload,
                              version: QrVersions.auto,
                              size: 190.0,
                              backgroundColor: Colors.white,
                            ),
                            const SizedBox(height: MeshDesignTokens.spaceCompact),
                            Text(
                              widget.controller.localShortFingerprint,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.2,
                                color: Colors.black87,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: MeshDesignTokens.spaceSection),

                    // Bannière de rotation 15 min anti-espionnage
                    Container(
                      padding: const EdgeInsets.all(MeshDesignTokens.spaceMedium),
                      decoration: BoxDecoration(
                        color: Theme.of(sheetContext)
                            .colorScheme
                            .surfaceContainerHighest
                            .withValues(alpha: 0.5),
                        borderRadius: MeshDesignTokens.radiusCard,
                        border: Border.all(
                          color: Theme.of(sheetContext)
                              .colorScheme
                              .outline
                              .withValues(alpha: 0.2),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              const Icon(
                                Icons.shield_outlined,
                                size: 18,
                                color: MeshDesignTokens.primaryElectricTeal,
                              ),
                              const SizedBox(width: 8),
                              const Expanded(
                                child: Text(
                                  'Jeton éphémère anti-espionnage (15 min)',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: MeshDesignTokens.primaryElectricTeal
                                      .withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  '$minutes:$seconds',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: MeshDesignTokens.primaryElectricTeal,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Ce QR code se renouvelle automatiquement toutes les 15 minutes pour empêcher les captures d\'écran malveillantes. Vos contacts déjà enregistrés restent connectés indéfiniment.',
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.4,
                              color: Theme.of(sheetContext)
                                  .colorScheme
                                  .onSurface
                                  .withValues(alpha: 0.7),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              onPressed: () {
                                HapticFeedback.lightImpact();
                                widget.controller.rotateQrCodeNow();
                                setSheetState(() {});
                              },
                              icon: const Icon(Icons.refresh, size: 16),
                              label: const Text(
                                'Renouveler le code maintenant',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: MeshDesignTokens.spaceSection),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: SizedBox(
                            height: MeshDesignTokens.minTouchTarget,
                            child: OutlinedButton.icon(
                              onPressed: () {
                                Navigator.of(sheetContext).pop();
                                _openCameraScanner(context);
                              },
                              icon: const Icon(Icons.qr_code_scanner),
                              label: const Text('Scanner l\'autre'),
                            ),
                          ),
                        ),
                        const SizedBox(width: MeshDesignTokens.spaceMedium),
                        Expanded(
                          child: SizedBox(
                            height: MeshDesignTokens.minTouchTarget,
                            child: FilledButton.icon(
                              onPressed: () {
                                for (final peer in widget.controller.peers) {
                                  widget.controller.markPeerQrVerified(peer.peerId);
                                }
                                Navigator.of(sheetContext).pop();
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Contacts validés avec succès.'),
                                    duration: Duration(seconds: 2),
                                  ),
                                );
                              },
                              icon: const Icon(Icons.check_circle_outline),
                              label: const Text('Valider'),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// Ouvre l'interface de gestion de la passerelle matérielle radio LoRa Sub-GHz (Portée 15 à 30 km).
  Future<void> _openLoRaGatewaySheet(BuildContext context) async {
    await HapticFeedback.mediumImpact();
    if (!context.mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (BuildContext sheetContext) {
        return ListenableBuilder(
          listenable: widget.controller.loraService,
          builder: (BuildContext ctx, _) {
            final lora = widget.controller.loraService;
            final node = lora.node;
            final isConnected = lora.isConnected;

            return SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(MeshDesignTokens.spaceSection),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        const Icon(Icons.cell_tower, color: MeshDesignTokens.primaryElectricTeal),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Passerelle Radio LoRa',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.of(sheetContext).pop(),
                        ),
                      ],
                    ),
                    const SizedBox(height: MeshDesignTokens.spaceCompact),
                    Text(
                      'Connectez un boîtier radio autonome de poche (Meshtastic, LilyGO T-Beam, Heltec) '
                      'pour étendre la portée directe de 15 km à plus de 30 km sans Internet.',
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.4,
                        color: Theme.of(sheetContext).colorScheme.onSurface.withValues(alpha: 0.75),
                      ),
                    ),
                    const SizedBox(height: MeshDesignTokens.spaceGutter),
                    // État de connexion
                    Container(
                      padding: const EdgeInsets.all(MeshDesignTokens.spaceGutter),
                      decoration: BoxDecoration(
                        color: isConnected
                            ? MeshDesignTokens.statusNodeGreen.withValues(alpha: 0.12)
                            : Theme.of(sheetContext).colorScheme.surfaceContainerHighest,
                        borderRadius: MeshDesignTokens.radiusCard,
                        border: Border.all(
                          color: isConnected
                              ? MeshDesignTokens.statusNodeGreen
                              : Theme.of(sheetContext).colorScheme.outline.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Column(
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Icon(
                                isConnected ? Icons.bluetooth_connected : Icons.bluetooth_searching,
                                color: isConnected
                                    ? MeshDesignTokens.statusNodeGreen
                                    : MeshDesignTokens.textSignalGray,
                                size: 26,
                              ),
                              const SizedBox(width: MeshDesignTokens.spaceMedium),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(
                                      isConnected ? node.nodeName : 'Aucun boîtier radio couplé',
                                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      isConnected
                                          ? 'Liaison Sub-GHz active • Portée kilométrique active'
                                          : 'Prêt pour couplage Bluetooth ou câble USB-OTG',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: isConnected
                                            ? MeshDesignTokens.statusNodeGreen
                                            : MeshDesignTokens.textSignalGray,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          if (isConnected) ...<Widget>[
                            const Divider(height: 24),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceAround,
                              children: <Widget>[
                                Column(
                                  children: <Widget>[
                                    const Icon(Icons.battery_charging_full, size: 20, color: MeshDesignTokens.statusNodeGreen),
                                    const SizedBox(height: 4),
                                    Text('${node.batteryPercent}%', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                                    const Text('Batterie', style: TextStyle(fontSize: 11, color: MeshDesignTokens.textSignalGray)),
                                  ],
                                ),
                                Column(
                                  children: <Widget>[
                                    const Icon(Icons.signal_cellular_alt, size: 20, color: MeshDesignTokens.primaryElectricTeal),
                                    const SizedBox(height: 4),
                                    Text('+${node.signalSnrDb} dB', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                                    const Text('SNR Radio', style: TextStyle(fontSize: 11, color: MeshDesignTokens.textSignalGray)),
                                  ],
                                ),
                                Column(
                                  children: <Widget>[
                                    const Icon(Icons.upload, size: 20, color: Colors.blueAccent),
                                    const SizedBox(height: 4),
                                    Text('${node.packetsTransmitted}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                                    const Text('Émis', style: TextStyle(fontSize: 11, color: MeshDesignTokens.textSignalGray)),
                                  ],
                                ),
                                Column(
                                  children: <Widget>[
                                    const Icon(Icons.download, size: 20, color: Colors.amber),
                                    const SizedBox(height: 4),
                                    Text('${node.packetsReceived}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                                    const Text('Reçus', style: TextStyle(fontSize: 11, color: MeshDesignTokens.textSignalGray)),
                                  ],
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: MeshDesignTokens.spaceSection),
                    SizedBox(
                      height: MeshDesignTokens.minTouchTarget,
                      child: isConnected
                          ? OutlinedButton.icon(
                              onPressed: () {
                                lora.disconnectDevice();
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Module LoRa déconnecté.')),
                                );
                              },
                              icon: const Icon(Icons.bluetooth_disabled),
                              label: const Text('Déconnecter le boîtier'),
                            )
                          : FilledButton.icon(
                              onPressed: () async {
                                await lora.connectToDevice();
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Boîtier LoRa T-Beam connecté ! Portée étendue à 30 km.'),
                                    backgroundColor: MeshDesignTokens.statusNodeGreen,
                                  ),
                                );
                              },
                              icon: const Icon(Icons.bluetooth_searching),
                              label: const Text('Détecter et connecter le boîtier LoRa'),
                            ),
                    ),
                    const SizedBox(height: MeshDesignTokens.spaceSection),
                    const Text('Bande de fréquence Sub-GHz', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                    const SizedBox(height: MeshDesignTokens.spaceCompact),
                    Wrap(
                      spacing: 8,
                      children: LoRaFrequencyBand.values.map((band) {
                        final isSelected = node.frequencyBand == band;
                        return ChoiceChip(
                          label: Text(band.name),
                          selected: isSelected,
                          onSelected: (_) => lora.setFrequencyBand(band),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: MeshDesignTokens.spaceSection),
                    const Text('Profil de portée radio', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                    const SizedBox(height: MeshDesignTokens.spaceCompact),
                    for (final preset in LoRaModulationPreset.values)
                      RadioListTile<LoRaModulationPreset>(
                        value: preset,
                        // ignore: deprecated_member_use
                        groupValue: node.modulationPreset,
                        title: Text(preset.label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                        subtitle: Text(preset.description, style: const TextStyle(fontSize: 12)),
                        // ignore: deprecated_member_use
                        onChanged: (val) {
                          if (val != null) lora.setModulationPreset(val);
                        },
                      ),
                    const SizedBox(height: MeshDesignTokens.spaceSection),
                    FilledButton(
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      child: const Text('Enregistrer et fermer'),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (BuildContext context, _) {
        final isLoRaConnected = widget.controller.loraService.isConnected;

        return Scaffold(
          appBar: AppBar(
            title: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  'SansInternet',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
                Text(
                  '● Hors-ligne E2EE',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: MeshDesignTokens.statusNodeGreen,
                  ),
                ),
              ],
            ),
            actions: <Widget>[
              IconButton(
                tooltip: isLoRaConnected ? 'Passerelle LoRa active (30 km)' : 'Activer radio LoRa',
                icon: Icon(
                  Icons.cell_tower,
                  color: isLoRaConnected
                      ? MeshDesignTokens.primaryElectricTeal
                      : MeshDesignTokens.textSignalGray,
                ),
                onPressed: () => _openLoRaGatewaySheet(context),
              ),
              PopupMenuButton<String>(
                tooltip: 'Options',
                constraints: const BoxConstraints(minWidth: 260, maxWidth: 320),
                onSelected: (String value) {
                  if (value == 'refresh') {
                    widget.controller.startRadioDiscovery();
                  } else if (value == 'my_qr') {
                    _openQrIdentitySheet(context);
                  } else if (value == 'scan_qr') {
                    _openCameraScanner(context);
                  } else if (value == 'lora') {
                    _openLoRaGatewaySheet(context);
                  } else if (value == 'relay_info') {
                    _showRelayExplainerSheet(context, widget.controller.packetsRelayedForNetwork);
                  }
                },
                itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                  const PopupMenuItem<String>(
                    value: 'refresh',
                    child: Row(
                      children: <Widget>[
                        Icon(Icons.refresh, size: 20, color: MeshDesignTokens.primaryElectricTeal),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Actualiser les contacts',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const PopupMenuItem<String>(
                    value: 'my_qr',
                    child: Row(
                      children: <Widget>[
                        Icon(Icons.qr_code_2, size: 20, color: MeshDesignTokens.primaryElectricTeal),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Mon identifiant & QR code',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const PopupMenuItem<String>(
                    value: 'scan_qr',
                    child: Row(
                      children: <Widget>[
                        Icon(Icons.qr_code_scanner, size: 20, color: MeshDesignTokens.primaryElectricTeal),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Scanner un contact',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const PopupMenuDivider(),
                  const PopupMenuItem<String>(
                    value: 'lora',
                    child: Row(
                      children: <Widget>[
                        Icon(Icons.settings_input_antenna, size: 20, color: MeshDesignTokens.primaryElectricTeal),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Passerelle radio (LoRa)',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const PopupMenuItem<String>(
                    value: 'relay_info',
                    child: Row(
                      children: <Widget>[
                        Icon(Icons.hub, size: 20, color: MeshDesignTokens.primaryElectricTeal),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Réseau maillé & Relais',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
          body: SafeArea(
            child: switch (widget.controller.status) {
              MeshViewStatus.loading => const _GpuSkeletonPeerList(),
              MeshViewStatus.empty => _EmptyMeshRadarState(
                  onRescan: () => widget.controller.startRadioDiscovery(),
                  onShowQr: () => _openQrIdentitySheet(context),
                  onScanQr: () => _openCameraScanner(context),
                ),
              MeshViewStatus.error => _RadioErrorState(
                  message: widget.controller.errorMessage ?? '',
                  onRetry: () => widget.controller.startRadioDiscovery(),
                ),
              MeshViewStatus.nominal => _NominalPeerListView(
                  controller: widget.controller,
                  onOpenLoRa: () => _openLoRaGatewaySheet(context),
                ),
            },
          ),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                MeshDesignTokens.spaceGutter,
                MeshDesignTokens.spaceCompact,
                MeshDesignTokens.spaceGutter,
                MeshDesignTokens.spaceGutter,
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: SizedBox(
                      height: MeshDesignTokens.minTouchTarget,
                      child: OutlinedButton.icon(
                        onPressed: () => _openCameraScanner(context),
                        icon: const Icon(Icons.qr_code_scanner, size: 20),
                        label: const Text('Scanner'),
                      ),
                    ),
                  ),
                  const SizedBox(width: MeshDesignTokens.spaceMedium),
                  Expanded(
                    child: SizedBox(
                      height: MeshDesignTokens.minTouchTarget,
                      child: FilledButton.icon(
                        onPressed: () => _openQrIdentitySheet(context),
                        icon: const Icon(Icons.qr_code_2, size: 20),
                        label: const Text('Mon QR code'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Squelette de chargement épuré.
class _GpuSkeletonPeerList extends StatefulWidget {
  const _GpuSkeletonPeerList();

  @override
  State<_GpuSkeletonPeerList> createState() => _GpuSkeletonPeerListState();
}

class _GpuSkeletonPeerListState extends State<_GpuSkeletonPeerList>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
      lowerBound: 0.45,
      upperBound: 0.95,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final disableAnimations =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    return FadeTransition(
      opacity: disableAnimations
          ? const AlwaysStoppedAnimation<double>(0.75)
          : _pulseController,
      child: ListView.separated(
        padding: const EdgeInsets.all(MeshDesignTokens.spaceGutter),
        itemCount: 3,
        separatorBuilder: (_, __) =>
            const SizedBox(height: MeshDesignTokens.spaceMedium),
        itemBuilder: (BuildContext context, int index) {
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(MeshDesignTokens.spaceGutter),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.outline,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: MeshDesignTokens.spaceMedium),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Container(
                          height: 16,
                          width: 160,
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.outline,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        const SizedBox(height: MeshDesignTokens.spaceCompact),
                        Container(
                          height: 12,
                          width: 100,
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.outline,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Écran vide bienveillant et orienté utilisateur.
class _EmptyMeshRadarState extends StatelessWidget {
  final VoidCallback onRescan;
  final VoidCallback onShowQr;
  final VoidCallback onScanQr;

  const _EmptyMeshRadarState({
    required this.onRescan,
    required this.onShowQr,
    required this.onScanQr,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(MeshDesignTokens.spaceSection),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: MeshDesignTokens.primaryElectricTeal.withValues(alpha: 0.12),
              ),
              child: const Icon(
                Icons.people_outline,
                size: 52,
                color: MeshDesignTokens.primaryElectricTeal,
              ),
            ),
            const SizedBox(height: MeshDesignTokens.spaceGutter),
            const Text(
              'Aucun contact à proximité',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: MeshDesignTokens.spaceCompact),
            Text(
              'Scannez le QR code d\'un ami ou affichez le vôtre pour établir une liaison directe sans Internet.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                height: 1.4,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.75),
              ),
            ),
            const SizedBox(height: MeshDesignTokens.spaceSection),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onScanQr,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Scanner'),
                  ),
                ),
                const SizedBox(width: MeshDesignTokens.spaceMedium),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: onShowQr,
                    icon: const Icon(Icons.qr_code),
                    label: const Text('Mon QR code'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Écran d'alerte matériel clair (Zéro jargon).
class _RadioErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _RadioErrorState({
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(MeshDesignTokens.spaceSection),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(MeshDesignTokens.spaceSection),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(
                  Icons.bluetooth_disabled,
                  size: 48,
                  color: MeshDesignTokens.statusDangerCrimson,
                ),
                const SizedBox(height: MeshDesignTokens.spaceGutter),
                const Text(
                  'Bluetooth requis pour échanger',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: MeshDesignTokens.spaceCompact),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 14, height: 1.4),
                ),
                const SizedBox(height: MeshDesignTokens.spaceSection),
                SizedBox(
                  width: double.infinity,
                  height: MeshDesignTokens.minTouchTarget,
                  child: FilledButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Réessayer la recherche'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

void _showRelayExplainerSheet(BuildContext context, int packetsRelayedCount) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (BuildContext sheetContext) {
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(MeshDesignTokens.spaceSection),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Icon(Icons.hub, color: MeshDesignTokens.primaryElectricTeal),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Réseau Maillé & Relais Citoyen',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(sheetContext).pop(),
                  ),
                ],
              ),
              const SizedBox(height: MeshDesignTokens.spaceGutter),
              Container(
                padding: const EdgeInsets.all(MeshDesignTokens.spaceGutter),
                decoration: BoxDecoration(
                  color: MeshDesignTokens.primaryElectricTeal.withValues(alpha: 0.1),
                  borderRadius: MeshDesignTokens.radiusCard,
                  border: Border.all(
                    color: MeshDesignTokens.primaryElectricTeal.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  children: <Widget>[
                    const Icon(Icons.shield_outlined, color: MeshDesignTokens.primaryElectricTeal, size: 28),
                    const SizedBox(width: MeshDesignTokens.spaceMedium),
                    Expanded(
                      child: Text(
                        '$packetsRelayedCount message(s) anonyme(s) relayé(s) par votre téléphone pour la communauté.',
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: MeshDesignTokens.spaceGutter),
              const _RelayAdvantageRow(
                icon: Icons.cell_tower,
                title: 'Portée Kilométrique Sans Internet',
                subtitle:
                    'Les téléphones des utilisateurs se transmettent les paquets de proche en proche. Vos messages peuvent ainsi traverser toute une ville.',
              ),
              const SizedBox(height: MeshDesignTokens.spaceMedium),
              const _RelayAdvantageRow(
                icon: Icons.lock_clock,
                title: 'Confidentialité Totale (Zéro-Lecture)',
                subtitle:
                    'Chaque paquet est scellé de bout en bout. Les téléphones qui le transportent ne voient qu\'une enveloppe opaque et ne peuvent jamais en lire le contenu.',
              ),
              const SizedBox(height: MeshDesignTokens.spaceMedium),
              const _RelayAdvantageRow(
                icon: Icons.battery_charging_full,
                title: 'Basse Consommation Intelligente',
                subtitle:
                    'Le protocole utilise le Bluetooth Low Energy passif pour préserver l\'autonomie de votre batterie.',
              ),
              const SizedBox(height: MeshDesignTokens.spaceSection),
              FilledButton(
                onPressed: () => Navigator.of(sheetContext).pop(),
                child: const Text('Compris'),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Liste de contacts grand public, style Signal / WhatsApp avec cartes de maillage.
class _NominalPeerListView extends StatelessWidget {
  final MeshController controller;
  final VoidCallback onOpenLoRa;

  const _NominalPeerListView({
    required this.controller,
    required this.onOpenLoRa,
  });

  @override
  Widget build(BuildContext context) {
    final peers = controller.peers;
    final isLoRaConnected = controller.loraService.isConnected;

    return ListView(
      padding: const EdgeInsets.all(MeshDesignTokens.spaceGutter),
      children: <Widget>[
        // Carte d'état du maillage longue portée
        Card(
          color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          shape: RoundedRectangleBorder(
            borderRadius: MeshDesignTokens.radiusCard,
            side: BorderSide(
              color: MeshDesignTokens.primaryElectricTeal.withValues(alpha: 0.25),
            ),
          ),
          child: InkWell(
            borderRadius: MeshDesignTokens.radiusCard,
            onTap: () => _showRelayExplainerSheet(context, controller.packetsRelayedForNetwork),
            child: Padding(
              padding: const EdgeInsets.all(MeshDesignTokens.spaceGutter),
              child: Row(
                children: <Widget>[
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: MeshDesignTokens.primaryElectricTeal.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.hub,
                      color: MeshDesignTokens.primaryElectricTeal,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: MeshDesignTokens.spaceMedium),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Row(
                          children: <Widget>[
                            Flexible(
                              child: Text(
                                'Réseau Maillé Longue Portée',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            SizedBox(width: 6),
                            Icon(Icons.info_outline, size: 14, color: MeshDesignTokens.textSignalGray),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Les téléphones s\'entraident pour étendre la portée • ${controller.packetsRelayedForNetwork} paquet(s) relayé(s)',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, size: 20, color: MeshDesignTokens.textSignalGray),
                ],
              ),
            ),
          ),
        ),
        if (isLoRaConnected) ...<Widget>[
          const SizedBox(height: MeshDesignTokens.spaceMedium),
          Card(
            color: MeshDesignTokens.statusNodeGreen.withValues(alpha: 0.12),
            shape: const RoundedRectangleBorder(
              borderRadius: MeshDesignTokens.radiusCard,
              side: BorderSide(color: MeshDesignTokens.statusNodeGreen),
            ),
            child: InkWell(
              borderRadius: MeshDesignTokens.radiusCard,
              onTap: onOpenLoRa,
              child: Padding(
                padding: const EdgeInsets.all(MeshDesignTokens.spaceGutter),
                child: Row(
                  children: <Widget>[
                    const Icon(Icons.cell_tower, color: MeshDesignTokens.statusNodeGreen, size: 22),
                    const SizedBox(width: MeshDesignTokens.spaceMedium),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            'Passerelle LoRa Sub-GHz Active (${controller.loraService.node.frequencyBand.frequencyMhz.toStringAsFixed(1)} MHz)',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: MeshDesignTokens.statusNodeGreen),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Portée directe jusqu\'à 30 km activée • Batterie boîtier ${controller.loraService.node.batteryPercent}%',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.tune, size: 18, color: MeshDesignTokens.statusNodeGreen),
                  ],
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: MeshDesignTokens.spaceGutter),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Text(
            'CONTACTS À PORTÉE & RELAIS',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
              color: MeshDesignTokens.textSignalGray,
            ),
          ),
        ),
        const SizedBox(height: MeshDesignTokens.spaceCompact),
        for (final peer in peers) ...<Widget>[
          _PeerItemCard(controller: controller, peer: peer),
          const SizedBox(height: MeshDesignTokens.spaceMedium),
        ],
      ],
    );
  }
}

class _PeerItemCard extends StatelessWidget {
  final MeshController controller;
  final MeshPeer peer;

  const _PeerItemCard({required this.controller, required this.peer});

  @override
  Widget build(BuildContext context) {
    final isOnline = peer.linkState == PeerLinkState.authenticated;
    final isMultiHop = peer.linkState == PeerLinkState.multiHopRelay;
    final isQrVerified = peer.verificationStatus == PeerVerificationStatus.qrVerified;

    final initials = peer.displayName
        .trim()
        .split(' ')
        .take(2)
        .map((s) => s.isNotEmpty ? s[0].toUpperCase() : '')
        .join();

    final statusLabel = isOnline
        ? 'À proximité immédiate'
        : (isMultiHop ? 'Relayé par le réseau (~1.8 km)' : 'Non connecté actuellement');

    final presenceColor = isOnline
        ? MeshDesignTokens.statusNodeGreen
        : (isMultiHop ? MeshDesignTokens.statusMeshAmber : MeshDesignTokens.textSignalGray);

    return Card(
      child: InkWell(
        borderRadius: MeshDesignTokens.radiusCard,
        onTap: () async {
          await HapticFeedback.selectionClick();
          if (!context.mounted) return;
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => SecureChatPage(
                controller: controller,
                peerId: peer.peerId,
              ),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(MeshDesignTokens.spaceGutter),
          child: Row(
            children: <Widget>[
              Stack(
                children: <Widget>[
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: MeshDesignTokens.primaryElectricTeal.withValues(alpha: 0.18),
                    child: Text(
                      initials.isNotEmpty ? initials : '?',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: MeshDesignTokens.primaryElectricTeal,
                      ),
                    ),
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: presenceColor,
                        border: Border.all(
                          color: Theme.of(context).colorScheme.surface,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: MeshDesignTokens.spaceMedium),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            peer.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (isQrVerified) ...<Widget>[
                          const Icon(
                            Icons.verified,
                            size: 16,
                            color: MeshDesignTokens.statusNodeGreen,
                          ),
                          const SizedBox(width: 4),
                          const Text(
                            'Vérifié',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: MeshDesignTokens.statusNodeGreen,
                            ),
                          ),
                        ] else ...<Widget>[
                          const Text(
                            'Nouveau',
                            style: TextStyle(
                              fontSize: 12,
                              color: MeshDesignTokens.textSignalGray,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: MeshDesignTokens.spaceMicro),
                    Row(
                      children: <Widget>[
                        if (isMultiHop) ...<Widget>[
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: MeshDesignTokens.statusMeshAmber.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                const Icon(Icons.alt_route, size: 12, color: MeshDesignTokens.statusMeshAmber),
                                const SizedBox(width: 4),
                                Text(
                                  '${peer.hopCount} sauts',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: MeshDesignTokens.statusMeshAmber,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 6),
                        ] else if (isOnline) ...<Widget>[
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: MeshDesignTokens.statusNodeGreen.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Icon(Icons.near_me, size: 12, color: MeshDesignTokens.statusNodeGreen),
                                SizedBox(width: 4),
                                Text(
                                  'Direct',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: MeshDesignTokens.statusNodeGreen,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        Expanded(
                          child: Text(
                            statusLabel,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: isOnline
                                  ? MeshDesignTokens.statusNodeGreen
                                  : MeshDesignTokens.textSignalGray,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: MeshDesignTokens.spaceCompact),
              const Icon(
                Icons.chevron_right,
                color: MeshDesignTokens.textSignalGray,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RelayAdvantageRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _RelayAdvantageRow({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 20, color: MeshDesignTokens.primaryElectricTeal),
        ),
        const SizedBox(width: MeshDesignTokens.spaceMedium),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.75),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
