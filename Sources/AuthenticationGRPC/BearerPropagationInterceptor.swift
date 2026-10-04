// Copyright (c) 2026 Zaid Rahhawi
// SPDX-License-Identifier: MIT
// See LICENSE for license information.

import Authentication
public import GRPCCore
import ServiceContextModule

/// Presents the caller's bearer token on an outgoing call, so one token identifies the caller at
/// every service in the chain.
///
/// It reads the principal ``BearerAuthenticationInterceptor`` bound and presents the original
/// credential unchanged. Each receiving service verifies that JWT independently. Apply it only
/// to upstream user service descriptors:
///
/// ```swift
/// GRPCClient(transport: transport, interceptorPipeline: [
///     .apply(BearerPropagationInterceptor<UserIdentity>(), to: .services([UpstreamUserService.descriptor]))
/// ])
/// ```
///
/// With no bound user principal, the request is passed through unchanged. Internal service and
/// worker clients use mandatory mTLS, with the transport presenting their certificate at the
/// handshake. Public operations supply their operation-specific proofs.
public struct BearerPropagationInterceptor<Identity: Sendable>: ClientInterceptor {
    /// An interceptor that forwards the bound principal's credential.
    public init() {}

    /// Presents the bound principal's original token on the outgoing request, if one is bound.
    public func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingClientRequest<Input>,
        context: ClientContext,
        next:
            @concurrent (
                _ request: StreamingClientRequest<Input>,
                _ context: ClientContext
            ) async throws -> StreamingClientResponse<Output>
    ) async throws -> StreamingClientResponse<Output> {
        guard let principal = ServiceContext.current?[PrincipalKey<Identity, String>.self] else {
            return try await next(request, context)
        }

        var request = request
        request.metadata.bearer = principal.credential

        return try await next(request, context)
    }
}
