# Interceptors and principals

Authenticate users and forward their original credential between user RPCs.

## RPC audiences

mTLS secures service-to-service connections. JWTs additionally authenticate users making these
calls. Use separate public, user, and internal protobuf descriptors; scope bearer authentication,
propagation, and user database settings to user descriptors. Keep backend listeners private and
gateway routes limited to intended public and user operations.

Public operations validate their required credentials or proofs. Every peer admitted by an
internal listener's CA trust can call its internal RPCs. Internal operations accept business
input and enforce resource relationships, state transitions, consistency, and idempotency.

## Authenticate the user

``BearerAuthenticationInterceptor`` reads `authorization` metadata and calls
`Authenticator.authenticate(_:)`. A successful return binds the identity and original token as
`Principal<UserIdentity, String>` in `ServiceContext` for the call. Verification failure returns
`RPCError(code: .unauthenticated)` before the handler runs.

A missing token continues unbound. The user handler requires the identity and passes it to the
owning use case, which checks permissions and resource access before side effects.

## Forward the original JWT

Scope ``BearerPropagationInterceptor`` to upstream user descriptors:

```swift
let client = GRPCClient(transport: transport, interceptorPipeline: [
    .apply(
        BearerPropagationInterceptor<UserIdentity>(),
        to: .services([UpstreamUserService.descriptor])
    )
])
```

The interceptor presents the original credential unchanged, replacing existing authorization
metadata when a user principal is present. Without a principal, it leaves the request unchanged.
Each receiving service verifies the original JWT independently.

See <doc:MutualTLSAndCertificateRenewal> for transport configuration and lifecycle management.
