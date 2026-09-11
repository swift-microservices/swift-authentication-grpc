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
    func principalSeen(withAuthorization authorization: String?) async throws -> Principal<Claims, String>? {
        var metadata = Metadata()
        if let authorization {
            metadata.addString(authorization, forKey: "authorization")
        }
        let request = StreamingServerRequest<String>(metadata: metadata, messages: RPCAsyncSequence(wrapping: AsyncThrowingStream { $0.finish() }))
        let context = ServerContext(descriptor: .init(fullyQualifiedService: "test.Service", method: "Call"), remotePeer: "client", localPeer: "server", cancellation: .init())

        let seen = Seen<Principal<Claims, String>?>()
        _ = try await interceptor.intercept(request: request, context: context) { _, _ -> StreamingServerResponse<String> in
            await seen.record(ServiceContext.current?[PrincipalKey<Claims, String>.self])
            return StreamingServerResponse(metadata: [:]) { _ in [:] }
        }
        return await seen.value ?? nil
    }

    @Test("A call with no token continues anonymously")
    func noTokenContinuesAnonymously() async throws {
        #expect(try await principalSeen(withAuthorization: nil) == nil)
    }

    @Test("A proved token binds its principal for the handler")
    func provedTokenBindsPrincipal() async throws {
        let principal = try await principalSeen(withAuthorization: "Bearer alice-token")

        #expect(principal?.identity == Claims(subject: "alice"))
        #expect(principal?.credential == "alice-token")
    }

    @Test("A declined token continues unbound")
    func declinedTokenContinuesUnbound() async throws {
        #expect(try await principalSeen(withAuthorization: "Bearer unknown-token") == nil)
    }

    @Test("A refused token fails the call as unauthenticated before the handler runs")
    func refusedTokenIsUnauthenticated() async throws {
        await #expect {
            try await principalSeen(withAuthorization: "Bearer expired-token")
        } throws: { error in
            (error as? RPCError)?.code == .unauthenticated
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
