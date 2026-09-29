//
//  SPIFFETransportTests.swift
//  swift-authentication-grpc
//
//  Created by Zaid Rahhawi on 9/28/26.
//

import Authentication
import AuthenticationSPIFFE
import AuthenticationSPIFFEGRPC
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
            let principal = ServiceContext.current?[PrincipalKey<SPIFFEID, SPIFFEAuthenticator.Verification>.self]
            let identity = principal?.identity.uri ?? "anonymous"
            await beforeResponse()
            return StreamingServerResponse { writer in
                try await writer.write(identity)
                return [:]
            }
        }
    }
}

private final class TestTLS: Sendable {
    let authenticator: SPIFFEAuthenticator
    let reloader: TimedCertificateReloader
    let source: Source

    final class Source: Sendable {
        let bytes: Mutex<(certificate: [UInt8], key: [UInt8])>
        init(_ value: (certificate: [UInt8], key: [UInt8])) { bytes = Mutex(value) }
    }

    init(_ leaf: TestCertificate, roots: SPIFFETrustBundle) throws {
        authenticator = SPIFFEAuthenticator(bundle: roots)
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
        .certificates(try authenticator.bundle.authorities.map { .bytes(Array(try $0.serializeAsPEM().pemString.utf8), format: .pem) })
    }

    func serverTransportSecurity() throws -> HTTP2ServerTransport.Posix.TransportSecurity {
        let roots = try trustRoots()
        return try .mTLS(certificateReloader: reloader) {
            $0.trustRoots = roots
            $0.requireALPN = true
            $0.customVerificationCallback = authenticator.certificateVerificationCallback()
        }
    }

    func clientTransportSecurity(expectedServer: SPIFFEID) throws -> HTTP2ClientTransport.Posix.TransportSecurity {
        let roots = try trustRoots()
        return try .mTLS(certificateReloader: reloader) {
            $0.trustRoots = roots
            $0.serverCertificateVerification = .noHostnameVerification
            $0.customVerificationCallback = authenticator.certificateVerificationCallback(expectedPeer: expectedServer)
        }
    }
}

@Suite struct SPIFFETransportTests {
    private func bundle(_ roots: TestCertificate...) throws -> SPIFFETrustBundle {
        try SPIFFETrustBundle(trustDomain: "example", authorities: roots.map(\.certificate))
    }

    private func security(_ leaf: TestCertificate, roots: SPIFFETrustBundle) throws -> TestTLS {
        try TestTLS(leaf, roots: roots)
    }

    private func call(port: Int, client: TestTLS, expectedServer: String = "spiffe://example/server") async throws -> String {
        try await call(port: port, tls: client.clientTransportSecurity(expectedServer: SPIFFEID(uri: expectedServer)))
    }

    private func call(port: Int, tls: HTTP2ClientTransport.Posix.TransportSecurity) async throws -> String {
        let transport = try HTTP2ClientTransport.Posix(target: .ipv4(address: "127.0.0.1", port: port), transportSecurity: tls)
        return try await withGRPCClient(transport: transport) { client in
            var options = CallOptions.defaults
            options.timeout = .seconds(2)
            options.waitForReady = true
            return try await client.unary(request: ClientRequest(message: ""), descriptor: method, serializer: StringCodec(), deserializer: StringCodec(), options: options) { try $0.message }
        }
    }

    private func withServer<T: Sendable>(security: TestTLS, beforeResponse: @escaping @Sendable () async -> Void = {}, operation: (Int) async throws -> T) async throws -> T {
        let transport = HTTP2ServerTransport.Posix(address: .ipv4(host: "127.0.0.1", port: 0), transportSecurity: try security.serverTransportSecurity(), config: HTTP2ServerTransport.Posix.Config.defaults)
        return try await withGRPCServer(transport: transport, services: [IdentityService(beforeResponse: beforeResponse)], interceptors: [SPIFFEAuthenticationInterceptor(authenticator: security.authenticator)]) { server in
            let address = try #require(await server.listeningAddress?.ipv4)
            return try await operation(address.port)
        }
    }

