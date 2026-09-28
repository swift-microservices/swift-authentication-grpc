# Repository guidelines

This package connects authentication to gRPC.

## Products

- `AuthenticationGRPC`: transport-independent bearer authentication, propagation, and metadata.
- `AuthenticationGRPCNIOTransport`: the generic certificate interceptor. An identity binds,
  nil continues anonymously, and a thrown error refuses authentication.
- `AuthenticationSPIFFEGRPC`: SPIFFE TLS callbacks, exact server-ID matching, required peer
  binding, and validated atomic credential/trust updates. It depends on AuthenticationSPIFFE;
  the generic products do not. Cryptographic/profile verification stays in that package.
- The SPIFFE interceptor requires verified TLS chain context and binds
  `PrincipalKey<Identity, SPIFFEAuthenticator.Verification>`. It refuses missing/invalid peers.
- An external provider supplies updates. No issuer or workload-attestation service is implemented
  here. Validate updates before publishing; retain only the last still-valid snapshot on failure.
- Policies and business permissions belong in application use cases. Never log private material.
- Use real TLS integration tests for identity, rotation, and rejection behavior. Bound established
  connection lifetimes and document that already-running streams require shutdown/draining.

## Swift

- Swift 6.3, strict concurrency, `Sendable` everywhere it is meaningful.
- Tests use Swift Testing and call `intercept` directly with a constructed request and context;
  generic adapter tests need no transport. SPIFFE tests also start real local TLS transports. `Metadata.bearer` is proven by a table, the certificate interceptor
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
