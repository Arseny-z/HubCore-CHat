enum PollingInterval {
  oneMinute,
  fiveMinutes,
  fifteenMinutes,
  thirtyMinutes,
  manual,
  disabled,
}

extension PollingIntervalExt on PollingInterval {
  Duration? get duration => switch (this) {
        PollingInterval.oneMinute      => const Duration(minutes: 1),
        PollingInterval.fiveMinutes    => const Duration(minutes: 5),
        PollingInterval.fifteenMinutes => const Duration(minutes: 15),
        PollingInterval.thirtyMinutes  => const Duration(minutes: 30),
        PollingInterval.manual         => null,
        PollingInterval.disabled       => null,
      };

  String get settingsValue => name;

  static PollingInterval fromSettings(String value) =>
      PollingInterval.values.firstWhere(
        (e) => e.name == value,
        orElse: () => PollingInterval.fiveMinutes,
      );
}
