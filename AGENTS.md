# Repository guidelines

This package connects authentication to gRPC.

## Products

- `AuthenticationGRPC`: transport-independent bearer authentication, propagation, and metadata.
- `AuthenticationGRPCNIOTransport`: the generic certificate interceptor. An identity binds,
  nil continues anonymously, and a thrown error refuses authentication.
- Native required mTLS validates chains/key possession. Clients use full DNS verification and explicit roots.
- WorkloadCertificateAuthenticator from AuthenticationX509 checks HTTPS caller identity and leaf validity.
  It is a dependency of integration tests; the generic interceptor remains identity-agnostic.
- Standard TimedCertificateReloader instances belong to the application's service group. External
  automation owns issuance and renewal; no custom security state machine belongs here.
- Policies and business permissions belong in application use cases. Never log private material.
- Use real TLS integration tests for identity, rotation, and rejection behavior. Bound established
  connection lifetimes and document that already-running streams require shutdown/draining.

## Swift

- Swift 6.3, strict concurrency, `Sendable` everywhere it is meaningful.
- Tests use Swift Testing and call `intercept` directly with a constructed request and context;
  generic adapter tests need no transport. Workload tests also start real local TLS transports. `Metadata.bearer` is proven by a table, the certificate interceptor
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
