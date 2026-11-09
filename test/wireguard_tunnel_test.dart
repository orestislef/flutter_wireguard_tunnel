import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_wireguard_tunnel/flutter_wireguard_tunnel.dart';

const channel = MethodChannel('flutter_wireguard_tunnel');

const config = WireGuardConfig(
  address: '10.8.0.2/32',
  serverPublicKey: 'xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=',
  endpoint: 'vpn.example.com:51820',
  allowedIps: ['10.8.0.0/24'],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const tunnel = WireGuardTunnel();
  final calls = <MethodCall>[];
  var replies = <String, Object? Function(MethodCall)>{};

  void reply(String method, Object? Function(MethodCall) handler) =>
      replies[method] = handler;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls.clear();
    replies = {};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final handler = replies[call.method];
      if (handler == null) throw MissingPluginException();
      return handler(call);
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('Android and iOS are supported, the rest is not', () {
    expect(tunnel.isSupported, isTrue);
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(tunnel.isSupported, isTrue);
    for (final platform in [
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
      TargetPlatform.fuchsia,
    ]) {
      debugDefaultTargetPlatformOverride = platform;
      expect(tunnel.isSupported, isFalse, reason: '$platform');
    }
  });

  test('publicKey', () async {
    reply('publicKey', (_) => 'abc=');
    expect(await tunnel.publicKey(), 'abc=');
  });

  test('isPrepared and prepare', () async {
    reply('isPrepared', (_) => false);
    reply('prepare', (_) => true);
    expect(await tunnel.isPrepared(), isFalse);
    expect(await tunnel.prepare(), isTrue);
  });

  test('start sends the config', () async {
    reply('up', (_) => true);
    await tunnel.start(config);
    expect(calls.single.method, 'up');
    expect(calls.single.arguments, config.toMap());
  });

  test('start checks the config before calling the platform', () async {
    reply('up', (_) => true);
    await expectLater(
      tunnel.start(config.copyWith(allowedIps: [])),
      throwsA(isA<WireGuardException>()
          .having((e) => e.code, 'code', 'bad_config')),
    );
    expect(calls, isEmpty);
  });

  test('platform errors become WireGuardException', () async {
    reply(
        'up',
        (_) => throw PlatformException(
              code: 'not_prepared',
              message: 'VPN permission not given',
            ));
    await expectLater(
      tunnel.start(config),
      throwsA(isA<WireGuardException>()
          .having((e) => e.code, 'code', 'not_prepared')
          .having((e) => e.message, 'message', 'VPN permission not given')),
    );
  });

  test('a missing plugin is reported as unsupported', () async {
    await expectLater(
      tunnel.publicKey(),
      throwsA(isA<WireGuardException>()
          .having((e) => e.code, 'code', 'unsupported')),
    );
  });

  test('stop and state', () async {
    reply('down', (_) => true);
    reply('state', (_) => 'up');
    expect(await tunnel.state(), WireGuardState.up);
    await tunnel.stop();
    reply('state', (_) => 'down');
    expect(await tunnel.state(), WireGuardState.down);
    expect(calls.map((c) => c.method), ['state', 'down', 'state']);
  });

  group('on other platforms', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.windows);

    test('queries answer without the platform', () async {
      expect(await tunnel.isPrepared(), isFalse);
      expect(await tunnel.state(), WireGuardState.down);
      await tunnel.stop();
      expect(calls, isEmpty);
    });

    test('actions throw unsupported', () async {
      for (final call in [
        tunnel.publicKey,
        tunnel.prepare,
        () => tunnel.start(config),
      ]) {
        await expectLater(
          call(),
          throwsA(isA<WireGuardException>()
              .having((e) => e.code, 'code', 'unsupported')),
        );
      }
      expect(calls, isEmpty);
    });
  });
}
