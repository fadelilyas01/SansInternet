import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:sans_internet/core/theme/mesh_design_tokens.dart';
import 'package:sans_internet/features/mesh/domain/entities/chat_message.dart';
import 'package:sans_internet/features/mesh/domain/entities/mesh_peer.dart';
import 'package:sans_internet/features/mesh/presentation/controllers/mesh_controller.dart';

/// Écran de discussion privée directe (chiffrement de bout en bout sans serveur)
/// avec support complet de texte, photos, vidéos et fichiers hors-ligne.
class SecureChatPage extends StatefulWidget {
  final MeshController controller;
  final String peerId;

  const SecureChatPage({
    super.key,
    required this.controller,
    required this.peerId,
  });

  @override
  State<SecureChatPage> createState() => _SecureChatPageState();
}

class _SecureChatPageState extends State<SecureChatPage> {
  final TextEditingController _textController = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();
  final ImagePicker _imagePicker = ImagePicker();

  @override
  void dispose() {
    _textController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  Future<void> _handleSubmitted() async {
    final text = _textController.text;
    if (text.trim().isEmpty || widget.controller.isSending) return;

    await HapticFeedback.lightImpact();
    _textController.clear();
    await widget.controller.sendMessage(
      peerId: widget.peerId,
      rawText: text,
    );
  }

  /// Ouvre la sélection pour envoyer une image (galerie ou caméra)
  Future<void> _pickAndSendImage(ImageSource source) async {
    try {
      final picked = await _imagePicker.pickImage(
        source: source,
        imageQuality: 80,
      );
      if (picked == null) return;

      final file = File(picked.path);
      final size = await file.length();
      final name = picked.name.isNotEmpty ? picked.name : 'Photo_${DateTime.now().millisecondsSinceEpoch}.jpg';

      await widget.controller.sendMediaMessage(
        peerId: widget.peerId,
        filePath: picked.path,
        type: ChatMessageType.image,
        fileName: name,
        fileSizeBytes: size,
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Impossible d\'accéder à la photo.')),
      );
    }
  }

  /// Ouvre la sélection pour envoyer une vidéo
  Future<void> _pickAndSendVideo() async {
    try {
      final picked = await _imagePicker.pickVideo(
        source: ImageSource.gallery,
        maxDuration: const Duration(minutes: 5),
      );
      if (picked == null) return;

      final file = File(picked.path);
      final size = await file.length();
      final name = picked.name.isNotEmpty ? picked.name : 'Vidéo_${DateTime.now().millisecondsSinceEpoch}.mp4';

      await widget.controller.sendMediaMessage(
        peerId: widget.peerId,
        filePath: picked.path,
        type: ChatMessageType.video,
        fileName: name,
        fileSizeBytes: size,
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Impossible d\'accéder à la vidéo.')),
      );
    }
  }

  /// Ouvre le sélecteur de fichiers pour envoyer un document
  Future<void> _pickAndSendDocument() async {
    try {
      final result = await FilePicker.pickFiles();
      if (result == null || result.files.isEmpty) return;

      final platformFile = result.files.first;
      final path = platformFile.path;
      if (path == null) return;

      final size = platformFile.size;
      final name = platformFile.name;

      await widget.controller.sendMediaMessage(
        peerId: widget.peerId,
        filePath: path,
        type: ChatMessageType.file,
        fileName: name,
        fileSizeBytes: size,
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Impossible d\'accéder au fichier.')),
      );
    }
  }

  void _showAttachmentOptions(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext sheetContext) {
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: MeshDesignTokens.spaceGutter,
              vertical: MeshDesignTokens.spaceMedium,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Text(
                  'Partager un fichier sans Internet',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: MeshDesignTokens.spaceMedium),
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Colors.blueAccent,
                    child: Icon(Icons.photo_library, color: Colors.white),
                  ),
                  title: const Text('Photo depuis la galerie'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _pickAndSendImage(ImageSource.gallery);
                  },
                ),
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Colors.teal,
                    child: Icon(Icons.camera_alt, color: Colors.white),
                  ),
                  title: const Text('Prendre une photo'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _pickAndSendImage(ImageSource.camera);
                  },
                ),
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Colors.deepPurpleAccent,
                    child: Icon(Icons.videocam, color: Colors.white),
                  ),
                  title: const Text('Vidéo'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _pickAndSendVideo();
                  },
                ),
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Colors.orangeAccent,
                    child: Icon(Icons.insert_drive_file, color: Colors.white),
                  ),
                  title: const Text('Fichier ou document (PDF, zip...)'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _pickAndSendDocument();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showContactSecurityDetails(BuildContext context, MeshPeer peer) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext sheetContext) {
        final isVerified =
            peer.verificationStatus == PeerVerificationStatus.qrVerified;
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(MeshDesignTokens.spaceSection),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(
                      isVerified ? Icons.verified : Icons.shield_outlined,
                      color: isVerified
                          ? MeshDesignTokens.statusNodeGreen
                          : MeshDesignTokens.statusMeshAmber,
                      size: 28,
                    ),
                    const SizedBox(width: MeshDesignTokens.spaceMedium),
                    Expanded(
                      child: Text(
                        peer.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: MeshDesignTokens.spaceMedium),
                const Text(
                  'Sécurité de la conversation',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: MeshDesignTokens.spaceCompact),
                Text(
                  isVerified
                      ? 'Ce contact a été vérifié en face-à-face via son QR code. Vos communications sont certifiées contre toute écoute ou falsification.'
                      : 'Vos messages sont totalement chiffrés d\'appareil à appareil. Pour certifier l\'identité de ce contact, scannez son QR code lors de votre prochaine rencontre.',
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.4,
                    color: Theme.of(sheetContext)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.8),
                  ),
                ),
                const SizedBox(height: MeshDesignTokens.spaceMedium),
                Container(
                  padding: const EdgeInsets.all(MeshDesignTokens.spaceGutter),
                  decoration: BoxDecoration(
                    borderRadius: MeshDesignTokens.radiusCard,
                    color: Theme.of(sheetContext).colorScheme.outline.withValues(alpha: 0.15),
                  ),
                  child: Column(
                    children: <Widget>[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: <Widget>[
                          const Text(
                            'Numéro de sécurité :',
                            style: TextStyle(fontSize: 13, color: MeshDesignTokens.textSignalGray),
                          ),
                          Flexible(
                            child: Text(
                              peer.shortFingerprint,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.1,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const Divider(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: <Widget>[
                          const Text(
                            'Acheminement radio :',
                            style: TextStyle(fontSize: 13, color: MeshDesignTokens.textSignalGray),
                          ),
                          Flexible(
                            child: Text(
                              peer.linkState == PeerLinkState.multiHopRelay
                                  ? 'Maillé (${peer.hopCount} sauts)'
                                  : (peer.linkState == PeerLinkState.authenticated ? 'Direct (1 saut)' : 'En attente'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: peer.linkState == PeerLinkState.authenticated
                                    ? MeshDesignTokens.statusNodeGreen
                                    : (peer.linkState == PeerLinkState.multiHopRelay
                                        ? MeshDesignTokens.statusMeshAmber
                                        : MeshDesignTokens.textSignalGray),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: MeshDesignTokens.spaceSection),
                if (!isVerified)
                  SizedBox(
                    height: MeshDesignTokens.minTouchTarget,
                    child: FilledButton.icon(
                      onPressed: () {
                        widget.controller.markPeerQrVerified(peer.peerId);
                        Navigator.of(sheetContext).pop();
                      },
                      icon: const Icon(Icons.check_circle_outline),
                      label: const Text('Marquer comme contact vérifié'),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _confirmClearHistory(BuildContext context, MeshPeer peer) {
    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          backgroundColor: Theme.of(context).colorScheme.surface,
          title: const Text('Effacer la conversation ?'),
          content: Text(
            'Tous les messages échangés localement avec ${peer.displayName} seront définitivement effacés de votre appareil.',
            style: const TextStyle(color: MeshDesignTokens.textSignalGray),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Annuler'),
            ),
            TextButton(
              onPressed: () {
                widget.controller.clearConversation(peer.peerId);
                Navigator.of(dialogContext).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Conversation locale effacée avec succès.'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
              child: const Text(
                'Effacer',
                style: TextStyle(color: MeshDesignTokens.statusDangerCrimson),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (BuildContext context, _) {
        final peer = widget.controller.peers.firstWhere(
          (MeshPeer p) => p.peerId == widget.peerId,
        );
        final messages = widget.controller.messagesForPeer(widget.peerId);
        final isOnline = peer.linkState == PeerLinkState.authenticated;
        final isMultiHop = peer.linkState == PeerLinkState.multiHopRelay;

        final statusText = isOnline
            ? 'À proximité'
            : (isMultiHop ? 'Connecté via relais (${peer.hopCount} sauts)' : 'Hors de portée');

        final statusColor = isOnline
            ? MeshDesignTokens.statusNodeGreen
            : (isMultiHop ? MeshDesignTokens.statusMeshAmber : MeshDesignTokens.textSignalGray);

        return Scaffold(
          appBar: AppBar(
            titleSpacing: 0,
            title: Row(
              children: <Widget>[
                CircleAvatar(
                  radius: 19,
                  backgroundColor: MeshDesignTokens.primaryElectricTeal.withValues(alpha: 0.2),
                  child: Text(
                    peer.displayName.isNotEmpty ? peer.displayName[0].toUpperCase() : '?',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: MeshDesignTokens.primaryElectricTeal,
                    ),
                  ),
                ),
                const SizedBox(width: MeshDesignTokens.spaceMedium),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        peer.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: <Widget>[
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: statusColor,
                            ),
                          ),
                          const SizedBox(width: MeshDesignTokens.spaceCompact),
                          Flexible(
                            child: Text(
                              statusText,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                color: MeshDesignTokens.textSignalGray,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: <Widget>[
              IconButton(
                tooltip: 'Sécurité du contact',
                icon: Icon(
                  peer.verificationStatus == PeerVerificationStatus.qrVerified
                      ? Icons.verified
                      : Icons.info_outline,
                  color: peer.verificationStatus == PeerVerificationStatus.qrVerified
                      ? MeshDesignTokens.statusNodeGreen
                      : MeshDesignTokens.textSignalGray,
                ),
                onPressed: () => _showContactSecurityDetails(context, peer),
              ),
              PopupMenuButton<String>(
                tooltip: 'Options de la conversation',
                constraints: const BoxConstraints(minWidth: 240, maxWidth: 300),
                onSelected: (String value) {
                  if (value == 'security') {
                    _showContactSecurityDetails(context, peer);
                  } else if (value == 'clear') {
                    _confirmClearHistory(context, peer);
                  }
                },
                itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                  const PopupMenuItem<String>(
                    value: 'security',
                    child: Row(
                      children: <Widget>[
                        Icon(Icons.verified_user_outlined, size: 20, color: MeshDesignTokens.primaryElectricTeal),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Sécurité & Chiffrement',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const PopupMenuItem<String>(
                    value: 'clear',
                    child: Row(
                      children: <Widget>[
                        Icon(Icons.delete_outline, size: 20, color: MeshDesignTokens.statusDangerCrimson),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Effacer la conversation',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: MeshDesignTokens.statusDangerCrimson),
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
            child: Column(
              children: <Widget>[
                _SecurityBanner(
                  peer: peer,
                  onTap: () => _showContactSecurityDetails(context, peer),
                ),
                Expanded(
                  child: messages.isEmpty
                      ? const _EmptyConversationView()
                      : ListView.separated(
                          padding: const EdgeInsets.all(
                            MeshDesignTokens.spaceGutter,
                          ),
                          itemCount: messages.length,
                          separatorBuilder: (_, __) => const SizedBox(
                            height: MeshDesignTokens.spaceMedium,
                          ),
                          itemBuilder: (BuildContext context, int index) {
                            return _MessageBubble(message: messages[index]);
                          },
                        ),
                ),
                _ThumbZoneComposer(
                  controller: _textController,
                  focusNode: _inputFocusNode,
                  isSending: widget.controller.isSending,
                  isPeerOnline: isOnline || isMultiHop,
                  onSend: _handleSubmitted,
                  onAttach: () => _showAttachmentOptions(context),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SecurityBanner extends StatelessWidget {
  final MeshPeer peer;
  final VoidCallback onTap;

  const _SecurityBanner({
    required this.peer,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isVerified =
        peer.verificationStatus == PeerVerificationStatus.qrVerified;
    return InkWell(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: MeshDesignTokens.spaceGutter,
          vertical: MeshDesignTokens.spaceCompact,
        ),
        decoration: BoxDecoration(
          color: isVerified
              ? MeshDesignTokens.statusNodeGreen.withValues(alpha: 0.1)
              : MeshDesignTokens.statusMeshAmber.withValues(alpha: 0.1),
          border: Border(
            bottom: BorderSide(
              color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.5),
            ),
          ),
        ),
        child: Row(
          children: <Widget>[
            Icon(
              isVerified ? Icons.lock : Icons.lock_open,
              size: 16,
              color: isVerified
                  ? MeshDesignTokens.statusNodeGreen
                  : MeshDesignTokens.statusMeshAmber,
            ),
            const SizedBox(width: MeshDesignTokens.spaceCompact),
            Expanded(
              child: Text(
                isVerified
                    ? 'Conversation privée de bout en bout • Contact vérifié'
                    : 'Conversation chiffrée d\'appareil à appareil • Touchez pour vérifier',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
              ),
            ),
            const Icon(
              Icons.chevron_right,
              size: 16,
              color: MeshDesignTokens.textSignalGray,
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyConversationView extends StatelessWidget {
  const _EmptyConversationView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(MeshDesignTokens.spaceSection),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.15),
              ),
              child: const Icon(
                Icons.lock_outline,
                size: 32,
                color: MeshDesignTokens.textSignalGray,
              ),
            ),
            const SizedBox(height: MeshDesignTokens.spaceMedium),
            const Text(
              'Aucun message pour l\'instant',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: MeshDesignTokens.spaceCompact),
            Text(
              'Vos messages et fichiers sont échangés directement sans passer par Internet ni par aucun serveur central.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  const _MessageBubble({required this.message});

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes o';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} Ko';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} Mo';
  }

  bool _safeFileExists(String? path) {
    if (path == null || path.isEmpty) return false;
    try {
      return File(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isOutbound = message.direction == MessageDirection.outbound;
    final (statusIcon, statusLabel, statusColor) = switch (message.deliveryStatus) {
      MessageDeliveryStatus.queued => (
          Icons.schedule,
          'En attente',
          MeshDesignTokens.statusMeshAmber,
        ),
      MessageDeliveryStatus.sent => (
          Icons.done,
          'Envoyé',
          MeshDesignTokens.textSignalGray,
        ),
      MessageDeliveryStatus.delivered => (
          Icons.done_all,
          'Reçu',
          MeshDesignTokens.primaryElectricTeal,
        ),
      MessageDeliveryStatus.failed => (
          Icons.error_outline,
          'Non remis',
          MeshDesignTokens.statusDangerCrimson,
        ),
    };

    return Align(
      alignment: isOutbound ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.78,
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: MeshDesignTokens.spaceGutter,
            vertical: MeshDesignTokens.spaceMedium,
          ),
          decoration: BoxDecoration(
            color: isOutbound
                ? MeshDesignTokens.sentBubblePetrolTeal
                : MeshDesignTokens.receivedBubbleSlateGray,
            borderRadius: MeshDesignTokens.radiusBubble,
            border: Border.all(
              color: isOutbound
                  ? MeshDesignTokens.primaryElectricTeal.withValues(alpha: 0.28)
                  : MeshDesignTokens.borderSlate,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // Rendu selon le type de contenu (image, vidéo, fichier ou texte)
              if (message.messageType == ChatMessageType.image && message.filePath != null) ...<Widget>[
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: _safeFileExists(message.filePath)
                      ? Image.file(
                          File(message.filePath!),
                          fit: BoxFit.cover,
                          height: 180,
                          width: double.infinity,
                        )
                      : Container(
                          height: 140,
                          color: Colors.black26,
                          child: const Center(
                            child: Icon(Icons.image, size: 48, color: Colors.white70),
                          ),
                        ),
                ),
                const SizedBox(height: 6),
              ] else if (message.messageType == ChatMessageType.video) ...<Widget>[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black38,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: <Widget>[
                      const CircleAvatar(
                        backgroundColor: Colors.white24,
                        child: Icon(Icons.play_arrow, color: Colors.white),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              message.fileName ?? 'Vidéo',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                            ),
                            if (message.fileSizeBytes != null)
                              Text(
                                _formatFileSize(message.fileSizeBytes!),
                                style: const TextStyle(color: Colors.white70, fontSize: 11),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
              ] else if (message.messageType == ChatMessageType.file) ...<Widget>[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black38,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: <Widget>[
                      const CircleAvatar(
                        backgroundColor: Colors.white24,
                        child: Icon(Icons.insert_drive_file, color: Colors.white),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              message.fileName ?? 'Document',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                            ),
                            if (message.fileSizeBytes != null)
                              Text(
                                _formatFileSize(message.fileSizeBytes!),
                                style: const TextStyle(color: Colors.white70, fontSize: 11),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
              ] else ...<Widget>[
                Text(
                  message.contentText,
                  style: const TextStyle(
                    fontSize: 15,
                    height: 1.35,
                    color: MeshDesignTokens.textCrispOffWhite,
                  ),
                ),
              ],
              const SizedBox(height: MeshDesignTokens.spaceCompact),
              Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  Text(
                    statusLabel,
                    style: const TextStyle(
                      fontSize: 11,
                      color: MeshDesignTokens.textSignalGray,
                    ),
                  ),
                  const SizedBox(width: MeshDesignTokens.spaceMicro),
                  Icon(
                    statusIcon,
                    size: 14,
                    color: statusColor,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThumbZoneComposer extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isSending;
  final bool isPeerOnline;
  final VoidCallback onSend;
  final VoidCallback onAttach;

  const _ThumbZoneComposer({
    required this.controller,
    required this.focusNode,
    required this.isSending,
    required this.isPeerOnline,
    required this.onSend,
    required this.onAttach,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        MeshDesignTokens.spaceCompact,
        MeshDesignTokens.spaceCompact,
        MeshDesignTokens.spaceCompact,
        MeshDesignTokens.spaceMedium,
      ),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(color: Theme.of(context).colorScheme.outline),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (!isPeerOnline) ...<Widget>[
            Padding(
              padding: const EdgeInsets.only(bottom: 6, left: 4),
              child: Row(
                children: const <Widget>[
                  Icon(
                    Icons.schedule_send,
                    size: 13,
                    color: MeshDesignTokens.statusMeshAmber,
                  ),
                  SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      'Contact éloigné : le message partira dès que vous vous croiserez.',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: MeshDesignTokens.statusMeshAmber,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          Row(
            children: <Widget>[
              IconButton(
                tooltip: 'Joindre photo, vidéo ou fichier',
                icon: const Icon(Icons.add_circle_outline, size: 26),
                color: MeshDesignTokens.primaryElectricTeal,
                onPressed: onAttach,
              ),
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => onSend(),
                  decoration: InputDecoration(
                    hintText: 'Écrire un message...',
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: MeshDesignTokens.spaceGutter,
                      vertical: MeshDesignTokens.spaceMedium,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: MeshDesignTokens.radiusPill,
                      borderSide: BorderSide(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: MeshDesignTokens.spaceCompact),
              Semantics(
                button: true,
                label: isSending ? 'Envoi en cours' : 'Envoyer',
                child: SizedBox(
                  width: MeshDesignTokens.minTouchTarget,
                  height: MeshDesignTokens.minTouchTarget,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      padding: EdgeInsets.zero,
                      shape: const CircleBorder(),
                    ),
                    onPressed: isSending ? null : onSend,
                    child: Icon(
                      isPeerOnline ? Icons.send : Icons.schedule_send,
                      size: 20,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
