import '../entities/message.dart';

/// Abstract repository for message persistence.
abstract class MessageRepository {
  Future<int> insert(Message message);
  Future<List<Message>> forConversation(String conversationId, {int limit = 50, int? beforeId});
  Future<Message?> lastMessage(String conversationId);
  Future<Message?> findByMessageId(String messageId);
  Future<List<Message>> expiredBefore(int nowSeconds);
  Future<void> updateStatus(int id, MessageStatus status);
  Future<void> setExpiry(int id, int expiresAt);
  Future<void> deleteConversation(String conversationId);
  Future<int> deleteById(int id);
}
