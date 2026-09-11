//
//  BearerAuthenticationInterceptor.swift
//  swift-authentication-grpc
//
//  Created by Zaid Rahhawi on 9/11/26.
//

import Authentication
import GRPCCore
import ServiceContextModule

/// Binds the principal a bearer token proves, for the length of the call.
///
/// The token is read from the request's `authorization` metadata. A call with no token continues
/// anonymously, which is what an open RPC needs. A token the authenticator declines continues
/// unbound. A token the authenticator refuses fails the call as unauthenticated, because absent
/// and invalid are not the same thing.
///
/// Apply it to the services whose RPCs take a token:
///
/// ```swift
/// GRPCServer(
///     transport: transport,
///     services: [service],
///     interceptorPipeline: [
///         .apply(BearerAuthenticationInterceptor(authenticator: authenticator), to: .services([Service.descriptor]))
///     ]
/// )
/// ```
///
/// Requiring a caller is the handler's decision:
///
/// ```swift
/// guard let caller = ServiceContext.current?[PrincipalKey<AppToken, String>.self]?.identity else {
///     throw RPCError(code: .unauthenticated, message: "Sign in to continue.")
/// }
/// ```
public struct BearerAuthenticationInterceptor<Identity: Sendable>: ServerInterceptor {
    private let authenticator: any Authenticator<String, Identity>

    /// - Parameter authenticator: Proves the token, such as a `JWTAuthenticator`.
    public init(authenticator: any Authenticator<String, Identity>) {
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
        guard let token = request.metadata.bearer else {
            return try await next(request, context)
        }

        guard let identity = try await authenticate(token) else {
            return try await next(request, context)
        }

        var serviceContext = ServiceContext.current ?? .topLevel
        serviceContext[PrincipalKey<Identity, String>.self] = Principal(identity: identity, credential: token)

        return try await ServiceContext.withValue(serviceContext) {
            try await next(request, context)
        }
    }

    private func authenticate(_ token: String) async throws -> Identity? {
        do {
            return try await authenticator.authenticate(token)
        } catch {
            throw RPCError(code: .unauthenticated, message: "Invalid or expired token.")
        }
    }
}
