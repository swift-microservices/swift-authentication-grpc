//
//  BearerPropagationInterceptor.swift
//  swift-authentication-grpc
//
//  Created by Zaid Rahhawi on 9/11/26.
//

import Authentication
import GRPCCore
import ServiceContextModule

/// Presents the caller's bearer token on an outgoing call, so one token identifies the caller at
/// every service in the chain.
///
/// It reads the principal ``BearerAuthenticationInterceptor`` bound and puts its credential back
/// on the request. Apply it to the upstream services that take a token, so a public service is
/// dialled with nothing:
///
/// ```swift
/// GRPCClient(transport: transport, interceptorPipeline: [
///     .apply(BearerPropagationInterceptor<AppToken>(), to: .services([UpstreamService.descriptor]))
/// ])
/// ```
///
/// Calls made outside a caller's request, startup work, a workflow activity, anything with no
/// inbound token, go out unauthenticated rather than failing here. A process that must identify
/// itself on such calls needs a credential of its own, which this interceptor does not provide.
public struct BearerPropagationInterceptor<Identity: Sendable>: ClientInterceptor {
    public init() {}

    public func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingClientRequest<Input>,
        context: ClientContext,
        next: (
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
