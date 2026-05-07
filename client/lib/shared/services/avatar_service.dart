import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

/// Stores and retrieves contact avatar photos.
///
/// Photos are saved as JPEG files under:
///   `<appDocDir>/contact_avatars/<masterPub8>.jpg`
class AvatarService {
  AvatarService._();
  static final AvatarService instance = AvatarService._();

  Future<Directory> avatarsDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/contact_avatars');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  String _key(String masterPub) =>
      masterPub.length >= 8 ? masterPub.substring(0, 8) : masterPub;

  /// Returns the avatar [File] for [masterPub]. The file may not exist yet.
  Future<File> avatarFile(String masterPub) async {
    final dir = await avatarsDir();
    return File('${dir.path}/${_key(masterPub)}.jpg');
  }

  /// Synchronous shortcut when the directory path is already known.
  File avatarFileAt(String masterPub, String dirPath) =>
      File('$dirPath/${_key(masterPub)}.jpg');

  /// Pick from gallery or camera, resize to 512×512, save as avatar.
  /// Returns the saved [File] or null if the user cancelled.
  Future<File?> pickAndSave(
    String masterPub, {
    ImageSource source = ImageSource.gallery,
  }) async {
    final picked = await ImagePicker().pickImage(
      source: source,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 85,
    );
    if (picked == null) return null;
    final dest = await avatarFile(masterPub);
    await FileImage(dest).evict();
    await File(picked.path).copy(dest.path);
    return dest;
  }

  /// Delete the avatar for [masterPub].
  Future<void> delete(String masterPub) async {
    final file = await avatarFile(masterPub);
    if (file.existsSync()) file.deleteSync();
  }

  // ── My own avatar ──────────────────────────────────────────────────────────

  /// Key for the user's own contacts-only avatar (full photo).
  static const _myKey = '__me__';
  /// Key for the user's public avatar (shown to strangers).
  static const _myPublicKey = '__me_public__';

  /// Returns the File for the user's own avatar.
  /// [publicProfile] = true → public avatar shown to strangers.
  Future<File> myAvatarFile({bool publicProfile = false}) async {
    final dir = await avatarsDir();
    return File('${dir.path}/${publicProfile ? _myPublicKey : _myKey}.jpg');
  }

  /// Pick and save the user's own avatar. Returns saved File or null if cancelled.
  /// [publicProfile] = true → saves as public avatar.
  Future<File?> pickAndSaveMy({
    ImageSource source = ImageSource.gallery,
    bool publicProfile = false,
  }) async {
    final picked = await ImagePicker().pickImage(
      source: source,
      maxWidth: 256,
      maxHeight: 256,
      imageQuality: 75,
    );
    if (picked == null) return null;
    final dest = await myAvatarFile(publicProfile: publicProfile);
    await FileImage(dest).evict();
    await File(picked.path).copy(dest.path);
    return dest;
  }

  /// Delete the user's own avatar.
  /// [publicProfile] = true → deletes public avatar.
  Future<void> deleteMy({bool publicProfile = false}) async {
    final file = await myAvatarFile(publicProfile: publicProfile);
    if (file.existsSync()) file.deleteSync();
  }

  // ── Avatar exchange ────────────────────────────────────────────────────────

  /// Max avatar size for transmission in contact_hello (32 KB).
  static const maxAvatarBytes = 32 * 1024;

  /// Returns the user's own avatar as base64 string, or null if not set or too large.
  /// [publicProfile] = true → returns public avatar (for strangers).
  Future<String?> myAvatarBase64({bool publicProfile = false}) async {
    final file = await myAvatarFile(publicProfile: publicProfile);
    if (!file.existsSync()) return null;
    final bytes = await file.readAsBytes();
    if (bytes.length > maxAvatarBytes) return null;
    return base64Encode(bytes);
  }

  /// Save a received avatar (base64) for [masterPub].
  /// Silently ignores if too large or invalid.
  Future<void> saveFromBase64(String masterPub, String b64) async {
    try {
      final bytes = base64Decode(b64);
      if (bytes.length > maxAvatarBytes) return;
      final file = await avatarFile(masterPub);
      await FileImage(file).evict();
      await file.writeAsBytes(bytes);
    } catch (_) {}
  }

  /// Save own avatar from base64 (used when syncing profile from another device).
  Future<void> saveMyFromBase64(String b64, {bool publicProfile = false}) async {
    try {
      final bytes = base64Decode(b64);
      if (bytes.length > maxAvatarBytes) return;
      final file = await myAvatarFile(publicProfile: publicProfile);
      await FileImage(file).evict();
      await file.writeAsBytes(bytes);
    } catch (_) {}
  }
}
