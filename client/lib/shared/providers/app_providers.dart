// Composition root: re-exports domain types for screens + barrel for providers.
// Screens only need to import this one file.

// ── Domain type re-exports ────────────────────────────────────────────────────
export '../../storage/dao/contacts_dao.dart' show Contact;
export '../../application/use_cases/contacts/send_contact_hello_use_case.dart'
    show SendContactHelloUseCase;
export '../../storage/dao/messages_dao.dart' show Message, MessageStatus;
export '../../storage/dao/groups_dao.dart' show Group, GroupMember;
export '../../storage/lock_manager.dart' show LockManager, UnlockResult;
export '../../infrastructure/transport/polling_service.dart' show PollingInterval;
export '../../infrastructure/notifications/notification_service.dart' show NotificationService;
export '../../domain/entities/envelope.dart' show Envelope;
export '../../domain/ports/transport_port.dart' show TransportProtocol;
export '../../domain/entities/message.dart' show ContentType;
export '../../storage/dao/send_queue_dao.dart' show QueueRecipient;
export '../../services/queue_service.dart' show QueueService;

// ── Provider barrels ──────────────────────────────────────────────────────────
export 'crypto_providers.dart';
export 'storage_providers.dart';
export 'transport_providers.dart';
export 'messaging_providers.dart';
