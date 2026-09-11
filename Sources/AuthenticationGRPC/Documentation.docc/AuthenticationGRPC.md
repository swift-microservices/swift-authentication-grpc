# ``AuthenticationGRPC``

Binding who is calling on gRPC: a bearer token on the way in, and the same token on the way out.

## Overview

``BearerAuthenticationInterceptor`` reads the `authorization` metadata, proves the token with an
`Authenticator<String, Identity>` from swift-authentication, and binds the
`Principal<Identity, String>` in the task's `ServiceContext` for the length of the call.
``BearerPropagationInterceptor`` reads that principal back and presents its token on an outgoing
call, so one token identifies the caller at every service in the chain. Both work on any
transport, because they read metadata alone.

The certificate side, binding the peer a client certificate proves, needs the NIO Posix HTTP/2
transport, which is the only one that exposes the certificate. It is the separate product
`AuthenticationGRPCNIOTransport`, so a service that admits only tokens links neither the
transport nor swift-certificates through this package.

## Example

```swift
GRPCServer(
    transport: transport,
    services: [service],
    interceptorPipeline: [
        .apply(BearerAuthenticationInterceptor(authenticator: authenticator), to: .services([Service.descriptor]))
    ]
)

GRPCClient(transport: transport, interceptorPipeline: [
    .apply(BearerPropagationInterceptor<AppToken>(), to: .services([UpstreamService.descriptor]))
])
```

Over the NIO transport, the peer's certificate is bound the same way:

```swift
import AuthenticationGRPCNIOTransport

CertificateAuthenticationInterceptor(authenticator: SPIFFEAuthenticator(trustDomain: "example"))
```

## Topics

### Server

- ``BearerAuthenticationInterceptor``

### Client

- ``BearerPropagationInterceptor``

### Metadata

- ``GRPCCore/Metadata/bearer``

### Design

- <doc:InterceptorsAndPrincipals>
