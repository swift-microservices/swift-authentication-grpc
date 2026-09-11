//
//  CertificateAuthenticationInterceptorTests.swift
//  swift-authentication-grpc
//
//  Created by Zaid Rahhawi on 9/11/26.
//

import Authentication
import AuthenticationGRPCNIOTransport
import Crypto
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import ServiceContextModule
import Testing
import X509

@Suite
struct CertificateAuthenticationInterceptorTests {
    struct Workload: Sendable, Equatable {
        let name: String
    }

    /// Names a peer by its certificate's common name: known names prove a workload, `refused`
    /// throws, anything else is declined.
    struct CommonNameAuthenticator: Authenticator {
        struct Refused: Error {}

        let workloads: [String: Workload]
        var refused: Set<String> = []

        func authenticate(_ certificate: Certificate) throws -> Workload? {
            let name = certificate.subject.first { $0.first?.type == .RDNAttributeType.commonName }?.first?.value.description ?? ""
            if refused.contains(name) {
                throw Refused()
            }
            return workloads[name]
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
    func principalSeen(presenting certificate: Certificate?, overNIOTransport: Bool = true) async throws -> Principal<Workload, Certificate>? {
        let request = StreamingServerRequest<String>(metadata: [:], messages: RPCAsyncSequence(wrapping: AsyncThrowingStream { $0.finish() }))
        var context = ServerContext(descriptor: .init(fullyQualifiedService: "test.Service", method: "Call"), remotePeer: "client", localPeer: "server", cancellation: .init())
        if overNIOTransport {
            var transport = HTTP2ServerTransport.Posix.Context()
            transport.peerCertificate = certificate
            context.transportSpecific = transport
        }

        let seen = Seen<Principal<Workload, Certificate>?>()
        _ = try await interceptor.intercept(request: request, context: context) { _, _ -> StreamingServerResponse<String> in
            await seen.record(ServiceContext.current?[PrincipalKey<Workload, Certificate>.self])
            return StreamingServerResponse(metadata: [:]) { _ in [:] }
        }
        return await seen.value ?? nil
    }

    @Test("A known peer's certificate binds its principal for the handler")
    func knownPeerBindsPrincipal() async throws {
        let certificate = try certificate(commonName: "billing-worker")

        let principal = try await principalSeen(presenting: certificate)

        #expect(principal?.identity == Workload(name: "billing-worker"))
        #expect(principal?.credential == certificate)
    }

    @Test("A connection without a client certificate continues unbound")
    func noCertificateContinuesUnbound() async throws {
        #expect(try await principalSeen(presenting: nil) == nil)
    }

    @Test("A transport that exposes no certificate continues unbound")
    func otherTransportContinuesUnbound() async throws {
        #expect(try await principalSeen(presenting: nil, overNIOTransport: false) == nil)
    }

    @Test("A declined certificate continues unbound")
    func declinedCertificateContinuesUnbound() async throws {
        #expect(try await principalSeen(presenting: try certificate(commonName: "stranger")) == nil)
    }

    @Test("A refused certificate fails the call as unauthenticated before the handler runs")
    func refusedCertificateIsUnauthenticated() async throws {
        await #expect {
            try await principalSeen(presenting: try certificate(commonName: "revoked"))
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
