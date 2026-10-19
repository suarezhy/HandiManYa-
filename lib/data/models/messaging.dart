import 'booking.dart';

class Conversation {
  const Conversation({
    required this.id,
    required this.bookingId,
    required this.bookingCode,
    required this.otherName,
    this.lastMessageAt,
    this.lastMessagePreview,
    this.unreadCount = 0,
    required this.bookingStatus,
  });

  final String id;
  final String bookingId;
  final String bookingCode;
  final String otherName;
  final DateTime? lastMessageAt;
  final String? lastMessagePreview;
  final int unreadCount;
  final BookingStatus bookingStatus;

  factory Conversation.fromMap(Map<String, dynamic> m) => Conversation(
    id: m['id'] as String,
    bookingId: m['booking_id'] as String,
    bookingCode: m['booking_code'] as String,
    otherName: m['other_name'] as String,
    lastMessageAt: m['last_message_at'] == null ? null : DateTime.parse(m['last_message_at'] as String),
    lastMessagePreview: m['last_message_preview'] as String?,
    unreadCount: (m['unread_count'] as num?)?.toInt() ?? 0,
    bookingStatus: BookingStatus.parse(m['booking_status'] as String?),
  );
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.senderId,
    this.body,
    this.imagePath,
    required this.createdAt,
  });

  final int id;
  final String conversationId;
  final String senderId;
  final String? body;
  final String? imagePath;
  final DateTime createdAt;

  factory ChatMessage.fromMap(Map<String, dynamic> m) => ChatMessage(
    id: (m['id'] as num).toInt(),
    conversationId: m['conversation_id'] as String,
    senderId: m['sender_id'] as String,
    body: m['body'] as String?,
    imagePath: m['image_path'] as String?,
    createdAt: DateTime.parse(m['created_at'] as String),
  );
}

class AppNotification {
  const AppNotification({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    this.bookingId,
    this.conversationId,
    this.readAt,
    required this.createdAt,
  });

  final int id;
  final String kind;
  final String title;
  final String body;
  final String? bookingId;
  final String? conversationId;
  final DateTime? readAt;
  final DateTime createdAt;

  bool get isRead => readAt != null;

  factory AppNotification.fromMap(Map<String, dynamic> m) {
    final data = Map<String, dynamic>.from((m['data'] as Map?) ?? const {});
    return AppNotification(
      id: (m['id'] as num).toInt(),
      kind: m['kind'] as String,
      title: m['title'] as String,
      body: m['body'] as String? ?? '',
      bookingId: data['booking_id'] as String?,
      conversationId: data['conversation_id'] as String?,
      readAt: m['read_at'] == null ? null : DateTime.parse(m['read_at'] as String),
      createdAt: DateTime.parse(m['created_at'] as String),
    );
  }
}
