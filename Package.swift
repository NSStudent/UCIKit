// swift-tools-version: 6.1

import PackageDescription

// UCIKit: talk UCI to any chess engine from Swift, whatever carries the text.
// MIT. It contains no engine: Stockfish, Caissa and others are separate packages, packs or programs.
let package = Package(
    name: "UCIKit",
    platforms: [.iOS(.v18), .macOS(.v15), .macCatalyst(.v18)],
    products: [
        .library(name: "UCIKit", targets: ["UCIKit"]),
        .library(name: "UCIKitWeb", targets: ["UCIKitWeb"]),
        .library(name: "UCIKitProcess", targets: ["UCIKitProcess"]),
    ],
    targets: [
        .target(name: "UCIKit"),
        // A WebAssembly engine in a hidden WKWebView, served from 127.0.0.1 with COOP/COEP so threads work.
        .target(name: "UCIKitWeb", dependencies: ["UCIKit"]),
        // A separate engine program over pipes (macOS and Mac Catalyst; iOS cannot start processes).
        .target(name: "UCIKitProcess", dependencies: ["UCIKit"]),
        .testTarget(name: "UCIKitTests", dependencies: ["UCIKit", "UCIKitProcess", "UCIKitWeb"]),
    ]
)
