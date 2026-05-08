import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../reticulum/reticulum_node.dart';
import '../../shared/providers/app_providers.dart';
import '../../application/events/app_events.dart' show ContactUpdatedEvent;
import '../../shared/providers/storage_providers.dart' show eventBusProvider;
import '../../shared/utils/l10n.dart';
import '../../shared/utils/pubkey_codec.dart';
import '../../shared/widgets/my_qr_code.dart';
import '../../shared/widgets/hubcore_app_bar.dart';

class AddContactScreen extends ConsumerStatefulWidget {
  const AddContactScreen({super.key});

  @override
  ConsumerState<AddContactScreen> createState() => _AddContactScreenState();
}

class _AddContactScreenState extends ConsumerState<AddContactScreen> {
  final _aliasCtrl = TextEditingController();
  final _pubkeyCtrl = TextEditingController();
  bool _scanning = false;
  bool _saving = false;
  String? _error;

  final _scannerCtrl = MobileScannerController();

  @override
  void dispose() {
    _scannerCtrl.dispose();
    _aliasCtrl.dispose();
    _pubkeyCtrl.dispose();
    super.dispose();
  }

  // Parsed from QR or manual entry
  String? _scannedSigningPub;   // base58, if present in QR
  String? _scannedX25519Pub;    // base58, X25519 identity key, if present in QR
  String? _scannedYggPubKeyHex;     // hex, Yggdrasil node key, if present in QR
  String? _scannedReticulumAddress; // hex, Reticulum destination hash, if present in QR

