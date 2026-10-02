# ``AuthenticationGRPC``

Authenticate user JWTs and forward the original token on user RPCs.

## Overview

``BearerAuthenticationInterceptor`` reads the `authorization` metadata, verifies the token with
an `Authenticator<String, Identity>`, and binds a `Principal<Identity, String>` in the task's
`ServiceContext` for the call. ``BearerPropagationInterceptor`` presents that principal's
original token on an outgoing user RPC. Each receiving service verifies it independently.
Both interceptors work on any gRPC transport.

Use separate public, user, and internal protobuf service descriptors. Apply bearer authentication
and propagation only to user descriptors. A missing token continues unbound; user handlers
require an identity, and their owning use cases check permissions and resource access. A failed
authentication ends the call with `RPCError(code: .unauthenticated)` before the handler runs.

mTLS secures service connections. User JWTs provide user authentication, and owning use cases
check permissions. Internal handlers accept business input and enforce domain invariants.

## Example

```swift
let server = GRPCServer(
    transport: transport,
    services: [publicService, userService, internalService],
    interceptorPipeline: [
        .apply(
            BearerAuthenticationInterceptor(authenticator: authenticator),
            to: .services([UserService.descriptor])
        )
    ]
)

let client = GRPCClient(transport: transport, interceptorPipeline: [
    .apply(
        BearerPropagationInterceptor<UserIdentity>(),
        to: .services([UpstreamUserService.descriptor])
    )
])
```

Configure the client and server transports using <doc:MutualTLSAndCertificateRenewal>.

## Topics

### Server

- ``BearerAuthenticationInterceptor``

### Client

- ``BearerPropagationInterceptor``

### Metadata

- ``GRPCCore/Metadata/bearer``

### Guides

- <doc:InterceptorsAndPrincipals>
- <doc:MutualTLSAndCertificateRenewal>
- <doc:ConfiguringTransportCredentials>
