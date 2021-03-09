// swift-tools-version:5.0
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
//  $Id: //depot/HotReloading/Package.swift#9 $
//

import PackageDescription
import Foundation

let package = Package(
    name: "HotReloading",
    platforms: [.macOS("10.12"), .iOS("10.0"), .tvOS("10.0")],
    products: [
        .library(name: "HotReloading", type: .dynamic, targets: ["HotReloading"]),
        .library(name: "HotReloadingGuts", targets: ["HotReloadingGuts"]),
        .library(name: "injectiondGuts", targets: ["injectiondGuts"]),
        .executable(name: "injectiond", targets: ["injectiond"]),
    ],
    dependencies: [
        .package(url: "https://github.com/johnno1962/SwiftTrace",
                 .upToNextMajor(from: "7.0.2")),
        .package(url: "https://github.com/johnno1962/SwiftRegex5",
                 .upToNextMajor(from: "5.2.1")),
    ],
    targets: [
        .target(name: "HotReloading", dependencies: ["HotReloadingGuts", "SwiftTrace"]),
        .target(name: "HotReloadingGuts", dependencies: []),
        .target(name: "injectiondGuts", dependencies: []),
        .target(name: "injectiond", dependencies: ["HotReloadingGuts", "injectiondGuts", "SwiftRegex"]),
    ]
)
