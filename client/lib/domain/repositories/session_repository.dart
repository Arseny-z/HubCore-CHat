import '../entities/session_record.dart';

/// Abstract repository for Double Ratchet session state persistence.
abstract class SessionRepository {
  Future<int> insert(SessionRecord record);
  Future<SessionRecord?> forContact(int contactId);
  Future<void> update(SessionRecord record);
  Future<void> deleteForContact(int contactId);
}
