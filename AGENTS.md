# Repository guidelines

This package binds principals on gRPC. Read this before changing anything.

## What this package is

- Two products. `AuthenticationGRPC` holds `BearerAuthenticationInterceptor`,
  `BearerPropagationInterceptor`, `BearerCredentialsInterceptor`, and `Metadata.bearer`, so it
  works on any transport. `AuthenticationGRPCNIOTransport` holds
  `CertificateAuthenticationInterceptor` and depends on the NIO Posix HTTP/2 transport and
  swift-certificates, because only that transport exposes the peer certificate.
- The server interceptors take any `Authenticator` from swift-authentication and never know which
  credential format is in use. They read the credential off the call, apply the authenticator,
  and bind a `Principal` under `PrincipalKey<Identity, Credential>`.
- Authentication returns an identity or throws. An identity binds; a failure ends the call
  with `RPCError(code: .unauthenticated)` before the handler runs. A call with no exposed
  credential never reaches the authenticator and continues unbound.
- Server interceptors identify without requiring a caller. That is the handler's decision.
- `BearerCredentialsInterceptor` presents a token supplied by an async `@Sendable` closure on
  each interception, independently of any inbound principal. Apply it only to the RPC services
  accepting that token. It replaces authorization metadata and propagates acquisition failures
  and cancellation before calling `next`; an empty token or whitespace is unauthenticated.
- `BearerPropagationInterceptor` forwards the inbound caller's token. Configure propagation and
  supplied credentials on separate service descriptors so one call has one bearer identity.
- Internal connections use mandatory mTLS. A service JWT identifies the application caller;
  receiving services validate its issuer, audience, expiration, and purpose, and use cases
  decide permissions. An ordinary bearer token is not bound to the TLS certificate.

## What does not belong here

- Authorization. Roles and permissions are the application's.
- A credential format. Proofs are swift-authentication-jwt and swift-authentication-x509.
- Credential issuance protocols, token endpoints, acquisition, caching, renewal, and signing-key
  management. Those belong to the issuer and authentication client supplied by the application.
- Application workload names, token claims, audience values, and permission policies.

## Swift

- Swift 6.3, strict concurrency, `Sendable` everywhere it is meaningful.
- Tests use Swift Testing and call `intercept` directly with a constructed request and context;
  no transport is started. `Metadata.bearer` is proven by a table, the certificate interceptor
  against certificates generated in memory over a constructed NIO transport context.
- Doc comments on every public declaration; the DocC catalog is the long-form explanation.
- Format with `swift-format format --in-place --recursive Sources Tests`; the soundness check on
  every pull request runs the same rules, an API breakage check against the base branch, and
  shellcheck and yamllint.
- File headers follow the existing files: name, package, author, date.

## Releases

- Every pull request carries exactly one label: `⚠️ semver/major`, `🆕 semver/minor`,
  `🔨 semver/patch`, or `semver/none`. The label check blocks merging without one.
- Releases are GitHub Releases, created by the Auto Release workflow: run it by hand on `main`
  and it computes the next version from the labels of the pull requests merged since the last
  release, tags it, and writes the notes from `.github/release.yml`. A major bump is refused
  there and is cut by hand.
- Consumers pin by tag, never by branch or path.
