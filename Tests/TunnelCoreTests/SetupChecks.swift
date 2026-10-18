import Foundation
@testable import TunnelCore

@MainActor
enum SetupChecks {
    static let checks: [(String, () async throws -> Void)] = [
        ("SSH profile migration and explicit risk consent", profileCoding),
        ("identity paths and isolated SSH argument boundaries", identityArguments),
        ("private key readiness uses file metadata", identityMetadata),
        ("strict setup evidence marker parsing", markers),
        ("setup diagnostics separate TCP SSH and dependencies", successfulSetup),
        ("setup validation and key errors prevent SSH", invalidSetup),
        ("setup auth host and timeout errors skip dependencies", sshFailures),
        ("cancelled setup never starts the next command", cancellation)
    ]

    private struct Failure: Error { let message: String }
    private static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }
    private static func rejects(_ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw Failure(message: "Expected validation failure")
    }
    private static var profile: ServerProfile {
        .init(id: "setup-fixture", name: "Fixture", host: "192.0.2.10", user: "fixture",
              sshPort: 2222, remotePort: 17892, localPort: 7890, autoReconnect: false)
    }
    private static let validEvidence = "CATUNNEL_SETUP_V1 ssh ready\nCATUNNEL_SETUP_V1 remoteSS yes\nCATUNNEL_SETUP_V1 remoteCurl yes\n"

    static func profileCoding() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var object = try JSONSerialization.jsonObject(with: encoder.encode(profile)) as! [String: Any]
        object.removeValue(forKey: "identityFile"); object.removeValue(forKey: "assessIPRisk")
        let legacy = try decoder.decode(ServerProfile.self, from: JSONSerialization.data(withJSONObject: object))
        try require(legacy.identityFile == nil && !legacy.assessIPRisk, "Legacy profile opted into a new external service")
        var selected = profile
        selected.identityFile = "~/.ssh/fixture key"
        selected.assessIPRisk = true
        let decoded = try decoder.decode(ServerProfile.self, from: encoder.encode(selected))
        try require(decoded == selected, "SSH options did not round trip")
        try selected.validate()
        object["assessIPRisk"] = "true"
        try rejects { _ = try decoder.decode(ServerProfile.self, from: JSONSerialization.data(withJSONObject: object)) }
        try require(!ServerProfile.draft().assessIPRisk, "New server default silently enabled IP assessment")
    }

    static func identityArguments() throws {
        var value = profile
        value.identityFile = "~/keys/test ' $(touch should-not-exist) key"
        try value.validate()
        let args = SSHCommands.master(value, socket: "/tmp/catunnel-fixture.sock")
        guard let index = args.firstIndex(of: "-i") else { throw Failure(message: "Explicit key was ignored") }
        try require(args[index + 1] == value.expandedIdentityFile && args.contains("IdentitiesOnly=yes"),
                    "Identity path was split or not restricted")
        try require(args[index + 1].contains("$(touch should-not-exist)"), "Key argument was interpreted as shell code")
        try require(!SSHCommands.master(profile, socket: "/tmp/catunnel-fixture.sock").contains("IdentitiesOnly=yes"),
                    "Default agent authentication unexpectedly restricted")
        let setup = SSHCommands.setup(value, command: SetupDiagnostics.dependencyCommand)
        try require(setup.contains("none") && setup.contains("ControlMaster=no") && setup.contains("ClearAllForwardings=yes"),
                    "Setup could reuse a live master or forward ports")
        try require(!setup.contains("-R") && !setup.contains("-M") && setup.contains("StrictHostKeyChecking=yes") &&
                    setup.contains("UpdateHostKeys=no") && setup.contains("CheckHostIP=no") &&
                    setup.prefix(2) == ["-F", "/dev/null"], "Setup weakened SSH isolation")
        let manual = try SetupDiagnostics.terminalVerificationCommand(for: value)
        try require(manual.contains("'\\''") && manual.contains("StrictHostKeyChecking=ask") &&
                    manual.contains("PasswordAuthentication=no") && manual.contains("KbdInteractiveAuthentication=no") &&
                    !manual.contains("StrictHostKeyChecking=no"), "Manual command did not preserve quoting or host confirmation")
        for path in ["relative/key", "~someone/.ssh/key", "/tmp/key\n-oProxyCommand=bad", ""] {
            value.identityFile = path
            try rejects { try value.validate() }
        }
        value = profile; value.host = "-oProxyCommand=bad"
        try rejects { _ = try SetupDiagnostics.terminalVerificationCommand(for: value) }
    }

    static func identityMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catunnel-metadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appendingPathComponent("empty-key-fixture")
        try Data().write(to: fixture)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.path)
        var value = profile; value.identityFile = fixture.path
        try require(SetupDiagnostics.identityReadiness(value).state == .passed,
                    "Readiness parsed key content instead of inspecting metadata")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.path)
        try require(SetupDiagnostics.identityReadiness(value).state == .failed, "Overly broad private key permissions accepted")
        value.identityFile = directory.path
        try require(SetupDiagnostics.identityReadiness(value).state == .failed, "Directory accepted as private key")
        value.identityFile = directory.appendingPathComponent("missing").path
        try require(SetupDiagnostics.identityReadiness(value).state == .failed, "Missing private key accepted")
        try require(SetupDiagnostics.identityReadiness(profile).state == .warning,
                    "Default identities claimed verified without authentication")
    }

    static func markers() throws {
        let valid = SetupDiagnostics.parseDependencies("Banner text\n" + validEvidence)
        try require(valid?.ss == true && valid?.curl == true, "Valid evidence rejected")
        let missing = SetupDiagnostics.parseDependencies(validEvidence.replacingOccurrences(of: "remoteCurl yes", with: "remoteCurl no"))
        try require(missing?.curl == false, "Missing dependency not represented")
        for output in ["", validEvidence + "CATUNNEL_SETUP_V1 ssh ready\n",
                       validEvidence.replacingOccurrences(of: "remoteSS yes", with: "remoteSS maybe"),
                       validEvidence.replacingOccurrences(of: "ssh ready", with: "ssh ready extra"),
                       validEvidence.replacingOccurrences(of: "remoteCurl yes", with: "unknown yes")] {
            try require(SetupDiagnostics.parseDependencies(output) == nil, "Malformed or duplicate evidence accepted")
        }
    }

    static func successfulSetup() async throws {
        var commands: [(String, [String])] = []
        let runner = SetupDiagnostics { executable, arguments, _ in
            commands.append((executable, arguments))
            return .init(exitCode: 0, stdout: executable == "/usr/bin/ssh" ? validEvidence : "", stderr: "")
        }
        let result = await runner.run(profile)
        try require(result.map(\.id) == ["localProxy", "identity", "ssh", "remoteSS", "remoteCurl"], "Setup result IDs/order changed")
        try require(result.filter { $0.state == .passed }.count == 4 && result[1].state == .warning, "Unexpected successful setup state")
        try require(commands.count == 2 && commands[0].0 == "/usr/bin/nc" &&
                    commands[0].1 == ["-z", "-G", "2", "127.0.0.1", "7890"], "Local probe wasn't TCP-only on loopback")
        try require(commands[1].1.last == SetupDiagnostics.dependencyCommand &&
                    !SetupDiagnostics.dependencyCommand.contains("https://"), "Setup queried an external service")
        let partial = SetupDiagnostics { executable, _, _ in
            .init(exitCode: executable == "/usr/bin/nc" ? 1 : 0,
                  stdout: validEvidence.replacingOccurrences(of: "yes", with: "no"), stderr: "")
        }
        let issues = await partial.run(profile)
        try require(issues[0].state == .failed && issues[2].state == .passed && issues[3].state == .failed && issues[4].state == .warning,
                    "Independent local, SSH, and dependency checks were conflated")
    }

    static func invalidSetup() async throws {
        var calls = 0
        let runner = SetupDiagnostics { _, _, _ in calls += 1; return .init(exitCode: 0, stdout: validEvidence, stderr: "") }
        var invalid = profile; invalid.host = "example"
        let result = await runner.run(invalid)
        try require(calls == 0 && result.first { $0.id == "ssh" }?.state == .failed, "Invalid profile launched a command")
        invalid = profile; invalid.identityFile = "/tmp/catunnel-absent-key-\(UUID().uuidString)"
        let keyFailure = await runner.run(invalid)
        try require(calls == 1 && keyFailure[1].state == .failed && keyFailure[2].state == .skipped,
                    "Failed explicit identity fell back to another SSH key")
    }

    static func sshFailures() async throws {
        for (error, timeout) in [("Permission denied (publickey).", false), ("Host key verification failed.", false), ("", true)] {
            let runner = SetupDiagnostics { executable, _, _ in
                .init(exitCode: executable == "/usr/bin/ssh" ? 255 : 0, stdout: "", stderr: error,
                      timedOut: executable == "/usr/bin/ssh" && timeout)
            }
            let result = await runner.run(profile)
            try require(result[2].state == .failed && result[3].state == .skipped && result[4].state == .skipped,
                        "Failed SSH implied remote readiness")
        }
        let truncated = SetupDiagnostics { executable, _, _ in
            .init(exitCode: 0, stdout: validEvidence, stderr: "", stdoutTruncated: executable == "/usr/bin/ssh")
        }
        let result = await truncated.run(profile)
        try require(result[2].state == .failed, "Truncated SSH evidence accepted")
        try require(!SSHFailure.classify("sign_and_send_pubkey: signing failed: agent refused operation").retryable,
                    "Agent unlock failure incorrectly scheduled endless reconnects")
    }

    static func cancellation() async throws {
        var calls = 0
        var runner: SetupDiagnostics!
        runner = SetupDiagnostics { _, _, _ in
            calls += 1
            runner.cancel()
            return .init(exitCode: 0, stdout: validEvidence, stderr: "")
        }
        let result = await runner.run(profile)
        try require(calls == 1 && result.allSatisfy { $0.state == .skipped }, "Cancellation started a later SSH command")
        let cancelled = Task { @MainActor in await runner.run(profile) }
        cancelled.cancel()
        let early = await cancelled.value
        try require(calls == 1 && early.allSatisfy { $0.state == .skipped }, "Already-cancelled task executed a command")
    }
}
