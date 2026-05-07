import 'dart:convert';
import 'dart:typed_data';

/// Wire type for group invitation messages.
class GroupInvite {
  final String    groupId;
  final String    name;
  final List<String> members;
  final Uint8List chainKeyBlob; // 72-byte SenderKeys export
  final String    adminPub58;

  const GroupInvite({
    required this.groupId,
    required this.name,
    required this.members,
    required this.chainKeyBlob,
    required this.adminPub58,
  });

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode({
        'type':      'group_invite',
        'group_id':  groupId,
        'name':      name,
        'members':   members,
        'chain_key': base64.encode(chainKeyBlob),
        'admin':     adminPub58,
      })));

  static GroupInvite? tryDecode(Uint8List bytes) {
    try {
      final m = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (m['type'] != 'group_invite') return null;
      return GroupInvite(
        groupId:      m['group_id'] as String,
        name:         m['name']     as String,
        members:      (m['members'] as List).cast<String>(),
        chainKeyBlob: base64.decode(m['chain_key'] as String),
        adminPub58:   m['admin']    as String,
      );
    } catch (_) {
      return null;
    }
  }
}
