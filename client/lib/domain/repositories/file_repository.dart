import '../entities/file_record.dart';

/// Abstract repository for encrypted file metadata persistence.
abstract class FileRepository {
  Future<int> insert(FileRecord record);
  Future<FileRecord?> forMessage(int messageId);
  Future<void> updateMessageId(int fileId, int messageId);
  Future<void> deleteForMessage(int messageId);
  Future<void> deleteForConversation(String conversationId);
  Future<void> deleteAll();
}
