# swift-authentication-grpc

Binding who is calling on gRPC: a bearer token or the peer's certificate on the way in, and a
propagated or supplied bearer token on the way out.

```swift
.package(url: "https://github.com/swift-microservices/swift-authentication-grpc.git", from: "0.3.0"),
```

| Product | Depends on | For |
| --- | --- | --- |
| `AuthenticationGRPC` | grpc-swift-2 | the bearer interceptors and `Metadata.bearer`; any transport |
| `AuthenticationGRPCNIOTransport` | grpc-swift-nio-transport, swift-certificates | the certificate interceptor; needs the NIO Posix HTTP/2 transport, the only one that exposes the peer certificate |

The server interceptors take their authenticators from [swift-authentication](https://github.com/swift-microservices/swift-authentication)'s
contract: `Authenticator<Credential, Identity>.authenticate(_:)` returns an identity or throws.
The interceptors read the credential off the call and bind the identity and credential as a
`Principal` in the task's `ServiceContext` for the length of the call. A failed authentication
ends the call with `RPCError(code: .unauthenticated)` before the handler runs.

## Binding a caller from a token

```swift
let authenticator = JWTAuthenticator<AppToken>(keys: keys)

GRPCServer(
    transport: transport,
    services: [service],
    interceptorPipeline: [
        .apply(BearerAuthenticationInterceptor(authenticator: authenticator), to: .services([Service.descriptor]))
    ]
)
```

A call with no token continues anonymously, which is what an open RPC needs: signing in mints the
first token and has no caller yet. A presented token must authenticate successfully; a failure
ends the call as unauthenticated before the handler runs.

Requiring a caller is the handler's decision:

```swift
guard let caller = ServiceContext.current?[PrincipalKey<AppToken, String>.self]?.identity else {
    throw RPCError(code: .unauthenticated, message: "Sign in to continue.")
}
```

## Binding a peer from its certificate

```swift
import AuthenticationGRPCNIOTransport

CertificateAuthenticationInterceptor(authenticator: SPIFFEAuthenticator(trustDomain: "example"))
```

The transport validates the certificate at the handshake; the authenticator establishes an
accepted identity. A call with no exposed client certificate continues unbound. A presented
certificate must authenticate successfully; a failure ends the call as unauthenticated before
the handler runs. The principal is bound under
`PrincipalKey<SPIFFEID, Certificate>`, separately from any bearer principal, because a service
relaying a person's call arrives with its own certificate and the person's token.

## Calling onward as the same caller

```swift
GRPCClient(transport: transport, interceptorPipeline: [
    .apply(BearerPropagationInterceptor<AppToken>(), to: .services([UpstreamService.descriptor]))
])
```

The propagation interceptor reads the bearer principal and puts its token back on the outgoing
call. Apply it to the upstream services that accept that caller's token, so a public service is
dialled with nothing. Calls made outside a caller's request have no token to propagate and
continue without one.

## Calling as a service or worker

Supply a bearer token through an async closure, applied only to the internal RPC services that
accept it:

```swift
let credentials = BearerCredentialsInterceptor {
    try await authenticationClient.accessToken(for: "users-internal")
}

GRPCClient(transport: mtlsTransport, interceptorPipeline: [
    .apply(credentials, to: .services([UserInternalService.descriptor]))
])
```

`authenticationClient` is the application's token client. It obtains, caches, and renews a
short-lived service access token from a trusted issuer. The interceptor calls the closure on
each interception, replaces authorization metadata with the supplied token, and presents it
independently of any inbound principal. The closure may be called concurrently. Acquisition
failures and cancellation propagate before the next interceptor runs; an empty token or a
token containing whitespace fails as unauthenticated. There is no token cache or renewal task
inside the interceptor.

Use `JWTAuthenticator<ServiceIdentity>` and `BearerAuthenticationInterceptor` at the receiver,
where `ServiceIdentity` is the application's `JWTPayload`. Configure the application's token
verification to enforce the expected issuer, audience, expiration, and service-token purpose.
Internal handlers require the bound identity, and owning use cases check permissions before
side effects. Configure
supplied credentials and user-token propagation on separate service descriptors.

Internal connections retain mandatory mTLS. An ordinary bearer JWT is independent of the
client certificate; certificate-bound tokens require an additional binding check. During a
Temporal Activity, obtain credentials in the outgoing client path. Keep access tokens outside
workflow inputs, Activity results, and workflow history.

## Testing a handler

`Authenticator` is a one-method protocol, so a handler test conforms a dictionary to it and sends
`Bearer admin-token` without minting a key. The interceptors themselves are tested the same way
here, by calling `intercept` directly with a constructed request and context.

## Requirements

Swift 6.3, macOS 15 or Linux.

## Development

```sh
swift test
swift-format lint --strict --recursive Sources Tests    # what the soundness check runs
```

## Contributing

Pull requests are welcome. Keep a change focused, prove new behaviour with a test, and label the
pull request with its semantic version impact.

## License

MIT. See [LICENSE](LICENSE).
