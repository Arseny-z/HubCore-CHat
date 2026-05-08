import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ru.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ru'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'HubCore Chat'**
  String get appTitle;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @copied.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get copied;

  /// No description provided for @dismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get dismiss;

  /// No description provided for @continueAction.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get continueAction;

  /// No description provided for @fingerprint.
  ///
  /// In en, this message translates to:
  /// **'Fingerprint'**
  String get fingerprint;

  /// No description provided for @publicKeyBase58.
  ///
  /// In en, this message translates to:
  /// **'Public Key (base58)'**
  String get publicKeyBase58;

  /// No description provided for @yesterday.
  ///
  /// In en, this message translates to:
  /// **'Yesterday'**
  String get yesterday;

  /// No description provided for @today.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get today;

  /// No description provided for @selectFromGallery.
  ///
  /// In en, this message translates to:
  /// **'Select from gallery'**
  String get selectFromGallery;

  /// No description provided for @takePhoto.
  ///
  /// In en, this message translates to:
  /// **'Take photo'**
  String get takePhoto;

  /// No description provided for @deletePhoto.
  ///
  /// In en, this message translates to:
  /// **'Delete photo'**
  String get deletePhoto;

  /// No description provided for @myQrCode.
  ///
  /// In en, this message translates to:
  /// **'My QR Code'**
  String get myQrCode;

  /// No description provided for @networkStatus.
  ///
  /// In en, this message translates to:
  /// **'Network Status'**
  String get networkStatus;

  /// No description provided for @yggdrasilReticulum.
  ///
  /// In en, this message translates to:
  /// **'Yggdrasil, Reticulum'**
  String get yggdrasilReticulum;

  /// No description provided for @mediaAudio.
  ///
  /// In en, this message translates to:
  /// **'🎤 Audio'**
  String get mediaAudio;

  /// No description provided for @mediaVideoCircle.
  ///
  /// In en, this message translates to:
  /// **'⭕ Video circle'**
  String get mediaVideoCircle;

  /// No description provided for @mediaPhoto.
  ///
  /// In en, this message translates to:
  /// **'🖼 Photo'**
  String get mediaPhoto;

  /// No description provided for @selectFileType.
  ///
  /// In en, this message translates to:
  /// **'Select file type'**
  String get selectFileType;

  /// No description provided for @photoVideo.
  ///
  /// In en, this message translates to:
  /// **'Photo / Video'**
  String get photoVideo;

  /// No description provided for @document.
  ///
  /// In en, this message translates to:
  /// **'Document'**
  String get document;

  /// No description provided for @deliveryStatus.
  ///
  /// In en, this message translates to:
  /// **'Delivery status'**
  String get deliveryStatus;

  /// No description provided for @deliveryStatusSent.
  ///
  /// In en, this message translates to:
  /// **'Sent'**
  String get deliveryStatusSent;

  /// No description provided for @deliveryStatusDelivered.
  ///
  /// In en, this message translates to:
  /// **'Delivered'**
  String get deliveryStatusDelivered;

  /// No description provided for @deliveryStatusRead.
  ///
  /// In en, this message translates to:
  /// **'Read'**
  String get deliveryStatusRead;

  /// No description provided for @noDeliveryInfo.
  ///
  /// In en, this message translates to:
  /// **'No delivery info'**
  String get noDeliveryInfo;

  /// No description provided for @noMessages.
  ///
  /// In en, this message translates to:
  /// **'No messages yet'**
  String get noMessages;

  /// No description provided for @onboardingSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Private messenger. No phone number. No servers.'**
  String get onboardingSubtitle;

  /// No description provided for @featureE2eTitle.
  ///
  /// In en, this message translates to:
  /// **'End-to-end encrypted'**
  String get featureE2eTitle;

  /// No description provided for @featureE2eSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Messages are encrypted with Double Ratchet'**
  String get featureE2eSubtitle;

  /// No description provided for @featureP2pTitle.
  ///
  /// In en, this message translates to:
  /// **'Peer-to-peer network'**
  String get featureP2pTitle;

  /// No description provided for @featureP2pSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Built on Yggdrasil — no central server'**
  String get featureP2pSubtitle;

  /// No description provided for @featureNoRegTitle.
  ///
  /// In en, this message translates to:
  /// **'No registration'**
  String get featureNoRegTitle;

  /// No description provided for @featureNoRegSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Your identity is a cryptographic key pair'**
  String get featureNoRegSubtitle;

  /// No description provided for @createIdentity.
  ///
  /// In en, this message translates to:
  /// **'Create Identity'**
  String get createIdentity;

  /// No description provided for @keyLocalWarning.
  ///
  /// In en, this message translates to:
  /// **'Your keys are generated locally and never leave your device.'**
  String get keyLocalWarning;

  /// No description provided for @setPinTitle.
  ///
  /// In en, this message translates to:
  /// **'Set PIN'**
  String get setPinTitle;

  /// No description provided for @confirmPinTitle.
  ///
  /// In en, this message translates to:
  /// **'Confirm PIN'**
  String get confirmPinTitle;

  /// No description provided for @enterPinTitle.
  ///
  /// In en, this message translates to:
  /// **'Enter PIN'**
  String get enterPinTitle;

  /// No description provided for @setPinSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Create a PIN to protect your messages'**
  String get setPinSubtitle;

  /// No description provided for @confirmPinSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Re-enter your PIN to confirm'**
  String get confirmPinSubtitle;

  /// No description provided for @unlockSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Unlock HubCore Chat'**
  String get unlockSubtitle;

  /// No description provided for @pinsDoNotMatch.
  ///
  /// In en, this message translates to:
  /// **'PINs do not match'**
  String get pinsDoNotMatch;

  /// No description provided for @wrongPin.
  ///
  /// In en, this message translates to:
  /// **'Wrong PIN'**
  String get wrongPin;

  /// No description provided for @wrongPinAttemptsLeft.
  ///
  /// In en, this message translates to:
  /// **'{remaining, plural, one{Wrong PIN — {remaining} attempt left} other{Wrong PIN — {remaining} attempts left}}'**
  String wrongPinAttemptsLeft(int remaining);

  /// No description provided for @failedAttemptsCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{{count} failed attempt} other{{count} failed attempts}}'**
  String failedAttemptsCount(int count);

  /// No description provided for @keyMismatchTitle.
  ///
  /// In en, this message translates to:
  /// **'Key mismatch'**
  String get keyMismatchTitle;

  /// No description provided for @keyMismatchContent.
  ///
  /// In en, this message translates to:
  /// **'Database is encrypted with a different key. This happens after device reinstall or recovery.\n\nDelete data and start fresh?'**
  String get keyMismatchContent;

  /// No description provided for @resetButton.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get resetButton;

  /// No description provided for @profileSetupTitle.
  ///
  /// In en, this message translates to:
  /// **'What\'s your name?'**
  String get profileSetupTitle;

  /// No description provided for @profileSetupSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Your nickname and avatar will be visible to your contacts. You can skip.'**
  String get profileSetupSubtitle;

  /// No description provided for @nicknameHint.
  ///
  /// In en, this message translates to:
  /// **'Your nickname (optional)'**
  String get nicknameHint;

  /// No description provided for @tabChats.
  ///
  /// In en, this message translates to:
  /// **'Chats'**
  String get tabChats;

  /// No description provided for @tabContacts.
  ///
  /// In en, this message translates to:
  /// **'Contacts'**
  String get tabContacts;

  /// No description provided for @tabProfile.
  ///
  /// In en, this message translates to:
  /// **'Profile'**
  String get tabProfile;

  /// No description provided for @tabSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get tabSettings;

  /// No description provided for @pressAgainToExit.
  ///
  /// In en, this message translates to:
  /// **'Press again to exit'**
  String get pressAgainToExit;

  /// No description provided for @searchChats.
  ///
  /// In en, this message translates to:
  /// **'Search chats…'**
  String get searchChats;

  /// No description provided for @searchMessages.
  ///
  /// In en, this message translates to:
  /// **'Search messages'**
  String get searchMessages;

  /// No description provided for @newGroup.
  ///
  /// In en, this message translates to:
  /// **'New group'**
  String get newGroup;

  /// No description provided for @noChatMatchingQuery.
  ///
  /// In en, this message translates to:
  /// **'No chats matching \"{query}\"'**
  String noChatMatchingQuery(String query);

  /// No description provided for @emptyChatsTitle.
  ///
  /// In en, this message translates to:
  /// **'No chats yet'**
  String get emptyChatsTitle;

  /// No description provided for @emptyChatsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Add a contact via QR code\nor share your code'**
  String get emptyChatsSubtitle;

  /// No description provided for @addContactButton.
  ///
  /// In en, this message translates to:
  /// **'Add contact'**
  String get addContactButton;

  /// No description provided for @deleteChatTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete chat?'**
  String get deleteChatTitle;

  /// No description provided for @deleteChatContent.
  ///
  /// In en, this message translates to:
  /// **'All messages with \"{name}\" will be deleted.'**
  String deleteChatContent(String name);

  /// No description provided for @noContactsYet.
  ///
  /// In en, this message translates to:
  /// **'No contacts yet'**
  String get noContactsYet;

  /// No description provided for @tapPlusToAdd.
  ///
  /// In en, this message translates to:
  /// **'Tap + to add someone'**
  String get tapPlusToAdd;

  /// No description provided for @myProfile.
  ///
  /// In en, this message translates to:
  /// **'My Profile'**
  String get myProfile;

  /// No description provided for @shareQrToAddContacts.
  ///
  /// In en, this message translates to:
  /// **'Share QR to add contacts'**
  String get shareQrToAddContacts;

  /// No description provided for @yourNickname.
  ///
  /// In en, this message translates to:
  /// **'Your nickname'**
  String get yourNickname;

  /// No description provided for @searchMessagesTitle.
  ///
  /// In en, this message translates to:
  /// **'Search messages…'**
  String get searchMessagesTitle;

  /// No description provided for @nothingFound.
  ///
  /// In en, this message translates to:
  /// **'Nothing found'**
  String get nothingFound;

  /// No description provided for @youPrefix.
  ///
  /// In en, this message translates to:
  /// **'You: '**
  String get youPrefix;

  /// No description provided for @addContactTitle.
  ///
  /// In en, this message translates to:
  /// **'Add Contact'**
  String get addContactTitle;

  /// No description provided for @shareYourKey.
  ///
  /// In en, this message translates to:
  /// **'Share your key'**
  String get shareYourKey;

  /// No description provided for @contactKeyLabel.
  ///
  /// In en, this message translates to:
  /// **'Contact key'**
  String get contactKeyLabel;

  /// No description provided for @fromFile.
  ///
  /// In en, this message translates to:
  /// **'From file'**
  String get fromFile;

  /// No description provided for @pasteKeyHint.
  ///
  /// In en, this message translates to:
  /// **'base58 key or contact JSON'**
  String get pasteKeyHint;

  /// No description provided for @pasteFromClipboard.
  ///
  /// In en, this message translates to:
  /// **'Paste from clipboard'**
  String get pasteFromClipboard;

  /// No description provided for @contactNameHint.
  ///
  /// In en, this message translates to:
  /// **'Contact name (optional)'**
  String get contactNameHint;

  /// No description provided for @qrCodeNotFound.
  ///
  /// In en, this message translates to:
  /// **'QR code not found in image'**
  String get qrCodeNotFound;

  /// No description provided for @invalidPublicKey.
  ///
  /// In en, this message translates to:
  /// **'Invalid public key'**
  String get invalidPublicKey;

  /// No description provided for @sendMessage.
  ///
  /// In en, this message translates to:
  /// **'Send Message'**
  String get sendMessage;

  /// No description provided for @clearChatHistory.
  ///
  /// In en, this message translates to:
  /// **'Clear Chat History'**
  String get clearChatHistory;

  /// No description provided for @clearChatTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear chat history?'**
  String get clearChatTitle;

  /// No description provided for @clearChatContent.
  ///
  /// In en, this message translates to:
  /// **'All messages and files with {name} will be deleted. Keys and sessions are not affected.'**
  String clearChatContent(String name);

  /// No description provided for @chatHistoryCleared.
  ///
  /// In en, this message translates to:
  /// **'Chat history cleared'**
  String get chatHistoryCleared;

  /// No description provided for @deleteContactTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete contact?'**
  String get deleteContactTitle;

  /// No description provided for @deleteContactContent.
  ///
  /// In en, this message translates to:
  /// **'Remove {name} from your contacts? Messages will not be deleted.'**
  String deleteContactContent(String name);

  /// No description provided for @messageHint.
  ///
  /// In en, this message translates to:
  /// **'Message'**
  String get messageHint;

  /// No description provided for @chatInitializing.
  ///
  /// In en, this message translates to:
  /// **'App is still initializing. Wait a second.'**
  String get chatInitializing;

  /// No description provided for @contactNotFoundError.
  ///
  /// In en, this message translates to:
  /// **'Contact not found. Try exchanging QR codes again.'**
  String get contactNotFoundError;

  /// No description provided for @noSessionError.
  ///
  /// In en, this message translates to:
  /// **'No session established. Wait for the contact to come online.'**
  String get noSessionError;

  /// No description provided for @databaseError.
  ///
  /// In en, this message translates to:
  /// **'Database unavailable. Restart the app.'**
  String get databaseError;

  /// No description provided for @networkErrorQueued.
  ///
  /// In en, this message translates to:
  /// **'Network error. Message queued and will be sent automatically.'**
  String get networkErrorQueued;

  /// No description provided for @sendError.
  ///
  /// In en, this message translates to:
  /// **'Failed to send. Try again.'**
  String get sendError;

  /// No description provided for @reply.
  ///
  /// In en, this message translates to:
  /// **'Reply'**
  String get reply;

  /// No description provided for @forward.
  ///
  /// In en, this message translates to:
  /// **'Forward'**
  String get forward;

  /// No description provided for @forwardTo.
  ///
  /// In en, this message translates to:
  /// **'Forward to…'**
  String get forwardTo;

  /// No description provided for @messageForwarded.
  ///
  /// In en, this message translates to:
  /// **'Message forwarded'**
  String get messageForwarded;

  /// No description provided for @muteNotifications.
  ///
  /// In en, this message translates to:
  /// **'Mute'**
  String get muteNotifications;

  /// No description provided for @unmuteNotifications.
  ///
  /// In en, this message translates to:
  /// **'Enable notifications'**
  String get unmuteNotifications;

  /// No description provided for @autoDeleteOff.
  ///
  /// In en, this message translates to:
  /// **'Auto-delete off'**
  String get autoDeleteOff;

  /// No description provided for @autoDeleteLabel.
  ///
  /// In en, this message translates to:
  /// **'Auto-delete: {duration}'**
  String autoDeleteLabel(String duration);

  /// No description provided for @autoDelete1Min.
  ///
  /// In en, this message translates to:
  /// **'1 minute'**
  String get autoDelete1Min;

  /// No description provided for @autoDelete1Hour.
  ///
  /// In en, this message translates to:
  /// **'1 hour'**
  String get autoDelete1Hour;

  /// No description provided for @autoDelete1Day.
  ///
  /// In en, this message translates to:
  /// **'1 day'**
  String get autoDelete1Day;

  /// No description provided for @autoDelete1Week.
  ///
  /// In en, this message translates to:
  /// **'1 week'**
  String get autoDelete1Week;

  /// No description provided for @autoDeleteDisabled.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get autoDeleteDisabled;

  /// No description provided for @deleteLocally.
  ///
  /// In en, this message translates to:
  /// **'Delete locally'**
  String get deleteLocally;

  /// No description provided for @deleteForAll.
  ///
  /// In en, this message translates to:
  /// **'Delete for all'**
  String get deleteForAll;

  /// No description provided for @deleteCancelSend.
  ///
  /// In en, this message translates to:
  /// **'Delete (cancel send)'**
  String get deleteCancelSend;

  /// No description provided for @copyText.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copyText;

  /// No description provided for @sendAttempt.
  ///
  /// In en, this message translates to:
  /// **'Attempt {current}/{max}'**
  String sendAttempt(int current, int max);

  /// No description provided for @lastSeenRecently.
  ///
  /// In en, this message translates to:
  /// **'last seen recently'**
  String get lastSeenRecently;

  /// No description provided for @lastSeenMinutesAgo.
  ///
  /// In en, this message translates to:
  /// **'last seen {m} min ago'**
  String lastSeenMinutesAgo(int m);

  /// No description provided for @lastSeenHoursAgo.
  ///
  /// In en, this message translates to:
  /// **'last seen {h}h ago'**
  String lastSeenHoursAgo(int h);

  /// No description provided for @lastSeenYesterday.
  ///
  /// In en, this message translates to:
  /// **'last seen yesterday'**
  String get lastSeenYesterday;

  /// No description provided for @lastSeenDaysAgo.
  ///
  /// In en, this message translates to:
  /// **'last seen {d} days ago'**
  String lastSeenDaysAgo(int d);

  /// No description provided for @fileTooLarge.
  ///
  /// In en, this message translates to:
  /// **'File too large (max {mb} MB)'**
  String fileTooLarge(int mb);

  /// No description provided for @groupLabel.
  ///
  /// In en, this message translates to:
  /// **'Group'**
  String get groupLabel;

  /// No description provided for @noMessagesHint.
  ///
  /// In en, this message translates to:
  /// **'No messages yet\nPull to refresh'**
  String get noMessagesHint;

  /// No description provided for @monthJan.
  ///
  /// In en, this message translates to:
  /// **'January'**
  String get monthJan;

  /// No description provided for @monthFeb.
  ///
  /// In en, this message translates to:
  /// **'February'**
  String get monthFeb;

  /// No description provided for @monthMar.
  ///
  /// In en, this message translates to:
  /// **'March'**
  String get monthMar;

  /// No description provided for @monthApr.
  ///
  /// In en, this message translates to:
  /// **'April'**
  String get monthApr;

  /// No description provided for @monthMay.
  ///
  /// In en, this message translates to:
  /// **'May'**
  String get monthMay;

  /// No description provided for @monthJun.
  ///
  /// In en, this message translates to:
  /// **'June'**
  String get monthJun;

  /// No description provided for @monthJul.
  ///
  /// In en, this message translates to:
  /// **'July'**
  String get monthJul;

  /// No description provided for @monthAug.
  ///
  /// In en, this message translates to:
  /// **'August'**
  String get monthAug;

  /// No description provided for @monthSep.
  ///
  /// In en, this message translates to:
  /// **'September'**
  String get monthSep;

  /// No description provided for @monthOct.
  ///
  /// In en, this message translates to:
  /// **'October'**
  String get monthOct;

  /// No description provided for @monthNov.
  ///
  /// In en, this message translates to:
  /// **'November'**
  String get monthNov;

  /// No description provided for @monthDec.
  ///
  /// In en, this message translates to:
  /// **'December'**
  String get monthDec;

  /// No description provided for @newGroupTitle.
  ///
  /// In en, this message translates to:
  /// **'New Group'**
  String get newGroupTitle;

  /// No description provided for @groupNameHint.
  ///
  /// In en, this message translates to:
  /// **'Group name'**
  String get groupNameHint;

  /// No description provided for @selectMembersLabel.
  ///
  /// In en, this message translates to:
  /// **'Select members'**
  String get selectMembersLabel;

  /// No description provided for @noContactsToAdd.
  ///
  /// In en, this message translates to:
  /// **'No contacts to add'**
  String get noContactsToAdd;

  /// No description provided for @enterGroupName.
  ///
  /// In en, this message translates to:
  /// **'Enter a group name'**
  String get enterGroupName;

  /// No description provided for @selectAtLeastOneMember.
  ///
  /// In en, this message translates to:
  /// **'Select at least one member'**
  String get selectAtLeastOneMember;

  /// No description provided for @messagingNotReady.
  ///
  /// In en, this message translates to:
  /// **'Messaging not ready'**
  String get messagingNotReady;

  /// No description provided for @createGroupButton.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{Create (1 member)} other{Create ({count} members)}}'**
  String createGroupButton(int count);

  /// No description provided for @membersCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{1 member} other{{count} members}}'**
  String membersCount(int count);

  /// No description provided for @notGroupMember.
  ///
  /// In en, this message translates to:
  /// **'You are no longer a member of this group'**
  String get notGroupMember;

  /// No description provided for @leaveGroup.
  ///
  /// In en, this message translates to:
  /// **'Leave group'**
  String get leaveGroup;

  /// No description provided for @leaveGroupTitle.
  ///
  /// In en, this message translates to:
  /// **'Leave group?'**
  String get leaveGroupTitle;

  /// No description provided for @leaveGroupContent.
  ///
  /// In en, this message translates to:
  /// **'You will no longer receive messages from this group.'**
  String get leaveGroupContent;

  /// No description provided for @groupManagement.
  ///
  /// In en, this message translates to:
  /// **'Group management'**
  String get groupManagement;

  /// No description provided for @youInGroup.
  ///
  /// In en, this message translates to:
  /// **'you'**
  String get youInGroup;

  /// No description provided for @noData.
  ///
  /// In en, this message translates to:
  /// **'No data'**
  String get noData;

  /// No description provided for @renameGroup.
  ///
  /// In en, this message translates to:
  /// **'Rename group'**
  String get renameGroup;

  /// No description provided for @addMember.
  ///
  /// In en, this message translates to:
  /// **'Add member'**
  String get addMember;

  /// No description provided for @noAvailableContacts.
  ///
  /// In en, this message translates to:
  /// **'No available contacts to add'**
  String get noAvailableContacts;

  /// No description provided for @invitationSent.
  ///
  /// In en, this message translates to:
  /// **'Invitation sent'**
  String get invitationSent;

  /// No description provided for @removeMemberTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove member?'**
  String get removeMemberTitle;

  /// No description provided for @removeMemberContent.
  ///
  /// In en, this message translates to:
  /// **'{name} will be removed from the group.'**
  String removeMemberContent(String name);

  /// No description provided for @deleteGroupTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete group?'**
  String get deleteGroupTitle;

  /// No description provided for @deleteGroupContent.
  ///
  /// In en, this message translates to:
  /// **'The group will be deleted for all members. This action cannot be undone.'**
  String get deleteGroupContent;

  /// No description provided for @groupRenamed.
  ///
  /// In en, this message translates to:
  /// **'Group renamed'**
  String get groupRenamed;

  /// No description provided for @memberRemovedMessage.
  ///
  /// In en, this message translates to:
  /// **'{name} removed from group'**
  String memberRemovedMessage(String name);

  /// No description provided for @unnamedGroup.
  ///
  /// In en, this message translates to:
  /// **'Unnamed'**
  String get unnamedGroup;

  /// No description provided for @tapToRename.
  ///
  /// In en, this message translates to:
  /// **'Tap to rename'**
  String get tapToRename;

  /// No description provided for @adminLabel.
  ///
  /// In en, this message translates to:
  /// **'Admin: {name}'**
  String adminLabel(String name);

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @sectionIdentity.
  ///
  /// In en, this message translates to:
  /// **'Identity'**
  String get sectionIdentity;

  /// No description provided for @rotateSigningKey.
  ///
  /// In en, this message translates to:
  /// **'Rotate Signing Key'**
  String get rotateSigningKey;

  /// No description provided for @rotateSigningKeyDesc.
  ///
  /// In en, this message translates to:
  /// **'Issue a new signing key certified by master'**
  String get rotateSigningKeyDesc;

  /// No description provided for @fingerprintCopied.
  ///
  /// In en, this message translates to:
  /// **'Fingerprint copied'**
  String get fingerprintCopied;

  /// No description provided for @publicKeyCopied.
  ///
  /// In en, this message translates to:
  /// **'Public key copied'**
  String get publicKeyCopied;

  /// No description provided for @signingKeyRotated.
  ///
  /// In en, this message translates to:
  /// **'Signing key rotated'**
  String get signingKeyRotated;

  /// No description provided for @sectionNetwork.
  ///
  /// In en, this message translates to:
  /// **'Network'**
  String get sectionNetwork;

  /// No description provided for @sectionBackup.
  ///
  /// In en, this message translates to:
  /// **'Backup & Restore'**
  String get sectionBackup;

  /// No description provided for @exportBackup.
  ///
  /// In en, this message translates to:
  /// **'Export Identity Backup'**
  String get exportBackup;

  /// No description provided for @exportBackupDesc.
  ///
  /// In en, this message translates to:
  /// **'Save encrypted backup file'**
  String get exportBackupDesc;

  /// No description provided for @importBackup.
  ///
  /// In en, this message translates to:
  /// **'Import Identity Backup'**
  String get importBackup;

  /// No description provided for @importBackupDesc.
  ///
  /// In en, this message translates to:
  /// **'Restore identity from backup file'**
  String get importBackupDesc;

  /// No description provided for @sectionSecurity.
  ///
  /// In en, this message translates to:
  /// **'Security'**
  String get sectionSecurity;

  /// No description provided for @softwareKeystore.
  ///
  /// In en, this message translates to:
  /// **'Software Keystore'**
  String get softwareKeystore;

  /// No description provided for @softwareKeystoreDesc.
  ///
  /// In en, this message translates to:
  /// **'Android 8 does not guarantee hardware key protection. Android 9+ recommended.'**
  String get softwareKeystoreDesc;

  /// No description provided for @duressPin.
  ///
  /// In en, this message translates to:
  /// **'Duress PIN'**
  String get duressPin;

  /// No description provided for @duressPinDesc.
  ///
  /// In en, this message translates to:
  /// **'Silent wipe PIN — entering it erases all data'**
  String get duressPinDesc;

  /// No description provided for @wipeAllData.
  ///
  /// In en, this message translates to:
  /// **'Wipe All Data'**
  String get wipeAllData;

  /// No description provided for @wipeAllDataDesc.
  ///
  /// In en, this message translates to:
  /// **'Irreversibly delete all keys and messages'**
  String get wipeAllDataDesc;

  /// No description provided for @backupPassword.
  ///
  /// In en, this message translates to:
  /// **'Backup Password'**
  String get backupPassword;

  /// No description provided for @importBackupDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Import Identity Backup?'**
  String get importBackupDialogTitle;

  /// No description provided for @importBackupDialogContent.
  ///
  /// In en, this message translates to:
  /// **'This will replace your current identity. Messages and contacts are NOT restored.'**
  String get importBackupDialogContent;

  /// No description provided for @enterPassword.
  ///
  /// In en, this message translates to:
  /// **'Enter password'**
  String get enterPassword;

  /// No description provided for @identityNotLoaded.
  ///
  /// In en, this message translates to:
  /// **'Identity not loaded'**
  String get identityNotLoaded;

  /// No description provided for @sodiumNotReady.
  ///
  /// In en, this message translates to:
  /// **'Sodium not ready'**
  String get sodiumNotReady;

  /// No description provided for @backupSavedTo.
  ///
  /// In en, this message translates to:
  /// **'Backup saved to: {path}'**
  String backupSavedTo(String path);

  /// No description provided for @exportFailed.
  ///
  /// In en, this message translates to:
  /// **'Export failed: {error}'**
  String exportFailed(String error);

  /// No description provided for @importFailed.
  ///
  /// In en, this message translates to:
  /// **'Import failed: {error}'**
  String importFailed(String error);

  /// No description provided for @identityRestored.
  ///
  /// In en, this message translates to:
  /// **'Identity restored. Please restart the app.'**
  String get identityRestored;

  /// No description provided for @appNotUnlocked.
  ///
  /// In en, this message translates to:
  /// **'App not unlocked'**
  String get appNotUnlocked;

  /// No description provided for @duressPinSet.
  ///
  /// In en, this message translates to:
  /// **'Duress PIN set'**
  String get duressPinSet;

  /// No description provided for @duressPinRemoved.
  ///
  /// In en, this message translates to:
  /// **'Duress PIN removed'**
  String get duressPinRemoved;

  /// No description provided for @wrongCurrentPin.
  ///
  /// In en, this message translates to:
  /// **'Wrong current PIN'**
  String get wrongCurrentPin;

  /// No description provided for @enterCurrentPin.
  ///
  /// In en, this message translates to:
  /// **'Enter current PIN'**
  String get enterCurrentPin;

  /// No description provided for @setDuressPin.
  ///
  /// In en, this message translates to:
  /// **'Set duress PIN'**
  String get setDuressPin;

  /// No description provided for @confirmDuressPin.
  ///
  /// In en, this message translates to:
  /// **'Confirm duress PIN'**
  String get confirmDuressPin;

  /// No description provided for @pinConfirmIdentity.
  ///
  /// In en, this message translates to:
  /// **'Confirm your identity before changing security settings'**
  String get pinConfirmIdentity;

  /// No description provided for @duressPinSetHelp.
  ///
  /// In en, this message translates to:
  /// **'This PIN silently wipes all data when entered at unlock'**
  String get duressPinSetHelp;

  /// No description provided for @duressPinConfirmHelp.
  ///
  /// In en, this message translates to:
  /// **'Re-enter duress PIN to confirm'**
  String get duressPinConfirmHelp;

  /// No description provided for @duressMustDiffer.
  ///
  /// In en, this message translates to:
  /// **'Duress PIN must differ from your unlock PIN'**
  String get duressMustDiffer;

  /// No description provided for @removeDuressPin.
  ///
  /// In en, this message translates to:
  /// **'Remove duress PIN'**
  String get removeDuressPin;

  /// No description provided for @wipeAllDataTitle.
  ///
  /// In en, this message translates to:
  /// **'Wipe All Data?'**
  String get wipeAllDataTitle;

  /// No description provided for @wipeAllDataContent.
  ///
  /// In en, this message translates to:
  /// **'This will permanently delete your identity key, all messages, and contacts. This cannot be undone.'**
  String get wipeAllDataContent;

  /// No description provided for @wipeButton.
  ///
  /// In en, this message translates to:
  /// **'Wipe'**
  String get wipeButton;

  /// No description provided for @retryInterval.
  ///
  /// In en, this message translates to:
  /// **'Retry interval'**
  String get retryInterval;

  /// No description provided for @maxAttempts.
  ///
  /// In en, this message translates to:
  /// **'Max send attempts'**
  String get maxAttempts;

  /// No description provided for @networkSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Network Settings'**
  String get networkSettingsTitle;

  /// No description provided for @peersList.
  ///
  /// In en, this message translates to:
  /// **'Peers list'**
  String get peersList;

  /// No description provided for @trustedPeersOnly.
  ///
  /// In en, this message translates to:
  /// **'Trusted peers only'**
  String get trustedPeersOnly;

  /// No description provided for @trustedPeersOnlyDesc.
  ///
  /// In en, this message translates to:
  /// **'Only contacts\' Yggdrasil keys can peer inbound'**
  String get trustedPeersOnlyDesc;

  /// No description provided for @allInboundAllowed.
  ///
  /// In en, this message translates to:
  /// **'All inbound peering allowed (default)'**
  String get allInboundAllowed;

  /// No description provided for @trustedPeersModeOn.
  ///
  /// In en, this message translates to:
  /// **'Trusted-peers mode on. Add contacts to populate the whitelist.'**
  String get trustedPeersModeOn;

  /// No description provided for @lanDiscoveryPassword.
  ///
  /// In en, this message translates to:
  /// **'LAN discovery password'**
  String get lanDiscoveryPassword;

  /// No description provided for @openDiscovery.
  ///
  /// In en, this message translates to:
  /// **'Open — any device on LAN is discovered'**
  String get openDiscovery;

  /// No description provided for @protectedDiscovery.
  ///
  /// In en, this message translates to:
  /// **'Protected — only devices with same password'**
  String get protectedDiscovery;

  /// No description provided for @wifiLanDiscovery.
  ///
  /// In en, this message translates to:
  /// **'WiFi LAN Discovery'**
  String get wifiLanDiscovery;

  /// No description provided for @autoInterface.
  ///
  /// In en, this message translates to:
  /// **'AutoInterface (mDNS)'**
  String get autoInterface;

  /// No description provided for @autoInterfaceDesc.
  ///
  /// In en, this message translates to:
  /// **'Device discovery on local network'**
  String get autoInterfaceDesc;

  /// No description provided for @tcpTransportNodes.
  ///
  /// In en, this message translates to:
  /// **'TCP Transport Nodes'**
  String get tcpTransportNodes;

  /// No description provided for @tcpTransportDesc.
  ///
  /// In en, this message translates to:
  /// **'Connection to RNS transport nodes over internet. At least one needed for mobile networks.'**
  String get tcpTransportDesc;

  /// No description provided for @builtIn.
  ///
  /// In en, this message translates to:
  /// **'Built-in'**
  String get builtIn;

  /// No description provided for @addTransportNode.
  ///
  /// In en, this message translates to:
  /// **'Add transport node'**
  String get addTransportNode;

  /// No description provided for @rnsTransportNode.
  ///
  /// In en, this message translates to:
  /// **'RNS Transport Node'**
  String get rnsTransportNode;

  /// No description provided for @addNodeHint.
  ///
  /// In en, this message translates to:
  /// **'host:port (e.g. 1.2.3.4:4242)'**
  String get addNodeHint;

  /// No description provided for @reticulumViaYgg.
  ///
  /// In en, this message translates to:
  /// **'Reticulum via Yggdrasil'**
  String get reticulumViaYgg;

  /// No description provided for @addYggRnsNode.
  ///
  /// In en, this message translates to:
  /// **'Add Yggdrasil RNS node'**
  String get addYggRnsNode;

  /// No description provided for @restartReticulum.
  ///
  /// In en, this message translates to:
  /// **'Restart Reticulum'**
  String get restartReticulum;

  /// No description provided for @addPeer.
  ///
  /// In en, this message translates to:
  /// **'Add peer'**
  String get addPeer;

  /// No description provided for @addYggPeer.
  ///
  /// In en, this message translates to:
  /// **'Add Yggdrasil peer'**
  String get addYggPeer;

  /// No description provided for @peerPriority.
  ///
  /// In en, this message translates to:
  /// **'Peer Priority (1–255)'**
  String get peerPriority;

  /// No description provided for @priority.
  ///
  /// In en, this message translates to:
  /// **'Priority'**
  String get priority;

  /// No description provided for @lanDiscoveryPasswordTitle.
  ///
  /// In en, this message translates to:
  /// **'LAN Discovery Password'**
  String get lanDiscoveryPasswordTitle;

  /// No description provided for @openDiscoveryHint.
  ///
  /// In en, this message translates to:
  /// **'Leave empty for open discovery'**
  String get openDiscoveryHint;

  /// No description provided for @ddns.
  ///
  /// In en, this message translates to:
  /// **'DDNS'**
  String get ddns;

  /// No description provided for @ddnsProvider.
  ///
  /// In en, this message translates to:
  /// **'Provider'**
  String get ddnsProvider;

  /// No description provided for @ddnsDomain.
  ///
  /// In en, this message translates to:
  /// **'Domain'**
  String get ddnsDomain;

  /// No description provided for @ddnsToken.
  ///
  /// In en, this message translates to:
  /// **'Token / API key'**
  String get ddnsToken;

  /// No description provided for @peerAddress.
  ///
  /// In en, this message translates to:
  /// **'Peer address'**
  String get peerAddress;

  /// No description provided for @peerModeHelp.
  ///
  /// In en, this message translates to:
  /// **'⚠ White IP or port forwarding on router needed for peer mode.'**
  String get peerModeHelp;

  /// No description provided for @publicPeerMode.
  ///
  /// In en, this message translates to:
  /// **'Public peer mode'**
  String get publicPeerMode;

  /// No description provided for @publicPeerModeDesc.
  ///
  /// In en, this message translates to:
  /// **'Phone accepts inbound Yggdrasil connections'**
  String get publicPeerModeDesc;

  /// No description provided for @wifiOnly.
  ///
  /// In en, this message translates to:
  /// **'WiFi only'**
  String get wifiOnly;

  /// No description provided for @disableOnMobile.
  ///
  /// In en, this message translates to:
  /// **'Disable peer mode on mobile network'**
  String get disableOnMobile;

  /// No description provided for @port.
  ///
  /// In en, this message translates to:
  /// **'Port'**
  String get port;

  /// No description provided for @notSet.
  ///
  /// In en, this message translates to:
  /// **'Not set'**
  String get notSet;

  /// No description provided for @addressCopied.
  ///
  /// In en, this message translates to:
  /// **'Address copied'**
  String get addressCopied;

  /// No description provided for @notImplementedYet.
  ///
  /// In en, this message translates to:
  /// **'{name} — not implemented yet'**
  String notImplementedYet(String name);

  /// No description provided for @networkStatusTitle.
  ///
  /// In en, this message translates to:
  /// **'Network Status'**
  String get networkStatusTitle;

  /// No description provided for @yggdrasilNode.
  ///
  /// In en, this message translates to:
  /// **'Yggdrasil Node'**
  String get yggdrasilNode;

  /// No description provided for @myAddress.
  ///
  /// In en, this message translates to:
  /// **'My Address'**
  String get myAddress;

  /// No description provided for @nodePublicKey.
  ///
  /// In en, this message translates to:
  /// **'Node Public Key'**
  String get nodePublicKey;

  /// No description provided for @listeningInbound.
  ///
  /// In en, this message translates to:
  /// **'Listening (inbound peers)'**
  String get listeningInbound;

  /// No description provided for @peersConnectedCount.
  ///
  /// In en, this message translates to:
  /// **'Peers ({up}/{total} up)'**
  String peersConnectedCount(int up, int total);

  /// No description provided for @noPeersConnected.
  ///
  /// In en, this message translates to:
  /// **'No peers connected'**
  String get noPeersConnected;

  /// No description provided for @activeSessionsCount.
  ///
  /// In en, this message translates to:
  /// **'Active Sessions ({count})'**
  String activeSessionsCount(int count);

  /// No description provided for @inbound.
  ///
  /// In en, this message translates to:
  /// **'inbound'**
  String get inbound;

  /// No description provided for @outbound.
  ///
  /// In en, this message translates to:
  /// **'outbound'**
  String get outbound;

  /// No description provided for @errorYggdrasilStartFailed.
  ///
  /// In en, this message translates to:
  /// **'Yggdrasil failed to start'**
  String get errorYggdrasilStartFailed;

  /// No description provided for @errorReticulumStartFailed.
  ///
  /// In en, this message translates to:
  /// **'Reticulum failed to start'**
  String get errorReticulumStartFailed;

  /// No description provided for @errorSessionCorrupted.
  ///
  /// In en, this message translates to:
  /// **'Session corrupted — will renegotiate on next message'**
  String get errorSessionCorrupted;

  /// No description provided for @keyChangeBanner.
  ///
  /// In en, this message translates to:
  /// **'Contact\'s security key changed — verify before trusting'**
  String get keyChangeBanner;

  /// No description provided for @keyChangeTitle.
  ///
  /// In en, this message translates to:
  /// **'Security key changed'**
  String get keyChangeTitle;

  /// No description provided for @keyChangeDescription.
  ///
  /// In en, this message translates to:
  /// **'{name} may have reinstalled the app, or the contact may be compromised. Verify the new QR code before trusting.'**
  String keyChangeDescription(String name);

  /// No description provided for @verifyContactQR.
  ///
  /// In en, this message translates to:
  /// **'Verify QR'**
  String get verifyContactQR;

  /// No description provided for @trustNewKey.
  ///
  /// In en, this message translates to:
  /// **'Trust'**
  String get trustNewKey;

  /// No description provided for @keyTrusted.
  ///
  /// In en, this message translates to:
  /// **'Key marked as trusted'**
  String get keyTrusted;

  /// No description provided for @panicGesture.
  ///
  /// In en, this message translates to:
  /// **'Panic gesture'**
  String get panicGesture;

  /// No description provided for @panicGestureDesc.
  ///
  /// In en, this message translates to:
  /// **'Shake the phone hard 3 times to wipe all data'**
  String get panicGestureDesc;

  /// No description provided for @panicMode.
  ///
  /// In en, this message translates to:
  /// **'Panic mode'**
  String get panicMode;

  /// No description provided for @panicModeSoft.
  ///
  /// In en, this message translates to:
  /// **'Soft (3-sec countdown, tap to cancel)'**
  String get panicModeSoft;

  /// No description provided for @panicModeHard.
  ///
  /// In en, this message translates to:
  /// **'Hard (instant, no cancel)'**
  String get panicModeHard;

  /// No description provided for @panicSensitivity.
  ///
  /// In en, this message translates to:
  /// **'Shake sensitivity'**
  String get panicSensitivity;

  /// No description provided for @panicSensitivityLow.
  ///
  /// In en, this message translates to:
  /// **'Low (firm shakes only)'**
  String get panicSensitivityLow;

  /// No description provided for @panicSensitivityMedium.
  ///
  /// In en, this message translates to:
  /// **'Medium (recommended)'**
  String get panicSensitivityMedium;

  /// No description provided for @panicSensitivityHigh.
  ///
  /// In en, this message translates to:
  /// **'High (light shakes — risk of false positives)'**
  String get panicSensitivityHigh;

  /// No description provided for @panicWipeImminent.
  ///
  /// In en, this message translates to:
  /// **'Wiping all data'**
  String get panicWipeImminent;

  /// No description provided for @panicTapToCancel.
  ///
  /// In en, this message translates to:
  /// **'Tap anywhere to cancel'**
  String get panicTapToCancel;

  /// No description provided for @searchInChatHint.
  ///
  /// In en, this message translates to:
  /// **'Search in chat'**
  String get searchInChatHint;

  /// No description provided for @searchHitsCount.
  ///
  /// In en, this message translates to:
  /// **'{current} of {total}'**
  String searchHitsCount(int current, int total);

  /// No description provided for @searchNoMatches.
  ///
  /// In en, this message translates to:
  /// **'No matches'**
  String get searchNoMatches;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ru'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ru':
      return AppLocalizationsRu();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
