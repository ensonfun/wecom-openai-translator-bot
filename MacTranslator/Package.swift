// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MacTranslator",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MacTranslatorCore", targets: ["MacTranslatorCore"]),
        .executable(name: "MacTranslator", targets: ["MacTranslatorApp"]),
        .executable(name: "MacTranslatorSelfTests", targets: ["MacTranslatorSelfTests"])
    ],
    targets: [
        .target(
            name: "MacTranslatorCore",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "MacTranslatorApp",
            dependencies: ["MacTranslatorCore"],
            linkerSettings: [
                .linkedFramework("Carbon")
            ]
        ),
        .executableTarget(
            name: "MacTranslatorSelfTests",
            dependencies: ["MacTranslatorCore"]
        )
    ]
)
