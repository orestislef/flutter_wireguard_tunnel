// swift-tools-version:5.9
// The packet tunnel extension's half of flutter_wireguard_tunnel. Copied into
// the app's ios folder by `dart run flutter_wireguard_tunnel:setup_ios` and
// linked to the extension target only, never to Runner.
//
// WireGuardKit and WireGuardKitC are wireguard-apple at 2fec12a6 (tag
// 1.0.16-27, MIT, see COPYING), plus a sys/types.h include in WireGuardKitC.h
// that newer Xcode needs. Vendored because its own manifest builds the Go
// library on every build and needs Go installed. WireGuardKitGo is that Go
// library prebuilt, see build_libwg.sh.

import PackageDescription

let package = Package(
  name: "WireGuardTunnelKit",
  platforms: [.iOS(.v15)],
  products: [
    .library(name: "WireGuardTunnelKit", targets: ["WireGuardTunnelKit"])
  ],
  targets: [
    .target(name: "WireGuardTunnelKit", dependencies: ["WireGuardKit"]),
    .target(name: "WireGuardKit", dependencies: ["WireGuardKitGo", "WireGuardKitC"]),
    .target(name: "WireGuardKitC", publicHeadersPath: "."),
    .binaryTarget(name: "WireGuardKitGo", path: "WireGuardKitGo.xcframework"),
  ]
)
