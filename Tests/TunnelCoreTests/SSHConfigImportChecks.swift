import Foundation
import Darwin
@testable import TunnelCore

enum SSHConfigImportChecks {
    static let checks: [(String, () async throws -> Void)] = [
        ("SSH import resolves concrete aliases and first-value defaults", firstValues),
        ("SSH import applies bounded wildcard and negated Host patterns", hostPatterns),
        ("SSH import preserves OpenSSH quoting, escapes and inline hashes", quoting),
        ("SSH import skips unsupported connection and identity settings", unsupportedAliases),
        ("SSH import fails loudly for Include and Match without evaluation", unsupportedSources),
        ("SSH import distinguishes missing, unavailable and empty files", fileStates),
        ("SSH import rejects malformed and oversized fixture input", boundedInput),
        ("SSH import wildcard matching avoids regular-expression backtracking", longPatterns)
    ]

    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(description: message) }
    }
    private static func parse(_ text: String) -> SSHConfigImportResult {
        SSHConfigImport.parse(text, defaultUser: "fixture")
    }

    private static func firstValues() throws {
        let result = parse("""
        Host alpha beta
            HostName 192.0.2.10
            User remote
            Port 2222
        Host ALPHA
            HostName 192.0.2.99
            Port 3333
        Host no-hostname
        Host *
            User fallback
            Port 22
            IdentityFile ~/.ssh/fixture_key
        """)
        try expect(result.availability == .available && result.skippedAliases.isEmpty,
                   "Ordinary Host aliases were rejected")
        try expect(result.entries.map(\.alias) == ["alpha", "beta", "no-hostname"],
                   "Concrete aliases were duplicated, reordered, or inferred from wildcards")
        for entry in result.entries.prefix(2) {
            try expect(entry.host == "192.0.2.10" && entry.user == "remote" && entry.sshPort == 2222,
                       "Later declarations overrode an earlier Host value")
        }
        try expect(result.entries[2].host == "no-hostname" && result.entries[2].user == "fallback" &&
                   result.entries[2].sshPort == 22 && result.entries[2].identityFile == "~/.ssh/fixture_key",
                   "Alias fallback or Host * defaults were lost")
        let earlierDefaults = parse("User earliest\nPort 2200\nHost one\n User later\n Port 2300")
        try expect(earlierDefaults.entries.first?.user == "earliest" && earlierDefaults.entries.first?.sshPort == 2200,
                   "Global defaults must also follow first-value-wins")
        let omitted = parse("Host defaults-only")
        try expect(omitted.entries.first?.user == "fixture" && omitted.entries.first?.sshPort == 22 &&
                   omitted.entries.first?.host == "defaults-only", "OpenSSH implicit defaults were not filled")
    }

    private static func hostPatterns() throws {
        let result = parse("""
        Host prod-1 prod-2 dev-1
        Host prod-? !prod-2
            User production
        Host PROD-*
            Port 2222
        Host *
            User fallback
        """)
        try expect(result.entries.count == 3 && result.entries[0].user == "production" &&
                   result.entries[1].user == "fallback" && result.entries[2].user == "fallback",
                   "Wildcard case folding or negated Host matching changed")
        try expect(result.entries.map(\.sshPort) == [2222, 2222, 22], "Question/star matching escaped its Host scope")
    }

    private static func quoting() throws {
        let result = parse(#"""
        # leading comment
        Host quoted hash escaped single malformed-host
        Host quoted
            HostName = "192.0.2.20" # trailing comment
            IdentityFile "/tmp/key # literal"
        Host hash
            IdentityFile /tmp/key#part # real comment
        Host escaped
            IdentityFile /tmp/key\ file
        Host single
            HostName '192.0.2.21'
            IdentityFile '/tmp/single quoted'
        Host malformed-host
            HostName 192.0.2.22#not-a-comment
        """#)
        try expect(result.entries.map(\.alias) == ["quoted", "hash", "escaped", "single"] &&
                   result.skippedAliases == ["malformed-host"], "Inline hash was incorrectly treated as a comment")
        try expect(result.entries.map(\.identityFile) == ["/tmp/key # literal", "/tmp/key#part", "/tmp/key file", "/tmp/single quoted"],
                   "Quoted or escaped identity paths were changed")
        try expect(result.entries[3].host == "192.0.2.21", "Single quotes did not follow OpenSSH argument parsing")
        let literalEscape = parse(#"Host literal"# + "\n" + #" IdentityFile /tmp/key\z"#)
        try expect(literalEscape.entries.first?.identityFile == #"/tmp/key\z"#,
                   "An unrecognized escape was silently removed")
    }

    private static func unsupportedAliases() throws {
        let result = parse("""
        Host good
            HostName 192.0.2.30
            ProxyJump none
        Host forwarded
            ProxyJump bastion
        Host commanded
            ProxyCommand arbitrary-command
        Host token
            HostName %h.internal
        Host envuser
            User ${REMOTE_USER}
        Host manykeys
            IdentityFile ~/.ssh/first
            IdentityFile ~/.ssh/second
        Host agent
            IdentityAgent /tmp/agent.sock
        Host cert
            CertificateFile /tmp/cert.pub
        Host trustedalias
            HostKeyAlias different-trust-name
        Host command-trust
            KnownHostsCommand arbitrary-command
        Host canonical
            CanonicalizeHostname yes
        Host emptyidentity
            IdentityFile ""
        Host invalid-port
            Port 70000
        """)
        try expect(result.availability == .available && result.entries.map(\.alias) == ["good"] &&
                   result.skippedAliases.count == 12, "Unsupported aliases were imported as ordinary direct connections")
        try expect(result.message?.contains("arbitrary-command") == false,
                   "Import status echoed raw configuration text")
        let duplicateKey = parse("Host duplicate\n IdentityFile ~/.ssh/one\n IdentityFile ~/.ssh/one")
        try expect(duplicateKey.entries.first?.identityFile == "~/.ssh/one", "Identical identity declarations were not deduplicated")
    }

    private static func unsupportedSources() throws {
        for source in ["Host fixture\n Include conf.d/*", "Include missing\nHost fixture",
                       "Host fixture\nMatch exec arbitrary-command\n User conditional", "Match all\nHost fixture"] {
            let result = parse(source)
            try expect(result.availability == .unavailable && result.entries.isEmpty && result.message != nil,
                       "A conditional or included source was partially imported")
            try expect(result.message?.contains("arbitrary-command") == false,
                       "Unsupported source status exposed a Match command")
        }
    }

    private static func fileStates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catunnel-ssh-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("config")
        try expect(SSHConfigImport.load(from: source, defaultUser: "fixture").availability == .missing,
                   "Missing file was confused with an empty, successfully parsed source")
        try Data().write(to: source)
        let empty = SSHConfigImport.load(from: source, defaultUser: "fixture")
        try expect(empty.availability == .available && empty.entries.isEmpty, "Empty configuration was unavailable")
        try Data("Host disk-fixture\n HostName 192.0.2.40".utf8).write(to: source)
        try expect(SSHConfigImport.load(from: source, defaultUser: "fixture").entries.first?.host == "192.0.2.40",
                   "Explicit fixture URL was not read")
        try Data([0xff, 0xfe]).write(to: source)
        try expect(SSHConfigImport.load(from: source, defaultUser: "fixture").availability == .unavailable,
                   "Invalid UTF-8 was accepted")
        try expect(SSHConfigImport.load(from: directory, defaultUser: "fixture").availability == .unavailable,
                   "Directory was accepted as a regular configuration file")
        let fifo = directory.appendingPathComponent("fifo")
        try expect(fifo.path.withCString { mkfifo($0, 0o600) } == 0, "Could not create isolated nonregular-file fixture")
        try expect(SSHConfigImport.load(from: fifo, defaultUser: "fixture").availability == .unavailable,
                   "Nonregular configuration input was not rejected")
        try expect(SSHConfigImport.load(from: URL(string: "https://example.invalid/config")!, defaultUser: "fixture").availability == .unavailable,
                   "Non-file URLs were accepted")
    }

    private static func boundedInput() throws {
        for malformed in ["Host", "Host alpha\n HostName \"unclosed", "Host alpha\n User bad user",
                          "Host alpha\n HostName 192.0.2.10\u{0000}", "Host alpha\u{0085}HostName 192.0.2.10"] {
            let result = parse(malformed)
            try expect(result.availability == .unavailable || result.entries.isEmpty,
                       "Malformed configuration became a usable imported profile")
        }
        for oversized in [String(repeating: "#", count: SSHConfigImport.maximumBytes + 1),
                          String(repeating: "\n", count: SSHConfigImport.maximumLines),
                          "#" + String(repeating: "a", count: SSHConfigImport.maximumLineBytes)] {
            try expect(parse(oversized).availability == .unavailable, "An input size limit was ignored")
        }
        let tooMany = (0...SSHConfigImport.maximumAliases).map { "Host alias\($0)" }.joined(separator: "\n")
        try expect(parse(tooMany).availability == .unavailable, "Alias count was unbounded")
        let crlf = parse("Host crlf\r\n HostName 192.0.2.41\r\n")
        try expect(crlf.entries.first?.host == "192.0.2.41", "CRLF configuration was rejected")
    }

    private static func longPatterns() throws {
        let alias = String(repeating: "a", count: 78)
        let pattern = String(repeating: "*a", count: 70) + "b"
        let result = parse("Host \(alias)\n HostName 192.0.2.42\nHost \(pattern)\n User wrong\nHost *\n User fixture")
        try expect(result.entries.count == 1 && result.entries[0].user == "fixture",
                   "A long repeated-wildcard pattern matched incorrectly")
    }
}
