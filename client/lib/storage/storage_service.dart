import 'dart:typed_data';

import 'database.dart';
import 'dao/contacts_dao.dart';
import 'dao/ephemeral_keys_dao.dart';
import 'dao/files_dao.dart';
import 'dao/groups_dao.dart';
import 'dao/messages_dao.dart';
import 'dao/sessions_dao.dart';
import 'dao/settings_dao.dart';
import 'dao/send_queue_dao.dart';
import 'dao/message_receipts_dao.dart';
import 'dao/message_reactions_dao.dart';
import 'dao/notifications_dao.dart';
import 'dao/my_devices_dao.dart';
import 'dao/contact_devices_dao.dart';
import 'dao/multi_sessions_dao.dart';
import 'dao/cross_device_inbox_dao.dart';
import '../infrastructure/persistence/repositories/contact_repository_impl.dart';
import '../infrastructure/persistence/repositories/message_repository_impl.dart';
import '../infrastructure/persistence/repositories/session_repository_impl.dart';
import '../infrastructure/persistence/repositories/group_repository_impl.dart';
import '../infrastructure/persistence/repositories/file_repository_impl.dart';

export 'dao/contacts_dao.dart';
export 'dao/ephemeral_keys_dao.dart';
export 'dao/files_dao.dart';
export 'dao/groups_dao.dart';
export 'dao/messages_dao.dart';
export 'dao/sessions_dao.dart';
export 'dao/settings_dao.dart';
export 'dao/send_queue_dao.dart';
export 'dao/message_receipts_dao.dart';
export 'dao/message_reactions_dao.dart';
export 'dao/notifications_dao.dart';
export 'dao/my_devices_dao.dart';
export 'dao/contact_devices_dao.dart';
export 'dao/multi_sessions_dao.dart';
export 'dao/cross_device_inbox_dao.dart';
export '../domain/repositories/contact_repository.dart';
export '../domain/repositories/message_repository.dart';
export '../domain/repositories/session_repository.dart';
export '../domain/repositories/group_repository.dart';
export '../domain/repositories/file_repository.dart';

/// Facade for all local storage operations.
///
/// Requires [open] to be called with the DB encryption key before use.
/// Call [close] when the app locks.
///
/// Exposes both raw DAO (legacy) and domain Repository interfaces.
/// New code should prefer the Repository interfaces; DAO access is kept
/// for backward compat and will be removed in Phase A3.
class StorageService {
  final AppDatabase _appDb;

  // Legacy DAO access — kept for backward compat.
  late ContactsDao contacts;
  late EphemeralKeysDao ephemeralKeys;
  late FilesDao files;
  late GroupsDao groups;
  late MessagesDao messages;
  late SessionsDao sessions;
  late SettingsDao settings;
  late SendQueueDao sendQueue;
  late MessageReceiptsDao messageReceipts;
  late MessageReactionsDao messageReactions;
  late NotificationsDao notifications;
  // Multi-device DAOs
  late MyDevicesDao myDevices;
  late ContactDevicesDao contactDevices;
  late MultiSessionsDao multiSessions;
  late CrossDeviceInboxDao crossDeviceInbox;

  // Domain repository interfaces — prefer these in new code.
  late ContactRepositoryImpl contactRepo;
  late MessageRepositoryImpl messageRepo;
  late SessionRepositoryImpl sessionRepo;
  late GroupRepositoryImpl groupRepo;
  late FileRepositoryImpl fileRepo;

  StorageService() : _appDb = AppDatabase();

  bool get isOpen => _appDb.isOpen;

  Future<String?> dbPath() => _appDb.dbPath();

  Future<void> open(Uint8List dbKey) async {
    await _appDb.open(dbKey);
    contacts      = ContactsDao(_appDb.db);
    ephemeralKeys = EphemeralKeysDao(_appDb.db);
    files         = FilesDao(_appDb.db);
    groups        = GroupsDao(_appDb.db);
    messages      = MessagesDao(_appDb.db);
    sessions      = SessionsDao(_appDb.db);
    settings        = SettingsDao(_appDb.db);
    sendQueue       = SendQueueDao(_appDb.db);
    messageReceipts = MessageReceiptsDao(_appDb.db);
    messageReactions   = MessageReactionsDao(_appDb.db);
    notifications      = NotificationsDao(_appDb.db);
    myDevices          = MyDevicesDao(_appDb.db);
    contactDevices     = ContactDevicesDao(_appDb.db);
    multiSessions      = MultiSessionsDao(_appDb.db);
    crossDeviceInbox   = CrossDeviceInboxDao(_appDb.db);

    contactRepo = ContactRepositoryImpl(contacts);
    messageRepo = MessageRepositoryImpl(messages);
    sessionRepo = SessionRepositoryImpl(sessions);
    groupRepo   = GroupRepositoryImpl(groups);
    fileRepo    = FileRepositoryImpl(files);
  }

  Future<void> close() => _appDb.close();
}
