import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_wireguard_tunnel/flutter_wireguard_tunnel.dart';
import 'package:integration_test/integration_test.dart';

// Runs on a real device or emulator: flutter test integration_test
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const tunnel = WireGuardTunnel();

  testWidgets('the device key is made once and kept', (tester) async {
    final first = await tunnel.publicKey();
    final second = await tunnel.publicKey();
    expect(first, hasLength(44));
    expect(first, endsWith('='));
    expect(second, first);
  });

  testWidgets('the tunnel starts down', (tester) async {
    expect(await tunnel.state(), WireGuardState.down);
    await tunnel.stop();
    expect(await tunnel.state(), WireGuardState.down);
  });

  testWidgets('isPrepared answers', (tester) async {
    expect(await tunnel.isPrepared(), isA<bool>());
  });
}
