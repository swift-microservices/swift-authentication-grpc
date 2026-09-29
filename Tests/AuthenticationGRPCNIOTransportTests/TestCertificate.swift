//
//  TestCertificate.swift
//  swift-authentication-grpc
//
//  Created by Zaid Rahhawi on 9/28/26.
//

import Crypto
import SwiftASN1
import X509

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

struct TestCertificate {
    let key: Certificate.PrivateKey
    let certificate: Certificate

    init(
        issuer: TestCertificate? = nil,
        uris: [String] = [],
        ca: Bool = true,
        dnsNames: [String] = ["server.example"],
        usage: KeyUsage? = nil,
        includeUsage: Bool = true,
        criticalUsage: Bool = true,
        eku: ExtendedKeyUsage? = nil,
        basicConstraints: Bool = true,
        unknownCritical: Bool = false,
        emptySubject: Bool = false,
        criticalSAN: Bool = false,
        notBefore: Date = Date(timeIntervalSince1970: 1_577_836_800),
        notAfter: Date = Date(timeIntervalSince1970: 4_102_444_800)
    ) throws {
        key = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let name = try DistinguishedName { CommonName(ca ? "CA" : "workload") }
        certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: key.publicKey,
            notValidBefore: notBefore,
            notValidAfter: notAfter,
            issuer: issuer?.certificate.subject ?? name,
            subject: emptySubject ? DistinguishedName() : name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                if basicConstraints {
                    Critical(ca ? BasicConstraints.isCertificateAuthority(maxPathLength: nil) : .notCertificateAuthority)
                }
                if includeUsage {
                    try Certificate.Extension(usage ?? KeyUsage(digitalSignature: !ca, keyCertSign: ca, cRLSign: ca), critical: criticalUsage)
                }
                if let eku { eku }
                if !uris.isEmpty || !dnsNames.isEmpty {
                    try Certificate.Extension(SubjectAlternativeNames(uris.map { .uniformResourceIdentifier($0) } + dnsNames.map { .dnsName($0) }), critical: criticalSAN)
                }
                if unknownCritical {
                    Certificate.Extension(oid: [1, 2, 3, 4], critical: true, value: [5, 0])
                }
            },
            issuerPrivateKey: issuer?.key ?? key
        )
    }
}
