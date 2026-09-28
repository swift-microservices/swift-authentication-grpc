// swift-tools-version: 6.3
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
        .library(name: "AuthenticationSPIFFEGRPC", targets: ["AuthenticationSPIFFEGRPC"]),
        .library(
            name: "AuthenticationGRPC",
            targets: ["AuthenticationGRPC"]
        ),
        .library(
            name: "AuthenticationGRPCNIOTransport",
            targets: ["AuthenticationGRPCNIOTransport"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swift-microservices/swift-authentication-spiffe.git", from: "0.2.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.103.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.5"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.35.1"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.7.3"),
        .package(url: "https://github.com/swift-microservices/swift-authentication.git", from: "0.2.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.20.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
        .package(url: "https://github.com/apple/swift-service-context.git", from: "1.3.0"),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.10.0"),
    ],
    targets: [
        .target(
            name: "AuthenticationSPIFFEGRPC",
            dependencies: [
                .product(name: "AuthenticationSPIFFE", package: "swift-authentication-spiffe"),
                .product(name: "Authentication", package: "swift-authentication"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2Posix", package: "grpc-swift-nio-transport"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOCertificateReloading", package: "swift-nio-extras"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "ServiceContextModule", package: "swift-service-context"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AuthenticationSPIFFEGRPCTests",
            dependencies: [
                .target(name: "AuthenticationSPIFFEGRPC"),
                .product(name: "AuthenticationSPIFFE", package: "swift-authentication-spiffe"),
                .product(name: "Authentication", package: "swift-authentication"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2Posix", package: "grpc-swift-nio-transport"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "ServiceContextModule", package: "swift-service-context"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "AuthenticationGRPC",
            dependencies: [
                .product(name: "Authentication", package: "swift-authentication"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "ServiceContextModule", package: "swift-service-context"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "AuthenticationGRPCNIOTransport",
            dependencies: [
                .product(name: "Authentication", package: "swift-authentication"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2Posix", package: "grpc-swift-nio-transport"),
                .product(name: "ServiceContextModule", package: "swift-service-context"),
                .product(name: "X509", package: "swift-certificates"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AuthenticationGRPCTests",
            dependencies: [
                .target(name: "AuthenticationGRPC"),
                .product(name: "Authentication", package: "swift-authentication"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "ServiceContextModule", package: "swift-service-context"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AuthenticationGRPCNIOTransportTests",
            dependencies: [
                .target(name: "AuthenticationGRPCNIOTransport"),
                .product(name: "Authentication", package: "swift-authentication"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2Posix", package: "grpc-swift-nio-transport"),
                .product(name: "ServiceContextModule", package: "swift-service-context"),
                .product(name: "X509", package: "swift-certificates"),
            ],
            swiftSettings: swiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
