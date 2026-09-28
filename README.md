# swift-authentication-grpc

Binding who is calling on gRPC: a bearer token or the peer's certificate on the way in, and the
same token on the way out.

```swift
.package(url: "https://github.com/swift-microservices/swift-authentication-grpc.git", from: "0.2.0"),
```

| Product | Depends on | For |
| --- | --- | --- |
| `AuthenticationGRPC` | grpc-swift-2 | the bearer interceptors and `Metadata.bearer`; any transport |
| `AuthenticationSPIFFEGRPC` | AuthenticationSPIFFE, NIO TLS | SPIFFE mutual TLS, exact endpoint matching, peer binding, and atomic updates |
| `AuthenticationGRPCNIOTransport` | grpc-swift-nio-transport, swift-certificates | the certificate interceptor; needs the NIO Posix HTTP/2 transport, the only one that exposes the peer certificate |

The generic interceptors take their authenticators from [swift-authentication](https://github.com/swift-microservices/swift-authentication)'s
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

## SPIFFE workload authentication

```swift
import AuthenticationSPIFFE
import AuthenticationSPIFFEGRPC
import GRPCNIOTransportHTTP2Posix

let security = try await SPIFFETransportSecurity(
    certificateChain: localCertificates,
    privateKey: localPrivateKey,
    bundle: SPIFFETrustBundle(
        trustDomain: "production.example.com",
        authorities: trustedAuthorities
    )
)

let transport = HTTP2ServerTransport.Posix(
    address: .ipv4(host: "0.0.0.0", port: 50051),
    transportSecurity: try security.serverTransportSecurity(),
    config: SPIFFETransportSecurity.serverConfiguration
)
let interceptor = SPIFFEAuthenticationInterceptor(security: security)

let usersSecurity = try security.clientTransportSecurity(
    expectedServer: SPIFFEID(uri: "spiffe://production.example.com/users")
)
// Pass usersSecurity to the users client's Posix transport.
```

Apply the interceptor to the protected services. It requires a TLS-validated peer chain,
verifies it against current SPIFFE trust, and binds
`PrincipalKey<SPIFFEID, SPIFFEAuthenticator.Verification>`. A project can provide
`identity: { id in ServiceIdentity(spiffeID: id) }` to bind its own identity type. Neither
verification nor mapping grants business permissions; use cases make those decisions.

The server requires client certificates. Clients verify both the full chain and the exact
expected SPIFFE ID; DNS addresses locate endpoints and are not used as SPIFFE identities.
A missing chain or invalid peer fails as `unauthenticated`. User bearer principals are separate.
Full verification runs at handshake and on request-cache misses, not for every request.
The bounded cache expires with the chain and is invalidated on every trust update.

### Renewal and revocation

An external identity provider obtains short-lived SVIDs and trust bundles. After each update:

```swift
try await security.update(
    certificateChain: renewedCertificates,
    privateKey: renewedKey,
    bundle: renewedBundle
)
```

The adapter validates the chain and key match before atomically publishing the pair and bundle.
An invalid update leaves the last valid snapshot intact. Concurrent updates are rejected;
serialize the provider's update stream. A workload ID cannot change during renewal. New
handshakes use renewed credentials without rebuilding the listener. Readiness is
`security.isReady`; expired or revoked local material refuses new handshakes and protected RPCs.

This product is the renewal **sink**, not a SPIRE Workload API client or an issuer. The provider
integration owns attestation, fetching, renewal scheduling/backoff, and outage/expiry alerts.
Keep that task in the application's structured lifecycle. File providers must publish a coherent
certificate/key/bundle generation; never independently watch three partially replaced files.
Expose time-to-expiry and renewal outcomes from the provider without logging private material.

Use overlapping authorities during planned root rotation, renew all peers, then remove old
roots. Removal is enforced on subsequent protected RPCs even on existing connections.
`security.revoke()` refuses new handshakes and RPCs; restoring service requires a validated update.
Existing streams and outgoing connections must also be drained or shut down by the application.
TLS does not reauthenticate a connection simply because files or trust changed.

`serverConfiguration` bounds connection age to five minutes and drain grace to thirty seconds.
Choose smaller bounds when required by the credential lifetime or revocation objective, and set
RPC deadlines. This is an operational bound, not a claim of instantaneous stream revocation.

### Generic certificate identities

`AuthenticationGRPCNIOTransport` provides `CertificateAuthenticationInterceptor` for
application-defined certificate schemes. It accepts `Authenticator<Certificate, Identity>`:
an identity binds, `nil` continues anonymously, and a thrown error refuses authentication.

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
`Bearer admin-token` without minting a key. Generic interceptors are tested directly. SPIFFE tests also use real local TLS client/server
connections for endpoint matching, certificate rejection, renewal, and root removal.

## Requirements

Swift 6.3, macOS 15 or Linux.

## Development

Run `swift test` against the published package dependencies. For coordinated development
with a sibling SPIFFE checkout, use `python3 scripts/test-with-local-spiffe.py`.
The script restores the tagged manifest after the test run.

```sh
swift test
swift-format lint --strict --recursive Sources Tests    # what the soundness check runs
```

## Contributing

Pull requests are welcome. Keep a change focused, prove new behaviour with a test, and label the
pull request with its semantic version impact.

## License

MIT. See [LICENSE](LICENSE).
