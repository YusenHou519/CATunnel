import Foundation
@testable import TunnelCore

@MainActor
enum Ping0Checks {
    static let checks: [(String, () async throws -> Void)] = [
        ("Ping0 browser links keep the fixed HTTPS host and canonical public IP", publicLinks),
        ("Ping0 browser links keep missing, private and special-use IPs off the query URL", privateAddresses),
        ("Ping0 browser links reject URL, shell and path injection", unsafeInput),
        ("retired Ping0 preference round-trips without changing Net.Coffee consent", legacyPreference),
        ("custom child stdout capture remains bounded with separate stderr", capture)
    ]

    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try condition() == false { throw Failure(description: message) }
    }

    private static func publicLinks() throws {
        for ip in ["1.1.1.1", "8.8.8.8", "2001:4860:4860::8888", "2606:4700:4700::1111"] {
            let url = Ping0Website.url(for: ip)
            try expect(url.scheme == "https" && url.host == "ping0.cc" && url.port == nil,
                       "Browser destination escaped the fixed HTTPS origin")
            try expect(url.path == "/ip/" + ip && url.query == nil && url.fragment == nil
                       && url.user == nil && url.password == nil, "Browser destination gained URL metadata")
        }
        try expect(Ping0Website.publicIP("2606:4700:4700:0:0:0:0:ABCD") == "2606:4700:4700::abcd",
                   "Public IPv6 address was not canonicalized")
        try expect(Ping0Website.url(for: "2606:4700:4700:0:0:0:0:ABCD").absoluteString
                   == "https://ping0.cc/ip/2606%3A4700%3A4700%3A%3Aabcd", "IPv6 path was not safely encoded")
    }

    private static func privateAddresses() throws {
        let addresses: [String?] = [nil, "", "0.0.0.0", "10.0.0.1", "100.64.0.1", "127.0.0.1",
            "169.254.1.1", "172.16.0.1", "172.31.255.255", "192.0.0.1", "192.168.1.1", "192.0.2.1",
            "192.88.99.1", "198.18.1.1", "198.51.100.2", "203.0.113.12", "224.0.0.1", "255.255.255.255",
            "::", "::1", "fc00::1", "fe80::1", "ff02::1", "::ffff:10.0.0.1", "::ffff:1.1.1.1",
            "2001:db8::1", "2001:2::1", "2002:a00:1::1", "3fff::1"]
        for ip in addresses {
            try expect(Ping0Website.publicIP(ip) == nil && Ping0Website.url(for: ip) == Ping0Website.homeURL,
                       "Private, missing or special-use address entered a third-party query URL")
        }
        try expect(Ping0Website.homeURL.absoluteString == "https://ping0.cc/", "Homepage changed")
    }

    private static func unsafeInput() throws {
        for ip in ["https://evil.example/", "1.1.1.1/extra", "1.1.1.1?token=x", "1.1.1.1#fragment",
                   "1.1.1.1@evil.example", "1.1.1.1; touch /tmp/unexpected", "$(id)", "1.1.1.1\n",
                   " 1.1.1.1", "001.1.1.1", "fe80::1%en0", "[2606:4700::1]", String(repeating: "a", count: 100)] {
            try expect(Ping0Website.url(for: ip) == Ping0Website.homeURL, "Untrusted input changed the browser destination")
        }
    }

    private static func legacyPreference() throws {
        let profile = ServerProfile.examples[0]
        let original = try JSONEncoder().encode(profile)
        for legacyValue in [nil, false, true] as [Bool?] {
            var object = try JSONSerialization.jsonObject(with: original) as! [String: Any]
            if let legacyValue { object["assessPing0"] = legacyValue }
            else { object.removeValue(forKey: "assessPing0") }
            let restored = try JSONDecoder().decode(ServerProfile.self,
                from: JSONSerialization.data(withJSONObject: object))
            try expect(restored.assessPing0 == (legacyValue ?? false) && !restored.assessIPRisk,
                       "Retired preference changed existing configuration or Net.Coffee consent")
            let roundTrip = try JSONDecoder().decode(ServerProfile.self, from: JSONEncoder().encode(restored))
            try expect(roundTrip == restored, "Retired preference did not round-trip")
        }
    }

    private static func capture() async throws {
        func run(count: Int, limit: Int) async throws -> CommandResult {
            let command = ChildCommand()
            return try await withCheckedThrowingContinuation { continuation in
                do {
                    try command.start(executable: "/usr/bin/awk", arguments: [
                        "BEGIN { for (i=0;i<\(count);i++) printf \"x\"; for (i=0;i<40000;i++) printf \"e\" > \"/dev/stderr\" }"
                    ], timeout: 5, stdoutLimit: limit) { continuation.resume(returning: $0) }
                } catch { continuation.resume(throwing: error) }
            }
        }
        let expanded = try await run(count: 40_000, limit: 65_536)
        try expect(expanded.exitCode == 0 && !expanded.stdoutTruncated && expanded.stdout.utf8.count == 40_000,
                   "Larger stdout capture truncated a valid page")
        try expect(expanded.stderr.utf8.count == 32_768, "Custom stdout size expanded stderr too")
        let bounded = try await run(count: 70_000, limit: 65_536)
        try expect(bounded.stdoutTruncated && bounded.stdout.utf8.count == 65_536, "Custom capture exceeded its configured bound")
        let capped = try await run(count: 1_100_000, limit: Int.max)
        try expect(capped.stdoutTruncated && capped.stdout.utf8.count == 1_048_576, "Custom capture escaped the absolute 1 MiB limit")
    }
}