    @Test func mutuallyAuthenticatesAndBindsIdentity() async throws {
        let root = try TestCertificate()
        let roots = try bundle(root)
        let server = try security(TestCertificate(issuer: root, uris: ["spiffe://example/server"], ca: false), roots: roots)
        let client = try security(TestCertificate(issuer: root, uris: ["spiffe://example/client"], ca: false), roots: roots)
        try await withServer(security: server) { port async throws -> Void in
            #expect(try await call(port: port, client: client) == "spiffe://example/client")
            await #expect(throws: (any Error).self) { try await call(port: port, client: client, expectedServer: "spiffe://example/other") }
        }
        #expect(ServiceContext.current?[PrincipalKey<SPIFFEID, SPIFFEAuthenticator.Verification>.self] == nil)
    }

    @Test func rejectsMissingAndUntrustedClientCertificates() async throws {
        let root = try TestCertificate()
        let foreign = try TestCertificate()
        let roots = try bundle(root)
        let server = try security(TestCertificate(issuer: root, uris: ["spiffe://example/server"], ca: false), roots: roots)
        let foreignClient = try security(TestCertificate(issuer: foreign, uris: ["spiffe://example/client"], ca: false), roots: bundle(root, foreign))
        try await withServer(security: server) { port async throws -> Void in
            await #expect(throws: (any Error).self) { try await call(port: port, client: foreignClient) }
            // The client can trust the server but offers no certificate. Server mTLS must refuse.
            let rootPEM = Array(try root.certificate.serializeAsPEM().pemString.utf8)
            let tls = HTTP2ClientTransport.Posix.TransportSecurity.tls { config in
                config.serverCertificateVerification = .noHostnameVerification
                config.trustRoots = .certificates([.bytes(rootPEM, format: .pem)])
            }
            await #expect(throws: (any Error).self) { try await call(port: port, tls: tls) }
        }
    }

    @Test func standardReloaderRotatesAndPeersRejectInvalidSPIFFEUpdates() async throws {
        let root = try TestCertificate()
        let roots = try bundle(root)
        let initial = try TestCertificate(issuer: root, uris: ["spiffe://example/server"], ca: false)
        let server = try security(initial, roots: roots)
        let client = try security(TestCertificate(issuer: root, uris: ["spiffe://example/client"], ca: false), roots: roots)
        try await withServer(security: server) { port async throws -> Void in
            #expect(try await call(port: port, client: client) == "spiffe://example/client")
            let renewed = try TestCertificate(issuer: root, uris: ["spiffe://example/server"], ca: false)
            try server.load(renewed)
            #expect(try await call(port: port, client: client) == "spiffe://example/client")
            let untrusted = try TestCertificate()
            for invalid in [
                try TestCertificate(issuer: root, uris: ["spiffe://example/other"], ca: false),
                try TestCertificate(issuer: root, uris: ["spiffe://example/server"], ca: false, notAfter: Date.now.addingTimeInterval(-1)),
                try TestCertificate(issuer: untrusted, uris: ["spiffe://example/server"], ca: false),
                try TestCertificate(issuer: root, uris: ["spiffe://other/server"], ca: false),
            ] {
                try server.load(invalid)
                await #expect(throws: (any Error).self) { try await call(port: port, client: client) }
            }
            try server.load(renewed)
            #expect(try await call(port: port, client: client) == "spiffe://example/client")
            server.source.bytes.withLock { $0.key = Array("invalid PEM".utf8) }
            #expect(throws: (any Error).self) { try server.reloader.reload() }
            #expect(try await call(port: port, client: client) == "spiffe://example/client")
        }
    }

