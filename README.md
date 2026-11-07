# Swift Authentication for gRPC

[![Documentation](https://img.shields.io/badge/docc-read_documentation-blue)](https://swiftpackageindex.com/swift-microservices/swift-authentication-grpc/documentation)
[![Release](https://img.shields.io/github/v/release/swift-microservices/swift-authentication-grpc)](https://github.com/swift-microservices/swift-authentication-grpc/releases)
[![Swift versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fswift-microservices%2Fswift-authentication-grpc%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/swift-microservices/swift-authentication-grpc)
[![CI](https://github.com/swift-microservices/swift-authentication-grpc/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/swift-microservices/swift-authentication-grpc/actions/workflows/ci.yml)

Swift Authentication for gRPC authenticates the user behind a gRPC call from their bearer token,
and forwards that same token when your service calls another one. Services authenticate each
other with mutual TLS at the transport.

- 🚀 Two interceptors for [grpc-swift-2](https://github.com/grpc/grpc-swift-2), one for servers
  and one for clients
- 📦 Swift Package Manager, built on
  [swift-authentication](https://github.com/swift-microservices/swift-authentication) and
  [swift-operation-context](https://github.com/swift-microservices/swift-operation-context)
- 📱 Supports Linux and macOS 15+
- 🔧 Requires Swift 6.3+

🔗 Jump to:
- 📖 [Overview](#-overview)
- 🏁 [Getting Started](#-getting-started)
- 📘 [Documentation](#-documentation)
- 🧰 [Release Info](#-release-info)
- 🛠️ [Support](#%EF%B8%8F-support)

## 📖 Overview

A request to your service carries the user's token in its `authorization` metadata. The server
interceptor checks that token with any `Authenticator` (a JWT verifier, for example) and makes the
verified identity available to your handler for the length of the call. When the handler calls
another service, the client interceptor presents the original token again, so every service in
the chain identifies the same user and verifies the token for itself.

There is no certificate interceptor. Peer identity between processes comes from mutual TLS (mTLS),
which the gRPC transport configures and checks during the TLS handshake. See
[Mutual TLS and certificate renewal](https://swiftpackageindex.com/swift-microservices/swift-authentication-grpc/documentation/authenticationgrpc/mutualtlsandcertificaterenewal).

**Key Features:**
- 🔐 **`BearerAuthenticationInterceptor`**: Verifies the bearer token and binds a
  `Principal<Identity, String>` in `OperationContext` for the call. An invalid or expired token
  ends the call with `RPCError(code: .unauthenticated)` before the handler runs.
- 🔁 **`BearerPropagationInterceptor`**: Presents the bound principal's original token, unchanged,
  on outgoing calls. With no principal bound, it leaves the request as it is.
- 🏷️ **`Metadata.bearer`**: Reads and writes the `authorization` bearer credential. The first
  `authorization` entry is authoritative, the `Bearer` scheme matches in any case, and setting it
  replaces any existing entry rather than adding a second one.
- 🧩 **Any transport, any authenticator**: Bearer authentication works on any gRPC transport and
  with any `Authenticator<String, Identity>`, such as `JWTAuthenticator` from
  [swift-authentication-jwt](https://github.com/swift-microservices/swift-authentication-jwt).

### Security model

mTLS secures service-to-service connections. JWTs additionally authenticate the users making these
calls. Give each audience its own protobuf service descriptor:

| Audience | Application authentication | Handler and use case |
| --- | --- | --- |
| Public | Operation-specific credentials or proofs, such as a password or verification challenge | Enforces the operation's business rules |
| User or administrator | Original user JWT, verified by the receiving service | Requires the user identity and checks permissions and resource access |
| Internal service or worker | The transport authenticates the peer through mTLS | Accepts business input directly and enforces business invariants |

Apply bearer authentication and propagation only to user descriptors; user principals and
database settings belong to user RPCs alone. Every peer admitted by the listener's CA trust can
call its internal RPCs, so keep backend listeners private and limit gateway routes to the intended
public and user operations.

## 🏁 Getting Started

### Prerequisites

- Swift version: Swift 6.3+
- Platforms: macOS 15+ or Linux

To install/upgrade Swift, see https://www.swift.org/install/

### Adding as a dependency

Add the package and the `AuthenticationGRPC` product to your `Package.swift`. Handlers read the
principal through `Authentication` and `OperationContext`, and the examples verify JWTs with
`AuthenticationJWT`, so depend on those directly as well:

```swift
dependencies: [
    .package(url: "https://github.com/swift-microservices/swift-authentication-grpc.git", from: "1.0.0"),
    .package(url: "https://github.com/swift-microservices/swift-authentication.git", from: "1.0.0"),
    .package(url: "https://github.com/swift-microservices/swift-operation-context.git", from: "1.0.0"),
    .package(url: "https://github.com/swift-microservices/swift-authentication-jwt.git", from: "1.0.0"),
],
targets: [
    .target(
        name: "UserService",
        dependencies: [
            .product(name: "AuthenticationGRPC", package: "swift-authentication-grpc"),
            .product(name: "Authentication", package: "swift-authentication"),
            .product(name: "OperationContext", package: "swift-operation-context"),
            .product(name: "AuthenticationJWT", package: "swift-authentication-jwt"),
        ]
    ),
]
```

### Usage

The examples use a service generated by `protoc-gen-grpc-swift` from this proto file, and
`AppToken`, your own `JWTPayload` with a `subject` claim (see
[swift-authentication-jwt](https://github.com/swift-microservices/swift-authentication-jwt)):

```proto
syntax = "proto3";
package users;

service UserService {
  rpc GetProfile(GetProfileRequest) returns (Profile);
}

message GetProfileRequest {}
message Profile { string user_id = 1; }
```

#### Authenticate users on a server

Apply `BearerAuthenticationInterceptor` to the user service, then read the principal in the
handler:

```swift
import Authentication
import AuthenticationGRPC
import AuthenticationJWT
import GRPCCore
import OperationContext

struct UserService: Users_UserService.SimpleServiceProtocol {
    func getProfile(
        request: Users_GetProfileRequest,
        context: ServerContext
    ) async throws -> Users_Profile {
        // A missing token reaches the handler unbound, so require the identity.
        guard let token = OperationContext.current[PrincipalKey<AppToken, String>.self]?.identity else {
            throw RPCError(code: .unauthenticated, message: "Sign in to continue.")
        }

        var profile = Users_Profile()
        profile.userID = token.subject
        return profile
    }
}

// `keys` is a JWTKeyCollection holding your token verification keys.
let authenticator = JWTAuthenticator<AppToken>(keys: keys)

let server = GRPCServer(
    transport: transport, // your server transport, configured with mTLS
    services: [UserService()],
    interceptorPipeline: [
        .apply(
            BearerAuthenticationInterceptor(authenticator: authenticator),
            to: .services([Users_UserService.descriptor])
        )
    ]
)
try await server.serve()
```

A verified token binds `Principal<AppToken, String>` for the call, holding the identity and the
original token. An invalid token never reaches the handler. Each handler requires its identity
before it calls the owning use case, which checks permissions before any side effects.

#### Forward the caller's token to another service

When the user service calls a downstream user service, such as billing, apply
`BearerPropagationInterceptor` to that client:

```swift
let billingClient = GRPCClient(
    transport: billingTransport, // your client transport, configured with mTLS
    interceptorPipeline: [
        .apply(
            BearerPropagationInterceptor<AppToken>(),
            to: .services([Billing_InvoiceService.descriptor])
        )
    ]
)
let invoices = Billing_InvoiceService.Client(wrapping: billingClient)

// Inside a user handler, the caller's token rides along on this call.
let response = try await invoices.listInvoices(Billing_ListInvoicesRequest())
```

The interceptor reads the principal the server interceptor bound for the current call and sends
its token unchanged. Billing verifies the token's signature and claims itself. Run the client
alongside the server, for example both in a `ServiceGroup`. Calls to internal descriptors carry
no user token: the transport presents the service's certificate during the mTLS handshake.

#### Configure mTLS and certificate renewal

The composition root creates a primed `TimedCertificateReloader` from `NIOCertificateReloading`,
passes it to each transport with `.mTLS(certificateReloader: reloader)`, and runs it alongside the
transports in a `ServiceGroup`. Deployment provisioning renews the mounted certificate files. The
[Mutual TLS and certificate renewal](https://swiftpackageindex.com/swift-microservices/swift-authentication-grpc/documentation/authenticationgrpc/mutualtlsandcertificaterenewal)
article has the full client and server configuration.

#### Testing

`Authenticator` is a one-method protocol, so handler tests can supply a small authenticator
without generating a signing key. Interceptor tests call `intercept` directly with a constructed
request and context. Verify transport mTLS and certificate renewal with real TLS handshakes.

## 📘 Documentation

- [API Documentation](https://swiftpackageindex.com/swift-microservices/swift-authentication-grpc/documentation)
  - Complete API reference and guides:
  - [Interceptors and principals](https://swiftpackageindex.com/swift-microservices/swift-authentication-grpc/documentation/authenticationgrpc/interceptorsandprincipals)
    - RPC audiences, authenticating the user, and forwarding the original JWT
  - [Mutual TLS and certificate renewal](https://swiftpackageindex.com/swift-microservices/swift-authentication-grpc/documentation/authenticationgrpc/mutualtlsandcertificaterenewal)
    - mTLS client and server transports, certificate reloading, and renewal operations
  - [Configuring transport credentials](https://swiftpackageindex.com/swift-microservices/swift-authentication-grpc/documentation/authenticationgrpc/configuringtransportcredentials)
    - Scoped configuration readers for certificate files, with application defaults
- Related packages:
  - [swift-authentication](https://github.com/swift-microservices/swift-authentication) -
    `Authenticator`, `Principal` and `PrincipalKey`
  - [swift-authentication-jwt](https://github.com/swift-microservices/swift-authentication-jwt) -
    `JWTAuthenticator` and `JWTIssuer`
  - [swift-operation-context](https://github.com/swift-microservices/swift-operation-context) -
    the task-scoped context that carries the principal

## 🧰 Release Info

- Versioning: [Semantic Versioning](https://semver.org). The public API is stable from 1.0.0, and
  only a major release breaks it. CI checks every pull request for API breakage.
- Release notes: [GitHub Releases](https://github.com/swift-microservices/swift-authentication-grpc/releases)
- Version compatibility: Swift 6.3 and 6.4, as tested by CI on Linux, and macOS 15+

## 🛠️ Support

If you have any questions or need help, feel free to reach out by [opening an
issue](https://github.com/swift-microservices/swift-authentication-grpc/issues).

Pull requests are welcome. Keep a change focused, prove new behaviour with a test, and label the
pull request with its semantic version impact.

### Development

```sh
swift test
swift-format lint --strict --recursive Sources Tests
```

## License

MIT. See [LICENSE](LICENSE).
