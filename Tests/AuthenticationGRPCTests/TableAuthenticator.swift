//
//  TableAuthenticator.swift
//  swift-authentication-grpc
//
//  Created by Zaid Rahhawi on 9/11/26.
//

import Authentication

/// An authenticator over a table: known credentials prove their identities; unknown or
/// refused credentials throw.
struct TableAuthenticator<Credential: Hashable & Sendable, Identity: Sendable>: Authenticator {
    struct Refused: Error {}

    let identities: [Credential: Identity]
    var refused: Set<Credential> = []

    func authenticate(_ credential: Credential) throws -> Identity {
        if refused.contains(credential) {
            throw Refused()
        }
        guard let identity = identities[credential] else {
            throw Refused()
        }
        return identity
    }
}
