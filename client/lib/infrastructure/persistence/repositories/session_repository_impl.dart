import '../../../domain/entities/session_record.dart';
import '../../../domain/repositories/session_repository.dart';
import '../../../storage/dao/sessions_dao.dart';

class SessionRepositoryImpl implements SessionRepository {
  final SessionsDao _dao;
  SessionRepositoryImpl(this._dao);

  @override
  Future<int> insert(SessionRecord record) => _dao.insert(record);

  @override
  Future<SessionRecord?> forContact(int contactId) => _dao.forContact(contactId);

  @override
  Future<void> update(SessionRecord record) => _dao.update(record);

  @override
  Future<void> deleteForContact(int contactId) => _dao.deleteForContact(contactId);
}
