import '../../../domain/entities/group.dart';
import '../../../domain/repositories/group_repository.dart';
import '../../../storage/dao/groups_dao.dart';

class GroupRepositoryImpl implements GroupRepository {
  final GroupsDao _dao;
  GroupRepositoryImpl(this._dao);

  @override
  Future<void> insertGroup(Group group) => _dao.insertGroup(group);

  @override
  Future<List<Group>> allGroups() => _dao.allGroups();

  @override
  Future<Group?> findGroup(String groupId) => _dao.findGroup(groupId);

  @override
  Future<void> deleteGroup(String groupId) => _dao.deleteGroup(groupId);

  @override
  Future<void> upsertMember(GroupMember member) => _dao.upsertMember(member);

  @override
  Future<List<GroupMember>> membersOf(String groupId) => _dao.membersOf(groupId);

  @override
  Future<GroupMember?> member(String groupId, String masterPub) =>
      _dao.member(groupId, masterPub);

  @override
  Future<void> removeMember(String groupId, String masterPub) =>
      _dao.removeMember(groupId, masterPub);

  @override
  Future<List<String>> memberPubs(String groupId) => _dao.memberPubs(groupId);
}
