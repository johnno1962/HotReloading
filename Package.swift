// swift-tools-version:5.2
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
//  Repo: https://github.com/johnno1962/HotReloading
//  $Id: //depot/HotReloading/Package.swift#205 $
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
// hostname = "192.168.0.243" // for example

let simulateDlopenOnDevice = false

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
                 .upToNextMinor(from: "8.6.1")),
        .package(name: "SwiftRegex",
                 url: "https://github.com/johnno1962/SwiftRegex5",
                 .upToNextMinor(from: "6.1.2")),
        .package(url: "https://github.com/johnno1962/XprobePlugin",
                 .upToNextMinor(from: "2.9.10")),
        .package(name: "RemotePlugin",
                 url: "https://github.com/johnno1962/Remote",
                 .upToNextMinor(from: "2.3.5")),
        .package(url: "https://github.com/johnno1962/ProfileSwiftUI",
                 .upToNextMinor(from: "1.1.3")),
//        .package(url: "https://github.com/johnno1962/DLKit",
//                 .upToNextMinor(from: "1.2.1")),
    ] + (simulateDlopenOnDevice ? [
        .package(url: "https://github.com/johnno1962/InjectionScratch",
                 .upToNextMinor(from: "1.2.13"))] : []),
    targets: [
        .target(name: "HotReloading", dependencies: ["HotReloadingGuts",
                 .product(name: "SwiftTraceD", package: "SwiftTrace"),
                 .product(name: "Xprobe", package: "XprobePlugin"),
                 .product(name: "SwiftRegex", package: "SwiftRegex"),
                    "ProfileSwiftUI" /*, "DLKit",
                    */] + (simulateDlopenOnDevice ? ["InjectionScratch"] : [])
                    /*, linkerSettings: [.unsafeFlags([
                    "-Xlinker", "-interposable", "-undefined", "dynamic_lookup"])]*/),
        .target(name: "HotReloadingGuts",
                cSettings: [.define("DEVELOPER_HOST", to: "\"\(hostname)\"")]),
        .target(name: "injectiondGuts"),
        .target(name: "injectiond", dependencies: ["HotReloadingGuts", "injectiondGuts",
                                   .product(name: "SwiftRegex", package: "SwiftRegex"),
                                   .product(name: "XprobeUI", package: "XprobePlugin"),
                                   .product(name: "RemoteUI", package: "RemotePlugin")],
                swiftSettings: [.define("INJECTION_III_APP")])],
    cxxLanguageStandard: .cxx11
)
