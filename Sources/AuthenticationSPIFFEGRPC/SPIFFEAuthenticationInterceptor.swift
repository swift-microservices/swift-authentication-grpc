//
//  SPIFFEAuthenticationInterceptor.swift
//  swift-authentication-grpc
//
//  Created by Zaid Rahhawi on 9/28/26.
//

import Authentication
public import AuthenticationSPIFFE
public import GRPCCore
import GRPCNIOTransportHTTP2Posix
import ServiceContextModule

/// Requires a verified SPIFFE peer and binds its principal for this RPC.
/// Business permissions remain in the application. No bearer principal is changed.
public struct SPIFFEAuthenticationInterceptor<Identity: Sendable>: ServerInterceptor {
    private let authenticator: SPIFFEAuthenticator
    private let identity: @Sendable (SPIFFEID) throws -> Identity

    /// Maps a verified workload ID to a project's identity. Throw to refuse an unmapped peer.
    public init(authenticator: SPIFFEAuthenticator, identity: @escaping @Sendable (SPIFFEID) throws -> Identity) {
        self.authenticator = authenticator
        self.identity = identity
    }

    /// Binds the verified peer's SPIFFE ID directly.
    public init(authenticator: SPIFFEAuthenticator) where Identity == SPIFFEID {
        self.init(authenticator: authenticator, identity: { $0 })
    }

    /// Requires TLS chain metadata and verifies it against the configured trust bundle.
    public func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingServerRequest<Input>,
        context: ServerContext,
        next: @concurrent @Sendable (StreamingServerRequest<Input>, ServerContext) async throws -> StreamingServerResponse<Output>
    ) async throws -> StreamingServerResponse<Output> {
        guard let transport = context.transportSpecific as? HTTP2ServerTransport.Posix.Context,
            let chain = transport.peerCertificateChain
        else { throw RPCError(code: .unauthenticated, message: "SPIFFE authentication is required.") }
        let verification: SPIFFEAuthenticator.Verification
        let peer: Identity
        do {
            verification = try await authenticator.verify(certificateChain: Array(chain))
            peer = try identity(verification.id)
        } catch {
            throw RPCError(code: .unauthenticated, message: "SPIFFE authentication failed.")
        }
        var serviceContext = ServiceContext.current ?? .topLevel
        serviceContext[PrincipalKey<Identity, SPIFFEAuthenticator.Verification>.self] = Principal(identity: peer, credential: verification)
        return try await ServiceContext.withValue(serviceContext) { try await next(request, context) }
    }
}
