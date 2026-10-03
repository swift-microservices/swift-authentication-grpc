// Copyright (c) 2026 Zaid Rahhawi
// SPDX-License-Identifier: MIT
// See LICENSE for license information.

public import Authentication
public import GRPCCore
import ServiceContextModule

/// Binds the principal a bearer token proves, for the length of the call.
///
/// The token is read from the request's `authorization` metadata. The authenticator returns an
/// identity or throws. A failed authentication ends the call as unauthenticated before the
/// handler runs. A missing token continues unbound; user handlers require their identity.
///
/// Apply it only to user service descriptors. Public operations check their own required proofs,
/// and internal operations accept business input over mandatory transport mTLS:
///
/// ```swift
/// GRPCServer(
///     transport: transport,
///     services: [service],
///     interceptorPipeline: [
///         .apply(BearerAuthenticationInterceptor(authenticator: authenticator), to: .services([UserService.descriptor]))
///     ]
/// )
/// ```
///
/// A user handler requires its identity before invoking the owning use case:
///
/// ```swift
/// guard let caller = ServiceContext.current?[PrincipalKey<UserIdentity, String>.self]?.identity else {
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
            @concurrent @Sendable (
                _ request: StreamingServerRequest<Input>,
                _ context: ServerContext
            ) async throws -> StreamingServerResponse<Output>
    ) async throws -> StreamingServerResponse<Output> {
        guard let token = request.metadata.bearer else {
            return try await next(request, context)
        }

        let identity = try await authenticate(token)

        var serviceContext = ServiceContext.current ?? .topLevel
        serviceContext[PrincipalKey<Identity, String>.self] = Principal(identity: identity, credential: token)

        return try await ServiceContext.withValue(serviceContext) {
            try await next(request, context)
        }
    }

    private func authenticate(_ token: String) async throws -> Identity {
        do {
            return try await authenticator.authenticate(token)
        } catch {
            throw RPCError(code: .unauthenticated, message: "Invalid or expired token.")
        }
    }
}
