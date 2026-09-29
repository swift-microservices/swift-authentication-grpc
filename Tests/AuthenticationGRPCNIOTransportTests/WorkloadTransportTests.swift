//
//  WorkloadTransportTests.swift
//  swift-authentication-grpc
//
//  Created by Zaid Rahhawi on 9/28/26.
//

import Authentication
import AuthenticationGRPCNIOTransport
import AuthenticationX509
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import NIOCertificateReloading
import NIOCore
import ServiceContextModule
import SwiftASN1
import Synchronization
import Testing
import X509

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

private struct StringCodec: MessageSerializer, MessageDeserializer {
    func serialize<Bytes: GRPCContiguousBytes>(_ message: String) throws -> Bytes { Bytes(message.utf8) }
    func deserialize<Bytes: GRPCContiguousBytes>(_ serializedMessageBytes: Bytes) throws -> String {
        serializedMessageBytes.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
    }
}

private let method = MethodDescriptor(fullyQualifiedService: "test.Identity", method: "WhoAmI")

private final class ConnectionCounter: Sendable {
    private let count = Mutex(0)

    func increment() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

private struct IdentityService: RegistrableRPCService {
    var beforeResponse: @Sendable () async -> Void = {}
    func registerMethods<Transport: ServerTransport>(with router: inout RPCRouter<Transport>) {
        router.registerHandler(forMethod: method, deserializer: StringCodec(), serializer: StringCodec()) { request, _ in
            _ = try await ServerRequest(stream: request)
            let principal = ServiceContext.current?[PrincipalKey<WorkloadIdentity, Certificate>.self]
            guard let principal else { throw RPCError(code: .unauthenticated, message: "Certificate required.") }
            let identity = principal.identity.uri
            await beforeResponse()
            return StreamingServerResponse { writer in
                try await writer.write(identity)
                return [:]
            }
        }
    }
}

private final class TestTLS: Sendable {
    let authenticator: WorkloadCertificateAuthenticator
    let authorities: [Certificate]
    let reloader: TimedCertificateReloader
    let source: Source

    final class Source: Sendable {
        let bytes: Mutex<(certificate: [UInt8], key: [UInt8])>
        init(_ value: (certificate: [UInt8], key: [UInt8])) { bytes = Mutex(value) }
    }

    init(_ leaf: TestCertificate, roots: [Certificate]) throws {
        authenticator = try WorkloadCertificateAuthenticator(authority: "identity.example")
        authorities = roots
        let source = Source(try Self.bytes(leaf))
        self.source = source
        reloader = try TimedCertificateReloader.makeReloaderValidatingSources(
            configuration: .init(
                refreshInterval: .seconds(60),
                certificateSource: .init(location: .memory { source.bytes.withLock { $0.certificate } }, format: .pem),
                privateKeySource: .init(location: .memory { source.bytes.withLock { $0.key } }, format: .pem)
            ))
    }

    static func bytes(_ leaf: TestCertificate) throws -> (certificate: [UInt8], key: [UInt8]) {
        (Array(try leaf.certificate.serializeAsPEM().pemString.utf8), Array(try leaf.key.serializeAsPEM().pemString.utf8))
    }

    func load(_ leaf: TestCertificate) throws {
        let bytes = try Self.bytes(leaf)
        source.bytes.withLock { $0 = bytes }
        try reloader.reload()
    }

    func trustRoots() throws -> TLSConfig.TrustRootsSource {
        .certificates(try authorities.map { .bytes(Array(try $0.serializeAsPEM().pemString.utf8), format: .pem) })
    }

    func serverTransportSecurity() throws -> HTTP2ServerTransport.Posix.TransportSecurity {
        let roots = try trustRoots()
        return try .mTLS(certificateReloader: reloader) {
            $0.trustRoots = roots
            $0.requireALPN = true
        }
    }

