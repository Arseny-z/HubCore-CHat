import 'dart:typed_data';

import '../../../domain/entities/envelope.dart';
import '../../../domain/entities/group_post_envelope.dart';
import '../../../domain/ports/crypto_port.dart';
import '../../../domain/repositories/contact_repository.dart';
import '../../../domain/repositories/group_repository.dart';
import '../../../shared/utils/logger.dart';
import '../../../shared/utils/pubkey_codec.dart';

/// Produces fan-out envelopes for a group / channel post under the
/// per-post-wrap scheme.
///
/// The use case is **pure**: it does not touch the DB messages table
/// (callers persist their own placeholder) and does not call the
/// transport — callers iterate the returned envelopes and route them.
class SendGroupPostUseCase {
  final CryptoPort _crypto;
  final ContactRepository _contacts;
  final GroupRepository _groups;
  final String Function() _myMasterPub;

  SendGroupPostUseCase({
    required CryptoPort crypto,
    required ContactRepository contacts,
    required GroupRepository groups,
    required String Function() myMasterPub,
  })  : _crypto = crypto,
        _contacts = contacts,
        _groups = groups,
        _myMasterPub = myMasterPub;

  /// Build per-recipient `Envelope`s for [plaintext] addressed to every
  /// non-banned member of [groupId] (excluding ourselves).
  ///
  /// Returns `(messageId, envelopes)`. [messageId] is generated here so
  /// receivers can dedup and so the caller can persist a placeholder
  /// `Message` with the same id.
  Future<SendGroupPostResult> execute({
    required String groupId,
    required Uint8List plaintext,
    required String messageId,
    int? ttlSeconds,
  }) async {
    final group = await _groups.findGroup(groupId);
    if (group == null) {
      throw StateError('SendGroupPost: unknown group $groupId');
    }

    final memberPubs = await _groups.memberPubs(groupId);
    final myPub = _myMasterPub();

    // Build recipients list: skip ourselves, skip members without
    // X25519 (we cannot wrap a content key for them), skip banned.
    final recipients = <GroupPostRecipient>[];
    for (final pub in memberPubs) {
      if (pub == myPub) continue;
      final member = await _groups.member(groupId, pub);
      if (member?.role == 'banned') continue;
      final contact = await _contacts.findByMasterPub(pub);
      final x25519PubB58 = contact?.x25519Pub;
      if (x25519PubB58 == null || x25519PubB58.isEmpty) {
        AppLogger.w('SendGroupPost', 'skipping $pub — no x25519 pub on contact');
        continue;
      }
      recipients.add(GroupPostRecipient(
        masterPub58: pub,
        x25519Pub:   PubkeyCodec.decode(x25519PubB58),
      ));
    }

    if (recipients.isEmpty) {
      AppLogger.w('SendGroupPost', 'no recipients for $groupId (solo group?)');
      return SendGroupPostResult(messageId: messageId, envelopes: const []);
    }

    final epoch = group.epoch;
    final build = await _crypto.encryptGroupPost(
      groupId:    groupId,
      epoch:      epoch,
      messageId:  messageId,
      plaintext:  plaintext,
      recipients: recipients,
      ttlSeconds: ttlSeconds,
    );

    final envelopes = build.envelopes
        .map((e) => Envelope(
              from: myPub,
              to:   e.to,
              body: e.envelope.encode(),
            ))
        .toList();

    return SendGroupPostResult(
      messageId: messageId,
      envelopes: envelopes,
    );
  }
}

class SendGroupPostResult {
  final String messageId;
  final List<Envelope> envelopes;
  const SendGroupPostResult({required this.messageId, required this.envelopes});
}
