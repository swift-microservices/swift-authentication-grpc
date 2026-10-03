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
- File headers use the compact license format documented below.

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
- PRs run documentation, formatting, compact license-header, shellcheck, and yamllint checks.
  Automatic API-breakage checking is disabled by project choice; SemVer labels still describe
  the public API impact. The docs workflow adds the DocC plugin only in its temporary checkout.
- PRs and main pushes run Linux tests on Swift 6.3 and 6.4, next/main snapshots, release builds,
  and x86_64/ARM64 static Linux SDK builds. CI has no scheduled runs. Require supported stable
  checks in branch protection; snapshot failures remain visible and advisory unless maintainers
  explicitly require them.
- Static SDK checks cross-compile only; they do not run ARM64 tests. Serialize ARM64 after
  x86_64 because SwiftNIO shares their concurrency group; run it even after x86_64 failure
  unless the workflow was canceled.
- CI is Linux-only by project choice. macOS and other Apple-platform builds/tests are
  outside this pipeline; Linux success does not establish Apple-platform compatibility.
- Shared library workflows and the SwiftNIO SemVer action follow `@main` by project choice.
  Soundness uses its release tag, and standard Actions use major-version tags. These moving
  references include upstream changes; do not describe them as immutable.
- Dependabot checks weekly, targets main, and labels workflow-update PRs `semver/none`.
- Use the three-line MIT header matched by `.license_header_template`. Keep the tools-version
  directive first in `Package.swift`, followed by that header. `.licenseignore` excludes the
  manifest (the upstream checker requires a header at line one) and the plain-text `LICENSE`.
- Keep the separate Foundation-linking consumer check on Swift 6.3 and 6.4 Noble; a successful
  static SDK build does not prove that the resolved graph avoids full Foundation.
