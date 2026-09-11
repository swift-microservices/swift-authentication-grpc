//
//  TableAuthenticator.swift
//  swift-authentication-grpc
//
//  Created by Zaid Rahhawi on 9/11/26.
//

import Authentication

/// An authenticator over a table: a known credential proves its identity, an unknown one is
/// declined, and a credential in the refused set throws.
struct TableAuthenticator<Credential: Hashable & Sendable, Identity: Sendable>: Authenticator {
    struct Refused: Error {}

    let identities: [Credential: Identity]
    var refused: Set<Credential> = []

    func authenticate(_ credential: Credential) throws -> Identity? {
        if refused.contains(credential) {
            throw Refused()
        }
        return identities[credential]
    }
}
