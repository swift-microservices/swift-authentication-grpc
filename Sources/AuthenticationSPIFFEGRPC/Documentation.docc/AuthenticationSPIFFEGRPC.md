# ``AuthenticationSPIFFEGRPC``

Stateless SPIFFE peer verification and workload principal binding for gRPC's NIO Posix transport.

## Overview

Create a `SPIFFEAuthenticator` with an explicit, fixed trust bundle. Install its
`certificateVerificationCallback(expectedPeer:)` in gRPC's mTLS configuration; clients
supply the exact expected server SPIFFE ID and disable DNS hostname matching only.
The callback validates the full chain and X.509-SVID profile and publishes verified TLS metadata.

Pass the authenticator to ``SPIFFEAuthenticationInterceptor`` for protected RPCs. It requires
TLS chain metadata, verifies the peer on every call, and binds its workload principal.
Business permissions remain in application use cases.

Use `TimedCertificateReloader` directly with `.mTLS(certificateReloader:)` and run it in the
application's service group. Validate initial local credentials before startup. The loader
checks parsing and key matching, not SPIFFE trust or identity: invalid SPIFFE replacements
are refused by verifying peers, not filtered before publication. Load failures retain the last
successfully loaded pair. Monitor expiry, renewal, and handshake errors separately.

Mount stable credential directories and atomically replace certificate files for routine
renewal with an unchanged key. Trust changes require new authenticators and transports.
Configure finite connection age, draining, and RPC deadlines; renewal does not reauthenticate
existing streams. Issuance, readiness, and lifecycle management belong to the application.

## Topics

### Workload principal binding
- ``SPIFFEAuthenticationInterceptor``
