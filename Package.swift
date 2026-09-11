// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "swift-authentication-grpc",
    platforms: [
        .macOS(.v15)
    ],
    products: [
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
        .package(url: "https://github.com/swift-microservices/swift-authentication.git", from: "0.1.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.20.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
        .package(url: "https://github.com/apple/swift-service-context.git", from: "1.3.0"),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.9.0"),
    ],
    targets: [
        .target(
            name: "AuthenticationGRPC",
            dependencies: [
                .product(name: "Authentication", package: "swift-authentication"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "ServiceContextModule", package: "swift-service-context"),
            ]
        ),
        .target(
            name: "AuthenticationGRPCNIOTransport",
            dependencies: [
                .product(name: "Authentication", package: "swift-authentication"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2Posix", package: "grpc-swift-nio-transport"),
                .product(name: "ServiceContextModule", package: "swift-service-context"),
                .product(name: "X509", package: "swift-certificates"),
            ]
        ),
        .testTarget(
            name: "AuthenticationGRPCTests",
            dependencies: [
                .target(name: "AuthenticationGRPC"),
                .product(name: "Authentication", package: "swift-authentication"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "ServiceContextModule", package: "swift-service-context"),
            ]
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
            ]
        ),
    ]
)
