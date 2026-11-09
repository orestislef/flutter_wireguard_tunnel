# flutter_wireguard_tunnel

WireGuard tunnel for Flutter on Android and iOS. Start and stop a tunnel from Dart, send only your server's network through it (split tunnel) or everything (full tunnel). The device makes its own key pair and keeps the private key to itself, your server only ever needs the public key.

Under the hood it is the official WireGuard code on both platforms: the `com.wireguard.android:tunnel` library on Android, and wireguard-apple's WireGuardKit with wireguard-go in a packet tunnel extension on iOS.

## What it does

- start, stop and restart a tunnel with one interface and one peer
- split tunnel (only `allowedIps` go through it) or full tunnel (`0.0.0.0/0`, `::/0`)
- device key pair made on first use, private key kept encrypted on the device, `publicKey()` for your server
- or bring your own private key, and an optional preshared key
- DNS servers, MTU, persistent keepalive, IPv4 and IPv6
- reads wg-quick `.conf` files with `WireGuardConfig.parse`
- the system VPN permission prompt with `prepare()`
- the tunnel lives with the app: closing the app takes it down, so the server never sees a device that is not there

## Platform support

| Platform | Minimum | Notes |
|----------|---------|-------|
| Android  | API 24  | Nothing to set up |
| iOS      | iOS 15 for the app, iOS 16 for the tunnel | Needs a packet tunnel extension, a paid Apple developer account and a real device (the simulator cannot run VPN tunnels) |

Other platforms are not supported. `isSupported` is false there and the calls throw `WireGuardException('unsupported')`.

## Install

```yaml
dependencies:
  flutter_wireguard_tunnel: ^0.1.0
```

### Android

Nothing to do. The WireGuard library brings its own `VpnService` (with `BIND_VPN_SERVICE`) and the plugin adds the `INTERNET` permission, both are merged into your manifest by Gradle. You do not need to touch `AndroidManifest.xml`, ProGuard or desugaring settings.

Your app's `minSdk` must be 24 or higher (the Flutter default).

If you publish on Google Play, apps that use `VpnService` have to fill in the VPN declaration in the Play Console (App content), with what the VPN is used for.

### iOS

On iOS a VPN runs in its own process, a packet tunnel extension. A Flutter plugin cannot add one to your app, so this part is done once by hand in Xcode. It takes about five minutes.

**1. Copy the tunnel kit into your app**

From your app's root folder:

```sh
dart run flutter_wireguard_tunnel:setup_ios
```

This copies `WireGuardTunnelKit` into `ios/`. It is the code the extension runs, with WireGuard prebuilt, so you do not need Go or anything else installed. Commit the folder with your app. Run the command again after you upgrade the package.

**2. Add the extension target**

Open `ios/Runner.xcworkspace` in Xcode.

- File > New > Target, pick **Network Extension**, then Next.
- Product Name: `WireGuardTunnel`. Provider Type: **Packet Tunnel**. Language: Swift. Embed in Application: **Runner**. Finish.
- If Xcode asks to activate the new scheme, say **Cancel** (you keep building Runner).

The bundle identifier Xcode suggests (`<your app id>.WireGuardTunnel`) is fine. It has to start with your app's bundle identifier, the plugin finds the extension by itself.

**3. Fill in the extension code**

Run the setup command once more:

```sh
dart run flutter_wireguard_tunnel:setup_ios
```

It replaces Xcode's template in `ios/WireGuardTunnel/PacketTunnelProvider.swift` with this, which is all the extension needs:

```swift
import WireGuardTunnelKit

class PacketTunnelProvider: WireGuardTunnelProvider {}
```

(If you prefer, paste those two lines in yourself.)

**4. Link the kit to the extension**

- File > Add Package Dependencies, then **Add Local...**, pick the `ios/WireGuardTunnelKit` folder and click Add Package.
- In the dialog, add the `WireGuardTunnelKit` library to the **WireGuardTunnel** target, not to Runner.

**5. Turn on the Network Extension capability, on both targets**

For the **Runner** target and again for the **WireGuardTunnel** target:

- Signing & Capabilities, pick your Team.
- \+ Capability, **Network Extensions**, tick **Packet Tunnel**.

This creates the entitlements files (`Runner/Runner.entitlements` and `WireGuardTunnel/WireGuardTunnel.entitlements`) with:

```xml
<key>com.apple.developer.networking.networkextension</key>
<array>
    <string>packet-tunnel-provider</string>
</array>
```

A free (personal team) account cannot sign Network Extensions, it has to be a paid Apple Developer Program account.

**6. Extension build settings**

Select the **WireGuardTunnel** target:

- General > Minimum Deployments: **iOS 16.0** (Xcode sets the newest iOS by default, which most phones do not have yet).
- Build Settings, search for **Versioning**: set Marketing Version to `$(FLUTTER_BUILD_NAME)` and Current Project Version to `$(FLUTTER_BUILD_NUMBER)`, so the extension always has the same version as the app. App Store Connect complains when they differ.

The `FLUTTER_BUILD_*` values come from Flutter's `Generated.xcconfig`. Select the Runner **project** (not a target), Info tab, Configurations, open Debug, Release and Profile, and set the WireGuardTunnel line to **Generated** in each.

**7. Build phase order**

Select the **Runner** target, Build Phases, and drag **Embed Foundation Extensions** above **Thin Binary** (right after Embed Frameworks). Without this Xcode stops with "Cycle inside Runner; building could produce unreliable results".

That's it. `flutter run` on an iPhone, call `prepare()` and iOS shows "Add VPN Configurations". After that the tunnel appears in Settings > VPN with your app's name.

The [example app](example) is set up exactly like this, if you want to compare.

## Usage

