//
//  SPIFFETransportSecurity.swift
//  swift-authentication-grpc
//
//  Created by Zaid Rahhawi on 9/28/26.
//

public import AuthenticationSPIFFE
public import GRPCNIOTransportHTTP2Posix
public import NIOCertificateReloading
import NIOCore
import NIOSSL
import SwiftASN1
import Synchronization
public import X509

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// SPIFFE mTLS configuration shared by the server, its interceptor, and outgoing clients.
///
/// An external identity provider calls `update` with renewed material. The update atomically
/// replaces the certificate/key pair and trust snapshot; this type does not contact an issuer.
/// Existing RPC streams still require bounded lifetimes and transport connection draining.
public final class SPIFFETransportSecurity: Sendable {
    /// The local workload identity. Rotation cannot silently change it.
    public let id: SPIFFEID
    private let state: Mutex<State>

    private struct State: Sendable {
        var snapshot: Snapshot
        var revision = 0
        var reloadRevision = 0
        var revoked = false
        var peers: [X509.ValidatedCertificateChain: SPIFFEAuthenticator.Verification] = [:]
    }

    private struct Snapshot: Sendable {
        let authenticator: SPIFFEAuthenticator
        let local: SPIFFEAuthenticator.Verification
        let override: NIOSSLContextConfigurationOverride
        let roots: TLSConfig.TrustRootsSource
    }

    /// Validates the local SVID, its private key, and the domain's trust configuration before use.
    public init(certificateChain: [Certificate], privateKey: Certificate.PrivateKey, bundle: SPIFFETrustBundle) async throws {
        let snapshot = try await Self.snapshot(certificateChain: certificateChain, privateKey: privateKey, bundle: bundle)
        id = snapshot.local.id
        state = Mutex(State(snapshot: snapshot))
    }

    /// Whether unrevoked, currently valid local material is available. Use in readiness checks.
    public var isReady: Bool {
        state.withLock { !$0.revoked && Self.isCurrent($0.snapshot.local.certificateChain) }
    }

    /// A starting server configuration that reauthenticates connections at least every five
    /// minutes, with thirty seconds to drain active streams. Adapt these bounds to the SVID
    /// lifetime and revocation objective; TLS credential updates alone do not close connections.
    public static var serverConfiguration: HTTP2ServerTransport.Posix.Config {
        .defaults {
            $0.connection.maxAge = .seconds(300)
            $0.connection.maxGraceTime = .seconds(30)
        }
    }

    /// Atomically replaces material after validating it. A failed update preserves the last valid
    /// snapshot. Serialize provider updates; overlapping updates are rejected rather than reordered.
    public func update(certificateChain: [Certificate], privateKey: Certificate.PrivateKey, bundle: SPIFFETrustBundle) async throws {
        let revision = state.withLock { $0.revision }
        let snapshot = try await Self.snapshot(certificateChain: certificateChain, privateKey: privateKey, bundle: bundle)
        guard snapshot.local.id == id else { throw Error.identityChanged }
        try state.withLock {
            guard $0.revision == revision else { throw Error.concurrentUpdate }
            $0.snapshot = snapshot
            $0.revision += 1
            $0.revoked = false
            $0.peers.removeAll(keepingCapacity: true)
        }
    }

