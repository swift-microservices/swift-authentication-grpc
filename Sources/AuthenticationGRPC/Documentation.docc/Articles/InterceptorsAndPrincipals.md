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

## Three answers, three outcomes

An authenticator answers one of three ways, and each has a fixed meaning on the wire:

- **An identity** binds the principal, and the handler finds it in the `ServiceContext`.
- **`nil`** declines, and the call continues with nothing bound. A certificate from another
  trust domain is the usual case: the transport already verified it, so the peer is real, it is
  simply not one this service admits.
- **A throw** refuses, and the call fails with `RPCError(code: .unauthenticated)` before the
  handler runs. A token with a bad signature or an expired claim is the usual case.

A call that carries no credential at all never reaches the authenticator and continues
anonymously. Open RPCs need that: signing in mints the first token and has no caller yet.
Requiring a caller is the handler's decision, made against the principal it reads.

## Two principals on one call

A service relaying a person's call arrives with its own certificate and the person's token. The
two interceptors bind two principals under two keys, `PrincipalKey<AppToken, String>` and
`PrincipalKey<SPIFFEID, Certificate>`, and neither touches the other. A handler can ask either
question: which process is calling, and on whose behalf.

## The same caller, onward

``BearerPropagationInterceptor`` reads the bearer principal and puts its token back on an
outgoing call, so one token identifies the caller at every service in the chain. It is applied
to the upstream services that take a token, so a public service is dialled with nothing. A call
made outside any caller's request, startup work, a workflow activity, goes out unauthenticated
rather than failing: a process identifies itself on such calls with its certificate, which the
transport presents at the handshake without any interceptor's help.
