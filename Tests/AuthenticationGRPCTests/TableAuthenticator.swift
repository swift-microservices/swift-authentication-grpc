// Copyright (c) 2026 Zaid Rahhawi
// SPDX-License-Identifier: MIT
// See LICENSE for license information.

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
