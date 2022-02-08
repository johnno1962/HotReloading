// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
//  Repo: https://github.com/johnno1962/HotReloading
//  $Id: //depot/HotReloading/Package.swift#119 $
//

import PackageDescription
import Foundation

// This means of locating the IP address of developer's
// Mac has been replaced by a multicast implementation.
// If the multicast implementation fails to connect,
// clone the HotReloading project and hardcode the IP
// address of your Mac into the hostname value below.
// Then drag the clone onto your project to have it
// take precedence over the configured version.
var hostname = Host.current().name ?? "localhost"
// hostname = "192.168.0.252" // for example

let package = Package(
    name: "HotReloading",
    platforms: [.macOS("10.12"), .iOS("10.0"), .tvOS("10.0")],
    products: [
        .library(name: "HotReloading", targets: ["HotReloading"]),
        .library(name: "HotReloadingGuts", targets: ["HotReloadingGuts"]),
        .library(name: "injectiondGuts", targets: ["injectiondGuts"]),
        .executable(name: "injectiond", targets: ["injectiond"]),
    ],
    dependencies: [
        .package(url: "https://github.com/johnno1962/SwiftTrace",
                 .upToNextMinor(from: "8.2.1")),
        .package(name: "SwiftRegex",
                 url: "https://github.com/johnno1962/SwiftRegex5",
                 .upToNextMinor(from: "5.2.1")),
        .package(url: "https://github.com/johnno1962/XprobePlugin",
                 .upToNextMinor(from: "2.9.0")),
        .package(name: "RemotePlugin",
                 url: "https://github.com/johnno1962/Remote",
                 .upToNextMinor(from: "2.3.5")),
        .package(url: "https://github.com/johnno1962/DLKit",
                 .upToNextMinor(from: "1.2.1")),
        // This package is configured to use a time limited
        // binary framework that allows iOS and tvOS device
        // injection until April 13th 2022 after which I'll
        // have to find a sustainable licensing mechanism.
        // It should still work fine with the simulator.
        .package(url: "https://github.com/johnno1962/InjectionScratch",
                 .upToNextMinor(from: "1.2.7")),
    ],
    targets: [
        .target(name: "HotReloading", dependencies: ["HotReloadingGuts",
             "SwiftTrace", .product(name: "Xprobe", package: "XprobePlugin"),
                 "DLKit", .product(name: "SwiftRegex", package: "SwiftRegex"),
                 "InjectionScratch"]),
        .target(name: "HotReloadingGuts",
                cSettings: [.define("DEVELOPER_HOST", to: "\"\(hostname)\"")]),
        .target(name: "injectiondGuts"),
        .target(name: "injectiond", dependencies: ["HotReloadingGuts", "injectiondGuts",
                                   .product(name: "SwiftRegex", package: "SwiftRegex"),
                                   .product(name: "XprobeUI", package: "XprobePlugin"),
                                   .product(name: "RemoteUI", package: "RemotePlugin")]),
    ]
)
