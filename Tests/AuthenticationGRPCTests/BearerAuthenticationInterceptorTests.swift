// Copyright (c) 2026 Zaid Rahhawi
// SPDX-License-Identifier: MIT
// See LICENSE for license information.

import Authentication
import AuthenticationGRPC
import GRPCCore
import OperationContext
import Testing

@Suite
struct BearerAuthenticationInterceptorTests {
    struct Claims: Sendable, Equatable {
        let subject: String
    }

    let interceptor = BearerAuthenticationInterceptor<Claims>(
        authenticator: TableAuthenticator(identities: ["alice-token": Claims(subject: "alice")], refused: ["expired-token"])
    )

    /// Runs the interceptor and returns the principal the handler saw, or `nil`.
    func principalSeen(
        withAuthorization authorization: String?,
        handlerCalls: Seen<Bool> = Seen(),
        contextSeen: Seen<OperationContext> = Seen()
    ) async throws -> Principal<Claims, String>? {
        var metadata = Metadata()
        if let authorization {
            metadata.addString(authorization, forKey: "authorization")
        }
        let request = StreamingServerRequest<String>(metadata: metadata, messages: RPCAsyncSequence(wrapping: AsyncThrowingStream { $0.finish() }))
        let context = ServerContext(
            descriptor: .init(fullyQualifiedService: "test.Service", method: "Call"),
            remotePeer: "client",
            localPeer: "server",
            cancellation: .init()
        )

        let seen = Seen<Principal<Claims, String>?>()
        _ = try await interceptor.intercept(request: request, context: context) { _, _ -> StreamingServerResponse<String> in
            await handlerCalls.record(true)
            await contextSeen.record(OperationContext.current)
            await seen.record(OperationContext.current[PrincipalKey<Claims, String>.self])
            return StreamingServerResponse(metadata: [:]) { _ in [:] }
        }
        return await seen.value ?? nil
    }

    @Test("A call with no token continues anonymously")
    func noTokenContinuesAnonymously() async throws {
        let calls = Seen<Bool>()
        #expect(try await principalSeen(withAuthorization: nil, handlerCalls: calls) == nil)
        #expect(await calls.value == true)
    }

    @Test("A proved token binds its principal for the handler")
    func provedTokenBindsPrincipal() async throws {
        let calls = Seen<Bool>()
        let principal = try await principalSeen(withAuthorization: "Bearer alice-token", handlerCalls: calls)
        #expect(await calls.value == true)

        #expect(principal?.identity == Claims(subject: "alice"))
        #expect(principal?.credential == "alice-token")
    }

    @Test("A failed token is unauthenticated before the handler runs", arguments: ["unknown-token", "expired-token"])
    func failedTokenIsUnauthenticated(token: String) async throws {
        let calls = Seen<Bool>()
        await #expect {
            try await principalSeen(withAuthorization: "Bearer \(token)", handlerCalls: calls)
        } throws: { error in
            (error as? RPCError)?.code == .unauthenticated
        }
        #expect(await calls.value == nil)
    }

    enum RequestIDKey: OperationContextKey {
        typealias Value = String
    }

    @Test("The bearer binding preserves context values and restores the enclosing principal")
    func bindingIsScoped() async throws {
        let outer = Principal(identity: Claims(subject: "outer"), credential: "outer-token")
        var context = OperationContext()
        context[RequestIDKey.self] = "request-1"
        context[PrincipalKey<Claims, String>.self] = outer
        let seen = Seen<OperationContext>()

        try await OperationContext.withContext(context) {
            let principal = try await principalSeen(withAuthorization: "Bearer alice-token", contextSeen: seen)
            #expect(principal?.identity.subject == "alice")
            #expect(await seen.value?[RequestIDKey.self] == "request-1")
            #expect(OperationContext.current[PrincipalKey<Claims, String>.self]?.identity == outer.identity)
            #expect(OperationContext.current[PrincipalKey<Claims, String>.self]?.credential == outer.credential)
        }
    }
}

/// A box a `@Sendable` handler can write into.
actor Seen<Value: Sendable> {
    private(set) var value: Value?

    func record(_ value: Value) {
        self.value = value
    }
}