  Future<void> _scanFromFile() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    final result = await _scannerCtrl.analyzeImage(picked.path);
    if (result == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.qrCodeNotFound)),
        );
      }
      return;
    }
    _onScan(result);
  }

  void _onScan(BarcodeCapture capture) {
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null) return;

    // Try to parse JSON envelope {"mp":"<masterPub58>","sp":"<signingPub58>","x":"<x25519Pub58>"}
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final mp  = map['mp'] as String?;
      final sp  = map['sp'] as String?;
      final xp  = map['x'] as String?;
      final yk  = map['yk'] as String?;
      final rk  = map['rk'] as String?;
      if (mp != null) {
        setState(() {
          _pubkeyCtrl.text = mp;
          _scannedSigningPub       = sp;
          _scannedX25519Pub        = xp;
          _scannedYggPubKeyHex     = yk;
          _scannedReticulumAddress = rk;
          _scanning = false;
        });
        return;
      }
    } catch (_) {}

    // Fallback: raw base58 string
    setState(() {
      _pubkeyCtrl.text = raw;
      _scannedSigningPub   = null;
      _scannedX25519Pub    = null;
      _scannedYggPubKeyHex     = null;
      _scannedReticulumAddress = null;
      _scanning = false;
    });
  }

  Future<void> _save() async {
    var masterPubStr = _pubkeyCtrl.text.trim();
    final alias = _aliasCtrl.text.trim();

    if (masterPubStr.isEmpty) {
      setState(() => _error = context.l10n.invalidPublicKey);
      return;
    }

    setState(() { _saving = true; _error = null; });

    try {
      // Support pasting the full JSON from a shared address card
      // e.g. {"mp":"...","sp":"...","x":"...","yk":"...","rk":"..."}
      try {
        final map = jsonDecode(masterPubStr) as Map<String, dynamic>;
        final mp = map['mp'] as String?;
        if (mp != null) {
          masterPubStr = mp;
          _scannedSigningPub       = map['sp'] as String?;
          _scannedX25519Pub        = map['x']  as String?;
          _scannedYggPubKeyHex     = map['yk'] as String?;
          _scannedReticulumAddress = map['rk'] as String?;
        }
      } catch (_) {
        // Not JSON — treat as raw base58 key
      }

      // Validate: must be valid base58 AND decode to exactly 32 bytes.
      final decoded = PubkeyCodec.decode(masterPubStr);
      if (decoded.length != 32) {
        setState(() {
          _error = '${context.l10n.invalidPublicKey} (${decoded.length} bytes, expected 32)';
          _saving = false;
        });
        return;
      }
      // Use scanned signingPub if available; otherwise fall back to masterPub
      final signingPubStr = _scannedSigningPub ?? masterPubStr;
      final storage = ref.read(storageProvider);
      // Build transport addresses map from QR fields.
      final transportAddresses = <String, String>{
        if (_scannedYggPubKeyHex != null && _scannedYggPubKeyHex!.isNotEmpty)
          'yggdrasil': _scannedYggPubKeyHex!,
        if (_scannedReticulumAddress != null && _scannedReticulumAddress!.isNotEmpty)
          'reticulum': _scannedReticulumAddress!,
      };
      final contact = Contact(
        masterPub: masterPubStr,
        signingPub: signingPubStr,
        x25519Pub: _scannedX25519Pub,
        yggPubKeyHex: _scannedYggPubKeyHex,
        transportAddresses: transportAddresses,
        alias: alias.isNotEmpty ? alias : masterPubStr.substring(0, 8),
        addedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
      await storage.contacts.insert(contact);

      // Notify all screens (ChatsScreen, ContactsTab) to reload.
      ref.read(eventBusProvider).emit(ContactUpdatedEvent(masterPub: masterPubStr));

      if (mounted) context.pop();

      // Send contact_hello in background — don't block navigation.
      _sendContactHello(masterPubStr, transportAddresses);
    } catch (e) {
      setState(() => _error = '${context.l10n.invalidPublicKey}: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Send a contact_hello so the recipient can auto-add us back with our keys.
  ///
  /// Waits up to 20 s for Yggdrasil to become available (presentation concern),
  /// then delegates envelope building + delivery + retry to [SendContactHelloUseCase].
  Future<void> _sendContactHello(
    String recipientMasterPub58,
    Map<String, String> destAddresses,
  ) async {
    final useCase = ref.read(sendContactHelloProvider);
    if (useCase == null) return;

    var yggPub = ref.read(yggPubKeyProvider);
    if (yggPub.isEmpty) {
      for (int i = 0; i < 20 && yggPub.isEmpty; i++) {
        await Future.delayed(const Duration(seconds: 1));
        yggPub = ref.read(yggPubKeyProvider);
      }
    }

    // Read our Reticulum address if available
    String? myRnsAddress;
    try {
      if (await ReticulumNode.isRunning()) {
        final addr = await ReticulumNode.address();
        if (addr.isNotEmpty) myRnsAddress = addr;
      }
    } catch (_) {}

    await useCase.execute(
      recipientMasterPub58: recipientMasterPub58,
      myYggPubKeyHex: yggPub,
      myReticulumAddress: myRnsAddress,
      destTransportAddresses: destAddresses,
    );
  }

  @override
  Widget build(BuildContext context) {
    final identity = ref.watch(identityNotifierProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: HubCoreAppBar(title: Text(context.l10n.addContactTitle)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // My QR for sharing: JSON {"mp":"<masterPub58>","sp":"<signingPub58>"}
            if (identity != null) ...[
              Text(context.l10n.shareYourKey, style: theme.textTheme.titleMedium),
              const SizedBox(height: 12),
              const Center(child: MyQrCode(size: 160)),
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    identity.fingerprint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      letterSpacing: 2,
                    ),
                  ),
                ),
              ),
              const Divider(height: 32),
            ],

            // Scan / enter their key
            Text(context.l10n.contactKeyLabel, style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),

            if (_scanning)
              SizedBox(
                height: 240,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: MobileScanner(
                    controller: _scannerCtrl,
                    onDetect: _onScan,
                  ),
                ),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => setState(() => _scanning = true),
                      icon: const Icon(Icons.qr_code_scanner),
                      label: const Text('Camera'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _scanFromFile,
                    icon: const Icon(Icons.image_search),
                    label: Text(context.l10n.fromFile),
                  ),
                ],
              ),

            const SizedBox(height: 12),

            TextField(
              controller: _pubkeyCtrl,
              decoration: InputDecoration(
                labelText: context.l10n.pasteKeyHint,
                hintText: 'base58 or JSON {"mp":"..."}',
                hintStyle: const TextStyle(fontSize: 11),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.content_paste),
                  tooltip: context.l10n.pasteFromClipboard,
                  onPressed: () async {
                    final data = await Clipboard.getData('text/plain');
                    if (data?.text != null) {
                      _pubkeyCtrl.text = data!.text!.trim();
                    }
                  },
                ),
              ),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              maxLines: 3,
              minLines: 1,
            ),

            const SizedBox(height: 12),

            TextField(
              controller: _aliasCtrl,
              decoration: InputDecoration(
                labelText: context.l10n.contactNameHint,
                border: const OutlineInputBorder(),
              ),
              textCapitalization: TextCapitalization.words,
              maxLength: 32,
              buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
            ),

            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],

            const SizedBox(height: 24),

            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(context.l10n.addContactTitle),
            ),
          ],
        ),
      ),
    );
  }
}
