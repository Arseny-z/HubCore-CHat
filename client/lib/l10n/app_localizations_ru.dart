// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class AppLocalizationsRu extends AppLocalizations {
  AppLocalizationsRu([String locale = 'ru']) : super(locale);

  @override
  String get appTitle => 'HubCore Chat';

  @override
  String get cancel => 'Отмена';

  @override
  String get save => 'Сохранить';

  @override
  String get delete => 'Удалить';

  @override
  String get close => 'Закрыть';

  @override
  String get copied => 'Скопировано';

  @override
  String get dismiss => 'Закрыть';

  @override
  String get continueAction => 'Продолжить';

  @override
  String get fingerprint => 'Отпечаток';

  @override
  String get publicKeyBase58 => 'Открытый ключ (base58)';

  @override
  String get yesterday => 'Вчера';

  @override
  String get today => 'Сегодня';

  @override
  String get selectFromGallery => 'Выбрать из галереи';

  @override
  String get takePhoto => 'Сделать фото';

  @override
  String get deletePhoto => 'Удалить фото';

  @override
  String get myQrCode => 'Мой QR-код';

  @override
  String get networkStatus => 'Состояние сети';

  @override
  String get yggdrasilReticulum => 'Yggdrasil, Reticulum';

  @override
  String get mediaAudio => '🎤 Голосовое';

  @override
  String get mediaVideoCircle => '⭕ Видео-кружок';

  @override
  String get mediaPhoto => '🖼 Фото';

  @override
  String get selectFileType => 'Выбор типа файла';

  @override
  String get photoVideo => 'Фото / Видео';

  @override
  String get document => 'Документ';

  @override
  String get deliveryStatus => 'Статус доставки';

  @override
  String get deliveryStatusSent => 'Отправлено';

  @override
  String get deliveryStatusDelivered => 'Доставлено';

  @override
  String get deliveryStatusRead => 'Прочитано';

  @override
  String get noDeliveryInfo => 'Нет информации о доставке';

  @override
  String get noMessages => 'Нет сообщений';

  @override
  String get onboardingSubtitle =>
      'Приватный мессенджер. Без номера телефона. Без серверов.';

  @override
  String get featureE2eTitle => 'Сквозное шифрование';

  @override
  String get featureE2eSubtitle =>
      'Сообщения шифруются с помощью Double Ratchet';

  @override
  String get featureP2pTitle => 'Peer-to-peer сеть';

  @override
  String get featureP2pSubtitle =>
      'Построена на Yggdrasil — без центрального сервера';

  @override
  String get featureNoRegTitle => 'Без регистрации';

  @override
  String get featureNoRegSubtitle =>
      'Ваша личность — пара криптографических ключей';

  @override
  String get createIdentity => 'Создать личность';

  @override
  String get keyLocalWarning =>
      'Ваши ключи генерируются локально и никогда не покидают устройство.';

  @override
  String get setPinTitle => 'Установить PIN';

  @override
  String get confirmPinTitle => 'Подтвердить PIN';

  @override
  String get enterPinTitle => 'Введите PIN';

  @override
  String get setPinSubtitle => 'Создайте PIN для защиты ваших сообщений';

  @override
  String get confirmPinSubtitle => 'Введите PIN ещё раз для подтверждения';

  @override
  String get unlockSubtitle => 'Разблокировать HubCore Chat';

  @override
  String get pinsDoNotMatch => 'PIN-коды не совпадают';

  @override
  String get wrongPin => 'Неверный PIN';

  @override
  String wrongPinAttemptsLeft(int remaining) {
    String _temp0 = intl.Intl.pluralLogic(
      remaining,
      locale: localeName,
      other: 'Неверный PIN — осталось $remaining попыток',
      few: 'Неверный PIN — осталось $remaining попытки',
      one: 'Неверный PIN — осталась $remaining попытка',
    );
    return '$_temp0';
  }

  @override
  String failedAttemptsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count неудачных попыток',
      few: '$count неудачных попытки',
      one: '$count неудачная попытка',
    );
    return '$_temp0';
  }

  @override
  String get keyMismatchTitle => 'Ключ не совпадает';

  @override
  String get keyMismatchContent =>
      'База данных зашифрована другим ключом. Это происходит после переустановки или восстановления устройства.\n\nУдалить данные и начать заново?';

  @override
  String get resetButton => 'Сбросить';

  @override
  String get profileSetupTitle => 'Как вас зовут?';

  @override
  String get profileSetupSubtitle =>
      'Ник и аватарка будут видны вашим контактам. Можно пропустить.';

  @override
  String get nicknameHint => 'Ваш ник (необязательно)';

  @override
  String get tabChats => 'Чаты';

  @override
  String get tabContacts => 'Контакты';

  @override
  String get tabProfile => 'Профиль';

  @override
  String get tabSettings => 'Настройки';

  @override
  String get pressAgainToExit => 'Нажмите ещё раз для выхода';

  @override
  String get searchChats => 'Поиск чатов…';

  @override
  String get searchMessages => 'Поиск сообщений';

  @override
  String get newGroup => 'Новая группа';

  @override
  String noChatMatchingQuery(String query) {
    return 'Нет чатов, совпадающих с \"$query\"';
  }

  @override
  String get emptyChatsTitle => 'Нет чатов';

  @override
  String get emptyChatsSubtitle =>
      'Добавьте контакт через QR-код\nили поделитесь своим кодом';

  @override
  String get addContactButton => 'Добавить контакт';

  @override
  String get deleteChatTitle => 'Удалить чат?';

  @override
  String deleteChatContent(String name) {
    return 'Все сообщения с \"$name\" будут удалены.';
  }

  @override
  String get noContactsYet => 'Нет контактов';

  @override
  String get tapPlusToAdd => 'Нажмите + для добавления';

  @override
  String get myProfile => 'Мой профиль';

  @override
  String get shareQrToAddContacts =>
      'Поделитесь QR-кодом для добавления контактов';

  @override
  String get yourNickname => 'Ваш ник';

  @override
  String get searchMessagesTitle => 'Поиск сообщений…';

  @override
  String get nothingFound => 'Ничего не найдено';

  @override
  String get youPrefix => 'Вы: ';

  @override
  String get addContactTitle => 'Добавить контакт';

  @override
  String get shareYourKey => 'Поделитесь своим ключом';

  @override
  String get contactKeyLabel => 'Ключ контакта';

  @override
  String get fromFile => 'Из файла';

  @override
  String get pasteKeyHint => 'base58 ключ или JSON контакта';

  @override
  String get pasteFromClipboard => 'Вставить из буфера';

  @override
  String get contactNameHint => 'Имя контакта (необязательно)';

  @override
  String get qrCodeNotFound => 'QR-код не найден в изображении';

  @override
  String get invalidPublicKey => 'Неверный открытый ключ';

  @override
  String get sendMessage => 'Написать сообщение';

  @override
  String get clearChatHistory => 'Очистить историю';

  @override
  String get clearChatTitle => 'Очистить историю чата?';

  @override
  String clearChatContent(String name) {
    return 'Все сообщения и файлы с $name будут удалены. Ключи и сессии не затронуты.';
  }

  @override
  String get chatHistoryCleared => 'История чата очищена';

  @override
  String get deleteContactTitle => 'Удалить контакт?';

  @override
  String deleteContactContent(String name) {
    return 'Удалить $name из контактов? Сообщения удалены не будут.';
  }

  @override
  String get messageHint => 'Сообщение';

  @override
  String get chatInitializing =>
      'Приложение ещё инициализируется. Подождите секунду.';

  @override
  String get contactNotFoundError =>
      'Контакт не найден. Попробуйте снова обменяться QR-кодами.';

  @override
  String get noSessionError =>
      'Нет установленной сессии. Дождитесь, пока контакт появится онлайн.';

  @override
  String get databaseError =>
      'База данных недоступна. Перезапустите приложение.';

  @override
  String get networkErrorQueued =>
      'Ошибка сети. Сообщение встанет в очередь и отправится автоматически.';

  @override
  String get sendError => 'Не удалось отправить. Попробуйте ещё раз.';

  @override
  String get reply => 'Ответить';

  @override
  String get forward => 'Переслать';

  @override
  String get forwardTo => 'Переслать в…';

  @override
  String get messageForwarded => 'Сообщение переслано';

  @override
  String get muteNotifications => 'Заглушить';

  @override
  String get unmuteNotifications => 'Включить уведомления';

  @override
  String get autoDeleteOff => 'Авто-удаление отключено';

  @override
  String autoDeleteLabel(String duration) {
    return 'Авто-удаление: $duration';
  }

  @override
  String get autoDelete1Min => '1 минута';

  @override
  String get autoDelete1Hour => '1 час';

  @override
  String get autoDelete1Day => '1 день';

  @override
  String get autoDelete1Week => '1 неделя';

  @override
  String get autoDeleteDisabled => 'Отключено';

  @override
  String get deleteLocally => 'Удалить у себя';

  @override
  String get deleteForAll => 'Удалить у всех';

  @override
  String get deleteCancelSend => 'Удалить (отменить отправку)';

  @override
  String get copyText => 'Скопировать';

  @override
  String sendAttempt(int current, int max) {
    return 'Попытка $current/$max';
  }

  @override
  String get lastSeenRecently => 'в сети недавно';

  @override
  String lastSeenMinutesAgo(int m) {
    return 'был(а) $m мин назад';
  }

  @override
  String lastSeenHoursAgo(int h) {
    return 'был(а) $h ч назад';
  }

  @override
  String get lastSeenYesterday => 'был(а) вчера';

  @override
  String lastSeenDaysAgo(int d) {
    return 'был(а) $d дн назад';
  }

  @override
  String fileTooLarge(int mb) {
    return 'Файл слишком большой (макс. $mb МБ)';
  }

  @override
  String get groupLabel => 'Группа';

  @override
  String get noMessagesHint => 'Нет сообщений\nПотяните для обновления';

  @override
  String get monthJan => 'Январь';

  @override
  String get monthFeb => 'Февраль';

  @override
  String get monthMar => 'Март';

  @override
  String get monthApr => 'Апрель';

  @override
  String get monthMay => 'Май';

  @override
  String get monthJun => 'Июнь';

  @override
  String get monthJul => 'Июль';

  @override
  String get monthAug => 'Август';

  @override
  String get monthSep => 'Сентябрь';

  @override
  String get monthOct => 'Октябрь';

  @override
  String get monthNov => 'Ноябрь';

  @override
  String get monthDec => 'Декабрь';

  @override
  String get newGroupTitle => 'Новая группа';

  @override
  String get groupNameHint => 'Название группы';

  @override
  String get selectMembersLabel => 'Выберите участников';

  @override
  String get noContactsToAdd => 'Нет контактов для добавления';

  @override
  String get enterGroupName => 'Введите название группы';

  @override
  String get selectAtLeastOneMember => 'Выберите хотя бы одного участника';

  @override
  String get messagingNotReady => 'Обмен сообщениями не готов';

  @override
  String createGroupButton(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Создать ($count участников)',
      few: 'Создать ($count участника)',
      one: 'Создать (1 участник)',
    );
    return '$_temp0';
  }

  @override
  String membersCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count участников',
      few: '$count участника',
      one: '1 участник',
    );
    return '$_temp0';
  }

  @override
  String get notGroupMember => 'Вы больше не являетесь участником этой группы';

  @override
  String get leaveGroup => 'Покинуть группу';

  @override
  String get leaveGroupTitle => 'Покинуть группу?';

  @override
  String get leaveGroupContent =>
      'Вы больше не будете получать сообщения из этой группы.';

  @override
  String get groupManagement => 'Управление группой';

  @override
  String get youInGroup => 'вы';

  @override
  String get noData => 'Нет данных';

  @override
  String get renameGroup => 'Переименовать группу';

  @override
  String get addMember => 'Добавить участника';

  @override
  String get noAvailableContacts => 'Нет доступных контактов для добавления';

  @override
  String get invitationSent => 'Приглашение отправлено';

  @override
  String get removeMemberTitle => 'Удалить участника?';

  @override
  String removeMemberContent(String name) {
    return '$name будет удалён из группы.';
  }

  @override
  String get deleteGroupTitle => 'Удалить группу?';

  @override
  String get deleteGroupContent =>
      'Группа будет удалена для всех участников. Это действие нельзя отменить.';

  @override
  String get groupRenamed => 'Группа переименована';

  @override
  String memberRemovedMessage(String name) {
    return '$name удалён из группы';
  }

  @override
  String get unnamedGroup => 'Без названия';

  @override
  String get tapToRename => 'Нажмите чтобы переименовать';

  @override
  String adminLabel(String name) {
    return 'Админ: $name';
  }

  @override
  String get settingsTitle => 'Настройки';

  @override
  String get sectionIdentity => 'Идентичность';

  @override
  String get rotateSigningKey => 'Ротация ключа подписи';

  @override
  String get rotateSigningKeyDesc =>
      'Выдать новый ключ подписи, сертифицированный мастер-ключом';

  @override
  String get fingerprintCopied => 'Отпечаток скопирован';

  @override
  String get publicKeyCopied => 'Открытый ключ скопирован';

  @override
  String get signingKeyRotated => 'Ключ подписи обновлён';

  @override
  String get sectionNetwork => 'Сеть';

  @override
  String get sectionBackup => 'Резервная копия';

  @override
  String get exportBackup => 'Экспорт резервной копии';

  @override
  String get exportBackupDesc => 'Сохранить зашифрованный файл резервной копии';

  @override
  String get importBackup => 'Импорт резервной копии';

  @override
  String get importBackupDesc =>
      'Восстановить идентичность из файла резервной копии';

  @override
  String get sectionSecurity => 'Безопасность';

  @override
  String get softwareKeystore => 'Программный Keystore';

  @override
  String get softwareKeystoreDesc =>
      'Android 8 не гарантирует аппаратную защиту ключей. Рекомендуется Android 9+.';

  @override
  String get duressPin => 'PIN паники';

  @override
  String get duressPinDesc => 'Тихий сброс — при вводе стирает все данные';

  @override
  String get wipeAllData => 'Стереть все данные';

  @override
  String get wipeAllDataDesc => 'Необратимо удалить все ключи и сообщения';

  @override
  String get backupPassword => 'Пароль резервной копии';

  @override
  String get importBackupDialogTitle => 'Импортировать резервную копию?';

  @override
  String get importBackupDialogContent =>
      'Это заменит вашу текущую идентичность. Сообщения и контакты НЕ восстанавливаются.';

  @override
  String get enterPassword => 'Введите пароль';

  @override
  String get identityNotLoaded => 'Идентичность не загружена';

  @override
  String get sodiumNotReady => 'Sodium не готов';

  @override
  String backupSavedTo(String path) {
    return 'Резервная копия сохранена: $path';
  }

  @override
  String exportFailed(String error) {
    return 'Ошибка экспорта: $error';
  }

  @override
  String importFailed(String error) {
    return 'Ошибка импорта: $error';
  }

  @override
  String get identityRestored =>
      'Идентичность восстановлена. Перезапустите приложение.';

  @override
  String get appNotUnlocked => 'Приложение не разблокировано';

  @override
  String get duressPinSet => 'PIN паники установлен';

  @override
  String get duressPinRemoved => 'PIN паники удалён';

  @override
  String get wrongCurrentPin => 'Неверный текущий PIN';

  @override
  String get enterCurrentPin => 'Введите текущий PIN';

  @override
  String get setDuressPin => 'Установить PIN паники';

  @override
  String get confirmDuressPin => 'Подтвердить PIN паники';

  @override
  String get pinConfirmIdentity =>
      'Подтвердите личность перед изменением настроек безопасности';

  @override
  String get duressPinSetHelp =>
      'При вводе этого PIN все данные стираются без предупреждения';

  @override
  String get duressPinConfirmHelp =>
      'Введите PIN паники ещё раз для подтверждения';

  @override
  String get duressMustDiffer =>
      'PIN паники должен отличаться от основного PIN';

  @override
  String get removeDuressPin => 'Удалить PIN паники';

  @override
  String get wipeAllDataTitle => 'Стереть все данные?';

  @override
  String get wipeAllDataContent =>
      'Это навсегда удалит ваш ключ идентичности, все сообщения и контакты. Отменить нельзя.';

  @override
  String get wipeButton => 'Стереть';

  @override
  String get retryInterval => 'Интервал повтора';

  @override
  String get maxAttempts => 'Макс. попыток отправки';

  @override
  String get networkSettingsTitle => 'Настройки сети';

  @override
  String get peersList => 'Список пиров';

  @override
  String get trustedPeersOnly => 'Только доверенные пиры';

  @override
  String get trustedPeersOnlyDesc =>
      'Только ключи контактов Yggdrasil могут подключаться';

  @override
  String get allInboundAllowed => 'Все входящие разрешены (по умолчанию)';

  @override
  String get trustedPeersModeOn =>
      'Режим доверенных пиров включён. Добавьте контакты для заполнения белого списка.';

  @override
  String get lanDiscoveryPassword => 'Пароль LAN Discovery';

  @override
  String get openDiscovery => 'Открытый — любое устройство в LAN';

  @override
  String get protectedDiscovery => 'Защищённый — только устройства с паролем';

  @override
  String get wifiLanDiscovery => 'WiFi LAN Discovery';

  @override
  String get autoInterface => 'AutoInterface (mDNS)';

  @override
  String get autoInterfaceDesc => 'Обнаружение устройств в локальной сети';

  @override
  String get tcpTransportNodes => 'TCP Transport Nodes';

  @override
  String get tcpTransportDesc =>
      'Подключение к RNS transport nodes через интернет. Нужен хотя бы один для мобильной сети.';

  @override
  String get builtIn => 'Встроенный';

  @override
  String get addTransportNode => 'Добавить transport node';

  @override
  String get rnsTransportNode => 'RNS Transport Node';

  @override
  String get addNodeHint => 'host:port (например 1.2.3.4:4242)';

  @override
  String get reticulumViaYgg => 'Reticulum через Yggdrasil';

  @override
  String get addYggRnsNode => 'Добавить Yggdrasil RNS ноду';

  @override
  String get restartReticulum => 'Перезапустить Reticulum';

  @override
  String get addPeer => 'Добавить пир';

  @override
  String get addYggPeer => 'Добавить Yggdrasil пир';

  @override
  String get peerPriority => 'Приоритет пира (1–255)';

  @override
  String get priority => 'Приоритет';

  @override
  String get lanDiscoveryPasswordTitle => 'Пароль LAN Discovery';

  @override
  String get openDiscoveryHint => 'Пусто — открытое обнаружение';

  @override
  String get ddns => 'DDNS';

  @override
  String get ddnsProvider => 'Провайдер';

  @override
  String get ddnsDomain => 'Домен';

  @override
  String get ddnsToken => 'Токен / API ключ';

  @override
  String get peerAddress => 'Адрес пира';

  @override
  String get peerModeHelp =>
      '⚠ Для работы пира нужен белый IP или проброс порта на роутере.';

  @override
  String get publicPeerMode => 'Режим публичного пира';

  @override
  String get publicPeerModeDesc =>
      'Телефон принимает входящие Yggdrasil соединения';

  @override
  String get wifiOnly => 'Только на WiFi';

  @override
  String get disableOnMobile => 'Отключить пир-режим в мобильной сети';

  @override
  String get port => 'Порт';

  @override
  String get notSet => 'Не указан';

  @override
  String get addressCopied => 'Адрес скопирован';

  @override
  String notImplementedYet(String name) {
    return '$name — пока не реализован';
  }

  @override
  String get networkStatusTitle => 'Состояние сети';

  @override
  String get yggdrasilNode => 'Yggdrasil Node';

  @override
  String get myAddress => 'Мой адрес';

  @override
  String get nodePublicKey => 'Открытый ключ узла';

  @override
  String get listeningInbound => 'Прослушивание (входящие пиры)';

  @override
  String peersConnectedCount(int up, int total) {
    return 'Пиры ($up/$total активны)';
  }

  @override
  String get noPeersConnected => 'Нет подключённых пиров';

  @override
  String activeSessionsCount(int count) {
    return 'Активные сессии ($count)';
  }

  @override
  String get inbound => 'входящий';

  @override
  String get outbound => 'исходящий';
}
