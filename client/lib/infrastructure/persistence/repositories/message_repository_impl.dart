import '../../../domain/entities/message.dart';
import '../../../domain/repositories/message_repository.dart';
import '../../../storage/dao/messages_dao.dart';

class MessageRepositoryImpl implements MessageRepository {
  final MessagesDao _dao;
  MessageRepositoryImpl(this._dao);

  @override
  Future<int> insert(Message message) => _dao.insert(message);

  @override
  Future<List<Message>> forConversation(String conversationId,
          {int limit = 50, int? beforeId}) =>
      _dao.forConversation(conversationId, limit: limit, beforeId: beforeId);

  @override
  Future<Message?> lastMessage(String conversationId) => _dao.lastMessage(conversationId);

  @override
  Future<Message?> findByMessageId(String messageId) => _dao.findByMessageId(messageId);

  @override
  Future<List<Message>> expiredBefore(int nowSeconds) => _dao.expiredBefore(nowSeconds);

  @override
  Future<void> updateStatus(int id, MessageStatus status) => _dao.updateStatus(id, status);

  @override
  Future<void> setExpiry(int id, int expiresAt) => _dao.setExpiry(id, expiresAt);

  @override
  Future<void> deleteConversation(String conversationId) =>
      _dao.deleteConversation(conversationId);

  @override
  Future<int> deleteById(int id) => _dao.deleteById(id);
}
