//
//  MetadataBearerTests.swift
//  swift-authentication-grpc
//
//  Created by Zaid Rahhawi on 9/11/26.
//

import AuthenticationGRPC
import GRPCCore
import Testing

@Suite
struct MetadataBearerTests {
    @Test(
        "The token in the authorization entry",
        arguments: [
            ("Bearer abc", "abc"),
            ("bearer abc", "abc"),
            ("BEARER abc", "abc"),
            ("Bearer   abc", "abc"),
            ("Bearer abc def", "abc def"),
            ("Bearer ", nil),
            ("Bearer", nil),
            ("Basic abc", nil),
            ("abc", nil),
        ] as [(String, String?)]
    )
    func reading(authorization: String, expected: String?) {
        var metadata = Metadata()
        metadata.addString(authorization, forKey: "authorization")

        #expect(metadata.bearer == expected)
    }

    @Test("No authorization entry is no token")
    func noEntryIsNoToken() {
        #expect(Metadata().bearer == nil)
    }

    @Test("The first entry is authoritative, even when a later one would parse")
    func firstEntryIsAuthoritative() {
        var metadata = Metadata()
        metadata.addString("Basic abc", forKey: "authorization")
        metadata.addString("Bearer def", forKey: "authorization")

        #expect(metadata.bearer == nil)
    }

    @Test("Setting replaces every existing entry with one")
    func settingReplaces() {
        var metadata = Metadata()
        metadata.addString("Bearer old", forKey: "authorization")
        metadata.addString("Bearer older", forKey: "authorization")

        metadata.bearer = "new"

        #expect(Array(metadata[stringValues: "authorization"]) == ["Bearer new"])
    }

    @Test("Setting nil removes every entry")
    func settingNilRemoves() {
        var metadata = Metadata()
        metadata.addString("Bearer old", forKey: "authorization")

        metadata.bearer = nil

        #expect(Array(metadata[stringValues: "authorization"]).isEmpty)
    }
}
