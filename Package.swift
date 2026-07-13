// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MaVo",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MaVo", targets: ["MaVo"]),
        .executable(name: "MaVoNetworkHelper", targets: ["MaVoNetworkHelper"]),
        .executable(name: "MaVoDialProbe", targets: ["MaVoDialProbe"]),
        .executable(name: "MaVoSMSDeleteProbe", targets: ["MaVoSMSDeleteProbe"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "CModemBridge",
            dependencies: [],
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOKit")
            ]
        ),
        .target(
            name: "CUACProbe",
            dependencies: [],
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOKit")
            ]
        ),
        .target(
            name: "MaVoNetworkIPC",
            dependencies: [],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "MaVo",
            dependencies: ["CModemBridge", "CUACProbe", "MaVoNetworkIPC"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Security"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .executableTarget(
            name: "MaVoNetworkHelper",
            dependencies: ["MaVoNetworkIPC"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration")
            ]
        ),
        .executableTarget(
            name: "MaVoDialProbe",
            dependencies: ["CModemBridge", "CUACProbe"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "MaVoSMSDeleteProbe",
            dependencies: ["CModemBridge"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
