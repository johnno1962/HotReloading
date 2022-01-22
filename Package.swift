// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
//  Repo: https://github.com/johnno1962/HotReloading
//  $Id: //depot/HotReloading/Package.swift#89 $
//

import PackageDescription
import Foundation

// This package is configured to use a time limited
// binary framework that allows iOS and tvOS device
// injection until April 13th 2022 after which I'll
// have to find some form of licensing mechanisim.
// It should still work fine with the simulator.

// If this doesn't work, setup the IP address in a
// clone of the repo and drag it onto your project.
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
                 .upToNextMinor(from: "8.0.0")),
        .package(url: "https://github.com/johnno1962/SwiftRegex5",
                 .upToNextMinor(from: "5.2.1")),
        .package(url: "https://github.com/johnno1962/XprobePlugin",
                 .upToNextMinor(from: "2.7.0")),
        .package(url: "https://github.com/johnno1962/Remote",
                 .upToNextMinor(from: "2.3.5")),
        .package(url: "https://github.com/johnno1962/DLKit",
                 .upToNextMinor(from: "1.2.1")),
    ],
    targets: [
        .target(name: "HotReloading", dependencies: ["HotReloadingGuts",
             "SwiftTrace", .product(name: "Xprobe", package: "XprobePlugin"), "DLKit",
             .product(name: "SwiftRegex", package: "SwiftRegex5"), "InjectionScratch"]),
        .target(name: "HotReloadingGuts",
                cSettings: [.define("DEVELOPER_HOST", to: "\"\(hostname)\"")]),
        .target(name: "injectiondGuts"),
        .target(name: "injectiond", dependencies: ["HotReloadingGuts", "injectiondGuts",
                                   .product(name: "SwiftRegex", package: "SwiftRegex5"),
                                   .product(name: "XprobeUI", package: "XprobePlugin"),
                                   .product(name: "RemoteUI", package: "Remote")]),
        .binaryTarget(
            name: "InjectionScratch",
            url: "https://raw.githubusercontent.com/johnno1962/InjectionScratch/master/InjectionScratch-1.1.0.zip",
            checksum: "385d4ed4bb8bc466b63799037232dc2580dedf0b9faffbe32dee52ef7fd61de3"
        ),
    ]
)
