# swift-authentication-grpc

User bearer authentication and propagation for gRPC, with mandatory transport mTLS between
services.

```swift
.package(url: "https://github.com/swift-microservices/swift-authentication-grpc.git", from: "0.3.0"),
```

```swift
.product(name: "AuthenticationGRPC", package: "swift-authentication-grpc"),
```

`AuthenticationGRPC` provides `BearerAuthenticationInterceptor`, `BearerPropagationInterceptor`,
and `Metadata.bearer` over grpc-swift-2. Bearer authentication works on any transport.

## Security model

mTLS secures service-to-service connections. JWTs additionally authenticate users making these
calls. Use separate protobuf descriptors for public, user, and internal operations:

| Audience | Application authentication | Handler and use case |
| --- | --- | --- |
| Public | Operation-specific credentials or proofs, such as a password or verification challenge | Enforces the operation's business rules |
| User or administrator | Original user JWT, verified by the receiving service | Requires the user identity and checks permissions and resource access |
| Internal service or worker | The transport authenticates the peer through mTLS | Accepts business input directly and enforces business invariants |

Every peer admitted by the listener's CA trust can call its internal RPCs. Keep listeners private
and gateway routes limited to intended public and user operations. User principals and database
settings are scoped to user descriptors.

## Authenticate user RPCs

```swift
let authenticator = JWTAuthenticator<UserIdentity>(keys: keys)

let server = GRPCServer(
    transport: transport,
    services: [publicService, userService, internalService],
    interceptorPipeline: [
        .apply(
            BearerAuthenticationInterceptor(authenticator: authenticator),
            to: .services([UserService.descriptor])
        )
    ]
)
```

`Authenticator.authenticate(_:)` returns an identity or throws. A verified token binds a
`Principal<UserIdentity, String>` in `ServiceContext` for the length of the call. An invalid token
ends the call with `RPCError(code: .unauthenticated)` before the handler runs.

A missing token continues unbound. Each user handler requires its identity before invoking the
owning use case, which checks user permissions before side effects:

```swift
guard let user = ServiceContext.current?[PrincipalKey<UserIdentity, String>.self]?.identity else {
    throw RPCError(code: .unauthenticated, message: "Sign in to continue.")
}
```

## Forward the original user JWT

```swift
let client = GRPCClient(transport: transport, interceptorPipeline: [
    .apply(
        BearerPropagationInterceptor<UserIdentity>(),
        to: .services([UpstreamUserService.descriptor])
    )
])
```

The interceptor forwards the original credential unchanged. Each receiving service verifies its
signature and claims independently. Apply propagation only to user descriptors.

## Certificate lifecycle

Composition roots use a primed `TimedCertificateReloader` with
`.mTLS(certificateReloader: reloader)` and run it alongside transports in `ServiceGroup`.
Deployment provisioning renews the mounted files. See [Mutual TLS and certificate renewal](Sources/AuthenticationGRPC/Documentation.docc/Articles/MutualTLSAndCertificateRenewal.md)
for client/server configuration and renewal operations.

## Testing a handler

`Authenticator` is a one-method protocol, so handler tests can supply a small authenticator
without generating a signing key. Interceptor tests call `intercept` directly with a constructed
request and context. Verify transport mTLS and certificate renewal with real TLS handshakes.

## Requirements

Swift 6.3, macOS 15 or Linux.

## Development

```sh
swift test
swift-format lint --strict --recursive Sources Tests
```

## Contributing

Pull requests are welcome. Keep a change focused, prove new behaviour with a test, and label the
pull request with its semantic version impact.

## License

MIT. See [LICENSE](LICENSE).
