import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../shared/providers/app_providers.dart';
import '../../shared/providers/avatar_providers.dart';
import '../../shared/services/avatar_service.dart';
import '../../shared/utils/l10n.dart';

class ProfileSetupScreen extends ConsumerStatefulWidget {
  const ProfileSetupScreen({super.key});

  @override
  ConsumerState<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends ConsumerState<ProfileSetupScreen> {
  final _nickCtrl = TextEditingController();
  File? _avatarFile;
  bool _saving = false;

  @override
  void dispose() {
    _nickCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar(ImageSource source) async {
    final file = await AvatarService.instance.pickAndSaveMy(source: source);
    if (file != null && mounted) {
      setState(() => _avatarFile = file);
      ref.read(myAvatarVersionProvider.notifier).state++;
    }
  }

  void _showAvatarOptions() {
    showModalBottomSheet<void>(
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
              onTap: () { Navigator.pop(ctx); _pickAvatar(ImageSource.gallery); },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined, color: Colors.white70),
              title: Text(ctx.l10n.takePhoto, style: const TextStyle(color: Colors.white)),
              onTap: () { Navigator.pop(ctx); _pickAvatar(ImageSource.camera); },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _continue() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final nick = _nickCtrl.text.trim();
      if (nick.isNotEmpty) {
        final storage = ref.read(storageProvider);
        if (storage.isOpen) {
          await storage.settings.set('my_alias', nick);
          // Also set as public alias if not already configured —
          // new users should be visible to strangers by default.
          final existing = await storage.settings.get('my_public_alias');
          if (existing == null || existing.isEmpty) {
            await storage.settings.set('my_public_alias', nick);
          }
        }
      }
      if (mounted) context.go('/main');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasPhoto = _avatarFile != null && _avatarFile!.existsSync();
    final version = ref.watch(myAvatarVersionProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF17212B),
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  children: [
                    const Spacer(flex: 2),

                    Text(
                      context.l10n.profileSetupTitle,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      context.l10n.profileSetupSubtitle,
                      style: const TextStyle(color: Colors.white54, fontSize: 14, height: 1.5),
                      textAlign: TextAlign.center,
                    ),

                    const Spacer(flex: 2),

                    // ── Avatar picker ────────────────────────────────────────
                    GestureDetector(
                      onTap: _showAvatarOptions,
                      child: Stack(
                        children: [
                          if (hasPhoto)
                            ClipOval(
                              child: Image.file(
                                _avatarFile!,
                                key: ValueKey(version),
                                width: 112,
                                height: 112,
                                fit: BoxFit.cover,
                              ),
                            )
                          else
                            CircleAvatar(
                              radius: 56,
                              backgroundColor: const Color(0xFF2AABEE).withAlpha(40),
                              child: const Icon(Icons.person_outline, color: Color(0xFF2AABEE), size: 52),
                            ),
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: Container(
                              padding: const EdgeInsets.all(6),
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

                    const SizedBox(height: 32),

                    // ── Nickname input ───────────────────────────────────────
                    TextField(
                      controller: _nickCtrl,
                      textCapitalization: TextCapitalization.words,
                      autofocus: false,
                      decoration: InputDecoration(
                        hintText: context.l10n.nicknameHint,
                        hintStyle: const TextStyle(color: Colors.white38),
                        prefixIcon: const Icon(Icons.alternate_email, color: Colors.white38),
                        filled: true,
                        fillColor: const Color(0xFF1C2733),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      style: const TextStyle(color: Colors.white),
                      maxLength: 32,
                      buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
                      onSubmitted: (_) => _continue(),
                    ),

                    const Spacer(flex: 3),

                    // ── Continue ─────────────────────────────────────────────
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _saving ? null : _continue,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        child: _saving
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : Text(context.l10n.continueAction),
                      ),
                    ),
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