    @Test func renewalDoesNotInterruptAnInFlightRPC() async throws {
        let root = try TestCertificate()
        let roots = try bundle(root)
        let server = try security(TestCertificate(issuer: root, uris: ["spiffe://example/server"], ca: false), roots: roots)
        let client = try security(TestCertificate(issuer: root, uris: ["spiffe://example/client"], ca: false), roots: roots)
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
                let renewed = try TestCertificate(issuer: root, uris: ["spiffe://example/server"], ca: false)
                try server.load(renewed)
                release.continuation.finish()
                #expect(try await response == "spiffe://example/client")
                // The same listener also accepts a fresh connection after rotation.
                #expect(try await call(port: port, client: client) == "spiffe://example/client")
            }
        )
    }

    @Test func connectionAgeForcesReauthentication() async throws {
        let root = try TestCertificate()
        let roots = try bundle(root)
        let serverSecurity = try security(TestCertificate(issuer: root, uris: ["spiffe://example/server"], ca: false), roots: roots)
        let clientSecurity = try security(TestCertificate(issuer: root, uris: ["spiffe://example/client"], ca: false), roots: roots)
        let connections = ConnectionCounter()
        var configuration = HTTP2ServerTransport.Posix.Config.defaults
        configuration.connection.maxAge = .milliseconds(100)
        configuration.connection.maxGraceTime = .milliseconds(100)
        configuration.channelDebuggingCallbacks.onAcceptTCPConnection = { channel in
            connections.increment()
            return channel.eventLoop.makeSucceededVoidFuture()
        }
        let serverTransport = HTTP2ServerTransport.Posix(address: .ipv4(host: "127.0.0.1", port: 0), transportSecurity: try serverSecurity.serverTransportSecurity(), config: configuration)
        try await withGRPCServer(transport: serverTransport, services: [IdentityService()], interceptors: [SPIFFEAuthenticationInterceptor(authenticator: serverSecurity.authenticator)]) { server in
            let address = try #require(await server.listeningAddress?.ipv4)
            let transport = try HTTP2ClientTransport.Posix(target: .ipv4(address: "127.0.0.1", port: address.port), transportSecurity: clientSecurity.clientTransportSecurity(expectedServer: SPIFFEID(uri: "spiffe://example/server")))
            try await withGRPCClient(transport: transport) { client in
                var options = CallOptions.defaults
                options.timeout = .seconds(2)
                options.waitForReady = true
                _ = try await client.unary(request: ClientRequest(message: ""), descriptor: method, serializer: StringCodec(), deserializer: StringCodec(), options: options) { try $0.message }
                try await Task.sleep(for: .milliseconds(500))
                let result = try await client.unary(request: ClientRequest(message: ""), descriptor: method, serializer: StringCodec(), deserializer: StringCodec(), options: options) { try $0.message }
                #expect(result == "spiffe://example/client")
                #expect(connections.value >= 2)
            }
        }
    }

    @Test func protectedRPCRejectsPeerExpiryOnAnExistingConnection() async throws {
        let root = try TestCertificate()
        let roots = try bundle(root)
        let server = try security(TestCertificate(issuer: root, uris: ["spiffe://example/server"], ca: false), roots: roots)
        let leaf = try TestCertificate(issuer: root, uris: ["spiffe://example/client"], ca: false, notAfter: Date.now.addingTimeInterval(3))
        let peer = try security(leaf, roots: roots)
        try await withServer(security: server) { port async throws -> Void in
            let transport = try HTTP2ClientTransport.Posix(target: .ipv4(address: "127.0.0.1", port: port), transportSecurity: peer.clientTransportSecurity(expectedServer: SPIFFEID(uri: "spiffe://example/server")))
            try await withGRPCClient(transport: transport) { client in
                var options = CallOptions.defaults
                options.timeout = .seconds(2)
                options.waitForReady = true
                let response = try await client.unary(request: ClientRequest(message: ""), descriptor: method, serializer: StringCodec(), deserializer: StringCodec(), options: options) { try $0.message }
                #expect(response == "spiffe://example/client")
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

    @Test func interceptorRefusesMissingChain() async throws {
        let root = try TestCertificate()
        let server = try security(TestCertificate(issuer: root, uris: ["spiffe://example/server"], ca: false), roots: bundle(root))
        let interceptor = SPIFFEAuthenticationInterceptor(authenticator: server.authenticator)
        let request = StreamingServerRequest<String>(metadata: [:], messages: RPCAsyncSequence(wrapping: AsyncThrowingStream { $0.finish() }))
        let context = ServerContext(descriptor: method, remotePeer: "client", localPeer: "server", cancellation: .init())
        await #expect(throws: RPCError(code: .unauthenticated, message: "SPIFFE authentication is required.")) {
            try await interceptor.intercept(request: request, context: context) { _, _ -> StreamingServerResponse<String> in
                Issue.record("Unauthenticated handler was reached")
                return StreamingServerResponse { _ in [:] }
            }
        }
    }
}
