# ``AuthenticationSPIFFEGRPC``

SPIFFE mutual TLS and workload principal binding for the NIO Posix gRPC transport.

## Overview

Create one ``SPIFFETransportSecurity`` from validated local credentials and a domain-specific
bundle. Use its server security and finite-age server configuration, and give the same instance
to ``SPIFFEAuthenticationInterceptor``. Outgoing clients require an exact expected server ID.

An external provider calls `update` with complete renewal snapshots. Readiness fails at expiry;
failed updates retain only the last still-valid snapshot. Revocation refuses new calls but the
application must drain existing streams and outgoing transports. Issuance and attestation are
outside this product. Application use cases retain all business authorization decisions.

## Topics

### Configuration and binding
- ``SPIFFETransportSecurity``
- ``SPIFFEAuthenticationInterceptor``

## Timed certificate files

For file-delivered credentials, `security.certificateReloader(configuration:bundle:)`
returns SwiftNIO's `TimedCertificateReloader`. Add it to the application's existing
`ServiceGroup`; no extra polling or shutdown service is required.

The standard loader owns timing, file parsing and key matching. Its callback validates
SPIFFE profiles, chains and the unchanged local identity before publishing to the
transport. Failed loads retain the last valid snapshot. Success callbacks run after
SPIFFE acceptance. Out-of-order validations cannot overwrite newer updates or revocation.

Continue using `security.serverTransportSecurity()` and
`security.clientTransportSecurity(expectedServer:)`. Do not pass the raw timed loader
straight to `.mTLS` for SPIFFE: its parsing checks alone do not validate SPIFFE identity.
For conventional hostname-verified TLS, direct `.mTLS(certificateReloader:)` is appropriate.

Mount a stable credential directory read-only. The issuer atomically replaces `chain.pem`
in that directory for routine renewal, leaving the key and trusted roots unchanged.
A bind mount of an individual certificate file may keep exposing the replaced inode.
Roots are explicit, fixed configuration for this loader; root rotation uses a separate
reviewed update. Existing connections are not reauthenticated by reloading certificates;
retain finite connection lifetimes and stream draining.
