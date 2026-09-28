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
    func registerMethods<Transport: ServerTransport>(with router: inout RPCRouter<Transport>) {
        router.registerHandler(forMethod: method, deserializer: StringCodec(), serializer: StringCodec()) { request, _ in
            _ = try await ServerRequest(stream: request)
            let principal = ServiceContext.current?[PrincipalKey<SPIFFEID, SPIFFEAuthenticator.Verification>.self]
            let identity = principal?.identity.uri ?? "anonymous"
            return StreamingServerResponse { writer in
                try await writer.write(identity)
                return [:]
            }
        }
    }
}

@Suite struct SPIFFETransportTests {
    private func bundle(_ roots: TestCertificate...) throws -> SPIFFETrustBundle {
        try SPIFFETrustBundle(trustDomain: "example", authorities: roots.map(\.certificate))
    }

    private func security(_ leaf: TestCertificate, roots: SPIFFETrustBundle) async throws -> SPIFFETransportSecurity {
        try await SPIFFETransportSecurity(certificateChain: [leaf.certificate], privateKey: leaf.key, bundle: roots)
    }

    private func call(port: Int, client: SPIFFETransportSecurity, expectedServer: String = "spiffe://example/server") async throws -> String {
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

    private func withServer<T: Sendable>(security: SPIFFETransportSecurity, operation: (Int) async throws -> T) async throws -> T {
        let transport = HTTP2ServerTransport.Posix(address: .ipv4(host: "127.0.0.1", port: 0), transportSecurity: try security.serverTransportSecurity(), config: SPIFFETransportSecurity.serverConfiguration)
        return try await withGRPCServer(transport: transport, services: [IdentityService()], interceptors: [SPIFFEAuthenticationInterceptor(security: security)]) { server in
            let address = try #require(await server.listeningAddress?.ipv4)
            return try await operation(address.port)
        }
    }

    @Test func mutuallyAuthenticatesAndBindsIdentity() async throws {
        let root = try TestCertificate()
        let roots = try bundle(root)
        let server = try await security(TestCertificate(issuer: root, uris: ["spiffe://example/server"], ca: false), roots: roots)
        let client = try await security(TestCertificate(issuer: root, uris: ["spiffe://example/client"], ca: false), roots: roots)
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
        let server = try await security(TestCertificate(issuer: root, uris: ["spiffe://example/server"], ca: false), roots: roots)
        let foreignClient = try await security(TestCertificate(issuer: foreign, uris: ["spiffe://example/client"], ca: false), roots: bundle(root, foreign))
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

    @Test func rotatesCertificatesAndRootsWithoutRebuildingTransport() async throws {
        let old = try TestCertificate()
        let new = try TestCertificate()
        let oldServer = try TestCertificate(issuer: old, uris: ["spiffe://example/server"], ca: false)
        let oldClient = try TestCertificate(issuer: old, uris: ["spiffe://example/client"], ca: false)
        let server = try await security(oldServer, roots: bundle(old))
        let client = try await security(oldClient, roots: bundle(old))
        let staleClient = try await security(oldClient, roots: bundle(old, new))
        try await withServer(security: server) { port async throws -> Void in
            #expect(try await call(port: port, client: client) == "spiffe://example/client")
            let newServer = try TestCertificate(issuer: new, uris: ["spiffe://example/server"], ca: false)
            let newClient = try TestCertificate(issuer: new, uris: ["spiffe://example/client"], ca: false)
            try await server.update(certificateChain: [newServer.certificate], privateKey: newServer.key, bundle: bundle(old, new))
            try await client.update(certificateChain: [newClient.certificate], privateKey: newClient.key, bundle: bundle(old, new))
            #expect(try await call(port: port, client: client) == "spiffe://example/client")
            #expect(try await call(port: port, client: staleClient) == "spiffe://example/client")
            try await server.update(certificateChain: [newServer.certificate], privateKey: newServer.key, bundle: bundle(new))
            await #expect(throws: (any Error).self) { try await call(port: port, client: staleClient) }
            #expect(try await call(port: port, client: client) == "spiffe://example/client")
        }
    }

    @Test func failedRenewalPreservesValidSnapshotAndRevocationRefusesCalls() async throws {
        let root = try TestCertificate()
        let leaf = try TestCertificate(issuer: root, uris: ["spiffe://example/server"], ca: false)
        let server = try await security(leaf, roots: bundle(root))
        let client = try await security(TestCertificate(issuer: root, uris: ["spiffe://example/client"], ca: false), roots: bundle(root))
        let expired = try TestCertificate(issuer: root, uris: ["spiffe://example/server"], ca: false, notBefore: Date(timeIntervalSince1970: 0), notAfter: Date(timeIntervalSince1970: 1))
        await #expect(throws: (any Error).self) { try await server.update(certificateChain: [expired.certificate], privateKey: expired.key, bundle: bundle(root)) }
        #expect(server.isReady)
        await #expect(throws: SPIFFETransportSecurity.Error.keyMismatch) { try await server.update(certificateChain: [leaf.certificate], privateKey: root.key, bundle: bundle(root)) }
        try await withServer(security: server) { port async throws -> Void in
            #expect(try await call(port: port, client: client) == "spiffe://example/client")
            server.revoke()
            #expect(!server.isReady)
            await #expect(throws: (any Error).self) { try await call(port: port, client: client) }
            try await server.update(certificateChain: [leaf.certificate], privateKey: leaf.key, bundle: bundle(root))
            #expect(try await call(port: port, client: client) == "spiffe://example/client")
        }
    }

    @Test func existingConnectionRechecksTrustAfterRotation() async throws {
        let old = try TestCertificate()
        let new = try TestCertificate()
        let oldServer = try TestCertificate(issuer: old, uris: ["spiffe://example/server"], ca: false)
        let oldClient = try TestCertificate(issuer: old, uris: ["spiffe://example/client"], ca: false)
        let server = try await security(oldServer, roots: bundle(old))
        let clientSecurity = try await security(oldClient, roots: bundle(old, new))
        try await withServer(security: server) { port async throws -> Void in
            let transport = try HTTP2ClientTransport.Posix(target: .ipv4(address: "127.0.0.1", port: port), transportSecurity: clientSecurity.clientTransportSecurity(expectedServer: SPIFFEID(uri: "spiffe://example/server")))
            try await withGRPCClient(transport: transport) { client in
                var options = CallOptions.defaults
                options.timeout = .seconds(2)
                options.waitForReady = true
                let result = try await client.unary(request: ClientRequest(message: ""), descriptor: method, serializer: StringCodec(), deserializer: StringCodec(), options: options) { try $0.message }
                #expect(result == "spiffe://example/client")
                let newServer = try TestCertificate(issuer: new, uris: ["spiffe://example/server"], ca: false)
                try await server.update(certificateChain: [newServer.certificate], privateKey: newServer.key, bundle: bundle(new))
                // The already-open TLS connection still carries the old client's certificate.
                do {
                    _ = try await client.unary(request: ClientRequest(message: ""), descriptor: method, serializer: StringCodec(), deserializer: StringCodec(), options: options) { try $0.message }
                    Issue.record("Removed authority remained trusted on an established connection")
                } catch let error as RPCError {
                    #expect(error.code == .unauthenticated)
                }
            }
        }
    }

    @Test func connectionAgeForcesReauthentication() async throws {
        let root = try TestCertificate()
        let roots = try bundle(root)
        let serverSecurity = try await security(TestCertificate(issuer: root, uris: ["spiffe://example/server"], ca: false), roots: roots)
        let clientSecurity = try await security(TestCertificate(issuer: root, uris: ["spiffe://example/client"], ca: false), roots: roots)
        let connections = ConnectionCounter()
        var configuration = SPIFFETransportSecurity.serverConfiguration
        configuration.connection.maxAge = .milliseconds(100)
        configuration.connection.maxGraceTime = .milliseconds(100)
        configuration.channelDebuggingCallbacks.onAcceptTCPConnection = { channel in
            connections.increment()
            return channel.eventLoop.makeSucceededVoidFuture()
        }
        let serverTransport = HTTP2ServerTransport.Posix(address: .ipv4(host: "127.0.0.1", port: 0), transportSecurity: try serverSecurity.serverTransportSecurity(), config: configuration)
        try await withGRPCServer(transport: serverTransport, services: [IdentityService()], interceptors: [SPIFFEAuthenticationInterceptor(security: serverSecurity)]) { server in
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

    @Test func expiredLocalMaterialFailsReadinessWithoutAnUpdate() async throws {
        let root = try TestCertificate()
        let expiration = Date.now.addingTimeInterval(2)
        let leaf = try TestCertificate(issuer: root, uris: ["spiffe://example/server"], ca: false, notAfter: expiration)
        let value = try await security(leaf, roots: bundle(root))
        #expect(value.isReady)
        // Certificate validity uses wall time; a monotonic sleep alone cannot establish expiry.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        let certificateExpiration = leaf.certificate.notValidAfter
        while Date.now <= certificateExpiration, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(Date.now > certificateExpiration)
        #expect(!value.isReady)
        #expect(throws: SPIFFETransportSecurity.Error.notReady) { try value.serverTransportSecurity() }
    }

    @Test func interceptorRefusesMissingChain() async throws {
        let root = try TestCertificate()
        let server = try await security(TestCertificate(issuer: root, uris: ["spiffe://example/server"], ca: false), roots: bundle(root))
        let interceptor = SPIFFEAuthenticationInterceptor(security: server)
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
