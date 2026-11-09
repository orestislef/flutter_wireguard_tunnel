import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_wireguard_tunnel/flutter_wireguard_tunnel.dart';
import 'package:integration_test/integration_test.dart';

// End to end against a real WireGuard server. Skipped unless the server is
// given:
//
//   flutter test integration_test/tunnel_test.dart \
//     --dart-define=WG_TEST_SERVER=10.0.2.2:8080
//
// tool/wg_test_server is that server (go run . in that folder). It answers
// GET /peer?key=<public key> (or ?generate=1) with address, serverPublicKey
// and endpoint (plus privateKey and presharedKey when it made the keys), and
// serves "hello from the tunnel" on 10.8.0.1:80 inside the tunnel.
//
// The VPN permission has to be given first. On the Android emulator:
// adb shell cmd appops set --uid <application id> ACTIVATE_VPN allow
// On iOS tap Allow when the first test asks to add the VPN configuration.
const server = String.fromEnvironment('WG_TEST_SERVER');
const inside = 'http://10.8.0.1/';

Future<Map<String, dynamic>> addPeer(String query) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(
      Uri.parse('http://$server/peer?$query'),
    );
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    expect(response.statusCode, 200, reason: body);
    return jsonDecode(body) as Map<String, dynamic>;
  } finally {
    client.close(force: true);
  }
}

/// The page inside the tunnel, or null when it cannot be reached.
Future<String?> fetchInside({int tries = 5}) async {
  for (var i = 0; i < tries; i++) {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final request = await client.getUrl(Uri.parse(inside));
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      return await response.transform(utf8.decoder).join();
    } catch (_) {
      await Future<void>.delayed(const Duration(seconds: 1));
    } finally {
      client.close(force: true);
    }
  }
  return null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const tunnel = WireGuardTunnel();

  tearDown(() => tunnel.stop());

  testWidgets('up with the device key, traffic goes through, down again', (
    tester,
  ) async {
    expect(await tunnel.prepare(), isTrue);
    final key = await tunnel.publicKey();
    final peer = await addPeer('key=${Uri.encodeQueryComponent(key)}');

    await tunnel.start(
      WireGuardConfig(
        address: peer['address'] as String,
        serverPublicKey: peer['serverPublicKey'] as String,
        endpoint: peer['endpoint'] as String,
        allowedIps: const ['10.8.0.1/32'],
      ),
    );
    expect(await tunnel.state(), WireGuardState.up);
    expect(await fetchInside(), 'hello from the tunnel');

    await tunnel.stop();
    expect(await tunnel.state(), WireGuardState.down);
    expect(await fetchInside(tries: 1), isNull);
  }, skip: server.isEmpty);

  testWidgets('own keys from a wg-quick file, replacing a running tunnel', (
    tester,
  ) async {
    final first = await addPeer(
      'key=${Uri.encodeQueryComponent(await tunnel.publicKey())}',
    );
    await tunnel.start(
      WireGuardConfig(
        address: first['address'] as String,
        serverPublicKey: first['serverPublicKey'] as String,
        endpoint: first['endpoint'] as String,
        allowedIps: const ['10.8.0.1/32'],
      ),
    );
    expect(await fetchInside(), 'hello from the tunnel');

    final own = await addPeer('generate=1');
    final config = WireGuardConfig.parse('''
[Interface]
PrivateKey = ${own['privateKey']}
Address = ${own['address']}
DNS = 10.8.0.1
MTU = 1380

[Peer]
PublicKey = ${own['serverPublicKey']}
PresharedKey = ${own['presharedKey']}
Endpoint = ${own['endpoint']}
AllowedIPs = 10.8.0.0/24
PersistentKeepalive = 15
''');
    // Started over the running tunnel, the new keys and address take over.
    await tunnel.start(config);
    expect(await tunnel.state(), WireGuardState.up);
    expect(await fetchInside(), 'hello from the tunnel');
  }, skip: server.isEmpty);

  testWidgets('a wrong server key does not reach the server', (tester) async {
    final peer = await addPeer(
      'key=${Uri.encodeQueryComponent(await tunnel.publicKey())}',
    );
    await tunnel.start(
      WireGuardConfig(
        address: peer['address'] as String,
        serverPublicKey: 'xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=',
        endpoint: peer['endpoint'] as String,
        allowedIps: const ['10.8.0.1/32'],
      ),
    );
    expect(await fetchInside(tries: 2), isNull);
  }, skip: server.isEmpty);
}
