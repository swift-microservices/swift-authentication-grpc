//
//  CertificateAuthenticationInterceptor.swift
//  swift-authentication-grpc
//
//  Created by Zaid Rahhawi on 9/11/26.
//

import Authentication
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import ServiceContextModule
import X509

/// Binds the principal the peer's certificate proves, for the length of the call.
///
/// The certificate is the one the peer presented at the TLS handshake, which the transport
/// verified before the request was read. Only the NIO Posix HTTP/2 transport exposes it, which
/// is why this interceptor is its own product. A connection with no client certificate, or a
/// certificate the authenticator declines, continues unbound: the transport already refused
/// every certificate that could be refused, and an unlisted peer is a valid one this service
/// simply does not admit. An authenticator that throws fails the call as unauthenticated.
///
/// ```swift
/// CertificateAuthenticationInterceptor(authenticator: SPIFFEAuthenticator(trustDomain: "example"))
/// ```
///
/// A call can carry both a certificate and a token, a service relaying a person's call, so this
/// binds under `PrincipalKey<Identity, Certificate>` and never touches the bearer principal.
public struct CertificateAuthenticationInterceptor<Identity: Sendable>: ServerInterceptor {
    private let authenticator: any Authenticator<Certificate, Identity>

    /// - Parameter authenticator: Names the peer from its certificate, such as a
    ///   `SPIFFEAuthenticator`.
    public init(authenticator: any Authenticator<Certificate, Identity>) {
        self.authenticator = authenticator
    }

    public func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingServerRequest<Input>,
        context: ServerContext,
        next:
            @Sendable (
                _ request: StreamingServerRequest<Input>,
                _ context: ServerContext
            ) async throws -> StreamingServerResponse<Output>
    ) async throws -> StreamingServerResponse<Output> {
        guard
            let transport = context.transportSpecific as? HTTP2ServerTransport.Posix.Context,
            let certificate = transport.peerCertificate
        else {
            return try await next(request, context)
        }

        guard let identity = try await authenticate(certificate) else {
            return try await next(request, context)
        }

        var serviceContext = ServiceContext.current ?? .topLevel
        serviceContext[PrincipalKey<Identity, Certificate>.self] = Principal(identity: identity, credential: certificate)

        return try await ServiceContext.withValue(serviceContext) {
            try await next(request, context)
        }
    }

    private func authenticate(_ certificate: Certificate) async throws -> Identity? {
        do {
            return try await authenticator.authenticate(certificate)
        } catch {
            throw RPCError(code: .unauthenticated, message: "Certificate not accepted.")
        }
    }
}
