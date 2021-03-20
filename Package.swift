// swift-tools-version:5.0
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
//  $Id: //depot/HotReloading/Package.swift#11 $
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
                 .upToNextMinor(from: "7.1.1")),
        .package(url: "https://github.com/johnno1962/SwiftRegex5",
                 .upToNextMinor(from: "5.2.1")),
        .package(url: "https://github.com/johnno1962/Xprobe",
                 .upToNextMinor(from: "1.0.0")),
    ],
    targets: [
        .target(name: "HotReloading", dependencies: ["HotReloadingGuts", "SwiftTrace", "Xprobe", "XprobeSwift"]),
        .target(name: "HotReloadingGuts", dependencies: ["Xprobe"]),
        .target(name: "injectiondGuts", dependencies: ["Xprobe"]),
        .target(name: "injectiond", dependencies: ["HotReloadingGuts", "injectiondGuts", "SwiftRegex", "XprobeUI"]),
    ]
)
