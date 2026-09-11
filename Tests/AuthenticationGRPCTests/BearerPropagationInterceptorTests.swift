//
//  BearerPropagationInterceptorTests.swift
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
struct BearerPropagationInterceptorTests {
    struct Claims: Sendable, Equatable {
        let subject: String
    }

    let interceptor = BearerPropagationInterceptor<Claims>()

    /// Runs the interceptor and returns the authorization the outgoing request carried.
    func outgoingAuthorization() async throws -> [String] {
        let request = StreamingClientRequest<String>(metadata: [:]) { _ in }
        let context = ClientContext(descriptor: .init(fullyQualifiedService: "test.Service", method: "Call"), remotePeer: "server", localPeer: "client")

        let seen = Seen<[String]>()
        _ = try await interceptor.intercept(request: request, context: context) { request, _ -> StreamingClientResponse<String> in
            await seen.record(Array(request.metadata[stringValues: "authorization"]))
            return StreamingClientResponse(metadata: [:], bodyParts: RPCAsyncSequence(wrapping: AsyncThrowingStream { $0.finish() }))
        }
        return await seen.value ?? []
    }

    @Test("The caller's token is presented on the outgoing call")
    func presentsTheCallersToken() async throws {
        var context = ServiceContext.topLevel
        context[PrincipalKey<Claims, String>.self] = Principal(identity: Claims(subject: "alice"), credential: "alice-token")

        let authorization = try await ServiceContext.withValue(context) {
            try await outgoingAuthorization()
        }

        #expect(authorization == ["Bearer alice-token"])
    }

    @Test("A call outside a caller's request goes out unauthenticated")
    func noCallerGoesOutUnauthenticated() async throws {
        #expect(try await outgoingAuthorization() == [])
    }
}
