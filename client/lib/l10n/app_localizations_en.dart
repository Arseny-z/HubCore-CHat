// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'HubCore Chat';

  @override
  String get cancel => 'Cancel';

  @override
  String get save => 'Save';

  @override
  String get delete => 'Delete';

  @override
  String get close => 'Close';

  @override
  String get copied => 'Copied';

  @override
  String get dismiss => 'Dismiss';

  @override
  String get continueAction => 'Continue';

  @override
  String get fingerprint => 'Fingerprint';

  @override
  String get publicKeyBase58 => 'Public Key (base58)';

  @override
  String get yesterday => 'Yesterday';

  @override
  String get today => 'Today';

  @override
  String get selectFromGallery => 'Select from gallery';

  @override
  String get takePhoto => 'Take photo';

  @override
  String get deletePhoto => 'Delete photo';

  @override
  String get myQrCode => 'My QR Code';

  @override
  String get networkStatus => 'Network Status';

  @override
  String get yggdrasilReticulum => 'Yggdrasil, Reticulum';

  @override
  String get mediaAudio => '🎤 Audio';

  @override
  String get mediaVideoCircle => '⭕ Video circle';

  @override
  String get mediaPhoto => '🖼 Photo';

  @override
  String get selectFileType => 'Select file type';

  @override
  String get photoVideo => 'Photo / Video';

  @override
  String get document => 'Document';

  @override
  String get deliveryStatus => 'Delivery status';

  @override
  String get deliveryStatusSent => 'Sent';

  @override
  String get deliveryStatusDelivered => 'Delivered';

  @override
  String get deliveryStatusRead => 'Read';

  @override
  String get noDeliveryInfo => 'No delivery info';

  @override
  String get noMessages => 'No messages yet';

  @override
  String get onboardingSubtitle =>
      'Private messenger. No phone number. No servers.';

  @override
  String get featureE2eTitle => 'End-to-end encrypted';

  @override
  String get featureE2eSubtitle => 'Messages are encrypted with Double Ratchet';

  @override
  String get featureP2pTitle => 'Peer-to-peer network';

  @override
  String get featureP2pSubtitle => 'Built on Yggdrasil — no central server';

  @override
  String get featureNoRegTitle => 'No registration';

  @override
  String get featureNoRegSubtitle =>
      'Your identity is a cryptographic key pair';

  @override
  String get createIdentity => 'Create Identity';

  @override
  String get keyLocalWarning =>
      'Your keys are generated locally and never leave your device.';

  @override
  String get setPinTitle => 'Set PIN';

  @override
  String get confirmPinTitle => 'Confirm PIN';

  @override
  String get enterPinTitle => 'Enter PIN';

  @override
  String get setPinSubtitle => 'Create a PIN to protect your messages';

  @override
  String get confirmPinSubtitle => 'Re-enter your PIN to confirm';

  @override
  String get unlockSubtitle => 'Unlock HubCore Chat';

  @override
  String get pinsDoNotMatch => 'PINs do not match';

  @override
  String get wrongPin => 'Wrong PIN';

  @override
  String wrongPinAttemptsLeft(int remaining) {
    String _temp0 = intl.Intl.pluralLogic(
      remaining,
      locale: localeName,
      other: 'Wrong PIN — $remaining attempts left',
      one: 'Wrong PIN — $remaining attempt left',
    );
    return '$_temp0';
  }

  @override
  String failedAttemptsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count failed attempts',
      one: '$count failed attempt',
    );
    return '$_temp0';
  }

  @override
  String get keyMismatchTitle => 'Key mismatch';

  @override
  String get keyMismatchContent =>
      'Database is encrypted with a different key. This happens after device reinstall or recovery.\n\nDelete data and start fresh?';

  @override
  String get resetButton => 'Reset';

  @override
  String get profileSetupTitle => 'What\'s your name?';

  @override
  String get profileSetupSubtitle =>
      'Your nickname and avatar will be visible to your contacts. You can skip.';

  @override
  String get nicknameHint => 'Your nickname (optional)';

  @override
  String get tabChats => 'Chats';

  @override
  String get tabContacts => 'Contacts';

  @override
  String get tabProfile => 'Profile';

  @override
  String get tabSettings => 'Settings';

  @override
  String get pressAgainToExit => 'Press again to exit';

  @override
  String get searchChats => 'Search chats…';

  @override
  String get searchMessages => 'Search messages';

  @override
  String get newGroup => 'New group';

  @override
  String noChatMatchingQuery(String query) {
    return 'No chats matching \"$query\"';
  }

  @override
  String get emptyChatsTitle => 'No chats yet';

  @override
  String get emptyChatsSubtitle =>
      'Add a contact via QR code\nor share your code';

  @override
  String get addContactButton => 'Add contact';

  @override
  String get deleteChatTitle => 'Delete chat?';

  @override
  String deleteChatContent(String name) {
    return 'All messages with \"$name\" will be deleted.';
  }

  @override
  String get noContactsYet => 'No contacts yet';

  @override
  String get tapPlusToAdd => 'Tap + to add someone';

  @override
  String get myProfile => 'My Profile';

  @override
  String get shareQrToAddContacts => 'Share QR to add contacts';

  @override
  String get yourNickname => 'Your nickname';

  @override
  String get searchMessagesTitle => 'Search messages…';

  @override
  String get nothingFound => 'Nothing found';

  @override
  String get youPrefix => 'You: ';

  @override
  String get addContactTitle => 'Add Contact';

  @override
  String get shareYourKey => 'Share your key';

  @override
  String get contactKeyLabel => 'Contact key';

  @override
  String get fromFile => 'From file';

  @override
  String get pasteKeyHint => 'base58 key or contact JSON';

  @override
  String get pasteFromClipboard => 'Paste from clipboard';

  @override
  String get contactNameHint => 'Contact name (optional)';

  @override
  String get qrCodeNotFound => 'QR code not found in image';

  @override
  String get invalidPublicKey => 'Invalid public key';

  @override
  String get sendMessage => 'Send Message';

  @override
  String get clearChatHistory => 'Clear Chat History';

  @override
  String get clearChatTitle => 'Clear chat history?';

  @override
  String clearChatContent(String name) {
    return 'All messages and files with $name will be deleted. Keys and sessions are not affected.';
  }

  @override
  String get chatHistoryCleared => 'Chat history cleared';

  @override
  String get deleteContactTitle => 'Delete contact?';

  @override
  String deleteContactContent(String name) {
    return 'Remove $name from your contacts? Messages will not be deleted.';
  }

  @override
  String get messageHint => 'Message';

  @override
  String get chatInitializing => 'App is still initializing. Wait a second.';

  @override
  String get contactNotFoundError =>
      'Contact not found. Try exchanging QR codes again.';

  @override
  String get noSessionError =>
      'No session established. Wait for the contact to come online.';

  @override
  String get databaseError => 'Database unavailable. Restart the app.';

  @override
  String get networkErrorQueued =>
      'Network error. Message queued and will be sent automatically.';

  @override
  String get sendError => 'Failed to send. Try again.';

  @override
  String get reply => 'Reply';

  @override
  String get forward => 'Forward';

  @override
  String get forwardTo => 'Forward to…';

  @override
  String get messageForwarded => 'Message forwarded';

  @override
  String get muteNotifications => 'Mute';

  @override
  String get unmuteNotifications => 'Enable notifications';

  @override
  String get autoDeleteOff => 'Auto-delete off';

  @override
  String autoDeleteLabel(String duration) {
    return 'Auto-delete: $duration';
  }

  @override
  String get autoDelete1Min => '1 minute';

  @override
  String get autoDelete1Hour => '1 hour';

  @override
  String get autoDelete1Day => '1 day';

  @override
  String get autoDelete1Week => '1 week';

  @override
  String get autoDeleteDisabled => 'Off';

  @override
  String get deleteLocally => 'Delete locally';

  @override
  String get deleteForAll => 'Delete for all';

  @override
  String get deleteCancelSend => 'Delete (cancel send)';

  @override
  String get copyText => 'Copy';

  @override
  String sendAttempt(int current, int max) {
    return 'Attempt $current/$max';
  }

  @override
  String get lastSeenRecently => 'last seen recently';

  @override
  String lastSeenMinutesAgo(int m) {
    return 'last seen $m min ago';
  }

  @override
  String lastSeenHoursAgo(int h) {
    return 'last seen ${h}h ago';
  }

  @override
  String get lastSeenYesterday => 'last seen yesterday';

  @override
  String lastSeenDaysAgo(int d) {
    return 'last seen $d days ago';
  }

  @override
  String fileTooLarge(int mb) {
    return 'File too large (max $mb MB)';
  }

  @override
  String get groupLabel => 'Group';

  @override
  String get noMessagesHint => 'No messages yet\nPull to refresh';

  @override
  String get monthJan => 'January';

  @override
  String get monthFeb => 'February';

  @override
  String get monthMar => 'March';

  @override
  String get monthApr => 'April';

  @override
  String get monthMay => 'May';

  @override
  String get monthJun => 'June';

  @override
  String get monthJul => 'July';

  @override
  String get monthAug => 'August';

  @override
  String get monthSep => 'September';

  @override
  String get monthOct => 'October';

  @override
  String get monthNov => 'November';

  @override
  String get monthDec => 'December';

  @override
  String get newGroupTitle => 'New Group';

  @override
  String get groupNameHint => 'Group name';

  @override
  String get selectMembersLabel => 'Select members';

  @override
  String get noContactsToAdd => 'No contacts to add';

  @override
  String get enterGroupName => 'Enter a group name';

  @override
  String get selectAtLeastOneMember => 'Select at least one member';

  @override
  String get messagingNotReady => 'Messaging not ready';

  @override
  String createGroupButton(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Create ($count members)',
      one: 'Create (1 member)',
    );
    return '$_temp0';
  }

  @override
  String membersCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count members',
      one: '1 member',
    );
    return '$_temp0';
  }

  @override
  String get notGroupMember => 'You are no longer a member of this group';

  @override
  String get leaveGroup => 'Leave group';

  @override
  String get leaveGroupTitle => 'Leave group?';

  @override
  String get leaveGroupContent =>
      'You will no longer receive messages from this group.';

  @override
  String get groupManagement => 'Group management';

  @override
  String get youInGroup => 'you';

  @override
  String get noData => 'No data';

  @override
  String get renameGroup => 'Rename group';

  @override
  String get addMember => 'Add member';

  @override
  String get noAvailableContacts => 'No available contacts to add';

  @override
  String get invitationSent => 'Invitation sent';

  @override
  String get removeMemberTitle => 'Remove member?';

  @override
  String removeMemberContent(String name) {
    return '$name will be removed from the group.';
  }

  @override
  String get deleteGroupTitle => 'Delete group?';

  @override
  String get deleteGroupContent =>
      'The group will be deleted for all members. This action cannot be undone.';

  @override
  String get groupRenamed => 'Group renamed';

  @override
  String memberRemovedMessage(String name) {
    return '$name removed from group';
  }

  @override
  String get unnamedGroup => 'Unnamed';

  @override
  String get tapToRename => 'Tap to rename';

  @override
  String adminLabel(String name) {
    return 'Admin: $name';
  }

  @override
  String get settingsTitle => 'Settings';

  @override
  String get sectionIdentity => 'Identity';

  @override
  String get rotateSigningKey => 'Rotate Signing Key';

  @override
  String get rotateSigningKeyDesc =>
      'Issue a new signing key certified by master';

  @override
  String get fingerprintCopied => 'Fingerprint copied';

  @override
  String get publicKeyCopied => 'Public key copied';

  @override
  String get signingKeyRotated => 'Signing key rotated';

  @override
  String get sectionNetwork => 'Network';

  @override
  String get sectionBackup => 'Backup & Restore';

  @override
  String get exportBackup => 'Export Identity Backup';

  @override
  String get exportBackupDesc => 'Save encrypted backup file';

  @override
  String get importBackup => 'Import Identity Backup';

  @override
  String get importBackupDesc => 'Restore identity from backup file';

  @override
  String get sectionSecurity => 'Security';

  @override
  String get softwareKeystore => 'Software Keystore';

  @override
  String get softwareKeystoreDesc =>
      'Android 8 does not guarantee hardware key protection. Android 9+ recommended.';

  @override
  String get duressPin => 'Duress PIN';

  @override
  String get duressPinDesc => 'Silent wipe PIN — entering it erases all data';

  @override
  String get wipeAllData => 'Wipe All Data';

  @override
  String get wipeAllDataDesc => 'Irreversibly delete all keys and messages';

  @override
  String get backupPassword => 'Backup Password';

  @override
  String get importBackupDialogTitle => 'Import Identity Backup?';

  @override
  String get importBackupDialogContent =>
      'This will replace your current identity. Messages and contacts are NOT restored.';

  @override
  String get enterPassword => 'Enter password';

  @override
  String get identityNotLoaded => 'Identity not loaded';

  @override
  String get sodiumNotReady => 'Sodium not ready';

  @override
  String backupSavedTo(String path) {
    return 'Backup saved to: $path';
  }

  @override
  String exportFailed(String error) {
    return 'Export failed: $error';
  }

  @override
  String importFailed(String error) {
    return 'Import failed: $error';
  }

  @override
  String get identityRestored => 'Identity restored. Please restart the app.';

  @override
  String get appNotUnlocked => 'App not unlocked';

  @override
  String get duressPinSet => 'Duress PIN set';

  @override
  String get duressPinRemoved => 'Duress PIN removed';

  @override
  String get wrongCurrentPin => 'Wrong current PIN';

  @override
  String get enterCurrentPin => 'Enter current PIN';

  @override
  String get setDuressPin => 'Set duress PIN';

  @override
  String get confirmDuressPin => 'Confirm duress PIN';

  @override
  String get pinConfirmIdentity =>
      'Confirm your identity before changing security settings';

  @override
  String get duressPinSetHelp =>
      'This PIN silently wipes all data when entered at unlock';

  @override
  String get duressPinConfirmHelp => 'Re-enter duress PIN to confirm';

  @override
  String get duressMustDiffer => 'Duress PIN must differ from your unlock PIN';

  @override
  String get removeDuressPin => 'Remove duress PIN';

  @override
  String get wipeAllDataTitle => 'Wipe All Data?';

  @override
  String get wipeAllDataContent =>
      'This will permanently delete your identity key, all messages, and contacts. This cannot be undone.';

  @override
  String get wipeButton => 'Wipe';

  @override
  String get retryInterval => 'Retry interval';

  @override
  String get maxAttempts => 'Max send attempts';

  @override
  String get networkSettingsTitle => 'Network Settings';

  @override
  String get peersList => 'Peers list';

  @override
  String get trustedPeersOnly => 'Trusted peers only';

  @override
  String get trustedPeersOnlyDesc =>
      'Only contacts\' Yggdrasil keys can peer inbound';

  @override
  String get allInboundAllowed => 'All inbound peering allowed (default)';

  @override
  String get trustedPeersModeOn =>
      'Trusted-peers mode on. Add contacts to populate the whitelist.';

  @override
  String get lanDiscoveryPassword => 'LAN discovery password';

  @override
  String get openDiscovery => 'Open — any device on LAN is discovered';

  @override
  String get protectedDiscovery =>
      'Protected — only devices with same password';

  @override
  String get wifiLanDiscovery => 'WiFi LAN Discovery';

  @override
  String get autoInterface => 'AutoInterface (mDNS)';

  @override
  String get autoInterfaceDesc => 'Device discovery on local network';

  @override
  String get tcpTransportNodes => 'TCP Transport Nodes';

  @override
  String get tcpTransportDesc =>
      'Connection to RNS transport nodes over internet. At least one needed for mobile networks.';

  @override
  String get builtIn => 'Built-in';

  @override
  String get addTransportNode => 'Add transport node';

  @override
  String get rnsTransportNode => 'RNS Transport Node';

  @override
  String get addNodeHint => 'host:port (e.g. 1.2.3.4:4242)';

  @override
  String get reticulumViaYgg => 'Reticulum via Yggdrasil';

  @override
  String get addYggRnsNode => 'Add Yggdrasil RNS node';

  @override
  String get restartReticulum => 'Restart Reticulum';

  @override
  String get addPeer => 'Add peer';

  @override
  String get addYggPeer => 'Add Yggdrasil peer';

  @override
  String get peerPriority => 'Peer Priority (1–255)';

  @override
  String get priority => 'Priority';

  @override
  String get lanDiscoveryPasswordTitle => 'LAN Discovery Password';

  @override
  String get openDiscoveryHint => 'Leave empty for open discovery';

  @override
  String get ddns => 'DDNS';

  @override
  String get ddnsProvider => 'Provider';

  @override
  String get ddnsDomain => 'Domain';

  @override
  String get ddnsToken => 'Token / API key';

  @override
  String get peerAddress => 'Peer address';

  @override
  String get peerModeHelp =>
      '⚠ White IP or port forwarding on router needed for peer mode.';

  @override
  String get publicPeerMode => 'Public peer mode';

  @override
  String get publicPeerModeDesc =>
      'Phone accepts inbound Yggdrasil connections';

  @override
  String get wifiOnly => 'WiFi only';

  @override
  String get disableOnMobile => 'Disable peer mode on mobile network';

  @override
  String get port => 'Port';

  @override
  String get notSet => 'Not set';

  @override
  String get addressCopied => 'Address copied';

  @override
  String notImplementedYet(String name) {
    return '$name — not implemented yet';
  }

  @override
  String get networkStatusTitle => 'Network Status';

  @override
  String get yggdrasilNode => 'Yggdrasil Node';

  @override
  String get myAddress => 'My Address';

  @override
  String get nodePublicKey => 'Node Public Key';

  @override
  String get listeningInbound => 'Listening (inbound peers)';

  @override
  String peersConnectedCount(int up, int total) {
    return 'Peers ($up/$total up)';
  }

  @override
  String get noPeersConnected => 'No peers connected';

  @override
  String activeSessionsCount(int count) {
    return 'Active Sessions ($count)';
  }

  @override
  String get inbound => 'inbound';

  @override
  String get outbound => 'outbound';
}
