import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'wireguard_config.dart';

/// Whether the tunnel is up.
enum WireGuardState { down, up }

/// A tunnel call that failed.
///
/// [code] is one of:
///
/// - `unsupported`: not Android or iOS
/// - `not_prepared`: the VPN permission was not given, call
///   [WireGuardTunnel.prepare] first
/// - `no_extension`: iOS only, the app has no packet tunnel extension (see
///   the iOS setup in the README)
/// - `no_activity`: Android only, [WireGuardTunnel.prepare] was called
///   without an activity
/// - `busy`: the VPN prompt is already open
/// - `bad_config`: the config was rejected
/// - `failed`: anything else, [message] says what
class WireGuardException implements Exception {
  const WireGuardException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'WireGuardException($code): $message';
}

/// The WireGuard tunnel on this device.
///
/// ```dart
/// const tunnel = WireGuardTunnel();
/// if (!await tunnel.prepare()) return;      // the VPN permission prompt
/// await tunnel.start(config);
/// ...
/// await tunnel.stop();
/// ```
///
/// There is one tunnel per app, starting again replaces the running one.
/// The tunnel belongs to the app: it goes down when the app is closed.
class WireGuardTunnel {
  const WireGuardTunnel();

  static const MethodChannel _channel =
      MethodChannel('flutter_wireguard_tunnel');

  /// Android and iOS.
  bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// This device's public key, base64. Give it to the server so it can add
  /// the device as a peer.
  ///
  /// The key pair is made on first use and kept on the device (Android
  /// Keystore, iOS Keychain). The private key never leaves the device.
  Future<String> publicKey() async =>
      (await _invoke<String>('publicKey')) ?? '';

  /// Whether the VPN permission is already given, so [start] works without
  /// a prompt.
  Future<bool> isPrepared() async {
    if (!isSupported) return false;
    return (await _invoke<bool>('isPrepared')) ?? false;
  }

  /// Asks for the VPN permission: Android's "Connection request" dialog, or
  /// iOS's "Add VPN Configurations" alert. Shown once, later calls return
  /// true straight away. False when the user says no.
  Future<bool> prepare() async => (await _invoke<bool>('prepare')) ?? false;

  /// Brings the tunnel up with [config] and waits until it is up. A running
  /// tunnel is replaced.
  ///
  /// Throws a [WireGuardException] when it does not come up.
  Future<void> start(WireGuardConfig config) async {
    final problem = config.validate();
    if (problem != null) throw WireGuardException('bad_config', problem);
    await _invoke<bool>('up', config.toMap());
  }

  /// Takes the tunnel down. Does nothing when it is already down.
  Future<void> stop() async {
    if (!isSupported) return;
    await _invoke<bool>('down');
  }

  /// Whether the tunnel is up right now.
  Future<WireGuardState> state() async {
    if (!isSupported) return WireGuardState.down;
    final state = await _invoke<String>('state');
    return state == 'up' ? WireGuardState.up : WireGuardState.down;
  }

  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    if (!isSupported) {
      throw const WireGuardException(
        'unsupported',
        'WireGuard tunnels work on Android and iOS only',
      );
    }
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (e) {
      throw WireGuardException(e.code, e.message ?? e.code);
    } on MissingPluginException {
      throw const WireGuardException(
        'unsupported',
        'The plugin is not registered, rebuild the app',
      );
    }
  }
}
