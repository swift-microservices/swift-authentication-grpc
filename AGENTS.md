# Repository guidelines

This package binds principals on gRPC. Read this before changing anything.

## What this package is

- `AuthenticationGRPC` provides `BearerAuthenticationInterceptor`,
  `BearerPropagationInterceptor`, and `Metadata.bearer` over grpc-swift-2, on any transport.
- Authenticators return a concrete identity or throw. Server interceptors bind successful
  identities under `PrincipalKey<Identity, Credential>`, translate failures to
  `RPCError(code: .unauthenticated)`, and continue unbound when no credential is exposed.
- Public, user, and internal protobuf service descriptors are separate. Scope user bearer
  authentication, propagation, and user database settings to user descriptors. User handlers
  require an identity; owning use cases check user permissions and resource access.
- Forward the original user JWT unchanged. Each receiving service verifies it independently.
- Every backend listener and outgoing service/worker connection requires transport mTLS.
  Internal handlers accept business input directly and enforce business invariants. Every peer
  admitted by the listener's explicit CA trust can call its internal RPCs.
- Keep listeners private and gateway routes limited to intended public and user operations.
  Public operations retain their required credentials and proofs.
- Composition roots prime `TimedCertificateReloader` with `makeReloaderValidatingSources`,
  pass it to `.mTLS(certificateReloader:)`, configure explicit trusted roots and full server
  hostname verification, and run it with transports in `ServiceGroup`. Deployment provisioning
  owns renewal on disk; the reloader reads renewed files for new handshakes.

## What does not belong here

- Authorization policies, workload permission lists, or application token claims.
- JWT issuance and verification implementation; swift-authentication-jwt owns those adapters.
- Certificate issuance, renewal daemons, and deployment secrets. Document their transport
  lifecycle in the DocC guide without adding them to the bearer interceptor API.

## Swift

- Swift 6.3, strict concurrency, `Sendable` everywhere it is meaningful.
- Tests use Swift Testing and call `intercept` directly with a constructed request and context;
  no transport is started. `Metadata.bearer` is proven by a table. Real transport admission and
  certificate renewal belong to application integration tests.
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
