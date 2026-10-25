import Foundation
import Darwin
@testable import TunnelCore

@MainActor
enum FixedEntryCoreChecks {
    static let checks: [(String, () async throws -> Void)] = [
        ("fixed entry SSH commands preserve identity and owned-master boundaries", commands),
        ("fixed entry control uses the selected literal Python path without changing forwarding", pythonCommands),
        ("fixed entry control requests keep lease credentials in bounded stdin", requests),
        ("fixed entry status strictly binds port and protocol fields", status),
        ("fixed entry candidate and leases reject mismatched or malformed identity", leases),
        ("fixed entry reconnect fence refuses takeover and ambiguous begin replies", fence),
        ("fixed entry helper errors distinguish permanent and retryable failures", errors),
        ("fixed entry Python and helper launch errors are actionable and do not leak stderr", pythonErrors),
        ("fixed entry dynamic forwarding accepts only one valid allocated port", allocatedPort),
        ("child private input round-trips and closes EOF", inputRoundTrip),
        ("child rejects oversized private input before starting", inputLimit),
        ("child private input survives broken pipe, early exit and cancellation", inputCleanup)
    ]

    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try condition() == false { throw Failure(description: message) }
    }
    private static func rejects(_ message: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw Failure(description: message)
    }
    nonisolated private static let epoch = "fixture_epoch-1"
    // Public fixture values only. Assertions never print full protocol objects.
    nonisolated private static let ticket = String(repeating: "a", count: 64)
    private static var identity: FixedEntryIdentity { .init(epoch: epoch, generation: 4, ticket: ticket) }
    private static func response(_ object: [String: Any], exitCode: Int32 = 0) throws -> CommandResult {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return .init(exitCode: exitCode, stdout: String(decoding: data, as: UTF8.self) + "\n", stderr: "")
    }
    private static func statusObject() -> [String: Any] {
        ["ok": true, "epoch": epoch, "generation": 3, "port": 17892,
         "active_generation": NSNull(), "backend_port": NSNull(), "lease_seconds": 15]
    }
    private static func commandProfile() -> ServerProfile {
        .init(id: "fixed-check", name: "Fixture", host: "server.example", user: "fixture", sshPort: 22022,
              remotePort: 17892, localPort: 7890, autoReconnect: true, useFixedEntry: true,
              fixedEntryHelperPath: "/fixture/relay.py", fixedEntryRuntimePath: "/fixture/runtime")
    }

    private static func commands() throws {
        var profile = commandProfile()
        let socket = "/tmp/private-fixture/c"
        let fixed = SSHCommands.master(profile, socket: socket)
        try expect(!fixed.contains("-R") && fixed.contains("-M") && fixed.contains("-N"), "Fixed master claimed the stable port directly")
        try expect(!fixed.contains("-i") && !fixed.contains("IdentitiesOnly=yes") && !fixed.contains("IdentityAgent=none"),
                   "Optional identity mode disabled default SSH identities")
        profile.useFixedEntry = false
        let legacy = SSHCommands.master(profile, socket: socket)
        try expect(legacy.contains("127.0.0.1:17892:127.0.0.1:7890"), "Legacy forwarding changed")
        profile.useFixedEntry = true
        profile.identityFile = "/fixture/client-key"
        let forward = SSHCommands.fixedEntryForward(profile, socket: socket, gatewayPort: 24567)
        let control = try SSHCommands.fixedEntryControl(profile, socket: socket)
        for args in [forward, control] {
            try expect(args.contains(socket) && args.contains("ProxyCommand=/usr/bin/false") &&
                       args.contains("/fixture/client-key") && args.contains("IdentitiesOnly=yes"),
                       "Fixed control escaped its owned SSH master or explicit identity")
        }
        try expect(forward.contains("forward") && forward.contains("127.0.0.1:0:127.0.0.1:24567"), "Dynamic backend was not loopback-only")
        try expect(control.contains("ControlMaster=no") && control.contains("ClearAllForwardings=yes"), "Control created another forwarding transport")
        profile.fixedEntryHelperPath = "/fixture/a'b;$(echo unexpected).py"
        let quoted = try SSHCommands.fixedEntryControl(profile, socket: socket).last ?? ""
        try expect(quoted == "'python3' '/fixture/a'\\''b;$(echo unexpected).py' 'control' '--runtime-dir' '/fixture/runtime'",
                   "Remote helper path escaped its shell argument")
        for path in ["relative.py", "/fixture/relay\n.py", "/fixture/relay\u{0}.py"] {
            profile.fixedEntryHelperPath = path
            try rejects("Invalid remote helper path accepted") { _ = try SSHCommands.fixedEntryControl(profile, socket: socket) }
        }
    }

    private static func requests() throws {
        let key = Data(repeating: 0x5b, count: 32)
        for request in [FixedEntryRequest.status, .begin(.init(epoch: epoch, generation: 3)),
                        .activate(identity, backendPort: 24567, healthKey: key), .renew(identity), .release(identity)] {
            let data = try FixedEntryProtocol.input(request)
            try expect(data.count <= 4096 && data.last == 10 && data.dropLast().firstIndex(of: 10) == nil,
                       "Control input is not a bounded single JSON line")
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            try expect(object?["op"] as? String != nil, "Control request lost its operation")
        }
        let activated = try JSONSerialization.jsonObject(with: FixedEntryProtocol.input(
            .activate(identity, backendPort: 24567, healthKey: key))) as? [String: Any]
        try expect(activated?["health_key"] as? String == String(repeating: "5b", count: 32)
                   && activated?["ticket"] as? String == ticket && activated?["generation"] as? Int == 4,
                   "Lease request identity or HMAC key encoding changed")
        let args = try SSHCommands.fixedEntryControl(commandProfile(), socket: "/tmp/fixture/c").joined(separator: " ")
        try expect(!args.contains(ticket) && !args.contains(String(repeating: "5b", count: 32)), "Control credentials appeared in process arguments")
        try rejects("Invalid HMAC key length accepted") {
            _ = try FixedEntryProtocol.input(.activate(identity, backendPort: 24567, healthKey: Data(count: 31)))
        }
        try rejects("Oversized control request accepted") {
            _ = try FixedEntryProtocol.input(.begin(.init(epoch: String(repeating: "x", count: 4096), generation: 3)))
        }
    }

    private static func pythonCommands() throws {
        var profile = commandProfile()
        let socket = "/tmp/private-fixture/c"
        let beforeMaster = SSHCommands.master(profile, socket: socket)
        let beforeForward = SSHCommands.fixedEntryForward(profile, socket: socket, gatewayPort: 24567)
        for (path, quoted) in [
            ("", "'python3'"),
            ("/opt/fixture env/bin/python3", "'/opt/fixture env/bin/python3'"),
            ("/opt/a'b;$(not-run)/python3", "'/opt/a'\\''b;$(not-run)/python3'")
        ] {
            profile.fixedEntryPythonPath = path
            let args = try SSHCommands.fixedEntryControl(profile, socket: socket)
            try expect(args.last == quoted + " '/fixture/relay.py' 'control' '--runtime-dir' '/fixture/runtime'",
                       "Selected Python was replaced or interpreted as shell syntax")
            try expect(SSHCommands.master(profile, socket: socket) == beforeMaster &&
                       SSHCommands.fixedEntryForward(profile, socket: socket, gatewayPort: 24567) == beforeForward,
                       "Python selection altered SSH forwarding")
        }
        for path in ["python3", "~/bin/python3", "/fixture/py\nthon", "/" + String(repeating: "x", count: 4096)] {
            profile.fixedEntryPythonPath = path
            try rejects("Control accepted an invalid Python path") { _ = try SSHCommands.fixedEntryControl(profile, socket: socket) }
        }
    }

    private static func status() throws {
        let good = try response(statusObject())
        try expect(try FixedEntryProtocol.status(good, expectedPort: 17892).generation == 3, "Valid idle status rejected")
        try rejects("Wrong fixed entry port accepted before begin") { _ = try FixedEntryProtocol.status(good, expectedPort: 17893) }
        for (field, bad) in [("epoch", "valid\n" as Any), ("epoch", "" as Any), ("epoch", "ｅpoch" as Any),
                             ("generation", -1 as Any), ("generation", true as Any), ("generation", Int.max as Any),
                             ("port", 0 as Any), ("port", true as Any), ("backend_port", 24567 as Any)] {
            var object = statusObject(); object[field] = bad
            try rejects("Invalid status field accepted") { _ = try FixedEntryProtocol.status(response(object), expectedPort: 17892) }
        }
        var active = statusObject(); active["active_generation"] = 2; active["backend_port"] = 24567
        _ = try FixedEntryProtocol.status(response(active), expectedPort: 17892)
        active["active_generation"] = 4
        try rejects("Future active generation accepted") { _ = try FixedEntryProtocol.status(response(active), expectedPort: 17892) }
        for index in 0..<4 {
            var malformed = good
            if index == 0 { malformed.stdout += good.stdout }
            if index == 1 { malformed.stdoutTruncated = true }
            if index == 2 { malformed.stdout.removeLast() }
            if index == 3 { malformed.stdout = String(repeating: " ", count: 4096) + good.stdout }
            try rejects("Unbounded or non-single-line status accepted") { _ = try FixedEntryProtocol.status(malformed, expectedPort: 17892) }
        }
    }

    private static func leases() throws {
        let baseline = FixedEntryFence(epoch: epoch, generation: 3)
        let candidate: [String: Any] = ["ok": true, "epoch": epoch, "generation": 4, "ticket": ticket]
        try expect(try FixedEntryProtocol.candidate(response(candidate), after: baseline) == identity, "Valid candidate rejected")
        for (field, value) in [("ticket", ticket + "\n" as Any), ("ticket", String(repeating: "A", count: 64) as Any),
                               ("ticket", String(repeating: "a", count: 63) as Any), ("epoch", epoch + "\n" as Any),
                               ("generation", 5 as Any), ("generation", true as Any)] {
            var invalid = candidate; invalid[field] = value
            try rejects("Malformed or mismatched candidate accepted") { _ = try FixedEntryProtocol.candidate(response(invalid), after: baseline) }
        }
        var activation: [String: Any] = ["ok": true, "epoch": epoch, "generation": 4, "backend_port": 24567, "lease_seconds": 15]
        try expect(try FixedEntryProtocol.activated(response(activation), identity: identity, backendPort: 24567) == 15, "Valid activation rejected")
        activation["backend_port"] = 24568
        try rejects("Activation selected another backend") { _ = try FixedEntryProtocol.activated(response(activation), identity: identity, backendPort: 24567) }
        for value in [0, -1, 3601] {
            try rejects("Unbounded lease accepted") { _ = try FixedEntryProtocol.renewed(response(["ok": true, "lease_seconds": value])) }
        }
        try rejects("Boolean lease accepted") { _ = try FixedEntryProtocol.renewed(response(["ok": true, "lease_seconds": true])) }
        try expect(try FixedEntryProtocol.renewed(response(["ok": true, "lease_seconds": 15])) == 15, "Valid renewal rejected")
    }

    private static func fence() throws {
        let baseline = FixedEntryFence(epoch: epoch, generation: 3)
        try baseline.check(.init(epoch: epoch, generation: 3, port: 17892))
        try baseline.check(.init(epoch: "new-helper-epoch", generation: 0, port: 17892))
        for generation in [2, 4, 100] {
            try rejects("Old client reclaimed a newer or ambiguous generation") {
                try baseline.check(.init(epoch: epoch, generation: generation, port: 17892))
            }
        }
        let acknowledged = try FixedEntryProtocol.candidate(response([
            "ok": true, "epoch": epoch, "generation": 4, "ticket": ticket]), after: baseline)
        let committed = FixedEntryFence(epoch: acknowledged.epoch, generation: acknowledged.generation)
        try committed.check(.init(epoch: epoch, generation: 4, port: 17892))
        try rejects("Acknowledged client ignored later takeover") { try committed.check(.init(epoch: epoch, generation: 5, port: 17892)) }
    }

    private static func failure(_ result: CommandResult) throws -> SSHFailure {
        do { _ = try FixedEntryProtocol.status(result, expectedPort: 17892) }
        catch let error as FixedEntryError { return error.failure }
        throw Failure(description: "Expected typed fixed-entry failure")
    }
    private static func errors() throws {
        for code in ["superseded", "stale_generation", "runtime_missing", "helper_unavailable", "runtime_unsafe", "runtime_busy", "runtime_not_clean"] {
            try expect(try !failure(response(["ok": false, "error": code], exitCode: 1)).retryable, "Permanent helper failure started retries")
        }
        for code in ["epoch_mismatch", "stale_candidate", "stale_lease", "health_failed", "control_timeout", "control_io_failed"] {
            try expect(try failure(response(["ok": false, "error": code], exitCode: 1)).retryable, "Transient helper failure stopped retries")
        }
        let timeout = CommandResult(exitCode: 15, stdout: "", stderr: "", timedOut: true)
        try expect(try failure(timeout).retryable, "Control timeout became permanent")
        try expect(try !failure(.init(exitCode: 255, stdout: "", stderr: "Permission denied (publickey).")).retryable, "Authentication failure became transient")
        try expect(try failure(.init(exitCode: 255, stdout: "", stderr: "Connection reset by peer")).retryable, "Transport loss became permanent")
        for stderr in ["python3: can't open file '/fixture/missing.py'", "sh: python3: command not found"] {
            try expect(try !failure(.init(exitCode: 2, stdout: "", stderr: stderr)).retryable, "Missing helper became transient")
        }
        let invalid = try failure(response(["ok": false, "error": "unknown", "ticket": ticket], exitCode: 1))
        try expect(!invalid.message.contains(ticket) && !invalid.retryable, "Untrusted helper response entered logs or automatic retries")
    }

    private static func allocatedPort() throws {
        try expect(try FixedEntryProtocol.allocatedPort(.init(exitCode: 0, stdout: "24567\n", stderr: "")) == 24567, "Valid dynamic port rejected")
        for output in ["0\n", "65536\n", "24567\n24568\n", "port 24567\n", "-1\n", "１２３\n", ""] {
            try rejects("Invalid dynamic port accepted") { _ = try FixedEntryProtocol.allocatedPort(.init(exitCode: 0, stdout: output, stderr: "")) }
        }
        try rejects("Truncated allocation accepted") {
            _ = try FixedEntryProtocol.allocatedPort(.init(exitCode: 0, stdout: "24567\n", stderr: "", stdoutTruncated: true))
        }
    }

    private static func pythonErrors() throws {
        let cases: [(Int32, String, String)] = [
            (127, "sh: /fixture/custom-python: not found", "找不到"),
            (126, "sh: /fixture/custom-python: Permission denied", "无法执行"),
            (2, "/fixture/custom-python: can't open file 'private-remote-detail'", "无法打开"),
            (1, "Traceback private-remote-detail TypeError: incompatible interpreter", "3.9")
        ]
        for (code, stderr, expected) in cases {
            let result = try failure(.init(exitCode: code, stdout: "", stderr: stderr))
            try expect(!result.retryable && result.message.contains(expected) && !result.message.contains("private-remote-detail"),
                       "Python/helper launch failure became transient, misleading, or leaked stderr")
        }
        let ssh = try failure(.init(exitCode: 255, stdout: "", stderr: "Permission denied (publickey)."))
        try expect(ssh.message.contains("SSH 密钥认证失败") && !ssh.message.contains("Python"),
                   "SSH authentication was confused with Python executable permissions")
    }

    private static func run(_ executable: String, arguments: [String] = [], input: Data? = nil) async throws -> CommandResult {
        let command = ChildCommand()
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try command.start(executable: executable, arguments: arguments, timeout: 3, stdin: input) {
                    continuation.resume(returning: $0)
                }
            } catch { continuation.resume(throwing: error) }
        }
    }
    private static func inputRoundTrip() async throws {
        let payload = Data(String(repeating: "x", count: 4096).utf8)
        let copied = try await run("/bin/cat", input: payload)
        try expect(copied.exitCode == 0 && !copied.timedOut && Data(copied.stdout.utf8) == payload, "Private input truncated or failed to close EOF")
        let empty = try await run("/bin/cat")
        try expect(empty.exitCode == 0 && empty.stdout.isEmpty, "Default stdin no longer reaches EOF")
    }
    private static func inputLimit() async throws {
        let command = ChildCommand()
        var callbacks = 0
        try rejects("Oversized private input started a process") {
            try command.start(executable: "/bin/cat", arguments: [], stdin: Data(count: 4097)) { _ in callbacks += 1 }
        }
        await command.waitForExit()
        try expect(!command.isRunning && callbacks == 0, "Rejected input left a child or callback")
    }
    private static func inputCleanup() async throws {
        let pipe = Pipe()
        let descriptor = pipe.fileHandleForWriting.fileDescriptor
        try pipe.fileHandleForReading.close()
        try rejects("Closed private pipe did not report a write error") {
            try ChildCommand.writePrivateInput(Data([1]), to: pipe.fileHandleForWriting)
        }
        try expect(fcntl(descriptor, F_GETFD) == -1 && errno == EBADF, "Broken-pipe writer was not closed")
        for _ in 0..<12 {
            let result = try await run("/usr/bin/true", input: Data(count: 4096))
            try expect(result.exitCode == 0 && !result.timedOut, "Early-exit input failed to drain safely")
        }
        let command = ChildCommand()
        var callbacks = 0
        try command.start(executable: "/bin/sleep", arguments: ["10"], stdin: Data(count: 4096)) { _ in callbacks += 1 }
        command.stop()
        await command.waitForExit()
        await command.waitForExit()
        try expect(!command.isRunning && callbacks == 1, "Cancellation leaked a private writer or duplicated completion")
    }
}
