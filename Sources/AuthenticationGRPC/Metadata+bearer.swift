//
//  Metadata+bearer.swift
//  swift-authentication-grpc
//
//  Created by Zaid Rahhawi on 9/11/26.
//

import GRPCCore

extension Metadata {
    /// The credential from the first `authorization` entry, or `nil` when there is none, or when
    /// it is not a bearer credential.
    ///
    /// The first entry is authoritative rather than the first one that happens to parse: taking
    /// the latter would let a caller hide a second credential behind one the service ignores.
    ///
    /// The scheme is matched without regard to case, as RFC 7235 defines it. Requiring the exact
    /// spelling `Bearer` would read a `bearer` header, which grpc-web clients and proxies do
    /// send, as no credential at all, and an unauthenticated caller is far harder to notice than
    /// a rejected one.
    ///
    /// Setting it replaces rather than adds: a second `authorization` entry would leave which one
    /// the receiver reads down to ordering, and the server side takes the first.
    public var bearer: String? {
        get {
            guard let authorization = self[stringValues: "authorization"].first() else {
                return nil
            }

            let parts = authorization.split(separator: " ", maxSplits: 1)

            guard parts.count == 2, parts[0].lowercased() == "bearer" else {
                return nil
            }

            let token = parts[1].drop(while: \.isWhitespace)

            return token.isEmpty ? nil : String(token)
        }
        set {
            if let newValue {
                replaceOrAddString("Bearer \(newValue)", forKey: "authorization")
            } else {
                removeAllValues(forKey: "authorization")
            }
        }
    }
}

extension Sequence {
    /// `first`, which this sequence does not otherwise offer.
    fileprivate func first() -> Element? {
        for element in self {
            return element
        }

        return nil
    }
}
