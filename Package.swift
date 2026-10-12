// swift-tools-version: 6.3
// Copyright (c) 2026 Zaid Rahhawi
// SPDX-License-Identifier: MIT
// See LICENSE for license information.

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    // https://github.com/apple/swift-evolution/blob/main/proposals/0335-existential-any.md
    .enableUpcomingFeature("ExistentialAny"),

    // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0444-member-import-visibility.md
    .enableUpcomingFeature("MemberImportVisibility"),

    // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0409-access-level-on-imports.md
    .enableUpcomingFeature("InternalImportsByDefault"),

    // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "swift-authentication-grpc",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "AuthenticationGRPC",
            targets: ["AuthenticationGRPC"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/swift-microservices/swift-authentication.git", from: "0.4.0"),
        .package(url: "https://github.com/swift-microservices/swift-operation-context.git", from: "0.1.0"),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.0"),
    ],
    targets: [
        .target(
            name: "AuthenticationGRPC",
            dependencies: [
                .product(name: "Authentication", package: "swift-authentication"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "OperationContext", package: "swift-operation-context"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AuthenticationGRPCTests",
            dependencies: [
                .target(name: "AuthenticationGRPC"),
                .product(name: "Authentication", package: "swift-authentication"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "OperationContext", package: "swift-operation-context"),
            ],
            swiftSettings: swiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
