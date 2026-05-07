import '../entities/group.dart';

/// Abstract repository for group and group member persistence.
abstract class GroupRepository {
  // Groups
  Future<void> insertGroup(Group group);
  Future<List<Group>> allGroups();
  Future<Group?> findGroup(String groupId);
  Future<void> deleteGroup(String groupId);

  // Members
  Future<void> upsertMember(GroupMember member);
  Future<List<GroupMember>> membersOf(String groupId);
  Future<GroupMember?> member(String groupId, String masterPub);
  Future<void> removeMember(String groupId, String masterPub);
  Future<List<String>> memberPubs(String groupId);
}
