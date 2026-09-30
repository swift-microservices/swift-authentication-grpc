# Interceptors and principals

Where a credential is read, what each of an authenticator's answers becomes on the wire, and
how one caller stays one caller across a chain of services.

## Reading the credential is the transport's job

An `Authenticator` proves a credential it is handed. Finding that credential on a call is the
transport's job, and it differs by credential. A bearer token is in the `authorization`
metadata, which every transport carries, so ``BearerAuthenticationInterceptor`` works on any of
them. A client certificate is on the connection, and only the NIO Posix HTTP/2 transport exposes
it, so `CertificateAuthenticationInterceptor` lives in its own product over that transport.

Both interceptors then do the same thing: apply the authenticator, and bind the result as a
`Principal` in the task's `ServiceContext` for the length of the call, under a key made of the
identity and the credential type.

## Authentication and binding

`Authenticator.authenticate(_:)` returns an identity or throws. An identity binds the principal,
and the handler finds it in the `ServiceContext`. A failure ends the call with
`RPCError(code: .unauthenticated)` before the handler runs. This applies to both tokens and
certificates: TLS validation and establishing an accepted identity are separate checks.

A call with no exposed credential never reaches the authenticator and continues anonymously.
Open RPCs need that: signing in mints the first token and has no caller yet. Requiring a caller
is the handler's decision, made against the principal it reads.

## Two principals on one call

A service relaying a person's call arrives with its own certificate and the person's token. The
two interceptors bind two principals under two keys, `PrincipalKey<AppToken, String>` and
`PrincipalKey<SPIFFEID, Certificate>`, and neither touches the other. A handler can ask either
question: which process is calling, and on whose behalf.

## The same caller, onward

``BearerPropagationInterceptor`` reads the bearer principal and puts its token back on an
outgoing call. It is applied to the upstream services that accept that caller's token, so a
public service is dialled with nothing. A call made outside any caller's request has no token
to propagate and continues without one.

## A service or worker as the caller

``BearerCredentialsInterceptor`` obtains a token from an async `@Sendable` closure and presents
it as the call's sole authorization entry. The closure is invoked on each interception and
may be called concurrently. It owns acquisition, caching, and renewal; the interceptor holds
no credential state and reads or binds no principal. Acquisition failures and cancellation
propagate before calling `next`. An empty token or one containing whitespace fails as
unauthenticated, so a required credential cannot silently become an anonymous call.

```swift
GRPCClient(transport: mtlsTransport, interceptorPipeline: [
    .apply(
        BearerCredentialsInterceptor {
            try await authenticationClient.accessToken(for: "users-internal")
        },
        to: .services([UserInternalService.descriptor])
    )
])
```

The authentication client belongs to the application and obtains credentials from a trusted
issuer. Apply supplied credentials and user-token propagation to separate service descriptors
so the call has one intended bearer identity. Receiver-side
``BearerAuthenticationInterceptor`` accepts an `Authenticator<String, ServiceIdentity>` in
the same way it accepts a user authenticator. The application validates issuer, audience,
expiration, and service-token purpose, requires the bound identity in internal handlers, and
checks permissions in the owning use case before side effects.

Mandatory mTLS protects and authenticates the internal connection. An ordinary bearer token
does not prove that the presenting certificate belongs to the token's subject. A
certificate-bound token requires a separate binding check. Certificate rotation and token
renewal have independent lifecycles for ordinary bearer tokens.

A workflow carries durable business input. Its Activities call remote services through the
worker's credential-configured client, obtaining a valid token at execution time. Access
tokens stay outside workflow inputs, Activity results, and recorded workflow history.