```dart
import 'package:flutter_wireguard_tunnel/flutter_wireguard_tunnel.dart';

const tunnel = WireGuardTunnel();

// The VPN permission, once per install. Shows the system prompt.
if (!await tunnel.prepare()) {
  // the user said no
  return;
}

await tunnel.start(const WireGuardConfig(
  address: '10.8.0.2/32',
  serverPublicKey: 'xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=',
  endpoint: 'vpn.example.com:51820',
  allowedIps: ['10.8.0.0/24'],   // only this goes through the tunnel
));

print(await tunnel.state());     // WireGuardState.up

await tunnel.stop();
```

`start` waits until the tunnel is up and throws a `WireGuardException` when it does not come up. Calling `start` while a tunnel runs replaces it with the new config.

### The device key

```dart
final publicKey = await tunnel.publicKey();
// send it to your server, which adds the device as a peer
```

The key pair is made the first time you ask for it and stays the same afterwards. When `WireGuardConfig.privateKey` is left out, this key is used. That is the safe way: the private key never leaves the device and never goes over the network.

A typical flow is: the app sends `publicKey()` to your backend, the backend adds the peer to the WireGuard server and answers with the address, the server's public key and the endpoint, and the app calls `start`.

### A wg-quick config

```dart
final config = WireGuardConfig.parse(confFileText);
await tunnel.start(config);
```

Only one `[Peer]` is supported. Without `PrivateKey` in `[Interface]` the device key is used.

### Options

```dart
WireGuardConfig(
  address: '10.8.0.2/32, fd00::2/128',  // one or more, comma separated
  serverPublicKey: '...',
  endpoint: 'vpn.example.com:51820',     // IPv6: [2001:db8::1]:51820
  allowedIps: ['0.0.0.0/0', '::/0'],     // full tunnel
  dns: ['1.1.1.1'],                      // empty keeps the device's DNS
  privateKey: null,                      // null uses the device key
  presharedKey: null,
  persistentKeepalive: 25,               // seconds, 0 turns it off
  mtu: 1280,
)
```

Keep the keepalive on for mobile devices. It keeps the NAT mapping open, otherwise the server cannot reach the phone after a while on mobile data.

### Errors

Everything that fails throws a `WireGuardException` with a `code`:

| Code | Meaning |
|------|---------|
| `not_prepared` | the VPN permission was not given, call `prepare()` first |
| `no_extension` | iOS: the app has no packet tunnel extension, see the iOS setup |
| `no_activity` | Android: `prepare()` was called without an activity |
| `busy` | the VPN prompt is already open |
| `bad_config` | the config was rejected, `message` says which field |
| `unsupported` | not Android or iOS |
| `failed` | anything else, `message` says what |

## How the tunnel behaves

- **App closed, tunnel down.** On Android the tunnel goes down when the Flutter engine goes (the app is swiped away). On iOS the app pings the extension every 10 seconds while the tunnel is wanted. After 45 seconds without a ping the extension stops itself, and a tunnel left over from a killed app is stopped at the next launch.
- **iOS in the background.** While your app runs in the background (with a background mode such as audio or location) the tunnel stays up. When iOS suspends the app, the tunnel stops after about 45 seconds and comes back by itself when the app returns to the foreground.
- **Network changes.** WireGuard follows the device across Wi-Fi and mobile data by itself, the address inside the tunnel stays the same.
- **One tunnel.** Android and iOS allow one VPN at a time. Another VPN app taking over stops this one, `start` again to get it back.
- **Settings.** The tunnel can be switched off from the system VPN settings. Switching it on there does nothing, the config only lives in your app.

## Security

The private key is made on the device and is never sent anywhere by this package.

- Android: stored in the app's private shared preferences, encrypted with AES-GCM using a key kept in the Android Keystore. After a backup is restored on a new phone the Keystore key is gone, so a new key pair is made, your server then needs the new public key.
- iOS: stored in the Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so it is not in backups and not on other devices. It is passed to the extension in memory when the tunnel starts.

`WireGuardConfig.toString()` leaves the private and preshared keys out, so logging a config is safe.

### Encryption and the stores

WireGuard brings its own encryption (Curve25519, ChaCha20-Poly1305, BLAKE2s), not only what the operating system offers. When you submit to the App Store, answer the export compliance questions accordingly: the app uses standard encryption algorithms, not proprietary ones. You can add `ITSAppUsesNonExemptEncryption` to `ios/Runner/Info.plist` so you are not asked on every upload, once you know your answer. Check the rules that apply to you (for example the US mass market exemption and its yearly self classification report, or France's declaration if you distribute there). This is not legal advice.

If the VPN is what your app offers to its users, App Review also asks that it uses the system VPN APIs (this package does) and that the developer account belongs to an organization, not an individual.

## Tests

`flutter test` runs the Dart tests. The end to end tests in `example/integration_test/tunnel_test.dart` bring a real tunnel up on a device, against the small WireGuard server in `tool/wg_test_server` (Go, nothing else to install). The comments at the top of both files say how to run them on the Android emulator and on an iPhone.

## Updating WireGuard

The iOS WireGuard library is prebuilt in `ios/WireGuardTunnelKit/WireGuardKitGo.xcframework` from wireguard-apple at tag 1.0.16-27. To rebuild it, run `ios/WireGuardTunnelKit/build_libwg.sh` on a Mac with Xcode. Android uses `com.wireguard.android:tunnel` from Maven Central.

## Licenses

This package is MIT, see [LICENSE](LICENSE). It includes WireGuardKit from wireguard-apple (MIT, see `ios/WireGuardTunnelKit/COPYING`) and a build of wireguard-go (MIT) and the Go standard library (BSD). The Android library `com.wireguard.android:tunnel` is Apache 2.0.

WireGuard is a registered trademark of Jason A. Donenfeld. This package is not affiliated with the WireGuard project.
