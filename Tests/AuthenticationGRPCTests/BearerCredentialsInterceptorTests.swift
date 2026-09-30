//
//  BearerCredentialsInterceptorTests.swift
//  swift-authentication-grpc
//
//  Created by Zaid Rahhawi on 10/1/26.
//

import Authentication
import AuthenticationGRPC
import GRPCCore
import ServiceContextModule
import Testing

@Suite
struct BearerCredentialsInterceptorTests {
    struct Claims: Sendable, Equatable {
        let subject: String
    }

    enum AcquisitionError: Error {
        case unavailable
    }

    actor Credentials {
        private(set) var calls = 0

        func token() -> String {
            calls += 1
            return "worker-token-\(calls)"
        }
    }

    func outgoingMetadata(
        interceptor: BearerCredentialsInterceptor,
        metadata: Metadata = [:],
        nextCalled: Seen<Bool> = Seen()
    ) async throws -> Metadata {
        let request = StreamingClientRequest<String>(metadata: metadata) { _ in }
        let context = ClientContext(descriptor: .init(fullyQualifiedService: "test.InternalService", method: "Call"), remotePeer: "server", localPeer: "worker")
        let seen = Seen<Metadata>()

        _ = try await interceptor.intercept(request: request, context: context) { request, context -> StreamingClientResponse<String> in
            #expect(context.descriptor.service == ServiceDescriptor(fullyQualifiedService: "test.InternalService"))
            await nextCalled.record(true)
            await seen.record(request.metadata)
            return StreamingClientResponse(metadata: [:], bodyParts: RPCAsyncSequence(wrapping: AsyncThrowingStream { $0.finish() }))
        }

        return try #require(await seen.value)
    }

    @Test("A worker presents its supplied token without an inbound principal")
    func workerPresentsToken() async throws {
        let interceptor = BearerCredentialsInterceptor { "worker-token" }
        let metadata = try await ServiceContext.withValue(.topLevel) {
            try await outgoingMetadata(interceptor: interceptor)
        }

        #expect(metadata.bearer == "worker-token")
    }

    @Test("The supplied token replaces all authorization entries and preserves other metadata")
    func replacesAuthorization() async throws {
        let interceptor = BearerCredentialsInterceptor { "worker-token" }
        let metadata = try await outgoingMetadata(
            interceptor: interceptor,
            metadata: ["authorization": "Bearer first", "authorization": "Bearer second", "trace-id": "trace-1"]
        )

        #expect(Array(metadata[stringValues: "authorization"]) == ["Bearer worker-token"])
        #expect(Array(metadata[stringValues: "trace-id"]) == ["trace-1"])
    }

    @Test("A service call uses its supplied credential and preserves the enclosing user principal")
    func serviceCredentialIsIndependentOfUser() async throws {
        let principal = Principal(identity: Claims(subject: "alice"), credential: "alice-token")
        var context = ServiceContext.topLevel
        context[PrincipalKey<Claims, String>.self] = principal
        let interceptor = BearerCredentialsInterceptor {
            #expect(ServiceContext.current?[PrincipalKey<Claims, String>.self]?.identity == principal.identity)
            return "worker-token"
        }

        try await ServiceContext.withValue(context) {
            let metadata = try await outgoingMetadata(interceptor: interceptor)
            #expect(metadata.bearer == "worker-token")
            #expect(ServiceContext.current?[PrincipalKey<Claims, String>.self]?.identity == principal.identity)
            #expect(ServiceContext.current?[PrincipalKey<Claims, String>.self]?.credential == principal.credential)
        }
    }

    @Test("Each interception obtains the current credential")
    func usesCurrentCredential() async throws {
        let credentials = Credentials()
        let interceptor = BearerCredentialsInterceptor { await credentials.token() }

        let first = try await outgoingMetadata(interceptor: interceptor)
        let second = try await outgoingMetadata(interceptor: interceptor)

        #expect(first.bearer == "worker-token-1")
        #expect(second.bearer == "worker-token-2")
        #expect(await credentials.calls == 2)
    }

    @Test("Concurrent calls each obtain and present a credential")
    func concurrentCalls() async throws {
        let credentials = Credentials()
        let interceptor = BearerCredentialsInterceptor { await credentials.token() }

        async let first = outgoingMetadata(interceptor: interceptor)
        async let second = outgoingMetadata(interceptor: interceptor)
        let metadata = try await [first, second]

        #expect(Set(metadata.compactMap(\.bearer)) == ["worker-token-1", "worker-token-2"])
        #expect(await credentials.calls == 2)
    }

    @Test("Acquisition failure propagates without invoking the next interceptor")
    func acquisitionFailureStopsCall() async throws {
        let nextCalled = Seen<Bool>()
        let interceptor = BearerCredentialsInterceptor { throw AcquisitionError.unavailable }

        await #expect(throws: AcquisitionError.unavailable) {
            try await outgoingMetadata(interceptor: interceptor, nextCalled: nextCalled)
        }
        #expect(await nextCalled.value == nil)
    }

    @Test("An acquisition RPC failure retains its status and cause")
    func acquisitionRPCFailureStopsCall() async throws {
        let nextCalled = Seen<Bool>()
        let interceptor = BearerCredentialsInterceptor {
            throw RPCError(code: .unavailable, message: "Token endpoint unavailable.", cause: AcquisitionError.unavailable)
        }

        await #expect {
            try await outgoingMetadata(interceptor: interceptor, nextCalled: nextCalled)
        } throws: { error in
            guard let error = error as? RPCError else { return false }
            return error.code == .unavailable && (error.cause as? AcquisitionError) == .unavailable
        }
        #expect(await nextCalled.value == nil)
    }

    @Test("An empty credential or whitespace fails before the next interceptor", arguments: ["", " ", "worker token", "token\r\n", "\ttoken", "token\u{00A0}"])
    func invalidCredentialStopsCall(token: String) async throws {
        let nextCalled = Seen<Bool>()
        let interceptor = BearerCredentialsInterceptor { token }

        await #expect {
            try await outgoingMetadata(interceptor: interceptor, nextCalled: nextCalled)
        } throws: { error in
            (error as? RPCError)?.code == .unauthenticated
        }
        #expect(await nextCalled.value == nil)
    }

    @Test("Cancellation before acquisition prevents credential and request work")
    func cancellationBeforeAcquisition() async throws {
        let acquired = Seen<Bool>()
        let nextCalled = Seen<Bool>()
        let interceptor = BearerCredentialsInterceptor {
            await acquired.record(true)
            return "worker-token"
        }

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await outgoingMetadata(interceptor: interceptor, nextCalled: nextCalled)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await acquired.value == nil)
        #expect(await nextCalled.value == nil)
    }

    @Test("Cancellation during acquisition prevents the outgoing request")
    func cancellationDuringAcquisition() async throws {
        let nextCalled = Seen<Bool>()
        let interceptor = BearerCredentialsInterceptor {
            withUnsafeCurrentTask { $0?.cancel() }
            return "worker-token"
        }

        let task = Task {
            try await outgoingMetadata(interceptor: interceptor, nextCalled: nextCalled)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await nextCalled.value == nil)
    }
}
