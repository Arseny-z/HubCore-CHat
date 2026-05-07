enum MessageStatus { queued, sent, received, delivered, read }

enum ContentType { text, image, video, audio, file, system }

class Message {
  final int? id;
  final String conversationId; // masterPub for DM, groupId for group
  final bool isGroup;
  final String senderPub;
  final String body; // plaintext (DB is encrypted by SQLCipher)
  final ContentType contentType;
  final int sentAt; // unix seconds
  final int? receivedAt;
  final MessageStatus status;
  final int? expiresAt;   // unix seconds; null = no expiry
  final String? messageId; // hex-8 random ID for delivery receipt correlation
  final String? transport; // 'yggdrasil'|'reticulum'|'meshcore'|null
  final String? replyToId; // messageId of the quoted message

  const Message({
    this.id,
    required this.conversationId,
    required this.isGroup,
    required this.senderPub,
    required this.body,
    this.contentType = ContentType.text,
    required this.sentAt,
    this.receivedAt,
    this.status = MessageStatus.sent,
    this.expiresAt,
    this.messageId,
    this.transport,
    this.replyToId,
  });

  factory Message.fromMap(Map<String, dynamic> m) => Message(
        id: m['id'] as int?,
        conversationId: m['conversation_id'] as String,
        isGroup: (m['is_group'] as int) == 1,
        senderPub: m['sender_pub'] as String,
        body: m['body'] as String,
        contentType: ContentType.values.firstWhere(
          (e) => e.name == (m['content_type'] as String),
          orElse: () => ContentType.text,
        ),
        sentAt: m['sent_at'] as int,
        receivedAt: m['received_at'] as int?,
        status: MessageStatus.values.firstWhere(
          (e) => e.name == (m['status'] as String),
          orElse: () => MessageStatus.sent,
        ),
        expiresAt: m['expires_at'] as int?,
        messageId: m['message_id'] as String?,
        transport: m['transport'] as String?,
        replyToId: m['reply_to_id'] as String?,
      );

  Map<String, dynamic> toMap() => {
        'conversation_id': conversationId,
        'is_group': isGroup ? 1 : 0,
        'sender_pub': senderPub,
        'body': body,
        'content_type': contentType.name,
        'sent_at': sentAt,
        if (receivedAt != null) 'received_at': receivedAt,
        'status': status.name,
        if (expiresAt != null) 'expires_at': expiresAt,
        if (messageId != null) 'message_id': messageId,
        if (transport != null) 'transport': transport,
        if (replyToId != null) 'reply_to_id': replyToId,
      };
}
