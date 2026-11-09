/// Where the tunnel goes: this device's interface and the one server (peer)
/// it talks to.
///
/// Only [allowedIps] go through the tunnel. Give the server's network for a
/// split tunnel, or `0.0.0.0/0` (and `::/0`) to send everything through it.
class WireGuardConfig {
  const WireGuardConfig({
    required this.address,
    required this.serverPublicKey,
    required this.endpoint,
    required this.allowedIps,
    this.dns = const [],
    this.privateKey,
    this.presharedKey,
    this.persistentKeepalive = 25,
    this.mtu = 1280,
  });

  /// This device's address inside the tunnel, with its prefix, for example
  /// `10.8.0.2/32`. Several addresses are separated by commas.
  final String address;

  /// The server's public key, base64.
  final String serverPublicKey;

  /// `host:port` of the server, for example `vpn.example.com:51820`. IPv6
  /// goes in brackets: `[2001:db8::1]:51820`.
  final String endpoint;

  /// The networks that go through the tunnel, for example `10.8.0.0/24`.
  final List<String> allowedIps;

  /// DNS servers to use while the tunnel is up. Empty keeps the device's own.
  final List<String> dns;

  /// The interface's private key, base64. Leave it null to use the key this
  /// device makes for itself (see `WireGuardTunnel.publicKey`), which never
  /// leaves the device.
  final String? privateKey;

  /// Optional preshared key shared with the server, base64.
  final String? presharedKey;

  /// Seconds between keepalive packets, 0 to turn them off. Keeps the NAT
  /// mapping open on mobile networks so the server can reach the device.
  final int persistentKeepalive;

  /// MTU of the tunnel interface. 1280 is safe on mobile networks.
  final int mtu;

  /// Reads a wg-quick style config, the `.conf` file most WireGuard servers
  /// hand out. Only one `[Peer]` is supported.
  ///
  /// Throws a [FormatException] when a required field is missing.
  factory WireGuardConfig.parse(String text) {
    final interface = <String, String>{};
    final peer = <String, String>{};
    Map<String, String>? section;
    var peers = 0;

    for (final raw in text.split(RegExp(r'\r?\n'))) {
      final line = raw.split('#').first.trim();
      if (line.isEmpty) continue;
      final lower = line.toLowerCase();
      if (lower == '[interface]') {
        section = interface;
        continue;
      }
      if (lower == '[peer]') {
        peers++;
        if (peers > 1) {
          throw const FormatException('Only one [Peer] is supported');
        }
        section = peer;
        continue;
      }
      final eq = line.indexOf('=');
      if (section == null || eq <= 0) continue;
      final key = line.substring(0, eq).trim().toLowerCase();
      final value = line.substring(eq + 1).trim();
      // Address, DNS and AllowedIPs may repeat, the values add up.
      final previous = section[key];
      section[key] = previous == null ? value : '$previous, $value';
    }

    String required(Map<String, String> from, String key, String name) {
      final value = from[key];
      if (value == null || value.isEmpty) {
        throw FormatException('Missing $name');
      }
      return value;
    }

    List<String> list(String? value) => (value ?? '')
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    int number(String? value, int fallback) =>
        value == null ? fallback : int.tryParse(value) ?? fallback;

    final keepalive = peer['persistentkeepalive'];
    return WireGuardConfig(
      address: list(required(interface, 'address', 'Address')).join(', '),
      privateKey: interface['privatekey'],
      dns: list(interface['dns']),
      mtu: number(interface['mtu'], 1280),
      serverPublicKey: required(peer, 'publickey', 'PublicKey'),
      presharedKey: peer['presharedkey'],
      endpoint: required(peer, 'endpoint', 'Endpoint'),
      allowedIps: list(required(peer, 'allowedips', 'AllowedIPs')),
      persistentKeepalive: keepalive == null || keepalive.toLowerCase() == 'off'
          ? 0
          : number(keepalive, 0),
    );
  }

  /// Copy with some fields changed.
  WireGuardConfig copyWith({
    String? address,
    String? serverPublicKey,
    String? endpoint,
    List<String>? allowedIps,
    List<String>? dns,
    String? privateKey,
    String? presharedKey,
    int? persistentKeepalive,
    int? mtu,
  }) {
    return WireGuardConfig(
      address: address ?? this.address,
      serverPublicKey: serverPublicKey ?? this.serverPublicKey,
      endpoint: endpoint ?? this.endpoint,
      allowedIps: allowedIps ?? this.allowedIps,
      dns: dns ?? this.dns,
      privateKey: privateKey ?? this.privateKey,
      presharedKey: presharedKey ?? this.presharedKey,
      persistentKeepalive: persistentKeepalive ?? this.persistentKeepalive,
      mtu: mtu ?? this.mtu,
    );
  }

  /// What is wrong with this config, or null when it can be used.
  String? validate() {
    if (address.trim().isEmpty) return 'address is empty';
    if (!_isKey(serverPublicKey)) return 'serverPublicKey is not a key';
    if (!_endpoint.hasMatch(endpoint.trim())) {
      return 'endpoint is not host:port';
    }
    if (allowedIps.where((e) => e.trim().isNotEmpty).isEmpty) {
      return 'allowedIps is empty';
    }
    final privateKey = this.privateKey;
    if (privateKey != null && !_isKey(privateKey)) {
      return 'privateKey is not a key';
    }
    final presharedKey = this.presharedKey;
    if (presharedKey != null && !_isKey(presharedKey)) {
      return 'presharedKey is not a key';
    }
    if (persistentKeepalive < 0 || persistentKeepalive > 65535) {
      return 'persistentKeepalive is out of range';
    }
    if (mtu < 576 || mtu > 65535) return 'mtu is out of range';
    return null;
  }

  /// What goes over the platform channel.
  Map<String, Object?> toMap() => {
        'address': address
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(),
        'serverPublicKey': serverPublicKey.trim(),
        'endpoint': endpoint.trim(),
        'allowedIps':
            allowedIps.map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
        'dns': dns.map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
        'privateKey': privateKey?.trim(),
        'presharedKey': presharedKey?.trim(),
        'keepalive': persistentKeepalive,
        'mtu': mtu,
      };

  /// Leaves the private and preshared keys out.
  @override
  String toString() => 'WireGuardConfig($address via $endpoint, '
      'allowed $allowedIps, dns $dns, mtu $mtu, '
      'keepalive $persistentKeepalive)';

  static final _key = RegExp(r'^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw480]=$');
  static final _endpoint =
      RegExp(r'^(\[[0-9A-Fa-f:.]+\]|[^\s:\[\]]+):\d{1,5}$');

  static bool _isKey(String value) => _key.hasMatch(value.trim());
}