    func clientTransportSecurity() throws -> HTTP2ClientTransport.Posix.TransportSecurity {
        let roots = try trustRoots()
        return try .mTLS(certificateReloader: reloader) {
            $0.trustRoots = roots
            $0.serverCertificateVerification = .fullVerification
        }
    }
}

@Suite struct WorkloadTransportTests {
    private func bundle(_ roots: TestCertificate...) throws -> [Certificate] {
        roots.map(\.certificate)
    }

    private func security(_ leaf: TestCertificate, roots: [Certificate]) throws -> TestTLS {
        try TestTLS(leaf, roots: roots)
    }

    private func call(port: Int, client: TestTLS, expectedServer: String = "server.example") async throws -> String {
        try await call(port: port, tls: client.clientTransportSecurity(), hostname: expectedServer)
    }

    private func call(port: Int, tls: HTTP2ClientTransport.Posix.TransportSecurity, hostname: String = "server.example") async throws -> String {
        var config = HTTP2ClientTransport.Posix.Config.defaults
        config.http2.authority = hostname
        let transport = try HTTP2ClientTransport.Posix(target: .ipv4(address: "127.0.0.1", port: port), transportSecurity: tls, config: config)
        return try await withGRPCClient(transport: transport) { client in
            var options = CallOptions.defaults
            options.timeout = .seconds(2)
            options.waitForReady = true
            return try await client.unary(request: ClientRequest(message: ""), descriptor: method, serializer: StringCodec(), deserializer: StringCodec(), options: options) { try $0.message }
        }
    }

    private func withServer<T: Sendable>(security: TestTLS, beforeResponse: @escaping @Sendable () async -> Void = {}, operation: (Int) async throws -> T) async throws -> T {
        let transport = HTTP2ServerTransport.Posix(address: .ipv4(host: "127.0.0.1", port: 0), transportSecurity: try security.serverTransportSecurity(), config: HTTP2ServerTransport.Posix.Config.defaults)
        return try await withGRPCServer(transport: transport, services: [IdentityService(beforeResponse: beforeResponse)], interceptors: [CertificateAuthenticationInterceptor(authenticator: security.authenticator)]) { server in
            let address = try #require(await server.listeningAddress?.ipv4)
            return try await operation(address.port)
        }
    }

    @Test func mutuallyAuthenticatesAndBindsIdentity() async throws {
        let root = try TestCertificate()
        let roots = try bundle(root)
        let server = try security(TestCertificate(issuer: root, uris: ["https://identity.example/server"], ca: false), roots: roots)
        let client = try security(TestCertificate(issuer: root, uris: ["https://identity.example/client"], ca: false), roots: roots)
        try await withServer(security: server) { port async throws -> Void in
            #expect(try await call(port: port, client: client) == "https://identity.example/client")
            await #expect(throws: (any Error).self) { try await call(port: port, client: client, expectedServer: "other.example") }
        }
        #expect(ServiceContext.current?[PrincipalKey<WorkloadIdentity, Certificate>.self] == nil)
    }

    @Test func rejectsMissingAndUntrustedClientCertificates() async throws {
        let root = try TestCertificate()
        let foreign = try TestCertificate()
        let roots = try bundle(root)
        let server = try security(TestCertificate(issuer: root, uris: ["https://identity.example/server"], ca: false), roots: roots)
        let foreignClient = try security(TestCertificate(issuer: foreign, uris: ["https://identity.example/client"], ca: false), roots: bundle(root, foreign))
        try await withServer(security: server) { port async throws -> Void in
            await #expect(throws: (any Error).self) { try await call(port: port, client: foreignClient) }
            // The client can trust the server but offers no certificate. Server mTLS must refuse.
            let rootPEM = Array(try root.certificate.serializeAsPEM().pemString.utf8)
            let tls = HTTP2ClientTransport.Posix.TransportSecurity.tls { config in
                config.serverCertificateVerification = .fullVerification
                config.trustRoots = .certificates([.bytes(rootPEM, format: .pem)])
            }
            await #expect(throws: (any Error).self) { try await call(port: port, tls: tls) }
        }
    }

