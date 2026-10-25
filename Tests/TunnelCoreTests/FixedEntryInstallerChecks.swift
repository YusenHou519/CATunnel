import Foundation
import CryptoKit
@testable import TunnelCore

@MainActor
enum FixedEntryInstallerChecks {
    static let checks: [(String, () async throws -> Void)] = [
        ("fixed entry installer rejects invalid bundled scripts before SSH", resources),
        ("fixed entry installer uses isolated strict SSH and private bounded upload", successfulInstall),
        ("fixed entry installer and independent verification use the same selected Python safely", selectedPython),
        ("fixed entry Python launch failures distinguish missing nonexecutable and unsupported interpreters", pythonFailures),
        ("fixed entry indeterminate install failures preserve uncertainty", uncertainFailures),
        ("fixed entry installer preserves explicit key and fixture trust boundaries", identities),
        ("fixed entry installer rejects invalid profile and missing identity before SSH", validation),
        ("fixed entry installer requires exact installation identity and framed result", invalidResponses),
        ("fixed entry installer requires detached helper readiness without takeover", readiness),
        ("fixed entry installer translates safe failures without leaking remote output", failures),
        ("fixed entry installer cancellation blocks late success and concurrent installs", cancellation),
        ("fixed entry installer task cancellation suppresses late verification success", taskCancellation),
        ("fixed entry installer pre-cancelled task never starts SSH", earlyCancellation),
        ("child explicit upload limit preserves small-control default and global cap", uploadLimits),
        ("child large upload closes EOF and survives blocked write cancellation", uploadCleanup)
    ]

    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(description: message) }
    }
    private static func rejects(_ message: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw Failure(description: message)
    }
    private static func failure(_ operation: () async throws -> FixedEntryInstallation) async throws -> String {
        do { _ = try await operation() } catch { return error.localizedDescription }
        throw Failure(description: "Expected installation failure")
    }
    private static let helper = Data("# Public fixture helper\nprint('fixture')\n".utf8)
    private static let installerScript = Data("# Public installer fixture\nprint('$(not shell code)')\n".utf8)
    private static var digest: String { SHA256.hash(data: helper).map { String(format: "%02x", $0) }.joined() }
    private static var profile: ServerProfile {
        .init(id: "install-fixture", name: "Fixture", host: "192.0.2.10", user: "fixture",
              sshPort: 2222, remotePort: 17892, localPort: 7890, autoReconnect: false,
              useFixedEntry: true)
    }
    private static var installationObject: [String: Any] {
        ["version": 1, "ok": true, "port": 17892, "helper_path": "/fixture/relay.py",
         "runtime_path": "/fixture/runtime", "sha256": digest, "pid": 4321, "reused": false]
    }
    private static var statusObject: [String: Any] {
        ["ok": true, "epoch": "fixture_epoch", "generation": 0, "port": 17892,
         "active_generation": NSNull(), "backend_port": NSNull()]
    }
    private static func response(_ object: [String: Any], code: Int32 = 0) throws -> CommandResult {
        .init(exitCode: code, stdout: String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n", stderr: "")
    }
    private static func makeInstaller(_ executor: @escaping FixedEntryInstaller.Executor) throws -> FixedEntryInstaller {
        try .init(helperScript: helper, installerScript: installerScript, executor: executor)
    }

    private static func resources() throws {
        for invalid in [Data(), Data([0xff]), Data([0]), Data(" \n\t".utf8), Data(repeating: 65, count: 262_145)] {
            try rejects("Invalid helper script accepted") { _ = try FixedEntryInstaller(helperScript: invalid, installerScript: installerScript) }
        }
        for invalid in [Data(), Data([0xff]), Data([0]), Data(" \n".utf8), Data(repeating: 65, count: 65_537)] {
            try rejects("Invalid installer script accepted") { _ = try FixedEntryInstaller(helperScript: helper, installerScript: invalid) }
        }
        _ = try FixedEntryInstaller(helperScript: helper, installerScript: installerScript)
    }

    private static func successfulInstall() async throws {
        var commands: [(String, [String], TimeInterval, Data, Int)] = []
        var installation = installationObject
        installation["helper_path"] = "/fixture/a'b;$(not-run).py"
        installation["reused"] = true
        let installed = try response(installation), status = try response(statusObject)
        let installer = try makeInstaller { executable, args, timeout, input, limit in
            commands.append((executable, args, timeout, input, limit))
            return commands.count == 1 ? installed : status
        }
        let before = profile
        let result = try await installer.install(before)
        try expect(before == profile, "Installation changed caller profile")
        try expect(result == .init(helperPath: "/fixture/a'b;$(not-run).py", runtimePath: "/fixture/runtime", port: 17892, reused: true),
                   "Installation did not preserve checked returned values")
        try expect(commands.count == 2, "Installation did not independently verify detached readiness")
        for (_, args, _, _, _) in commands {
            try expect(args.prefix(2) == ["-F", "/dev/null"] && args.contains("none") &&
                       args.contains("StrictHostKeyChecking=yes") && args.contains("UpdateHostKeys=no") &&
                       args.contains("CheckHostIP=no") && args.contains("ControlMaster=no") && args.contains("ClearAllForwardings=yes") &&
                       args.contains("BatchMode=yes") && !args.contains("-R") && !args.contains("-M"),
                       "Installer weakened host trust or reused/created a forwarding master")
            try expect(!args.contains("-i") && !args.contains("IdentitiesOnly=yes") && !args.contains("IdentityAgent=none"),
                       "Default SSH identity/agent behavior changed")
        }
        try expect(commands[0].0 == "/usr/bin/ssh" && commands[0].3 == helper && commands[0].4 == 262_144 && commands[0].2 == 45,
                   "Upload did not use bounded private stdin")
        let uploadArgs = commands[0].1.joined(separator: " ")
        try expect(!uploadArgs.contains(String(decoding: helper, as: UTF8.self)) && uploadArgs.contains("'--sha256' '\(digest)'"),
                   "Helper bytes appeared in argv or digest was missing")
        try expect(commands[1].1.last == "'python3' '/fixture/a'\\''b;$(not-run).py' 'control' '--runtime-dir' '/fixture/runtime'",
                   "Returned remote path escaped shell quoting")
        try expect(commands[1].4 == 4096 && commands[1].3 == FixedEntryProtocol.input(.status), "Verification sent a lease mutation")
    }

    private static func identities() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cat-install-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = directory.appendingPathComponent("metadata-only-key")
        try Data().write(to: key)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
        var target = profile; target.identityFile = key.path
        let installed = try response(installationObject), status = try response(statusObject)
        var commands: [[String]] = []
        let trust = directory.appendingPathComponent("fixture-known-hosts").path
        let installer = try FixedEntryInstaller(helperScript: helper, installerScript: installerScript,
            executionContext: SSHExecutionContext(knownHostsFile: trust)) { _, args, _, _, _ in
                commands.append(args)
                return commands.count == 1 ? installed : status
            }
        _ = try await installer.install(target)
        for args in commands {
            try expect(args.contains(key.path) && args.contains("IdentitiesOnly=yes") &&
                       args.contains("UserKnownHostsFile=\(trust)") && args.contains("GlobalKnownHostsFile=/dev/null") &&
                       args.contains("StrictHostKeyChecking=yes"), "Explicit identity or private fixture trust was ignored")
        }
    }

    private static func selectedPython() async throws {
        let paths: [String?] = [nil, "", "/opt/fixture env/bin/python3", "/opt/a'b;$(not-run)/python3"]
        for path in paths {
            var target = profile
            target.fixedEntryPythonPath = path
            let before = target
            var commands: [[String]] = []
            let installed = try response(installationObject), status = try response(statusObject)
            let installer = try makeInstaller { _, args, _, _, _ in
                commands.append(args)
                return commands.count == 1 ? installed : status
            }
            _ = try await installer.install(target)
            let executable = path?.isEmpty == false ? path! : "python3"
            let quoted = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
            try expect(commands.count == 2 && commands[0].last?.hasPrefix(quoted + " '-c' ") == true &&
                       commands[1].last == quoted + " '/fixture/relay.py' 'control' '--runtime-dir' '/fixture/runtime'",
                       "Installation or verification fell back to default Python or allowed shell expansion")
            try expect(target == before, "Installation rewrote the caller's Python selection")
        }
    }

    private static func pythonFailures() async throws {
        let errors: [(Int32, String)] = [(127, "找不到"), (126, "无法执行")]
        for (code, expected) in errors {
            for duringVerification in [false, true] {
                var target = profile
                target.fixedEntryPythonPath = "/fixture/custom python"
                var calls = 0
                let installed = try response(installationObject)
                let result = CommandResult(exitCode: code, stdout: "", stderr: "private-remote-detail")
                let installer = try makeInstaller { _, _, _, _, _ in
                    calls += 1
                    return duringVerification && calls == 1 ? installed : result
                }
                let message = try await failure { try await installer.install(target) }
                try expect(message.contains(expected) && !message.contains("private-remote-detail") &&
                           !message.contains("可能") && message.contains(duringVerification ? "安装已执行" : "尚未运行"),
                           "Python launch failure lost its exact stage or exposed remote output")
                try expect(calls == (duringVerification ? 2 : 1), "Python failure triggered a fallback or extra attempt")
            }
        }
        let oldPython = try response(["version": 1, "ok": false, "error": "python_unsupported"], code: 1)
        let installer = try makeInstaller { _, _, _, _, _ in oldPython }
        let message = try await failure { try await installer.install(profile) }
        try expect(message.contains("3.9") && message.contains("已有") && message.contains("不会升级") &&
                   !message.contains("可能") && !message.contains("安装未开始"),
                   "Unsupported Python received generic completion uncertainty or an unproven no-write claim")
    }

    private static func uncertainFailures() async throws {
        for result in [CommandResult(exitCode: 15, stdout: "", stderr: "", timedOut: true),
                       .init(exitCode: 255, stdout: "", stderr: "Connection reset by peer"),
                       .init(exitCode: 0, stdout: "broken response", stderr: "private-remote-detail")] {
            let installer = try makeInstaller { _, _, _, _, _ in result }
            let message = try await failure { try await installer.install(profile) }
            try expect((message.contains("可能") || message.contains("未确认")) && !message.contains("private-remote-detail"),
                       "Indeterminate installation was incorrectly described as definitely unapplied")
        }
    }

    private static func validation() async throws {
        var calls = 0
        let installer = try makeInstaller { _, _, _, _, _ in calls += 1; return .init(exitCode: 0, stdout: "", stderr: "") }
        var invalid = profile; invalid.host = "server.example"
        _ = try await failure { try await installer.install(invalid) }
        invalid = profile; invalid.remotePort = 0
        _ = try await failure { try await installer.install(invalid) }
        invalid = profile; invalid.identityFile = "/tmp/catunnel-missing-install-key-\(UUID().uuidString)"
        _ = try await failure { try await installer.install(invalid) }
        for path in ["python3 --version", "~/bin/python3", "/opt/python\n3", "/" + String(repeating: "x", count: 4096)] {
            invalid = profile
            invalid.fixedEntryPythonPath = path
            _ = try await failure { try await installer.install(invalid) }
        }
        try expect(calls == 0, "Invalid profile or private key started SSH")
    }

    private static func invalidResponses() async throws {
        let malformed: [(String, Any)] = [("version", 2), ("version", true), ("port", 17893), ("port", true),
            ("helper_path", "relative.py"), ("helper_path", "/fixture/x\n.py"), ("helper_path", "/"),
            ("runtime_path", "/fixture/runtime\u{0}"), ("runtime_path", "/" + String(repeating: "x", count: 4096)),
            ("sha256", String(repeating: "0", count: 64)), ("pid", 0), ("pid", Int64(Int32.max) + 1),
            ("pid", true), ("reused", 1), ("error", "unexpected")]
        var results = try malformed.map { field, value in
            var object = installationObject; object[field] = value
            return try response(object)
        }
        var samePaths = installationObject; samePaths["runtime_path"] = samePaths["helper_path"]
        results.append(try response(samePaths))
        let valid = try response(installationObject)
        var duplicate = valid; duplicate.stdout += valid.stdout; results.append(duplicate)
        var incomplete = valid; incomplete.stdout.removeLast(); results.append(incomplete)
        var truncated = valid; truncated.stdoutTruncated = true; results.append(truncated)
        var tooLarge = valid; tooLarge.stdout = String(repeating: " ", count: 16_384) + valid.stdout; results.append(tooLarge)
        var failedExit = valid; failedExit.exitCode = 1; results.append(failedExit)
        for result in results {
            var calls = 0
            let installer = try makeInstaller { _, _, _, _, _ in calls += 1; return result }
            _ = try await failure { try await installer.install(profile) }
            try expect(calls == 1, "Malformed installation output advanced to verification")
        }
    }

    private static func readiness() async throws {
        let installed = try response(installationObject)
        var wrongPort = statusObject; wrongPort["port"] = 17893
        var active = statusObject; active["generation"] = 3; active["active_generation"] = 3; active["backend_port"] = 24567
        let statuses = [try response(wrongPort), try response(active),
                        try response(["ok": false, "error": "helper_unavailable"], code: 1),
                        CommandResult(exitCode: 255, stdout: "", stderr: "Connection reset by peer")]
        for status in statuses {
            var requests: [Data] = []
            let installer = try makeInstaller { _, _, _, input, _ in
                requests.append(input); return requests.count == 1 ? installed : status
            }
            _ = try await failure { try await installer.install(profile) }
            try expect(requests.count == 2 && requests[1] == FixedEntryProtocol.input(.status),
                       "Readiness failure mutated or retried the remote lease")
        }
    }

    private static func failures() async throws {
        for code in ["python_unsupported", "home_unsafe", "directory_unsafe", "file_unsafe", "install_busy", "installation_unknown",
                     "installation_mismatch", "runtime_not_clean", "active_entry", "port_in_use", "helper_unavailable",
                     "helper_identity_mismatch", "start_failed", "payload_too_large", "payload_hash_mismatch", "install_io_failed", "interrupted",
                     "untrusted-secret-value"] {
            var result = try response(["version": 1, "ok": false, "error": code], code: 1)
            result.stderr = "untrusted-secret-value"
            let installer = try makeInstaller { _, _, _, _, _ in result }
            let message = try await failure { try await installer.install(profile) }
            try expect(!message.contains("untrusted-secret-value"), "Remote output leaked into user-facing error")
        }
        for result in [CommandResult(exitCode: 15, stdout: "", stderr: "", timedOut: true),
                       .init(exitCode: 255, stdout: "", stderr: "Host key verification failed."),
                       .init(exitCode: 127, stdout: "", stderr: "sh: python3: command not found")] {
            var calls = 0
            let installer = try makeInstaller { _, _, _, _, _ in calls += 1; return result }
            _ = try await failure { try await installer.install(profile) }
            try expect(calls == 1, "Installer retried failure without explicit user action")
        }
    }

    private final class Gate {
        var calls = 0
        var continuation: CheckedContinuation<CommandResult, Never>?
        func result() async -> CommandResult {
            calls += 1
            return await withCheckedContinuation { continuation = $0 }
        }
        func release(_ result: CommandResult) {
            let pending = continuation; continuation = nil; pending?.resume(returning: result)
        }
        func waitForCall() async throws {
            for _ in 0..<200 {
                if continuation != nil { return }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            throw Failure(description: "Fixture executor did not begin")
        }
    }

    private static func cancellation() async throws {
        let gate = Gate(), installed = try response(installationObject)
        var calls = 0
        let status = try response(statusObject)
        let installer = try makeInstaller { _, _, _, _, _ in
            calls += 1
            if calls == 1 { return await gate.result() }
            return calls == 2 ? installed : status
        }
        let task = Task { try await installer.install(profile) }
        try await gate.waitForCall()
        installer.cancel()
        let busy = try await failure { try await installer.install(profile) }
        try expect(busy.contains("正在进行") && calls == 1, "Cancelled but still-running child allowed a concurrent install")
        gate.release(installed)
        let cancelled = try await failure { try await task.value }
        try expect(cancelled.contains("已取消") && cancelled.contains("可能已经完成") && calls == 1,
                   "Late upload success bypassed cancellation or implied remote rollback")
        _ = try await installer.install(profile)
        try expect(calls == 3, "Completed cancellation prevented a fresh explicit install")
    }

    private static func taskCancellation() async throws {
        let gate = Gate(), installed = try response(installationObject), status = try response(statusObject)
        var calls = 0
        let installer = try makeInstaller { _, _, _, _, _ in
            calls += 1
            return calls == 1 ? installed : await gate.result()
        }
        let task = Task { try await installer.install(profile) }
        try await gate.waitForCall()
        task.cancel()
        gate.release(status)
        let message = try await failure { try await task.value }
        try expect(message.contains("已取消") && calls == 2, "Task cancellation accepted late verified readiness")
    }

    private static func earlyCancellation() async throws {
        var calls = 0
        let installer = try makeInstaller { _, _, _, _, _ in calls += 1; return .init(exitCode: 0, stdout: "", stderr: "") }
        let task = Task { try await installer.install(profile) }
        task.cancel()
        let message = try await failure { try await task.value }
        try expect(message.contains("已取消") && calls == 0, "Pre-cancelled install started SSH")
    }

    private static func uploadLimits() throws {
        let command = ChildCommand()
        for (size, limit) in [(4097, 4096), (262_145, 262_144), (1, 262_145), (1, 0)] {
            try rejects("Private stdin limit was bypassed") {
                try command.start(executable: "/bin/cat", arguments: [], stdin: Data(count: size), stdinLimit: limit) { _ in }
            }
        }
        try expect(!command.isRunning, "Rejected upload left a child process")
    }

    private static func uploadCleanup() async throws {
        let payload = Data(repeating: 65, count: 262_144)
        let command = ChildCommand()
        let copied: CommandResult = try await withCheckedThrowingContinuation { continuation in
            do {
                try command.start(executable: "/bin/cat", arguments: [], timeout: 4, stdoutLimit: 262_144,
                                  stdin: payload, stdinLimit: 262_144) { continuation.resume(returning: $0) }
            } catch { continuation.resume(throwing: error) }
        }
        try expect(copied.exitCode == 0 && !copied.timedOut && !copied.stdoutTruncated && Data(copied.stdout.utf8) == payload,
                   "Bounded helper upload truncated or failed to close EOF")
        for executable in ["/usr/bin/true", "/bin/sleep"] {
            let child = ChildCommand()
            var callbacks = 0
            try child.start(executable: executable, arguments: executable == "/bin/sleep" ? ["10"] : [],
                            stdin: payload, stdinLimit: 262_144) { _ in callbacks += 1 }
            if executable == "/bin/sleep" { child.stop() }
            await child.waitForExit()
            try expect(!child.isRunning && callbacks == 1, "Early exit or cancelled large upload left a blocked writer")
        }
    }
}
