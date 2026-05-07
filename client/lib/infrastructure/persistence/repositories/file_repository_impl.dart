import '../../../domain/entities/file_record.dart';
import '../../../domain/repositories/file_repository.dart';
import '../../../storage/dao/files_dao.dart';

class FileRepositoryImpl implements FileRepository {
  final FilesDao _dao;
  FileRepositoryImpl(this._dao);

  @override
  Future<int> insert(FileRecord record) => _dao.insert(record);

  @override
  Future<FileRecord?> forMessage(int messageId) => _dao.forMessage(messageId);

  @override
  Future<void> updateMessageId(int fileId, int messageId) =>
      _dao.updateMessageId(fileId, messageId);

  @override
  Future<void> deleteForMessage(int messageId) => _dao.deleteForMessage(messageId);

  @override
  Future<void> deleteForConversation(String conversationId) =>
      _dao.deleteForConversation(conversationId);

  @override
  Future<void> deleteAll() => _dao.deleteAll();
}
