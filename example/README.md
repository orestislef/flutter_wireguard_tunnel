# flutter_wireguard_tunnel example

Shows the device's public key, takes a wg-quick config and starts or stops the tunnel.

Leave `PrivateKey` out of the config to use the device key, and add the shown public key as a peer on your server.

## Run it

Android: `flutter run`.

iOS: the extension target is already set up (`ios/WireGuardTunnel`, linked to the package's `ios/WireGuardTunnelKit`). Open `ios/Runner.xcworkspace`, pick your Team in Signing & Capabilities for both the Runner and WireGuardTunnel targets, change the bundle identifiers if Xcode asks, then `flutter run` on a real iPhone. The simulator cannot run VPN tunnels.