    /// Creates a standard timed file/memory loader which publishes only validated SPIFFE material.
    /// Add the returned loader to your service group. Keep using this object's transport factories:
    /// the loader's raw override is not SPIFFE-validated. Trust roots remain the supplied bundle.
    /// Successful-load callbacks run after validation; rejected updates invoke the failure callback
    /// and retain the last valid snapshot. Callbacks may run on an asynchronous executor.
    public func certificateReloader(configuration: TimedCertificateReloader.Configuration, bundle: SPIFFETrustBundle) throws -> TimedCertificateReloader {
        var configuration = configuration
        let loaded = configuration.onCertificateLoaded
        let failed = configuration.onCertificateLoadFailed
        configuration.onCertificateLoaded = { change in
            guard change.previousX509CertificateChain != change.currentX509CertificateChain || change.previousX509PrivateKey?.publicKey != change.currentX509PrivateKey.publicKey else {
                if !self.isReady { failed?(.init(error: Error.notReady)) }
                return
            }
            let (ticket, revision) = self.state.withLock {
                $0.reloadRevision += 1
                return ($0.reloadRevision, $0.revision)
            }
            // The NIO callback is synchronous; SPIFFE path validation is asynchronous.
            // Tickets prevent a slower older validation from overwriting newer material.
            Task { @concurrent in
                do {
                    let snapshot = try await Self.snapshot(certificateChain: change.currentX509CertificateChain, privateKey: change.currentX509PrivateKey, bundle: bundle)
                    guard snapshot.local.id == self.id else { throw Error.identityChanged }
                    try self.state.withLock {
                        guard !$0.revoked, $0.reloadRevision == ticket, $0.revision == revision else { throw Error.concurrentUpdate }
                        $0.snapshot = snapshot
                        $0.revision += 1
                        $0.peers.removeAll(keepingCapacity: true)
                    }
                    loaded?(change)
                } catch {
                    failed?(.init(error: error))
                }
            }
        }
        return try TimedCertificateReloader.makeReloaderValidatingSources(configuration: configuration)
    }

    /// Refuses new handshakes and RPCs immediately. The application must also close transports
    /// to terminate already-running streams. A subsequent validated update restores readiness.
    public func revoke() {
        state.withLock {
            $0.revoked = true
            $0.revision += 1
            $0.peers.removeAll(keepingCapacity: true)
        }
    }

    /// Creates mTLS server security. Pair with `SPIFFEAuthenticationInterceptor` on protected RPCs.
    public func serverTransportSecurity() throws -> HTTP2ServerTransport.Posix.TransportSecurity {
        guard isReady else { throw Error.notReady }
        let roots = state.withLock { $0.snapshot.roots }
        return try .mTLS(certificateReloader: Reloader(security: self)) { tls in
            tls.trustRoots = roots
            tls.requireALPN = true
            tls.customVerificationCallback = verificationCallback(expectedPeer: nil)
        }
    }

    /// Creates mTLS client security for one exact workload. The SPIFFE ID authenticates the
    /// endpoint independently of its DNS address; URI-only SVIDs are supported.
    public func clientTransportSecurity(expectedServer: SPIFFEID) throws -> HTTP2ClientTransport.Posix.TransportSecurity {
        guard isReady else { throw Error.notReady }
        guard expectedServer.trustDomain == id.trustDomain, !expectedServer.path.isEmpty else { throw Error.unexpectedPeer }
        let roots = state.withLock { $0.snapshot.roots }
        return try .mTLS(certificateReloader: Reloader(security: self)) { tls in
            tls.trustRoots = roots
            // Complete chain verification and the exact SPIFFE endpoint match occur below.
            tls.serverCertificateVerification = .noHostnameVerification
            tls.customVerificationCallback = verificationCallback(expectedPeer: expectedServer)
        }
    }

    /// Adapter lifecycle/configuration failures, containing no private material.
    public enum Error: Swift.Error, Equatable, Sendable {
        /// Local credentials are expired, not yet valid, or explicitly revoked.
        case notReady
        /// The supplied key does not match the local leaf certificate.
        case keyMismatch
        /// Renewal attempted to change the local workload identity.
        case identityChanged
        /// Another update or revocation completed during validation.
        case concurrentUpdate
        /// The server identity differs from the configured endpoint.
        case unexpectedPeer
    }

