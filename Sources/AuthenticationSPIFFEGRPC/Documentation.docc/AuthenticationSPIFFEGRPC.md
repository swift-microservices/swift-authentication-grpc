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
