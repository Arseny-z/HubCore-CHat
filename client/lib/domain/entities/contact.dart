import 'dart:convert';

class Contact {
  final int? id;
  final String masterPub;
  final String signingPub;
  /// X25519 public key (base58) used as identity key in Double Ratchet handshake.
  final String? x25519Pub;
  /// Yggdrasil Ed25519 public key (hex) — kept for legacy compat.
  /// Mirrors transportAddresses['yggdrasil'].
  final String? yggPubKeyHex;
  final String alias;
  final bool aliasCustomized;
  final int addedAt;
  final int? lastSeen;

  /// Transport addresses per protocol.
  /// Key = protocol id (e.g. 'yggdrasil', 'reticulum').
  /// Value = protocol-specific address string.
  ///
  /// Populated from DB column `transport_addresses` (JSON) with automatic
  /// back-fill from legacy `ygg_pub_key_hex` on load.
  final Map<String, String> transportAddresses;
  final bool muted;
  final int devicesVersion;

  /// Relationship with this contact.
  /// - `contact`  — added by the user, appears in ContactsTab and ChatsScreen
  /// - `stranger` — wrote first, not yet added; appears in "New conversations"
  /// - `blocked`  — blocked; all incoming silently dropped
  final String relationship;

  bool get isContact  => relationship == 'contact';
  bool get isStranger => relationship == 'stranger';
  bool get isBlocked  => relationship == 'blocked';

  const Contact({
    this.id,
    required this.masterPub,
    required this.signingPub,
    this.x25519Pub,
    this.yggPubKeyHex,
    required this.alias,
    this.aliasCustomized = false,
    required this.addedAt,
    this.lastSeen,
    Map<String, String>? transportAddresses,
    this.muted = false,
    this.relationship = 'contact',
    this.devicesVersion = 0,
  }) : transportAddresses = transportAddresses ?? const {};

  factory Contact.fromMap(Map<String, dynamic> m) {
    final ygg = m['ygg_pub_key_hex'] as String?;

    // Load transport_addresses JSON, then back-fill yggdrasil from legacy column.
    Map<String, String> addresses = {};
    final raw = m['transport_addresses'] as String?;
    if (raw != null && raw.isNotEmpty) {
      try {
        addresses = Map<String, String>.from(jsonDecode(raw) as Map);
      } catch (_) {}
    }
    if (ygg != null && ygg.isNotEmpty && !addresses.containsKey('yggdrasil')) {
      addresses = {...addresses, 'yggdrasil': ygg};
    }

    return Contact(
      id: m['id'] as int?,
      masterPub: m['master_pub'] as String,
      signingPub: m['signing_pub'] as String,
      x25519Pub: m['x25519_pub'] as String?,
      yggPubKeyHex: ygg,
      alias: m['alias'] as String,
      aliasCustomized: (m['alias_customized'] as int? ?? 0) == 1,
      addedAt: m['added_at'] as int,
      lastSeen: m['last_seen'] as int?,
      transportAddresses: addresses,
      muted: (m['muted'] as int? ?? 0) == 1,
      relationship: m['relationship'] as String? ?? 'contact',
      devicesVersion: m['devices_version'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toMap() => {
        'master_pub': masterPub,
        'signing_pub': signingPub,
        if (x25519Pub != null) 'x25519_pub': x25519Pub,
        if (yggPubKeyHex != null) 'ygg_pub_key_hex': yggPubKeyHex,
        'alias': alias,
        'alias_customized': aliasCustomized ? 1 : 0,
        'added_at': addedAt,
        if (lastSeen != null) 'last_seen': lastSeen,
        if (transportAddresses.isNotEmpty)
          'transport_addresses': jsonEncode(transportAddresses),
        'muted': muted ? 1 : 0,
        'relationship': relationship,
        if (devicesVersion != 0) 'devices_version': devicesVersion,
      };

  Contact copyWith({
    String? signingPub,
    String? x25519Pub,
    String? yggPubKeyHex,
    String? alias,
    bool? aliasCustomized,
    int? lastSeen,
    Map<String, String>? transportAddresses,
    bool? muted,
    String? relationship,
    int? devicesVersion,
  }) {
    final newYgg = yggPubKeyHex ?? this.yggPubKeyHex;
    // Keep transportAddresses in sync with yggPubKeyHex
    final newAddresses = Map<String, String>.from(
      transportAddresses ?? this.transportAddresses,
    );
    if (newYgg != null && newYgg.isNotEmpty) {
      newAddresses['yggdrasil'] = newYgg;
    }
    return Contact(
      id: id,
      masterPub: masterPub,
      signingPub: signingPub ?? this.signingPub,
      x25519Pub: x25519Pub ?? this.x25519Pub,
      yggPubKeyHex: newYgg,
      alias: alias ?? this.alias,
      aliasCustomized: aliasCustomized ?? this.aliasCustomized,
      addedAt: addedAt,
      lastSeen: lastSeen ?? this.lastSeen,
      transportAddresses: newAddresses,
      muted: muted ?? this.muted,
      relationship: relationship ?? this.relationship,
      devicesVersion: devicesVersion ?? this.devicesVersion,
    );
  }
}
