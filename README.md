# swift-authentication-grpc

Binding who is calling on gRPC: a bearer token or the peer's certificate on the way in, and the
same token on the way out.

```swift
.package(url: "https://github.com/swift-microservices/swift-authentication-grpc.git", from: "0.4.0"),
```

| Product | Depends on | For |
| --- | --- | --- |
| `AuthenticationGRPC` | grpc-swift-2 | the bearer interceptors and `Metadata.bearer`; any transport |
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

## Workload certificates

Use `AuthenticationGRPCNIOTransport` with `WorkloadCertificateAuthenticator` from
`AuthenticationX509`. Native gRPC mTLS verifies certificate chains and proves key possession;
clients verify the configured server DNS name against explicit CA roots.

```swift
let authenticator = try WorkloadCertificateAuthenticator(authority: "identity.production.example")
let interceptor = CertificateAuthenticationInterceptor(authenticator: authenticator)
let tls: HTTP2ServerTransport.Posix.TransportSecurity = try .mTLS(certificateReloader: reloader) {
    $0.trustRoots = trustedRoots
}
```

Run SwiftNIO Extras' `TimedCertificateReloader` in the same service group as the server and clients.
It loads the chain/key supplied by external renewal automation. Configure clients with
`.fullVerification` and the actual server DNS target. Keep Temporal's credentials and roots separate.
No custom certificate verification callback or security coordinator is needed.

The interceptor binds `PrincipalKey<WorkloadIdentity, Certificate>`. A missing certificate or nil
identity continues unbound; a thrown authentication error becomes unauthenticated. Protected internal
handlers must require that principal. Use cases authorize exact HTTPS identities, including authority
and full path, before effects. The identity URI is never fetched over HTTP.

Routine leaf renewal keeps the key and roots unchanged and atomically replaces the chain in a stable
mounted directory. Malformed updates retain the last loaded pair. Parseable invalid material can
break new handshakes. Bound server connection age and grace, and set finite RPC deadlines. Existing
streams are not reauthenticated by renewal; emergency revocation requires closing transports.
The authenticator checks caller leaf validity per RPC; TLS chain/server-name validation occurs at
handshake. Roots remain fixed for each transport, so root rotation requires transport recreation.

Tests exercise real native TLS, wrong DNS, missing/untrusted certificates, foreign/ambiguous caller
URIs, renewed material, malformed-file retention, in-flight calls and expiry on established sessions.
