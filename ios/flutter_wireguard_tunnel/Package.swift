// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "flutter_wireguard_tunnel",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "flutter-wireguard-tunnel", targets: ["flutter_wireguard_tunnel"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "flutter_wireguard_tunnel",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            linkerSettings: [
                .linkedFramework("NetworkExtension")
            ]
        )
    ]
)
