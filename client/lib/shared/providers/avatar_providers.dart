import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:async';

import '../../application/events/app_events.dart';
import '../services/avatar_service.dart';
import 'storage_providers.dart' show eventBusProvider;

/// Resolved path to the contact_avatars directory.
/// Resolves once on app start, then cached.
final avatarsDirProvider = FutureProvider<String>((ref) async {
  final dir = await AvatarService.instance.avatarsDir();
  return dir.path;
});

/// Returns the avatar [File] for [masterPub], or null if dir not yet resolved.
final avatarFileProvider = Provider.family<File?, String>((ref, masterPub) {
  final dirAsync = ref.watch(avatarsDirProvider);
  return dirAsync.whenOrNull(data: (path) {
    final key = masterPub.length >= 8 ? masterPub.substring(0, 8) : masterPub;
    return File('$path/$key.jpg');
  });
});

/// Increment to force avatar widgets to rebuild after saving a new photo.
final avatarVersionProvider =
    StateProvider.family<int, String>((ref, masterPub) => 0);

/// Version counter for the user's own avatar.
final myAvatarVersionProvider = StateProvider<int>((ref) => 0);

/// Listens to ContactUpdatedEvent and increments avatarVersionProvider so
/// ContactAvatar widgets rebuild immediately after receiving an avatar via contact_hello.
final avatarRefresherProvider = Provider<void>((ref) {
  final bus = ref.read(eventBusProvider);
  final sub = bus.on<ContactUpdatedEvent>().listen((event) {
    ref.read(avatarVersionProvider(event.masterPub).notifier).state++;
  });
  ref.onDispose(sub.cancel);
});

/// Returns the user's own avatar File if it exists, null otherwise.
/// Returns null (not File) when deleted so downstream providers detect the change.
final myAvatarFileProvider = Provider<File?>((ref) {
  ref.watch(myAvatarVersionProvider);
  final dirAsync = ref.watch(avatarsDirProvider);
  return dirAsync.whenOrNull(data: (path) {
    final f = File('$path/__me__.jpg');
    return f.existsSync() ? f : null;
  });
});

/// Version counter for the user's own PUBLIC avatar.
final myAvatarPublicVersionProvider = StateProvider<int>((ref) => 0);

/// Returns the user's own PUBLIC avatar File if it exists, null otherwise.
final myAvatarPublicFileProvider = Provider<File?>((ref) {
  ref.watch(myAvatarPublicVersionProvider);
  final dirAsync = ref.watch(avatarsDirProvider);
  return dirAsync.whenOrNull(data: (path) {
    final f = File('$path/__me_public__.jpg');
    return f.existsSync() ? f : null;
  });
});
