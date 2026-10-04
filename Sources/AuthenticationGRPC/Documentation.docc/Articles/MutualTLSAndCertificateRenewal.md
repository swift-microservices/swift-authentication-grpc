# Mutual TLS and certificate renewal

Secure gRPC connections and reload renewed certificates without restarting the application.

## Overview

mTLS secures service-to-service connections, including gateway upstreams and worker clients.
User JWTs additionally authenticate users making these calls. Configure trusted CA roots
explicitly, require client certificates at backend listeners, and verify server certificates
and destination hostnames at clients. Keep backend listeners private.

The composition root configures transports and runs the certificate reloader. Deployment
provisioning issues and renews certificates. The examples use grpc-swift-nio-transport 2.10.0,
swift-nio-extras 1.35.1, grpc-swift-extras 2.2.0, and swift-service-lifecycle 2.11.0 or later.
For environment overrides and reusable configuration adapters, see <doc:ConfiguringTransportCredentials>.

## Provision the certificate directory

Issue a certificate/key pair per workload instance with the required TLS purposes and server
DNS SANs. Separate production and non-production CA trust. Mount the renewable directory at
`/run/tls`, writable by the provisioner and read-only in the application:

| File | Contents |
| --- | --- |
| `cert.pem` | Leaf certificate and required intermediates |
| `key.pem` | Matching private key |
| `ca.pem` | Trusted peer CA bundle |

Use scoped enrollment credentials, remove them after enrollment, and protect CA signing
material. Start the application after the initial files are available.

## Prime the reloader

The composition target declares the imported products below from grpc-swift-2,
grpc-swift-nio-transport, grpc-swift-extras, swift-log, swift-nio-extras, and
swift-service-lifecycle. `GRPCServiceLifecycle` supplies the gRPC client/server lifecycle
conformances.

```swift
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import GRPCServiceLifecycle
import Logging
import NIOCertificateReloading
import ServiceLifecycle

let logger = Logger(label: "service.transport")
var configuration = TimedCertificateReloader.Configuration(
    refreshInterval: .seconds(60),
    certificateSource: .init(
        location: .file(path: "/run/tls/cert.pem"),
        format: .pem
    ),
    privateKeySource: .init(
        location: .file(path: "/run/tls/key.pem"),
        format: .pem
    )
)
configuration.logger = logger
configuration.onCertificateLoadFailed = { failure in
    logger.warning("TLS certificate reload failed", metadata: ["error": "\(failure.error)"])
}
let reloader = try TimedCertificateReloader.makeReloaderValidatingSources(
    configuration: configuration
)
```

The validating factory loads the initial pair before transport creation; unreadable, malformed,
or mismatched material fails startup. Create one reloader per pair and reuse it where the
certificate supports the transports' client/server purposes. Configure destination trust
separately.

## Configure client and server transports

Use the destination DNS name covered by its certificate and retain full server verification:

```swift
let clientTransport = try HTTP2ClientTransport.Posix(
    target: .dns(host: "users.internal", port: 50051),
    transportSecurity: .mTLS(certificateReloader: reloader) {
        $0.trustRoots = .certificates([.file(path: "/run/tls/ca.pem", format: .pem)])
        $0.serverCertificateVerification = .fullVerification
    }
)
let client = GRPCClient(transport: clientTransport)
```

Require client certificates at the internal listener and bound connection age:

```swift
let serverTransport = HTTP2ServerTransport.Posix(
    address: .ipv4(host: "0.0.0.0", port: 50051),
    transportSecurity: try .mTLS(certificateReloader: reloader) {
        $0.trustRoots = .certificates([.file(path: "/run/tls/ca.pem", format: .pem)])
        $0.clientCertificateVerification = .noHostnameVerification
    },
    config: .defaults {
        $0.connection.maxAge = .seconds(300)
        $0.connection.maxGraceTime = .seconds(30)
    }
)
```

Server-side `.noHostnameVerification` verifies the client certificate against the CA without
matching a client DNS name; the mTLS listener requires the certificate. Clients use
`.fullVerification` for the server hostname. Choose connection age and drain grace to fit
certificate lifetime and RPC duration, including long-running streams.

## Run the lifecycle

Construct the `GRPCServer` with its service implementations, then run it with the client and
reloader:

```swift
try await ServiceGroup(
    services: [reloader, server, client],
    gracefulShutdownSignals: [.sigterm, .sigint],
    logger: logger
).run()
```

Running the reloader starts periodic updates. New handshakes use the refreshed pair; existing
connections retain their TLS session until reconnection or draining. Scope user bearer
interceptors as described in <doc:InterceptorsAndPrincipals>.

## Renew certificates on disk

Renewal is the deployment's job, not the application's. With Smallstep's `step-ca`, for
example, a `smallstep/step-cli` renewer companion runs beside each workload, with a private CA
and separate trust and state per environment. Persist the CA configuration and database,
protect the online intermediate key, and keep the root signing key offline. Each renewer writes
only its workload's directory, which the application mounts read-only. Pin images to reviewed
versions or digests, and run the renewer in the foreground with a restart policy:

```sh
step ca renew /run/tls/cert.pem /run/tls/key.pem \
  --ca-url https://step-ca.internal:9000 \
  --root /run/tls/ca.pem \
  --daemon \
  --expires-in 8h
```

Renewal authenticates with the existing certificate/key and keeps the key stable. Example
settings are a 24-hour leaf lifetime, renewal with eight hours remaining, a 60-second reload
interval, and an alert below four hours remaining. Validate these values against availability
requirements. See the [Smallstep renewal command](https://smallstep.com/docs/step-cli/reference/ca/renew/).

Publish complete PEM files through staged output and atomic replacement on the actual directory
mount, and verify the pinned renewer's behavior. Rotate the private key with
[`step ca rekey`](https://smallstep.com/docs/step-cli/reference/ca/rekey/); key rotation requires
coordinated publication of a validated pair, because independently replacing two files is not
atomic. Failed reloads retain the last usable pair and retry at the configured interval.

Monitor reload failures, renewal success, and remaining lifetime. Define readiness and graceful
shutdown before the usable certificate expires. CA outages allow continued use of valid loaded
material while renewal retries; recovery after expiry requires controlled enrollment. Rotate
trust roots separately with overlap and a tested transport rebuild or rolling restart.

## Other mTLS clients

A client of another system with its own trust, such as a Temporal client, uses a separate
certificate/key pair, its own configuration scope, and its own primed reloader, run in the same
`ServiceGroup`. Reuse the configuration adapters, not the service credentials.

## Verify renewal

Use real TLS connections to check rejection of missing, untrusted, or expired client certificates
and incorrect server hostnames. After renewal, confirm the new certificate serial and expiry
on disk and on a fresh connection without restarting the application. Exercise mismatched
updates, CA downtime, renewer/application restarts, connection draining, and trust-root rotation.
