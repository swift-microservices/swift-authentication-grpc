//
//  SPIFFEAuthenticator+TLS.swift
//  swift-authentication-grpc
//
//  Created by Zaid Rahhawi on 9/29/26.
//

public import AuthenticationSPIFFE
public import NIOCore
public import NIOSSL
import SwiftASN1
import X509

extension SPIFFEAuthenticator {
    /// Verifies TLS peers against this authenticator's fixed SPIFFE trust bundle.
    /// Pass the exact server ID on clients; servers authorize verified callers per RPC.
    /// Use with mTLS and explicit trust roots. URI identities replace DNS hostname matching.
    /// Credential loading, renewal, and connection lifetimes belong to the application.
    public func certificateVerificationCallback(expectedPeer: SPIFFEID? = nil) -> @Sendable ([NIOSSLCertificate], EventLoopPromise<NIOSSLVerificationResultWithMetadata>) -> Void {
        { certificates, promise in
            // NIOSSL requires a synchronous callback; bounded local verification is async.
            // This bridge performs no network I/O or retries and completes the promise once.
            Task { @concurrent in
                do {
                    guard certificates.count <= 16 else { throw Error.chainTooLong }
                    let chain = try certificates.map { try Certificate(derEncoded: $0.toDERBytes()) }
                    let verified = try await self.verify(certificateChain: chain)
                    if let expectedPeer, verified.id != expectedPeer {
                        promise.succeed(.failed)
                        return
                    }
                    let validated = try verified.certificateChain.map { certificate in
                        var serializer = DER.Serializer()
                        try certificate.serialize(into: &serializer)
                        return try NIOSSLCertificate(bytes: serializer.serializedBytes, format: .der)
                    }
                    promise.succeed(.certificateVerified(VerificationMetadata(NIOSSL.ValidatedCertificateChain(validated))))
                } catch {
                    promise.succeed(.failed)
                }
            }
        }
    }
}
