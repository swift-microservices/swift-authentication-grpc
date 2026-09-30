//
//  CertificateAuthenticationInterceptorTests.swift
//  swift-authentication-grpc
//
//  Created by Zaid Rahhawi on 9/11/26.
//

import Authentication
import AuthenticationGRPCNIOTransport
import Crypto
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import ServiceContextModule
import Testing
import X509

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

@Suite
struct CertificateAuthenticationInterceptorTests {
    struct Workload: Sendable, Equatable {
        let name: String
    }

    /// Names a peer by its certificate's common name: known names prove a workload; unknown
    /// or refused names throw.
    struct CommonNameAuthenticator: Authenticator {
        struct Refused: Error {}

        let workloads: [String: Workload]
        var refused: Set<String> = []

        func authenticate(_ certificate: Certificate) throws -> Workload {
            let name = certificate.subject.first { $0.first?.type == .RDNAttributeType.commonName }?.first?.value.description ?? ""
            if refused.contains(name) {
                throw Refused()
            }
            guard let workload = workloads[name] else {
                throw Refused()
            }
            return workload
        }
    }

    let interceptor = CertificateAuthenticationInterceptor<Workload>(
        authenticator: CommonNameAuthenticator(workloads: ["billing-worker": Workload(name: "billing-worker")], refused: ["revoked"])
    )

    /// A self-signed certificate with the given common name.
    func certificate(commonName: String) throws -> Certificate {
        let key = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let name = try DistinguishedName { CommonName(commonName) }
        return try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: key.publicKey,
            notValidBefore: Date(),
            notValidAfter: Date().addingTimeInterval(3600),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions(),
            issuerPrivateKey: key
        )
    }

    /// Runs the interceptor over a connection that presented `certificate`, if any, and returns
    /// the principal the handler saw.
    func principalSeen(presenting certificate: Certificate?, overNIOTransport: Bool = true, handlerCalls: Seen<Bool> = Seen(), contextSeen: Seen<ServiceContext> = Seen()) async throws -> Principal<Workload, Certificate>? {
        let request = StreamingServerRequest<String>(metadata: [:], messages: RPCAsyncSequence(wrapping: AsyncThrowingStream { $0.finish() }))
        var context = ServerContext(descriptor: .init(fullyQualifiedService: "test.Service", method: "Call"), remotePeer: "client", localPeer: "server", cancellation: .init())
        if overNIOTransport {
            var transport = HTTP2ServerTransport.Posix.Context()
            transport.peerCertificate = certificate
            context.transportSpecific = transport
        }

        let seen = Seen<Principal<Workload, Certificate>?>()
        _ = try await interceptor.intercept(request: request, context: context) { _, _ -> StreamingServerResponse<String> in
            await handlerCalls.record(true)
            await contextSeen.record(ServiceContext.current ?? .topLevel)
            await seen.record(ServiceContext.current?[PrincipalKey<Workload, Certificate>.self])
            return StreamingServerResponse(metadata: [:]) { _ in [:] }
        }
        return await seen.value ?? nil
    }

    @Test("A known peer's certificate binds its principal for the handler")
    func knownPeerBindsPrincipal() async throws {
        let certificate = try certificate(commonName: "billing-worker")

        let calls = Seen<Bool>()
        let principal = try await principalSeen(presenting: certificate, handlerCalls: calls)
        #expect(await calls.value == true)

        #expect(principal?.identity == Workload(name: "billing-worker"))
        #expect(principal?.credential == certificate)
    }

    @Test("A connection without a client certificate continues unbound")
    func noCertificateContinuesUnbound() async throws {
        let calls = Seen<Bool>()
        #expect(try await principalSeen(presenting: nil, handlerCalls: calls) == nil)
        #expect(await calls.value == true)
    }

    @Test("A transport that exposes no certificate continues unbound")
    func otherTransportContinuesUnbound() async throws {
        let calls = Seen<Bool>()
        #expect(try await principalSeen(presenting: nil, overNIOTransport: false, handlerCalls: calls) == nil)
        #expect(await calls.value == true)
    }

    @Test("A failed certificate is unauthenticated before the handler runs", arguments: ["stranger", "revoked"])
    func failedCertificateIsUnauthenticated(commonName: String) async throws {
        let calls = Seen<Bool>()
        await #expect {
            try await principalSeen(presenting: try certificate(commonName: commonName), handlerCalls: calls)
        } throws: { error in
            (error as? RPCError)?.code == .unauthenticated
        }
        #expect(await calls.value == nil)
    }

    enum TraceKey: ServiceContextKey {
        typealias Value = String
    }

    @Test("The certificate binding preserves the bearer principal and restores its scope")
    func bindingIsScoped() async throws {
        let certificate = try certificate(commonName: "billing-worker")
        let outer = Principal(identity: Workload(name: "outer"), credential: certificate)
        var context = ServiceContext.topLevel
        context[TraceKey.self] = "trace-1"
        context[PrincipalKey<String, String>.self] = Principal(identity: "alice", credential: "alice-token")
        context[PrincipalKey<Workload, Certificate>.self] = outer
        let seen = Seen<ServiceContext>()

        try await ServiceContext.withValue(context) {
            let principal = try await principalSeen(presenting: certificate, contextSeen: seen)
            #expect(principal?.identity.name == "billing-worker")
            #expect(await seen.value?[TraceKey.self] == "trace-1")
            #expect(await seen.value?[PrincipalKey<String, String>.self]?.identity == "alice")
            #expect(await seen.value?[PrincipalKey<String, String>.self]?.credential == "alice-token")
            #expect(ServiceContext.current?[PrincipalKey<Workload, Certificate>.self]?.identity == outer.identity)
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
