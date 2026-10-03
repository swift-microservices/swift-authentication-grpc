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
- Use the checked-in `.swift-format`, copied exactly from apple/swift-temporal-sdk at
  `508797b5468dbc532f77c317bf9df0cb3231f5c1`: four-space indentation, 150-column lines,
  and ordered imports. Format all tracked Swift files, including `Package.swift`, and run
  `swift-format lint --strict`. Public documentation remains a repository requirement even
  though this formatter does not enforce it.
- File headers follow the existing files: name, package, author, date.

## Releases

- Every pull request carries exactly one label: `⚠️ semver/major`, `🆕 semver/minor`,
  `🔨 semver/patch`, or `semver/none`. The label check blocks merging without one.
- Releases are GitHub Releases, created by the Auto Release workflow: run it by hand on `main`
  and it computes the next version from the labels of the pull requests merged since the last
  release, tags it, and writes the notes from `.github/release.yml`. A major bump is refused
  there and is cut by hand.
- Consumers pin by tag, never by branch or path.

## Library CI profile

- This repository profile overrides general service CI and formatting defaults. Libraries
  never commit `Package.resolved`; CI resolves released dependencies from the manifest.
- PRs run soundness checks, including API compatibility, documentation, formatting, shellcheck,
  and yamllint. The docs workflow adds the DocC plugin only in its temporary checkout.
  License-header checking stays disabled because source files use the author-header convention.
- PRs, main pushes, and the weekly schedule run Linux tests on Swift 6.3 and 6.4, next/main
  snapshots, release builds, and static Linux SDK compatibility. Require supported stable
  checks in branch protection; snapshot failures remain visible and advisory unless
  maintainers explicitly require them.
- CI is Linux-only by project choice. macOS and other Apple-platform builds/tests are
  outside this pipeline; Linux success does not establish Apple-platform compatibility.
- Actions and reusable workflows are SHA-pinned. The reviewed SwiftNIO main commit supplies
  Swift 6.4 inputs absent from release 2.103.0; its nested workflows and downloaded scripts
  still follow upstream main. Caller pins do not make that execution chain immutable.
- Keep the separate Foundation-linking consumer check; a successful static SDK build
  does not prove that the resolved graph avoids full Foundation.
