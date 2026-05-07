import '../entities/contact.dart';

/// Abstract repository for contact persistence.
///
/// Domain code depends on this interface, never on DAO or SQLite directly.
/// Implemented in [ContactRepositoryImpl] (infrastructure/persistence/).
abstract class ContactRepository {
  Future<Contact?> findByMasterPub(String masterPub);
  Future<List<Contact>> all();
  Future<int> insert(Contact contact);
  Future<void> updateAlias(String masterPub, String alias);
  Future<void> updateSigningPub(String masterPub, String newSigningPub);
  Future<void> updateX25519Pub(String masterPub, String x25519Pub);
  Future<void> updateYggPubKey(String masterPub, String yggPubKeyHex);
  Future<void> updateTransportAddress(String masterPub, String protocol, String address);
  Future<void> touchLastSeen(String masterPub);
  Future<void> delete(String masterPub);
}