    @Test func standardReloaderRotatesAndPeersRejectInvalidUpdates() async throws {
        let root = try TestCertificate()
        let roots = try bundle(root)
        let initial = try TestCertificate(issuer: root, uris: ["https://identity.example/server"], ca: false)
        let server = try security(initial, roots: roots)
        let client = try security(TestCertificate(issuer: root, uris: ["https://identity.example/client"], ca: false), roots: roots)
        try await withServer(security: server) { port async throws -> Void in
            #expect(try await call(port: port, client: client) == "https://identity.example/client")
            let renewed = try TestCertificate(issuer: root, uris: ["https://identity.example/server"], ca: false)
            try server.load(renewed)
            #expect(try await call(port: port, client: client) == "https://identity.example/client")
            let untrusted = try TestCertificate()
            for invalid in [
                try TestCertificate(issuer: root, uris: ["https://identity.example/server"], ca: false, dnsNames: ["other.example"]),
                try TestCertificate(issuer: root, uris: ["https://identity.example/server"], ca: false, notAfter: Date.now.addingTimeInterval(-1)),
                try TestCertificate(issuer: untrusted, uris: ["https://identity.example/server"], ca: false),
            ] {
                try server.load(invalid)
                await #expect(throws: (any Error).self) { try await call(port: port, client: client) }
            }
            try server.load(renewed)
            #expect(try await call(port: port, client: client) == "https://identity.example/client")
            server.source.bytes.withLock { $0.key = Array("invalid PEM".utf8) }
            #expect(throws: (any Error).self) { try server.reloader.reload() }
            #expect(try await call(port: port, client: client) == "https://identity.example/client")
        }
    }

    @Test func renewalDoesNotInterruptAnInFlightRPC() async throws {
        let root = try TestCertificate()
        let roots = try bundle(root)
        let server = try security(TestCertificate(issuer: root, uris: ["https://identity.example/server"], ca: false), roots: roots)
        let client = try security(TestCertificate(issuer: root, uris: ["https://identity.example/client"], ca: false), roots: roots)
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        defer {
            entered.continuation.finish()
            release.continuation.finish()
        }
        try await withServer(
            security: server,
            beforeResponse: {
                entered.continuation.yield(())
                for await _ in release.stream { break }
            },
            operation: { port async throws -> Void in
                async let response = call(port: port, client: client)
                for await _ in entered.stream { break }
                let renewed = try TestCertificate(issuer: root, uris: ["https://identity.example/server"], ca: false)
                try server.load(renewed)
                release.continuation.finish()
                #expect(try await response == "https://identity.example/client")
                // The same listener also accepts a fresh connection after rotation.
                #expect(try await call(port: port, client: client) == "https://identity.example/client")
            }
        )
    }

