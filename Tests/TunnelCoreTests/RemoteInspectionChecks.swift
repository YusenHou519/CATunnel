import Foundation
@testable import TunnelCore

@MainActor
enum RemoteInspectionChecks {
    static let checks: [(String, () async throws -> Void)] = [
        ("fixed entry inspection uses independent strict SSH and only reads status", healthyInspection),
        ("fixed entry inspection separates missing Python and local proxy failures", interpreterFailures),
        ("fixed entry inspection preserves occupied unknown listeners and inactive backends", helperFailures),
        ("fixed entry inspection rejects malformed entry and backend listener records", malformedListeners),
        ("fixed entry inspection refuses malformed and truncated environment evidence", malformedInspection),
        ("fixed entry inspection never starts after invalid profile or early cancellation", inspectionValidation),
        ("fixed entry inspection cancellation suppresses late success", inspectionCancellation),
        ("remote Python discovery preserves selected path and legacy configuration", pythonDiscovery),
        ("remote Python discovery validates framed bounded typed candidate output", invalidDiscovery),
        ("remote Python discovery explains empty old and partial candidate lists", discoveryStates),
        ("remote Python discovery preserves SSH isolation and safe path quoting", discoveryIsolation),
        ("remote Python discovery shell command is valid without executing it", discoveryShellSyntax),
        ("remote Python discovery handles invalid selection and SSH failures without saving", discoveryFailures),
        ("remote Python discovery cancellation discards late candidate output", discoveryCancellation)
    ]

    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(description: message) }
    }
    private static var profile: ServerProfile {
        .init(id: "inspection-fixture", name: "Fixture", host: "192.0.2.10", user: "fixture",
              sshPort: 2222, remotePort: 17892, localPort: 7890, autoReconnect: false,
              useFixedEntry: true, fixedEntryHelperPath: "/tmp/relay.py",
              fixedEntryRuntimePath: "/tmp/private-runtime", fixedEntryPythonPath: "/opt/python3")
    }
    private static func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
    private static func environment(version: [Int] = [3, 12, 0], readable: Bool = true, safe: Bool = true) throws -> CommandResult {
        .init(exitCode: 0, stdout: FixedEntryDiagnostics.marker + "\n" +
              (try json(["version": version, "helper_readable": readable, "runtime_safe": safe])) + "\n", stderr: "")
    }
    private static func status(port: Int = 17892, active: Bool = true) throws -> CommandResult {
        .init(exitCode: 0, stdout: try json(["ok": true, "epoch": "fixture_epoch", "generation": 4,
            "port": port, "active_generation": active ? 4 : NSNull(),
            "backend_port": active ? 34567 : NSNull(), "lease_seconds": 20]) + "\n", stderr: "")
    }
    private static func listening(_ port: Int) -> CommandResult {
        .init(exitCode: 0, stdout: "LISTEN 0 64 127.0.0.1:\(port) 0.0.0.0:*\n", stderr: "")
    }
    private static func standard(_ executable: String, _ args: [String], active: Bool = true) throws -> CommandResult {
        if executable == "/usr/bin/nc" { return .init(exitCode: 0, stdout: "", stderr: "") }
        if args.last == (try FixedEntryDiagnostics.environmentCommand(profile)) { return try environment() }
        if args.last == (try FixedEntryDiagnostics.statusCommand(profile)) { return try status(active: active) }
        if args.last == SSHCommands.listenerCommand(port: 17892) { return listening(17892) }
        if args.last == SSHCommands.listenerCommand(port: 34567) { return listening(34567) }
        throw Failure(description: "Unexpected inspection command")
    }

    private static func healthyInspection() async throws {
        var calls: [(String, [String], Data?)] = []
        var unexpected = false
        let service = FixedEntryDiagnostics(executionContext: .init(knownHostsFile: "/tmp/private-trust")) { executable, args, _, input, _ in
            calls.append((executable, args, input))
            do { return try standard(executable, args) }
            catch { unexpected = true; return .init(exitCode: 1, stdout: "", stderr: "") }
        }
        let before = profile
        let result = await service.run(before)
        try expect(!unexpected && result.map(\.id) == FixedEntryDiagnostics.ids && result.allSatisfy { $0.state == .passed },
                   "Healthy independent layers were not reported")
        try expect(before == profile && calls.count == 5, "Inspection changed configuration or made unexpected requests")
        for (executable, args, input) in calls where executable == "/usr/bin/ssh" {
            try expect(args.contains("StrictHostKeyChecking=yes") && args.contains("UpdateHostKeys=no") &&
                args.contains("ControlMaster=no") && args.contains("ClearAllForwardings=yes") && args.contains("none") &&
                args.contains("UserKnownHostsFile=/tmp/private-trust") && args.contains("IdentityAgent=none") &&
                !args.contains("-M") && !args.contains("-R") && !args.contains("-O"), "Inspection weakened SSH isolation")
            if let input {
                let object = try JSONSerialization.jsonObject(with: input) as? [String: String]
                try expect(object == ["op": "status"], "Inspection took or renewed a lease")
            }
        }
        try expect(result[0].message.contains("尚未验证") && result[5].message.contains("其他会话"),
                   "TCP listener inspection overclaimed proxy reachability or ownership")
    }

    private static func interpreterFailures() async throws {
        for code: Int32 in [126, 127] {
            var controls = 0
            let service = FixedEntryDiagnostics(executionContext: .init()) { executable, args, _, _, _ in
                if executable == "/usr/bin/nc" { return .init(exitCode: 1, stdout: "", stderr: "") }
                if args.last == (try? FixedEntryDiagnostics.environmentCommand(profile)) {
                    return .init(exitCode: code, stdout: FixedEntryDiagnostics.marker + "\n", stderr: "private diagnostic details")
                }
                controls += 1
                return listening(17892)
            }
            let result = await service.run(profile)
            try expect(result[0].state == .failed && result[1].state == .passed && result[2].state == .failed &&
                result[3].state == .skipped && controls == 1 && !result.contains { $0.message.contains("private diagnostic") },
                "Interpreter launch error was confused with SSH or leaked output")
        }
        let old = try environment(version: [3, 8, 10])
        let service = FixedEntryDiagnostics(executionContext: .init()) { executable, args, _, _, _ in
            if args.last == (try? FixedEntryDiagnostics.environmentCommand(profile)) { return old }
            return executable == "/usr/bin/nc" ? .init(exitCode: 0, stdout: "", stderr: "") : listening(17892)
        }
        let result = await service.run(profile)
        try expect(result[2].state == .failed && result[2].message.contains("3.8.10") && result[3].state == .skipped,
                   "Old interpreter was executed as helper")
    }

    private static func helperFailures() async throws {
        for active in [false, true] {
            let response = try status(port: active ? 17893 : 17892, active: active)
            let service = FixedEntryDiagnostics(executionContext: .init()) { executable, args, _, _, _ in
                if args.last == (try? FixedEntryDiagnostics.statusCommand(profile)) { return response }
                return (try? standard(executable, args)) ?? .init(exitCode: 1, stdout: "", stderr: "")
            }
            let result = await service.run(profile)
            try expect(active ? (result[3].state == .failed && result[4].state == .warning && result[5].state == .skipped)
                              : (result[3].state == .passed && result[5].state == .warning),
                       "Unknown occupied entry or idle helper reported healthy route")
        }
        let missing = try environment(readable: false)
        let service = FixedEntryDiagnostics(executionContext: .init()) { executable, args, _, _, _ in
            if args.last == (try? FixedEntryDiagnostics.environmentCommand(profile)) { return missing }
            return (try? standard(executable, args)) ?? .init(exitCode: 1, stdout: "", stderr: "")
        }
        let result = await service.run(profile)
        try expect(result[3].state == .failed && result[3].message.contains("文件不存在"), "Missing helper not distinguished")
    }

    private static func malformedInspection() async throws {
        let valid = try environment()
        let inputs = [CommandResult(exitCode: 0, stdout: valid.stdout, stderr: "", stdoutTruncated: true),
                      .init(exitCode: 0, stdout: valid.stdout + "extra\n", stderr: ""),
                      .init(exitCode: 0, stdout: valid.stdout + FixedEntryDiagnostics.marker + "\n", stderr: ""),
                      try environment(version: []), try environment(version: [3, -1, 0])]
        for bad in inputs {
            let service = FixedEntryDiagnostics(executionContext: .init()) { executable, args, _, _, _ in
                if args.last == (try? FixedEntryDiagnostics.environmentCommand(profile)) { return bad }
                return (try? standard(executable, args)) ?? .init(exitCode: 1, stdout: "", stderr: "")
            }
            let result = await service.run(profile)
            try expect(result[2].state != .passed && result[3].state != .passed, "Malformed environment accepted")
        }
    }

    private static func malformedListeners() async throws {
        for output in ["garbage 0 0 127.0.0.1:17892 0.0.0.0:*\n", "LISTEN 127.0.0.1:17892\n",
                       "LISTEN 0 0 127.0.0.1:17892 0.0.0.0:*\nunexpected banner\n"] {
            let service = FixedEntryDiagnostics(executionContext: .init()) { executable, args, _, _, _ in
                if args.last == SSHCommands.listenerCommand(port: 17892) || args.last == SSHCommands.listenerCommand(port: 34567) {
                    return .init(exitCode: 0, stdout: output, stderr: "")
                }
                return (try? standard(executable, args)) ?? .init(exitCode: 1, stdout: "", stderr: "")
            }
            let result = await service.run(profile)
            try expect(result[4].state == .warning && result[5].state == .warning,
                       "Malformed listener evidence was published as healthy")
        }
    }

    private static func inspectionValidation() async throws {
        var calls = 0
        let service = FixedEntryDiagnostics(executionContext: .init()) { _, _, _, _, _ in
            calls += 1; return .init(exitCode: 0, stdout: "", stderr: "")
        }
        var invalid = profile; invalid.host = "-bad"
        let result = await service.run(invalid)
        try expect(calls == 0 && result[1].state == .failed, "Invalid profile executed")
        let task = Task { await service.run(profile) }
        task.cancel()
        let cancelled = await task.value
        try expect(calls == 0 && cancelled.allSatisfy { $0.state == .skipped }, "Pre-cancelled inspection executed")
    }

    private static func inspectionCancellation() async throws {
        let service = FixedEntryDiagnostics(executionContext: .init()) { executable, args, _, _, _ in
            try? await Task.sleep(nanoseconds: 20_000_000)
            return (try? standard(executable, args)) ?? .init(exitCode: 1, stdout: "", stderr: "")
        }
        let task = Task { await service.run(profile) }
        await Task.yield()
        service.cancel()
        let result = await task.value
        try expect(result.allSatisfy { $0.state == .skipped }, "Cancelled inspection published late success")
    }

    private static func discovery(candidates: [[String: Any]] = [["path": "/opt/python3", "version": [3, 12, 0]]],
                                  checked: Int? = nil, partial: Bool = false) throws -> CommandResult {
        .init(exitCode: 0, stdout: RemotePythonDiscovery.marker + "\n" +
              (try json(["version": 1, "candidates": candidates, "partial": partial,
                         "checked": checked ?? candidates.count])) + "\n", stderr: "")
    }

    private static func pythonDiscovery() async throws {
        let response = try discovery()
        var calls = 0
        let service = RemotePythonDiscovery(executionContext: .init()) { _, _, _, _, _ in calls += 1; return response }
        let before = try JSONEncoder().encode(profile)
        let result = try await service.run(profile)
        try expect(result.candidates == [.init(path: "/opt/python3", version: "3.12.0", isSupported: true)] && !result.isPartial,
                   "Valid discovery candidate changed")
        try expect(calls == 1 && (try JSONEncoder().encode(profile)) == before, "Discovery changed persisted profile")
    }

    private static func invalidDiscovery() throws {
        let valid = try discovery()
        let invalid = [CommandResult(exitCode: 0, stdout: valid.stdout, stderr: "", stdoutTruncated: true),
                       .init(exitCode: 0, stdout: valid.stdout + "trailer\n", stderr: ""),
                       .init(exitCode: 0, stdout: valid.stdout + RemotePythonDiscovery.marker + "\n", stderr: ""),
                       try discovery(candidates: [["path": "~/python3", "version": [3, 12, 0]]]),
                       try discovery(candidates: [["path": "/opt/python\n3", "version": [3, 12, 0]]]),
                       try discovery(candidates: [["path": "/opt/python3", "version": [3]]]),
                       try discovery(candidates: [["path": "/opt/python3", "version": [3, 12, -1]]]),
                       try discovery(checked: 25), try discovery(checked: 0),
                       try discovery(candidates: Array(repeating: ["path": "/opt/python3", "version": [3, 12, 0]], count: 2))]
        for value in invalid {
            do { _ = try RemotePythonDiscovery.parse(value) }
            catch { continue }
            throw Failure(description: "Malformed discovery accepted")
        }
    }

    private static func discoveryStates() throws {
        let empty = try RemotePythonDiscovery.parse(discovery(candidates: []))
        try expect(empty.candidates.isEmpty && empty.message.contains("手动"), "Empty discovery gave no next step")
        let old = try RemotePythonDiscovery.parse(discovery(candidates: [["path": "/usr/bin/python3", "version": [3, 8, 10]]]))
        try expect(!old.candidates[0].isSupported && old.message.contains("不满足"), "Old Python offered as supported")
        let partial = try RemotePythonDiscovery.parse(discovery(checked: 3, partial: true))
        try expect(partial.isPartial && partial.message.contains("不完整"), "Partial result overclaimed exhaustive lookup")
    }

    private static func discoveryIsolation() async throws {
        var selected = profile
        selected.fixedEntryPythonPath = "/opt/py ' ;$(not-run)/python3"
        let command = try RemotePythonDiscovery.command(selected)
        let response = try discovery()
        var captured: [String] = []
        let service = RemotePythonDiscovery(executionContext: .init(knownHostsFile: "/tmp/private-trust")) { _, args, _, input, limit in
            captured = args
            if input != nil || limit != RemotePythonDiscovery.outputLimit { return .init(exitCode: 1, stdout: "", stderr: "") }
            return response
        }
        _ = try await service.run(selected)
        try expect(captured.last == command && command.contains("'\\''") &&
            captured.contains("StrictHostKeyChecking=yes") && captured.contains("ControlMaster=no") &&
            captured.contains("ClearAllForwardings=yes") && captured.contains("none") &&
            !captured.contains("-M") && !captured.contains("-R") &&
            captured.contains("UserKnownHostsFile=/tmp/private-trust"), "Discovery escaped SSH or quoting boundary")
    }

    private static func discoveryFailures() async throws {
        var selected = profile; selected.fixedEntryPythonPath = "~/invalid"
        let response = try discovery()
        let service = RemotePythonDiscovery(executionContext: .init()) { _, _, _, _, _ in response }
        let candidates = try await service.run(selected)
        try expect(!candidates.candidates.isEmpty && selected.fixedEntryPythonPath == "~/invalid", "Invalid typed choice blocked repair or changed draft")
        for failure in [CommandResult(exitCode: 255, stdout: "", stderr: "Permission denied (publickey). private details"),
                        .init(exitCode: -1, stdout: response.stdout, stderr: "private details", timedOut: true)] {
            let failing = RemotePythonDiscovery(executionContext: .init()) { _, _, _, _, _ in failure }
            do { _ = try await failing.run(profile) }
            catch {
                try expect(!error.localizedDescription.contains("private details"), "Discovery leaked raw SSH output")
                continue
            }
            throw Failure(description: "SSH failure published discovery success")
        }
    }

    private static func discoveryShellSyntax() async throws {
        let command = ChildCommand()
        let result: CommandResult = try await withCheckedThrowingContinuation { continuation in
            do {
                try command.start(executable: "/bin/sh", arguments: ["-n"], timeout: 4,
                                  stdin: Data(RemotePythonDiscovery.discoveryShell.utf8)) {
                    continuation.resume(returning: $0)
                }
            } catch { continuation.resume(throwing: error) }
        }
        try expect(result.exitCode == 0 && !result.timedOut, "Discovery shell has syntax errors: " + result.stderr)
    }

    private static func discoveryCancellation() async throws {
        let response = try discovery()
        var calls = 0
        let service = RemotePythonDiscovery(executionContext: .init()) { _, _, _, _, _ in
            calls += 1
            try? await Task.sleep(nanoseconds: 20_000_000)
            return response
        }
        let task = Task { try await service.run(profile) }
        await Task.yield()
        service.cancel()
        do { _ = try await task.value }
        catch {
            try expect(error.localizedDescription.contains("取消"), "Cancellation was not explained")
            let early = Task { try await service.run(profile) }
            early.cancel()
            do { _ = try await early.value } catch { try expect(calls <= 1, "Pre-cancelled discovery launched SSH"); return }
        }
        throw Failure(description: "Cancelled discovery published late candidates")
    }
}
