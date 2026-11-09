## 0.1.0

First release.

- `WireGuardTunnel`: `prepare`, `start`, `stop`, `state`, `isPrepared`, `publicKey`.
- `WireGuardConfig` with one interface and one peer: addresses, allowed IPs, DNS, MTU, keepalive, own or device private key, preshared key. Checked before it reaches the platform. `WireGuardConfig.parse` reads wg-quick files.
- Android on the WireGuard GoBackend (`com.wireguard.android:tunnel`). Device key encrypted with an Android Keystore key.
- iOS through a packet tunnel extension with WireGuardKit and a prebuilt wireguard-go. Device key in the Keychain. `dart run flutter_wireguard_tunnel:setup_ios` copies the extension kit into the app.
- The tunnel goes down when the app is closed, on both platforms.
