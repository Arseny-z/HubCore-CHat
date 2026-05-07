import '../../../domain/entities/contact.dart';
import '../../../domain/repositories/contact_repository.dart';
import '../../../storage/dao/contacts_dao.dart';

class ContactRepositoryImpl implements ContactRepository {
  final ContactsDao _dao;
  ContactRepositoryImpl(this._dao);

  @override
  Future<Contact?> findByMasterPub(String masterPub) => _dao.findByMasterPub(masterPub);

  @override
  Future<List<Contact>> all() => _dao.all();

  @override
  Future<int> insert(Contact contact) => _dao.insert(contact);

  @override
  Future<void> updateAlias(String masterPub, String alias) =>
      _dao.updateAlias(masterPub, alias);

  @override
  Future<void> updateSigningPub(String masterPub, String newSigningPub) =>
      _dao.updateSigningPub(masterPub, newSigningPub);

  @override
  Future<void> updateX25519Pub(String masterPub, String x25519Pub) =>
      _dao.updateX25519Pub(masterPub, x25519Pub);

  @override
  Future<void> updateYggPubKey(String masterPub, String yggPubKeyHex) =>
      _dao.updateYggPubKey(masterPub, yggPubKeyHex);

  @override
  Future<void> updateTransportAddress(String masterPub, String protocol, String address) =>
      _dao.updateTransportAddress(masterPub, protocol, address);

  @override
  Future<void> touchLastSeen(String masterPub) => _dao.touchLastSeen(masterPub);

  @override
  Future<void> delete(String masterPub) => _dao.delete(masterPub);
}
