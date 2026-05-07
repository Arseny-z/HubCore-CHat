
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:async';

import '../../application/events/app_events.dart';
import '../../shared/providers/app_providers.dart';
import '../../shared/providers/avatar_providers.dart' show myAvatarFileProvider, myAvatarVersionProvider, myAvatarPublicFileProvider, myAvatarPublicVersionProvider;
import '../../shared/providers/messaging_providers.dart';
import '../../shared/providers/storage_providers.dart' show eventBusProvider;
import '../../shared/services/avatar_service.dart';
import '../../shared/utils/l10n.dart';
import '../../shared/utils/pubkey_codec.dart';
import '../../shared/widgets/contact_avatar.dart' show GeneratedAvatar;
import '../../shared/widgets/my_qr_code.dart';
import '../../shared/widgets/hubcore_app_bar.dart';

class ProfileTab extends ConsumerStatefulWidget {
  const ProfileTab({super.key});

  @override
  ConsumerState<ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends ConsumerState<ProfileTab> {
  String _myName = '';
  bool _editingName = false;
  late TextEditingController _nameCtrl;

  String _myPublicName = '';
  bool _editingPublicName = false;
  late TextEditingController _publicNameCtrl;
  StreamSubscription<dynamic>? _profileSyncSub;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _publicNameCtrl.dispose();
    _profileSyncSub?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController();
    _publicNameCtrl = TextEditingController();
    _ensureIdentityLoaded();
    _loadName();
    // Refresh UI when profile_sync arrives from another own device.
    final bus = ref.read(eventBusProvider);
    _profileSyncSub = bus.on<ProfileSyncedEvent>().listen((_) {
      _loadName();
      ref.read(myAvatarVersionProvider.notifier).state++;
      ref.read(myAvatarPublicVersionProvider.notifier).state++;
    });
  }

  Future<void> _ensureIdentityLoaded() async {
    if (ref.read(identityNotifierProvider) != null) return;
    final sodium = await ref.read(sodiumProvider.future);
    await ref.read(identityNotifierProvider.notifier).load(sodium);
  }

  Future<void> _loadName() async {
    final storage = ref.read(storageProvider);
    if (!storage.isOpen) return;
    final v  = await storage.settings.get('my_alias');
    final vp = await storage.settings.get('my_public_alias');
    if (mounted) setState(() {
      _myName = v ?? '';
      _nameCtrl.text = _myName;
      _myPublicName = vp ?? '';
      _publicNameCtrl.text = _myPublicName;
    });
  }

  Future<void> _saveName() async {
    final name = _nameCtrl.text.trim();
    final storage = ref.read(storageProvider);
    if (storage.isOpen) {
      await storage.settings.set('my_alias', name);
    }
    setState(() {
      _myName = name;
      _editingName = false;
    });
    _broadcastProfile();
  }

  void _broadcastProfile() {
    ref.read(messageRouterProvider)?.broadcastHello();
    // Sync updated profile to own devices (fire and forget).
    ref.read(deviceSyncServiceProvider)?.syncProfile().catchError((_) {});
  }

  Future<void> _savePublicName() async {
    final name = _publicNameCtrl.text.trim();
    final storage = ref.read(storageProvider);
    if (storage.isOpen) {
      await storage.settings.set('my_public_alias', name);
    }
    setState(() { _myPublicName = name; _editingPublicName = false; });
    _broadcastProfile();
  }

  Future<void> _pickAvatar(ImageSource source, {bool publicProfile = false}) async {
    final file = await AvatarService.instance.pickAndSaveMy(
        source: source, publicProfile: publicProfile);
    if (file != null && mounted) {
      if (publicProfile) {
        ref.read(myAvatarPublicVersionProvider.notifier).state++;
      } else {
        ref.read(myAvatarVersionProvider.notifier).state++;
      }
      _broadcastProfile();
    }
  }

