# Repository guidelines

This package binds principals on gRPC. Read this before changing anything.

## What this package is

- Two products. `AuthenticationGRPC` holds `BearerAuthenticationInterceptor`,
  `BearerPropagationInterceptor`, and `Metadata.bearer`, and depends on grpc-swift-2 alone, so it
  works on any transport. `AuthenticationGRPCNIOTransport` holds
  `CertificateAuthenticationInterceptor` and depends on the NIO Posix HTTP/2 transport and
  swift-certificates, because only that transport exposes the peer certificate.
- The interceptors take any `Authenticator` from swift-authentication and never know which
  credential format is in use. They read the credential off the call, apply the authenticator,
  and bind a `Principal` under `PrincipalKey<Identity, Credential>`.
- The three answers are honoured exactly: an identity binds, `nil` continues unbound, a throw
  fails the call with `RPCError(code: .unauthenticated)`. A call with no credential never
  reaches the authenticator.
- Interceptors never require a caller. That is the handler's decision.

## What does not belong here

- Authorization. Roles and permissions are the application's.
- A credential format. Proofs are swift-authentication-jwt and swift-authentication-x509.
- A process credential for outgoing calls. `BearerPropagationInterceptor` forwards the inbound
  caller's token and nothing else; a process identifies itself with its certificate.

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
