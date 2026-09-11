# swift-authentication-grpc

Binding who is calling on gRPC: a bearer token or the peer's certificate on the way in, and the
same token on the way out.

```swift
.package(url: "https://github.com/swift-microservices/swift-authentication-grpc.git", from: "0.1.0"),
```

| Product | Depends on | For |
| --- | --- | --- |
| `AuthenticationGRPC` | grpc-swift-2 | the bearer interceptors and `Metadata.bearer`; any transport |
| `AuthenticationGRPCNIOTransport` | grpc-swift-nio-transport, swift-certificates | the certificate interceptor; needs the NIO Posix HTTP/2 transport, the only one that exposes the peer certificate |

Both take their authenticators from [swift-authentication](https://github.com/swift-microservices/swift-authentication)'s
shape: an `Authenticator<Credential, Identity>` proves a credential, declines it with `nil`, or
refuses it by throwing. The interceptors read the credential off the call and bind the result as
a `Principal` in the task's `ServiceContext` for the length of the call.

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
first token and has no caller yet. A token the authenticator declines continues unbound. A token
it refuses fails the call as unauthenticated, because absent and invalid are not the same thing.

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

The transport verified the certificate at the handshake; the authenticator reads who it names.
A connection with no client certificate, or one the authenticator declines, continues unbound: an
unlisted peer is a valid one this service simply does not admit. The principal is bound under
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
