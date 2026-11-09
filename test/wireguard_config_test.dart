import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_wireguard_tunnel/flutter_wireguard_tunnel.dart';

const serverKey = 'xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=';
const privateKey = 'yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=';
const presharedKey = 'FpCyhws9cxwWoV4xELtfJvjJN+zQVRPISllRWgeopVE=';

const config = WireGuardConfig(
  address: '10.8.0.2/32',
  serverPublicKey: serverKey,
  endpoint: 'vpn.example.com:51820',
  allowedIps: ['10.8.0.0/24'],
);

void main() {
  group('validate', () {
    test('a complete config is fine', () {
      expect(config.validate(), isNull);
    });

    test('defaults', () {
      expect(config.persistentKeepalive, 25);
      expect(config.mtu, 1280);
      expect(config.dns, isEmpty);
      expect(config.privateKey, isNull);
    });

    test('empty address', () {
      expect(config.copyWith(address: ' ').validate(), contains('address'));
    });

    test('server key that is not a key', () {
      expect(config.copyWith(serverPublicKey: 'abc').validate(),
          contains('serverPublicKey'));
      // 32 bytes end in one of 16 characters before the padding.
      expect(
          config
              .copyWith(serverPublicKey: serverKey.replaceFirst('g=', 'h='))
              .validate(),
          contains('serverPublicKey'));
    });

    test('endpoint needs a port', () {
      expect(config.copyWith(endpoint: 'vpn.example.com').validate(),
          contains('endpoint'));
      expect(config.copyWith(endpoint: '1.2.3.4:51820').validate(), isNull);
      expect(
          config.copyWith(endpoint: '[2001:db8::1]:51820').validate(), isNull);
      expect(config.copyWith(endpoint: '2001:db8::1:51820').validate(),
          contains('endpoint'));
    });

    test('allowed IPs cannot be empty', () {
      expect(config.copyWith(allowedIps: []).validate(), contains('allowedIps'));
      expect(
          config.copyWith(allowedIps: [' ']).validate(), contains('allowedIps'));
    });

    test('optional keys are checked when given', () {
      expect(config.copyWith(privateKey: privateKey).validate(), isNull);
      expect(config.copyWith(privateKey: 'nope').validate(),
          contains('privateKey'));
      expect(config.copyWith(presharedKey: presharedKey).validate(), isNull);
      expect(config.copyWith(presharedKey: 'nope').validate(),
          contains('presharedKey'));
    });

    test('ranges', () {
      expect(config.copyWith(persistentKeepalive: 0).validate(), isNull);
      expect(config.copyWith(persistentKeepalive: -1).validate(),
          contains('persistentKeepalive'));
      expect(config.copyWith(mtu: 500).validate(), contains('mtu'));
      expect(config.copyWith(mtu: 1420).validate(), isNull);
    });
  });

  group('toMap', () {
    test('trims and splits', () {
      final map = config
          .copyWith(
            address: ' 10.8.0.2/32, fd00::2/128 ',
            allowedIps: [' 10.8.0.0/24', '', 'fd00::/64 '],
            dns: ['1.1.1.1 '],
          )
          .toMap();
      expect(map['address'], ['10.8.0.2/32', 'fd00::2/128']);
      expect(map['allowedIps'], ['10.8.0.0/24', 'fd00::/64']);
      expect(map['dns'], ['1.1.1.1']);
      expect(map['serverPublicKey'], serverKey);
      expect(map['endpoint'], 'vpn.example.com:51820');
      expect(map['keepalive'], 25);
      expect(map['mtu'], 1280);
      expect(map['privateKey'], isNull);
      expect(map['presharedKey'], isNull);
    });
  });

  test('toString leaves the keys out', () {
    final text = config
        .copyWith(privateKey: privateKey, presharedKey: presharedKey)
        .toString();
    expect(text, contains('10.8.0.2/32'));
    expect(text, isNot(contains(privateKey)));
    expect(text, isNot(contains(presharedKey)));
  });

  group('parse', () {
    test('a typical wg-quick file', () {
      final parsed = WireGuardConfig.parse('''
[Interface]
# phone
PrivateKey = $privateKey
Address = 10.8.0.2/32, fd00::2/128
DNS = 1.1.1.1, 1.0.0.1
MTU = 1420

[Peer]
PublicKey = $serverKey
PresharedKey = $presharedKey
Endpoint = vpn.example.com:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 15
''');
      expect(parsed.privateKey, privateKey);
      expect(parsed.address, '10.8.0.2/32, fd00::2/128');
      expect(parsed.dns, ['1.1.1.1', '1.0.0.1']);
      expect(parsed.mtu, 1420);
      expect(parsed.serverPublicKey, serverKey);
      expect(parsed.presharedKey, presharedKey);
      expect(parsed.endpoint, 'vpn.example.com:51820');
      expect(parsed.allowedIps, ['0.0.0.0/0', '::/0']);
      expect(parsed.persistentKeepalive, 15);
      expect(parsed.validate(), isNull);
    });

    test('keys are case insensitive, repeated lines add up, CRLF works', () {
      final parsed = WireGuardConfig.parse('[interface]\r\n'
          'privatekey=$privateKey\r\n'
          'address=10.8.0.2/32\r\n'
          '[peer]\r\n'
          'publickey=$serverKey\r\n'
          'endpoint=1.2.3.4:51820\r\n'
          'allowedips=10.8.0.0/24\r\n'
          'allowedips=192.168.1.0/24 # office\r\n');
      expect(parsed.allowedIps, ['10.8.0.0/24', '192.168.1.0/24']);
      expect(parsed.persistentKeepalive, 0);
      expect(parsed.mtu, 1280);
      expect(parsed.dns, isEmpty);
      expect(parsed.presharedKey, isNull);
    });

    test('keepalive off', () {
      final parsed = WireGuardConfig.parse('[Interface]\n'
          'Address = 10.8.0.2/32\n'
          '[Peer]\n'
          'PublicKey = $serverKey\n'
          'Endpoint = 1.2.3.4:51820\n'
          'AllowedIPs = 10.8.0.0/24\n'
          'PersistentKeepalive = off\n');
      expect(parsed.persistentKeepalive, 0);
      expect(parsed.privateKey, isNull);
    });

    test('missing fields', () {
      expect(
          () => WireGuardConfig.parse('[Peer]\nPublicKey = $serverKey\n'),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'message', contains('Address'))));
      expect(
          () => WireGuardConfig.parse('[Interface]\nAddress = 10.8.0.2/32\n'
              '[Peer]\nPublicKey = $serverKey\nAllowedIPs = 10.8.0.0/24\n'),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'message', contains('Endpoint'))));
    });

    test('more than one peer', () {
      expect(
          () => WireGuardConfig.parse('[Interface]\nAddress = 10.8.0.2/32\n'
              '[Peer]\nPublicKey = $serverKey\n[Peer]\nPublicKey = $serverKey\n'),
          throwsA(isA<FormatException>()));
    });
  });
}
