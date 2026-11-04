// swift-tools-version: 6.0
// Nintanium Builder: a Mac app that builds a game's IPA with scripts/build_ipa_from_nsp.py, keeps each game's patches and cheats, installs the app and its game data on an
// iPhone or iPad (devicectl), and keeps the Nintanium checkout up to date. make_app.sh builds it into "Nintanium Builder.app".
import PackageDescription

let package = Package(
    name: "NintaniumBuilder",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "NintaniumBuilder",
            path: "Sources/NintaniumBuilder",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
