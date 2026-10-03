//
//  BearerAuthenticationInterceptorTests.swift
//  swift-authentication-grpc
//
//  Created by Zaid Rahhawi on 9/11/26.
//

import Authentication
import AuthenticationGRPC
import GRPCCore
import ServiceContextModule
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
        contextSeen: Seen<ServiceContext> = Seen()
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
            await contextSeen.record(ServiceContext.current ?? .topLevel)
            await seen.record(ServiceContext.current?[PrincipalKey<Claims, String>.self])
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

    enum TraceKey: ServiceContextKey {
        typealias Value = String
    }

    @Test("The bearer binding preserves context values and restores the enclosing principal")
    func bindingIsScoped() async throws {
        let outer = Principal(identity: Claims(subject: "outer"), credential: "outer-token")
        var context = ServiceContext.topLevel
        context[TraceKey.self] = "trace-1"
        context[PrincipalKey<Claims, String>.self] = outer
        let seen = Seen<ServiceContext>()

        try await ServiceContext.withValue(context) {
            let principal = try await principalSeen(withAuthorization: "Bearer alice-token", contextSeen: seen)
            #expect(principal?.identity.subject == "alice")
            #expect(await seen.value?[TraceKey.self] == "trace-1")
            #expect(ServiceContext.current?[PrincipalKey<Claims, String>.self]?.identity == outer.identity)
            #expect(ServiceContext.current?[PrincipalKey<Claims, String>.self]?.credential == outer.credential)
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