    @Test func connectionAgeForcesReauthentication() async throws {
        let root = try TestCertificate()
        let roots = try bundle(root)
        let serverSecurity = try security(TestCertificate(issuer: root, uris: ["https://identity.example/server"], ca: false), roots: roots)
        let clientSecurity = try security(TestCertificate(issuer: root, uris: ["https://identity.example/client"], ca: false), roots: roots)
        let connections = ConnectionCounter()
        var configuration = HTTP2ServerTransport.Posix.Config.defaults
        configuration.connection.maxAge = .milliseconds(500)
        configuration.connection.maxGraceTime = .milliseconds(500)
        configuration.channelDebuggingCallbacks.onAcceptTCPConnection = { channel in
            connections.increment()
            return channel.eventLoop.makeSucceededVoidFuture()
        }
        let serverTransport = HTTP2ServerTransport.Posix(address: .ipv4(host: "127.0.0.1", port: 0), transportSecurity: try serverSecurity.serverTransportSecurity(), config: configuration)
        try await withGRPCServer(transport: serverTransport, services: [IdentityService()], interceptors: [CertificateAuthenticationInterceptor(authenticator: serverSecurity.authenticator)]) { server in
            let address = try #require(await server.listeningAddress?.ipv4)
            var clientConfig = HTTP2ClientTransport.Posix.Config.defaults
            clientConfig.http2.authority = "server.example"
            let transport = try HTTP2ClientTransport.Posix(target: .ipv4(address: "127.0.0.1", port: address.port), transportSecurity: clientSecurity.clientTransportSecurity(), config: clientConfig)
            try await withGRPCClient(transport: transport) { client in
                var options = CallOptions.defaults
                options.timeout = .seconds(2)
                options.waitForReady = true
                let deadline = ContinuousClock.now.advanced(by: .seconds(8))
                var authenticatedOnReplacement = false
                repeat {
                    do {
                        let response = try await client.unary(request: ClientRequest(message: ""), descriptor: method, serializer: StringCodec(), deserializer: StringCodec(), options: options) { try $0.message }
                        #expect(response == "https://identity.example/client")
                        authenticatedOnReplacement = connections.value >= 2
                    } catch let error as RPCError where error.code == .unavailable {
                        // A bounded, read-only probe may overlap the deliberate GOAWAY/reconnect.
                    }
                    if !authenticatedOnReplacement { try await Task.sleep(for: .milliseconds(50)) }
                } while !authenticatedOnReplacement && ContinuousClock.now < deadline
                #expect(authenticatedOnReplacement)

            }
        }
    }

    @Test func protectedRPCRejectsPeerExpiryOnAnExistingConnection() async throws {
        let root = try TestCertificate()
        let roots = try bundle(root)
        let server = try security(TestCertificate(issuer: root, uris: ["https://identity.example/server"], ca: false), roots: roots)
        let leaf = try TestCertificate(issuer: root, uris: ["https://identity.example/client"], ca: false, notAfter: Date.now.addingTimeInterval(3))
        let peer = try security(leaf, roots: roots)
        try await withServer(security: server) { port async throws -> Void in
            var clientConfig = HTTP2ClientTransport.Posix.Config.defaults
            clientConfig.http2.authority = "server.example"
            let transport = try HTTP2ClientTransport.Posix(target: .ipv4(address: "127.0.0.1", port: port), transportSecurity: peer.clientTransportSecurity(), config: clientConfig)
            try await withGRPCClient(transport: transport) { client in
                var options = CallOptions.defaults
                options.timeout = .seconds(2)
                options.waitForReady = true
                let response = try await client.unary(request: ClientRequest(message: ""), descriptor: method, serializer: StringCodec(), deserializer: StringCodec(), options: options) { try $0.message }
                #expect(response == "https://identity.example/client")
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(10))
                // RFC 5280 validity comparisons have whole-second precision.
                let expiredAt = leaf.certificate.notValidAfter.addingTimeInterval(1)
                while Date.now <= expiredAt, clock.now < deadline {
                    try await Task.sleep(for: .milliseconds(100))
                }
                try #require(Date.now > expiredAt)
                do {
                    _ = try await client.unary(request: ClientRequest(message: ""), descriptor: method, serializer: StringCodec(), deserializer: StringCodec(), options: options) { try $0.message }
                    Issue.record("Expired peer reached a protected handler")
                } catch let error as RPCError {
                    #expect(error.code == .unauthenticated)
                }
            }
        }
    }

    @Test func rejectsForeignAndAmbiguousCallerURIs() async throws {
        let root = try TestCertificate()
        let roots = try bundle(root)
        let server = try security(TestCertificate(issuer: root, uris: ["https://identity.example/server"], ca: false), roots: roots)
        for names in [["https://identity.foreign/client"], ["https://identity.example/a", "https://identity.example/b"], []] {
            let client = try security(TestCertificate(issuer: root, uris: names, ca: false), roots: roots)
            try await withServer(security: server) { port async throws -> Void in
                await #expect(throws: (any Error).self) { try await call(port: port, client: client) }
            }
        }
    }
}