    // A bounded cache stores only results verified against the current trust generation.
    // The actual peer chain must come from a completed TLS handshake. Cache misses are fully
    // verified, so a different custom TLS callback cannot bypass this product's trust policy.
    func peer(_ chain: X509.ValidatedCertificateChain) async throws -> SPIFFEAuthenticator.Verification {
        let (snapshot, revision, cached) = try state.withLock {
            guard !$0.revoked, Self.isCurrent($0.snapshot.local.certificateChain) else { throw Error.notReady }
            return ($0.snapshot, $0.revision, $0.peers[chain])
        }
        if let cached, Self.isCurrent(cached.certificateChain) { return cached }
        let result = try await snapshot.authenticator.verify(certificateChain: Array(chain))
        try remember(result, revision: revision)
        return result
    }

    private func verificationCallback(expectedPeer: SPIFFEID?) -> @Sendable ([NIOSSLCertificate], EventLoopPromise<NIOSSLVerificationResultWithMetadata>) -> Void {
        { certificates, promise in
            // NIOSSL's synchronous callback requires an async bridge. This task performs bounded,
            // local verification only (no I/O or retry loop) and completes its promise exactly once.
            Task { @concurrent in
                do {
                    let (snapshot, revision) = try self.state.withLock {
                        guard !$0.revoked, Self.isCurrent($0.snapshot.local.certificateChain) else { throw Error.notReady }
                        return ($0.snapshot, $0.revision)
                    }
                    guard certificates.count <= 16 else { throw SPIFFEAuthenticator.Error.chainTooLong }
                    let chain = try certificates.map { try Certificate(derEncoded: $0.toDERBytes()) }
                    let result = try await snapshot.authenticator.verify(certificateChain: chain)
                    if let expectedPeer, result.id != expectedPeer { throw Error.unexpectedPeer }
                    try self.remember(result, revision: revision)
                    let validated = try result.certificateChain.map { try NIOSSLCertificate(bytes: $0.derBytes(), format: .der) }
                    promise.succeed(.certificateVerified(VerificationMetadata(NIOSSL.ValidatedCertificateChain(validated))))
                } catch {
                    promise.succeed(.failed)
                }
            }
        }
    }

    private func remember(_ result: SPIFFEAuthenticator.Verification, revision: Int) throws {
        try state.withLock {
            guard $0.revision == revision, !$0.revoked, Self.isCurrent($0.snapshot.local.certificateChain) else { throw Error.notReady }
            if $0.peers.count >= 1024 { $0.peers.removeAll(keepingCapacity: true) }
            $0.peers[result.certificateChain] = result
        }
    }

    private static func isCurrent(_ chain: X509.ValidatedCertificateChain) -> Bool {
        let now = Date.now
        return chain.allSatisfy { $0.notValidBefore <= now && now <= $0.notValidAfter }
    }

    private static func snapshot(certificateChain: [Certificate], privateKey: Certificate.PrivateKey, bundle: SPIFFETrustBundle) async throws -> Snapshot {
        guard certificateChain.first?.publicKey == privateKey.publicKey else { throw Error.keyMismatch }
        let authenticator = SPIFFEAuthenticator(bundle: bundle)
        let local = try await authenticator.verify(certificateChain: certificateChain)
        var override = NIOSSLContextConfigurationOverride()
        override.certificateChain = try certificateChain.map { .certificate(try NIOSSLCertificate(bytes: $0.derBytes(), format: .der)) }
        override.privateKey = .privateKey(try NIOSSLPrivateKey(bytes: Array(privateKey.serializeAsPEM().pemString.utf8), format: .pem))
        let roots = try TLSConfig.TrustRootsSource.certificates(bundle.authorities.map { .bytes(try $0.derBytes(), format: .der) })
        return Snapshot(authenticator: authenticator, local: local, override: override, roots: roots)
    }

    private struct Reloader: CertificateReloader {
        let security: SPIFFETransportSecurity
        var sslContextConfigurationOverride: NIOSSLContextConfigurationOverride {
            security.state.withLock { $0.snapshot.override }
        }
    }
}

extension Certificate {
    fileprivate func derBytes() throws -> [UInt8] {
        var serializer = DER.Serializer()
        try serializer.serialize(self)
        return serializer.serializedBytes
    }
}
