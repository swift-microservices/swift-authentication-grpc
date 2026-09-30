//
//  BearerCredentialsInterceptor.swift
//  swift-authentication-grpc
//
//  Created by Zaid Rahhawi on 10/1/26.
//

public import GRPCCore

/// Presents a supplied bearer credential on an outgoing call.
///
/// A service or worker supplies its own token through an asynchronous closure:
///
/// ```swift
/// BearerCredentialsInterceptor {
///     try await authenticationClient.accessToken(for: "users-internal")
/// }
/// ```
/// Apply this interceptor to the service descriptors that accept that credential. The closure
/// runs for each interception and owns credential acquisition, caching, and renewal. It may be
/// called concurrently. This interceptor does not read or bind a principal in `ServiceContext`.
///
/// Acquisition failures and cancellation propagate before the request reaches the next
/// interceptor. An empty credential or one containing whitespace fails as unauthenticated.
public struct BearerCredentialsInterceptor: ClientInterceptor {
    private let credential: @Sendable () async throws -> String

    /// - Parameter credential: Supplies a nonempty bearer token containing no whitespace.
    public init(_ credential: @escaping @Sendable () async throws -> String) {
        self.credential = credential
    }

    public func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingClientRequest<Input>,
        context: ClientContext,
        next:
            @concurrent (
                _ request: StreamingClientRequest<Input>,
                _ context: ClientContext
            ) async throws -> StreamingClientResponse<Output>
    ) async throws -> StreamingClientResponse<Output> {
        try Task.checkCancellation()
        let token = try await credential()
        try Task.checkCancellation()

        guard !token.isEmpty, !token.contains(where: \.isWhitespace) else {
            throw RPCError(code: .unauthenticated, message: "A bearer credential must be nonempty and contain no whitespace.")
        }

        var request = request
        request.metadata.bearer = token

        return try await next(request, context)
    }
}
