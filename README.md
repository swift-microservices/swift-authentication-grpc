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

Use the standard gRPC mTLS API with a certificate reloader and a fixed SPIFFE authenticator:

```swift
import AuthenticationSPIFFE
import AuthenticationSPIFFEGRPC
import GRPCNIOTransportHTTP2Posix
import NIOCertificateReloading

let authenticator = SPIFFEAuthenticator(bundle: bundle)
let reloader = try TimedCertificateReloader.makeReloaderValidatingSources(
    configuration: .init(
        refreshInterval: .seconds(60),
        certificateSource: .init(location: .file(path: "/run/tls/chain.pem"), format: .pem),
        privateKeySource: .init(location: .file(path: "/run/tls/key.pem"), format: .pem)
    )
)
let roots = TLSConfig.TrustRootsSource.certificates([
    .file(path: "/run/tls/bundle.pem", format: .pem)
])
let serverSecurity = try HTTP2ServerTransport.Posix.TransportSecurity.mTLS(
    certificateReloader: reloader
) {
    $0.trustRoots = roots
    $0.requireALPN = true
    $0.customVerificationCallback = authenticator.certificateVerificationCallback()
}
let interceptor = SPIFFEAuthenticationInterceptor(authenticator: authenticator)

let usersID = try SPIFFEID(uri: "spiffe://production.example.com/users")
let clientSecurity = try HTTP2ClientTransport.Posix.TransportSecurity.mTLS(
    certificateReloader: reloader
) {
    $0.trustRoots = roots
    $0.serverCertificateVerification = .noHostnameVerification
    $0.customVerificationCallback = authenticator.certificateVerificationCallback(expectedPeer: usersID)
}
```

Construct `bundle` from explicit trusted authorities for your trust domain. Validate the initial
local certificate chain, expected workload ID, key match, and sufficient remaining lifetime
before starting transports. Add the reloader to the application's `ServiceGroup` alongside
its servers, clients, and workers. Clients must supply the exact expected server SPIFFE ID;
DNS addresses locate endpoints but do not authenticate SPIFFE identities.

The TLS callback validates the peer's complete chain and X.509-SVID profile and supplies
verified chain metadata. The interceptor requires that metadata, revalidates the peer on
every protected RPC, and binds `PrincipalKey<SPIFFEID, SPIFFEAuthenticator.Verification>`.
Use `identity: ServiceIdentity.init(spiffeID:)` to bind a project identity. Authorization
belongs in use cases; user bearer principals remain separate. There is no peer cache or
shared mutable authentication state.

### Certificate renewal

An external issuer renews credentials. `TimedCertificateReloader` reads certificate/key files
and supplies them directly to gRPC. Parsing or key-matching errors retain the last successfully
loaded pair. The loader does not validate SPIFFE identity, trust, or expiry before publication:
a parseable but invalid SVID can become the offered credential, and verifying peers reject it.
Monitor issuer, load, handshake, and expiry failures; a successful load is not SPIFFE acceptance.

For routine leaf renewal, mount a stable credential directory and atomically replace the
certificate file, preserving its key and trust bundle. Individual file bind mounts can retain
old inodes. Coordinate private-key changes separately. Trust bundles are fixed for the lifetime
of the authenticator; root changes require rebuilding the authenticator and transports.

Set finite server connection age and drain grace (for example five minutes and thirty seconds)
and RPC deadlines in the application. Reloading affects new handshakes; existing connections
and in-flight streams are not reauthenticated. Protected RPCs recheck the calling peer's expiry,
but this product supplies no local revocation switch or local-credential readiness service.

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
