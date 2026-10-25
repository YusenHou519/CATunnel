import Foundation
@testable import TunnelCore

@MainActor
enum FixedEntryProfileChecks {
    static let checks: [(String, () async throws -> Void)] = [
        ("fixed entry defaults and old configuration compatibility", legacyDefaults),
        ("fixed entry preferences round trip without changing other options", roundTrip),
        ("fixed entry Python selection round trips without rewriting legacy defaults", pythonRoundTrip),
        ("fixed entry Python selection requires a bounded literal absolute path even before installation", pythonValidation),
        ("fixed entry requires explicit bounded remote absolute paths", pathValidation),
        ("disabled fixed entry preserves inactive paths and original SSH behavior", inactiveCompatibility),
        ("fixed entry and direct modes cannot share one configured entry", duplicateEntry)
    ]

    private struct Failure: Error { let message: String }
    private static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }
    private static func rejects(_ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw Failure(message: "Expected fixed-entry validation failure")
    }
    private static var profile: ServerProfile {
        .init(id: "fixed-entry-fixture", name: "Fixture", host: "192.0.2.25", user: "fixture",
              sshPort: 2222, remotePort: 17892, localPort: 7890, autoReconnect: true)
    }

    static func legacyDefaults() throws {
        let defaults = [ServerProfile.draft()] + ServerProfile.examples
        try require(defaults.allSatisfy { !$0.useFixedEntry && $0.fixedEntryHelperPath == nil && $0.fixedEntryRuntimePath == nil && $0.fixedEntryPythonPath == nil },
                    "New profiles must not silently enable fixed entry or invent remote paths")
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as! [String: Any]
        for name in ["useFixedEntry", "fixedEntryHelperPath", "fixedEntryRuntimePath", "fixedEntryPythonPath"] { old.removeValue(forKey: name) }
        let documents: [Any] = [[old], ["version": 1, "profiles": [old]]]
        for object in documents {
            let configuration = try ServerConfiguration.decode(JSONSerialization.data(withJSONObject: object))
            try require(configuration.profiles == [profile], "Old profile changed when fixed-entry fields were absent")
        }
        old["useFixedEntry"] = "true"
        try rejects { _ = try JSONDecoder().decode(ServerProfile.self, from: JSONSerialization.data(withJSONObject: old)) }
    }

    static func roundTrip() throws {
        for enabled in [false, true] {
            for automatic in [false, true] {
                var value = profile
                value.useFixedEntry = enabled
                value.fixedEntryHelperPath = "/opt/fixture relay/relay.py"
                value.fixedEntryRuntimePath = "/run/user/1000/fixture entry"
                value.autoReconnect = automatic
                value.autoConnectOnLaunch = true
                value.keepRetryingForwardingFailure = true
                value.assessIPRisk = true
                value.assessPing0 = true
                let configuration = ServerConfiguration(profiles: [value])
                let decoded = try ServerConfiguration.decode(configuration.encoded())
                try require(decoded.profiles == [value], "Fixed-entry choice changed another saved preference")
                try require(decoded.profiles[0].remotePort == 17892, "Remote port no longer represents the fixed entry")
            }
        }
    }

    static func pathValidation() throws {
        var value = profile
        value.useFixedEntry = true
        value.fixedEntryHelperPath = "/opt/catunnel/relay.py"
        value.fixedEntryRuntimePath = "/run/user/1000/catunnel"
        try value.validate()
        let invalid: [String?] = [nil, "", "relative/relay.py", "~/relay.py", " /tmp/relay.py",
                                  "/tmp/relay\n.py", "/tmp/relay\t.py", "/tmp/relay\u{0}",
                                  "/tmp/relay\u{7F}", "/" + String(repeating: "x", count: 4096)]
        for path in invalid {
            var helper = value
            helper.fixedEntryHelperPath = path
            try rejects { try helper.validate() }
            var runtime = value
            runtime.fixedEntryRuntimePath = path
            try rejects { try runtime.validateForConnection() }
        }
        value.fixedEntryHelperPath = "/" + String(repeating: "x", count: 4095)
        try value.validate()
        value.fixedEntryHelperPath = "/opt/fixture 'quoted' $literal/relay.py"
        try value.validate()
        let decoded = try ServerConfiguration.decode(ServerConfiguration(profiles: [value]).encoded())
        try require(decoded.profiles[0] == value, "Literal path characters changed during serialization")
    }

    static func pythonRoundTrip() throws {
        let paths: [String?] = [nil, "", "/opt/fixture env/bin/python3", "/opt/fixture 'quoted' $literal/python"]
        for path in paths {
            var value = profile
            value.fixedEntryPythonPath = path
            let data = try ServerConfiguration(profiles: [value]).encoded()
            let decoded = try ServerConfiguration.decode(data)
            try require(decoded.profiles == [value], "Python selection changed during serialization")
            let executable = try decoded.profiles[0].resolvedFixedEntryPython()
            try require(executable == (path?.isEmpty == false ? path! : "python3"),
                        "Empty or absent Python selection did not preserve the legacy command")
        }
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as! [String: Any]
        try require(encoded["fixedEntryPythonPath"] == nil, "Legacy profile gained an explicit Python setting")
        for invalid in [true as Any, 123 as Any, ["/usr/bin/python3"] as Any] {
            var object = encoded
            object["fixedEntryPythonPath"] = invalid
            try rejects { _ = try JSONDecoder().decode(ServerProfile.self, from: JSONSerialization.data(withJSONObject: object)) }
        }
    }

    static func pythonValidation() throws {
        var value = profile
        for path in ["python3", "~/bin/python3", " /opt/python3", "/", " ",
                     "/opt/python\n3", "/opt/python\t3", "/opt/python\u{0}", "/opt/python\u{7F}",
                     "/" + String(repeating: "x", count: 4096), "/" + String(repeating: "字", count: 1366)] {
            value.fixedEntryPythonPath = path
            try rejects { try value.validateForConnection() }
        }
        for path in ["", "/" + String(repeating: "x", count: 4095), "/opt/a'b;$(not-run)/python3"] {
            value.fixedEntryPythonPath = path
            try value.validateForConnection()
        }
        let original = SSHCommands.master(profile, socket: "/tmp/fixed-python-fixture.sock")
        try require(SSHCommands.master(value, socket: "/tmp/fixed-python-fixture.sock") == original,
                    "Choosing Python changed an inactive fixed-entry connection")
    }

    static func inactiveCompatibility() throws {
        let existingArguments = SSHCommands.master(profile, socket: "/tmp/fixed-entry-fixture.sock")
        var disabled = profile
        disabled.fixedEntryHelperPath = "old relative value"
        disabled.fixedEntryRuntimePath = "~/old runtime"
        try disabled.validateForConnection()
        let decoded = try ServerConfiguration.decode(ServerConfiguration(profiles: [disabled]).encoded())
        try require(decoded.profiles == [disabled], "Disabled mode discarded stored paths")
        try require(SSHCommands.master(disabled, socket: "/tmp/fixed-entry-fixture.sock") == existingArguments,
                    "Inactive fixed-entry options changed the existing SSH connection")
        disabled.useFixedEntry = true
        try rejects { try disabled.validate() }
    }

    static func duplicateEntry() throws {
        var fixed = profile
        fixed.id = "other-fixture"
        fixed.useFixedEntry = true
        fixed.fixedEntryHelperPath = "/opt/catunnel/relay.py"
        fixed.fixedEntryRuntimePath = "/run/user/1000/catunnel"
        try rejects { try ServerConfiguration(profiles: [profile, fixed]).validate() }
        fixed.remotePort += 1
        try ServerConfiguration(profiles: [profile, fixed]).validate()
    }
}
