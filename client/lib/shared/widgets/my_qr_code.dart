import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../providers/app_providers.dart';
import '../utils/pubkey_codec.dart';

/// Shows the user's identity QR code.
///
/// Displays a [CircularProgressIndicator] until Yggdrasil is ready
/// (i.e. [yggPubKeyProvider] is non-empty), so the QR always contains `yk`.
class MyQrCode extends ConsumerStatefulWidget {
  final double size;

  const MyQrCode({super.key, this.size = 200});

  @override
  ConsumerState<MyQrCode> createState() => _MyQrCodeState();
}

class _MyQrCodeState extends ConsumerState<MyQrCode> {
  String? _reticulumAddress;

  @override
  void initState() {
    super.initState();
    _loadReticulumAddress();
  }

  Future<void> _loadReticulumAddress() async {
    try {
      const ch = MethodChannel('hubcore/reticulum');
      final running = await ch.invokeMethod<bool>('isRunning') ?? false;
      if (!running) return;
      final addr = await ch.invokeMethod<String>('address');
      if (addr != null && addr.isNotEmpty && mounted) {
        setState(() => _reticulumAddress = addr);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final identity = ref.watch(identityNotifierProvider);
    final yggPub = ref.watch(yggPubKeyProvider);

    // Wait for identity — required. Yggdrasil is optional (may be disabled).
    if (identity == null) {
      return SizedBox(
        width: widget.size,
        height: widget.size,
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    // Need at least one transport address in the QR
    if (yggPub.isEmpty && (_reticulumAddress == null || _reticulumAddress!.isEmpty)) {
      return SizedBox(
        width: widget.size,
        height: widget.size,
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    // Keep payload minimal for reliable scanning: sp is redundant
    // (received in the first contact_hello), omitting it saves ~50 chars
    // and reduces QR density (fewer scan errors).
    final payload = <String, dynamic>{
      'mp': PubkeyCodec.encode(identity.masterPublicKey),
      'x': PubkeyCodec.encode(identity.x25519PublicKey),
      if (yggPub.isNotEmpty) 'yk': yggPub,
      if (_reticulumAddress != null && _reticulumAddress!.isNotEmpty)
        'rk': _reticulumAddress,
    };

    return QrImageView(
      data: jsonEncode(payload),
      version: QrVersions.auto,
      size: widget.size,
      backgroundColor: Colors.white,
    );
  }
}