  void _showAvatarOptions({bool publicProfile = false}) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF182533),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined, color: Colors.white70),
              title: Text(ctx.l10n.selectFromGallery, style: const TextStyle(color: Colors.white)),
              onTap: () { Navigator.pop(ctx); _pickAvatar(ImageSource.gallery, publicProfile: publicProfile); },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined, color: Colors.white70),
              title: Text(ctx.l10n.takePhoto, style: const TextStyle(color: Colors.white)),
              onTap: () { Navigator.pop(ctx); _pickAvatar(ImageSource.camera, publicProfile: publicProfile); },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
              title: Text(ctx.l10n.deletePhoto, style: const TextStyle(color: Colors.redAccent)),
              onTap: () async {
                Navigator.pop(ctx);
                await AvatarService.instance.deleteMy(publicProfile: publicProfile);
                if (mounted) {
                  if (publicProfile) {
                    ref.read(myAvatarPublicVersionProvider.notifier).state++;
                  } else {
                    ref.read(myAvatarVersionProvider.notifier).state++;
                  }
                  _broadcastProfile();
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final identity = ref.watch(identityNotifierProvider);
    final theme = Theme.of(context);
    ref.watch(myAvatarVersionProvider); // force rebuild on pick/delete
    final myAvatarFile = ref.watch(myAvatarFileProvider);
    final myPublicAvatarFile = ref.watch(myAvatarPublicFileProvider);

    if (identity == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final pub58 = PubkeyCodec.encode(identity.masterPublicKey);
    final fp = identity.fingerprint;
    final hasPhoto = myAvatarFile != null && myAvatarFile.existsSync();
    final displayName = _myName.isNotEmpty ? _myName : pub58.substring(0, 8);

    return Scaffold(
      appBar: HubCoreAppBar(
        title: Text(context.l10n.myProfile, style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            // ── Avatar + QR ──────────────────────────────────────────────
            Container(
              width: double.infinity,
              color: const Color(0xFF1C2733),
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Column(
                children: [
                  GestureDetector(
                    onTap: _showAvatarOptions,
                    child: Stack(
                      children: [
                        ClipOval(
                          child: hasPhoto
                              ? Image.file(
                                  myAvatarFile,
                                  key: ValueKey(ref.watch(myAvatarVersionProvider)),
                                  width: 104,
                                  height: 104,
                                  fit: BoxFit.cover,
                                )
                              : GeneratedAvatar(masterPub: pub58, name: displayName, radius: 52),
                        ),
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: const BoxDecoration(
                              color: Color(0xFF2AABEE),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.camera_alt, color: Colors.white, size: 16),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_editingName)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _nameCtrl,
                              autofocus: true,
                              textCapitalization: TextCapitalization.words,
                              maxLength: 32,
                              buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
                              style: const TextStyle(color: Colors.white, fontSize: 18),
                              decoration: InputDecoration(
                                hintText: context.l10n.yourNickname,
                                hintStyle: const TextStyle(color: Colors.white38),
                                filled: true,
                                fillColor: const Color(0xFF17212B),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: BorderSide.none,
                                ),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              ),
                              onSubmitted: (_) => _saveName(),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(Icons.check, color: Color(0xFF2AABEE)),
                            onPressed: _saveName,
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, color: Colors.white38),
                            onPressed: () => setState(() {
                              _editingName = false;
                              _nameCtrl.text = _myName;
                            }),
                          ),
                        ],
                      ),
                    )
                  else
                    GestureDetector(
                      onTap: () => setState(() => _editingName = true),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            displayName,
                            style: theme.textTheme.titleLarge?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Icon(Icons.edit_outlined, color: Colors.white38, size: 18),
                        ],
                      ),
                    ),
                  const SizedBox(height: 4),
                  Text(
                    context.l10n.shareQrToAddContacts,
                    style: theme.textTheme.bodySmall?.copyWith(color: Colors.white54),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 8),

            // ── QR code ──────────────────────────────────────────────────
            Container(
              color: const Color(0xFF1C2733),
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const MyQrCode(size: 200),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    fp,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      letterSpacing: 2,
                      fontSize: 12,
                      color: Colors.white70,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // ── Public profile ───────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Icon(Icons.public, size: 16, color: Colors.white38),
                  const SizedBox(width: 6),
                  Text('Публичный профиль',
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.white38, letterSpacing: 1.2)),
                ],
              ),
            ),
            const SizedBox(height: 8),
            _Section(children: [
              ListTile(
                leading: GestureDetector(
                  onTap: () => _showAvatarOptions(publicProfile: true),
                  child: CircleAvatar(
                    radius: 22,
                    backgroundColor: const Color(0xFF253341),
                    backgroundImage: myPublicAvatarFile != null
                        ? FileImage(myPublicAvatarFile) as ImageProvider
                        : null,
                    child: const Icon(Icons.public, color: Colors.white54, size: 20),
                  ),
                ),
                title: _editingPublicName
                    ? TextField(
                        controller: _publicNameCtrl,
                        autofocus: true,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          hintText: 'Публичное имя',
                          hintStyle: TextStyle(color: Colors.white38),
                          border: InputBorder.none,
                        ),
                        onSubmitted: (_) => _savePublicName(),
                      )
                    : GestureDetector(
                        onTap: () => setState(() => _editingPublicName = true),
                        child: Text(
                          _myPublicName.isNotEmpty
                              ? _myPublicName
                              : 'Задать публичное имя',
                          style: TextStyle(
                              color: _myPublicName.isNotEmpty
                                  ? Colors.white
                                  : Colors.white38),
                        ),
                      ),
                subtitle: const Text(
                  'Видят незнакомцы которые пишут вам',
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
                trailing: _editingPublicName
                    ? IconButton(
                        icon: const Icon(Icons.check, color: Color(0xFF2AABEE)),
                        onPressed: _savePublicName,
                      )
                    : IconButton(
                        icon: const Icon(Icons.edit, size: 16, color: Colors.white38),
                        onPressed: () => setState(() => _editingPublicName = true),
                      ),
              ),
            ]),

            const SizedBox(height: 8),

            // ── Key info ─────────────────────────────────────────────────
            _Section(children: [
              _CopyTile(
                icon: Icons.fingerprint,
                label: context.l10n.fingerprint,
                value: fp,
                copyValue: fp,
                monospace: true,
              ),
              _CopyTile(
                icon: Icons.key_outlined,
                label: context.l10n.publicKeyBase58,
                value: '${pub58.substring(0, 24)}…',
                copyValue: pub58,
                monospace: true,
              ),
            ]),

            const SizedBox(height: 8),

            // ── Actions ──────────────────────────────────────────────────
            _Section(children: [
              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFF26A69A),
                  child: Icon(Icons.network_check, color: Colors.white, size: 20),
                ),
                title: const Text('Network Status', style: TextStyle(color: Colors.white)),
                subtitle: const Text('Yggdrasil, Reticulum', style: TextStyle(color: Colors.white54, fontSize: 12)),
                trailing: const Icon(Icons.chevron_right, color: Colors.white38),
                onTap: () => context.push('/network-status'),
              ),
            ]),

            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final List<Widget> children;
  const _Section({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1C2733),
      child: Column(
        children: [
          for (int i = 0; i < children.length; i++) ...[
            children[i],
            if (i < children.length - 1)
              const Divider(height: 1, indent: 56, color: Color(0xFF253341)),
          ],
        ],
      ),
    );
  }
}

class _CopyTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final String copyValue;
  final bool monospace;

  const _CopyTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.copyValue,
    this.monospace = false,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: const Color(0xFF2AABEE)),
      title: Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
      subtitle: Text(
        value,
        style: TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontFamily: monospace ? 'monospace' : null,
          letterSpacing: monospace ? 1.0 : null,
        ),
      ),
      trailing: const Icon(Icons.copy, size: 16, color: Colors.white38),
      onTap: () {
        Clipboard.setData(ClipboardData(text: copyValue));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.copied), duration: const Duration(seconds: 1)),
        );
      },
    );
  }
}
