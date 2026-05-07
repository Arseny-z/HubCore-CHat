import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../application/events/app_events.dart' show ContactUpdatedEvent;
import '../../shared/providers/app_providers.dart';
import '../../shared/providers/avatar_providers.dart';
import '../../shared/utils/l10n.dart';
import '../../shared/services/avatar_service.dart';
import '../../shared/widgets/contact_avatar.dart';
import '../../shared/widgets/hubcore_app_bar.dart';

class ContactProfileScreen extends ConsumerStatefulWidget {
  final String masterPub;
  const ContactProfileScreen({super.key, required this.masterPub});

  @override
  ConsumerState<ContactProfileScreen> createState() =>
      _ContactProfileScreenState();
}

class _ContactProfileScreenState
    extends ConsumerState<ContactProfileScreen> {
  Contact? _contact;
  bool _editingName = false;
  late TextEditingController _nameCtrl;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController();
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final storage = ref.read(storageProvider);
    if (!storage.isOpen) return;
    final c = await storage.contacts.findByMasterPub(widget.masterPub);
    if (mounted) {
      setState(() {
        _contact = c;
        _nameCtrl.text = c?.alias ?? '';
      });
    }
  }

  Future<void> _pickAvatar(ImageSource source) async {
    final file = await AvatarService.instance.pickAndSave(
      widget.masterPub,
      source: source,
    );
    if (file != null && mounted) {
      ref.read(avatarVersionProvider(widget.masterPub).notifier).state++;
    }
  }

  void _showAvatarOptions() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF182533),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined, color: Colors.white70),
              title: Text(context.l10n.selectFromGallery, style: const TextStyle(color: Colors.white)),
              onTap: () { Navigator.pop(context); _pickAvatar(ImageSource.gallery); },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined, color: Colors.white70),
              title: Text(context.l10n.takePhoto, style: const TextStyle(color: Colors.white)),
              onTap: () { Navigator.pop(context); _pickAvatar(ImageSource.camera); },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: Text(context.l10n.deletePhoto, style: const TextStyle(color: Colors.red)),
              onTap: () async {
                Navigator.pop(context);
                await AvatarService.instance.delete(widget.masterPub);
                if (mounted) {
                  ref.read(avatarVersionProvider(widget.masterPub).notifier).state++;
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveName() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    final storage = ref.read(storageProvider);
    await storage.contacts.setCustomAlias(widget.masterPub, name);
    setState(() {
      _contact = _contact?.copyWith(alias: name, aliasCustomized: true);
      _editingName = false;
    });
  }

  Future<void> _clearHistory() async {
    final name = _contact?.alias.isNotEmpty == true
        ? _contact!.alias
        : widget.masterPub.substring(0, 8);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(context.l10n.clearChatTitle),
        content: Text(context.l10n.clearChatContent(name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.clearChatHistory),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final storage = ref.read(storageProvider);
    await storage.files.deleteForConversation(widget.masterPub);
    await storage.messages.deleteConversation(widget.masterPub);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.chatHistoryCleared)),
      );
    }
  }

  Future<void> _block() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Заблокировать контакт?'),
        content: const Text(
            'Этот контакт не сможет отправлять вам сообщения. '
            'DR-сессия будет удалена.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Заблокировать'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final storage = ref.read(storageProvider);
    await storage.contacts.setRelationship(widget.masterPub, 'blocked');
    final contact = _contact;
    if (contact?.id != null) await storage.sessions.deleteForContact(contact!.id!);
    await storage.sendQueue.deleteForRecipient(widget.masterPub);
    await _load();
  }

  Future<void> _unblock() async {
    final storage = ref.read(storageProvider);
    await storage.contacts.setRelationship(widget.masterPub, 'contact');
    await _load();
  }

  Future<void> _addToContacts() async {
    final storage = ref.read(storageProvider);
    await storage.contacts.setRelationship(widget.masterPub, 'contact');
    ref.read(eventBusProvider).emit(ContactUpdatedEvent(masterPub: widget.masterPub));
    await _load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Добавлено в контакты')));
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(context.l10n.deleteContactTitle),
        content: Text(
          context.l10n.deleteContactContent(
            _contact?.alias.isNotEmpty == true ? _contact!.alias : widget.masterPub.substring(0, 8),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await AvatarService.instance.delete(widget.masterPub);
    await ref.read(storageProvider).contacts.delete(widget.masterPub);
    if (mounted) context.go('/main');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final contact = _contact;
    final displayName = contact?.alias.isNotEmpty == true
        ? contact!.alias
        : widget.masterPub.substring(0, 8);

    // Fingerprint: first 40 chars of masterPub split into groups of 4
    final fp = _formatFingerprint(widget.masterPub);

    return Scaffold(
      backgroundColor: const Color(0xFF17212B),
      appBar: HubCoreAppBar(
        title: const Text('Contact Info'),
        actions: [
          if (!_editingName)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Edit name',
              onPressed: () => setState(() => _editingName = true),
            ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            // ── Avatar + name ──────────────────────────────────────────────
            Container(
              width: double.infinity,
              color: const Color(0xFF1C2733),
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Column(
                children: [
                  GestureDetector(
                    onTap: _showAvatarOptions,
                    child: Stack(
                      alignment: Alignment.bottomRight,
                      children: [
                        ContactAvatar(
                          name: displayName,
                          masterPub: widget.masterPub,
                          radius: 52,
                        ),
                        Container(
                          decoration: const BoxDecoration(
                            color: Color(0xFF2AABEE),
                            shape: BoxShape.circle,
                          ),
                          padding: const EdgeInsets.all(6),
                          child: const Icon(Icons.camera_alt, color: Colors.white, size: 16),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _editingName
                      ? Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 32),
                          child: Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _nameCtrl,
                                  autofocus: true,
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 20),
                                  textAlign: TextAlign.center,
                                  decoration: InputDecoration(
                                    hintText: context.l10n.contactNameHint,
                                    hintStyle: const TextStyle(
                                        color: Colors.white38),
                                    filled: true,
                                    fillColor: const Color(0xFF253341),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: BorderSide.none,
                                    ),
                                    contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 16, vertical: 10),
                                  ),
                                  onSubmitted: (_) => _saveName(),
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton.filled(
                                onPressed: _saveName,
                                icon: const Icon(Icons.check),
                              ),
                              IconButton(
                                onPressed: () =>
                                    setState(() => _editingName = false),
                                icon: const Icon(Icons.close,
                                    color: Colors.white54),
                              ),
                            ],
                          ),
                        )
                      : Text(
                          displayName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 22,
                          ),
                        ),
                ],
              ),
            ),

            const SizedBox(height: 8),

            // ── Key info ───────────────────────────────────────────────────
            _Section(
              children: [
                _InfoTile(
                  icon: Icons.fingerprint,
                  label: context.l10n.fingerprint,
                  value: fp,
                  monospace: true,
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: widget.masterPub));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(context.l10n.publicKeyCopied),
                        duration: const Duration(seconds: 1),
                      ),
                    );
                  },
                ),
                _InfoTile(
                  icon: Icons.key_outlined,
                  label: context.l10n.publicKeyBase58,
                  value: '${widget.masterPub.substring(0, 20)}…',
                  monospace: true,
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: widget.masterPub));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(context.l10n.publicKeyCopied),
                        duration: const Duration(seconds: 1),
                      ),
                    );
                  },
                ),
              ],
            ),

            const SizedBox(height: 8),

            // ── Stranger banner ────────────────────────────────────────────
            if (_contact?.isStranger == true)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 0, vertical: 4),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                color: const Color(0xFF1C2B3A),
                child: Row(
                  children: [
                    const Icon(Icons.person_outline,
                        color: Colors.white54, size: 18),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text('Незнакомый контакт',
                          style: TextStyle(color: Colors.white70, fontSize: 13)),
                    ),
                    TextButton(
                      onPressed: _addToContacts,
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFF2AABEE),
                        minimumSize: Size.zero,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('+ Добавить',
                          style: TextStyle(fontSize: 13)),
                    ),
                  ],
                ),
              ),

            // ── Actions ────────────────────────────────────────────────────
            _Section(
              children: [
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFF2AABEE),
                    child: Icon(Icons.chat_bubble_outline, color: Colors.white,
                        size: 20),
                  ),
                  title: Text(context.l10n.sendMessage,
                      style: const TextStyle(color: Colors.white)),
                  onTap: () => context.go('/chat/${widget.masterPub}'),
                ),
              ],
            ),

            const SizedBox(height: 8),

            _Section(
              children: [
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFF37474F),
                    child: Icon(Icons.delete_sweep_outlined,
                        color: Colors.white70, size: 20),
                  ),
                  title: Text(context.l10n.clearChatHistory,
                      style: const TextStyle(color: Colors.white)),
                  onTap: _clearHistory,
                ),
              ],
            ),

            const SizedBox(height: 8),

            _Section(
              children: [
                if (_contact?.isBlocked == true)
                  ListTile(
                    leading: CircleAvatar(
                      backgroundColor: Colors.orange.withAlpha(40),
                      child: const Icon(Icons.lock_open_outlined,
                          color: Colors.orange, size: 20),
                    ),
                    title: const Text('Разблокировать',
                        style: TextStyle(color: Colors.orange)),
                    onTap: _unblock,
                  )
                else
                  ListTile(
                    leading: CircleAvatar(
                      backgroundColor: Colors.red.withAlpha(40),
                      child: const Icon(Icons.block_outlined,
                          color: Colors.red, size: 20),
                    ),
                    title: const Text('Заблокировать',
                        style: TextStyle(color: Colors.red)),
                    onTap: _block,
                  ),
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor:
                        theme.colorScheme.error.withAlpha(40),
                    child: Icon(Icons.delete_outline,
                        color: theme.colorScheme.error, size: 20),
                  ),
                  title: Text(context.l10n.deleteContactTitle,
                      style: TextStyle(color: theme.colorScheme.error)),
                  onTap: _delete,
                ),
              ],
            ),

            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  static String _formatFingerprint(String pub) {
    // Take first 32 chars, split into 8 groups of 4 separated by spaces
    final s = pub.length > 32 ? pub.substring(0, 32) : pub;
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && i % 4 == 0) buf.write(' ');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}

// ── Helper widgets ─────────────────────────────────────────────────────────────

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

class _InfoTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool monospace;
  final VoidCallback? onTap;

  const _InfoTile({
    required this.icon,
    required this.label,
    required this.value,
    this.monospace = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: const Color(0xFF2AABEE)),
      title: Text(label,
          style: const TextStyle(color: Colors.white54, fontSize: 12)),
      subtitle: Text(
        value,
        style: TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontFamily: monospace ? 'monospace' : null,
          letterSpacing: monospace ? 1.2 : null,
        ),
      ),
      trailing: const Icon(Icons.copy, size: 16, color: Colors.white38),
      onTap: onTap,
    );
  }
}
