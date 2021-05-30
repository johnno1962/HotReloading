// swift-tools-version:5.0
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
//  $Id: //depot/HotReloading/Package.swift#49 $
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
                 .revision("328a5fbef73382626666ddb8bd7098715c289915")),
        .package(url: "https://github.com/johnno1962/SwiftRegex5",
                 .upToNextMinor(from: "5.2.1")),
        .package(url: "https://github.com/johnno1962/XprobePlugin",
                 .upToNextMinor(from: "2.3.1")),
        .package(url: "https://github.com/johnno1962/Remote",
                 .upToNextMinor(from: "2.2.4")),
    ],
    targets: [
        .target(name: "HotReloading", dependencies: ["HotReloadingGuts",
                                 "SwiftTrace", "Xprobe"]),
        .target(name: "HotReloadingGuts", dependencies: []),
        .target(name: "injectiondGuts", dependencies: []),
        .target(name: "injectiond", dependencies: ["HotReloadingGuts",
                           "injectiondGuts", "SwiftRegex", "XprobeUI", "RemoteUI"]),
    ]
)
