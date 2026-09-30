# swift-authentication-grpc

Binding who is calling on gRPC: a bearer token or the peer's certificate on the way in, and the
same token on the way out.

```swift
.package(url: "https://github.com/swift-microservices/swift-authentication-grpc.git", from: "0.3.0"),
```

| Product | Depends on | For |
| --- | --- | --- |
| `AuthenticationGRPC` | grpc-swift-2 | the bearer interceptors and `Metadata.bearer`; any transport |
| `AuthenticationGRPCNIOTransport` | grpc-swift-nio-transport, swift-certificates | the certificate interceptor; needs the NIO Posix HTTP/2 transport, the only one that exposes the peer certificate |

Both take their authenticators from [swift-authentication](https://github.com/swift-microservices/swift-authentication)'s
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
call, so one token identifies the caller at every service in the chain. Apply it to the upstream
services that take a token, so a public service is dialled with nothing. Calls made outside a
caller's request, startup work, a workflow activity, go out unauthenticated rather than failing;
a process identifies itself on such calls with its certificate, not a token.

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
