import Foundation
import Darwin
@testable import TunnelCore

private struct Failure: Error, CustomStringConvertible {
    let description: String
}

private struct Manifest: Decodable {
    let root: String
    let user: String
    let sshPorts: [Int]
    let localPorts: [Int]
    let installPorts: [Int]
    let legacyPort: Int
    let fixtureHome: String
    let selectedPythonPath: String
    let missingPythonPath: String
    let installerScriptPath: String
    let helperPath: String
    let markers: [String]
}

@MainActor
private final class InstallationRun {
    private let manifest: Manifest
    private let root: URL
    private let helper: Data
    private let bootstrap: Data
    private var checks: [[String: Any]] = []
    private var phases: [String: TunnelPhase] = [:]
    private var directories: [String] = []
    private var fixed: TunnelController?
    private var legacy: TunnelController?

    init(_ url: URL) throws {
        manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        root = URL(fileURLWithPath: manifest.root, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let shortTemporary = URL(fileURLWithPath: "/private/tmp", isDirectory: true).resolvingSymlinksInPath()
        let home = URL(fileURLWithPath: manifest.fixtureHome).resolvingSymlinksInPath()
        let metadata = try FileManager.default.attributesOfItem(atPath: root.path)
        let homeMetadata = try FileManager.default.attributesOfItem(atPath: home.path)
        guard root.path.hasPrefix(temporary.path + "/cati."),
              root.path == url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path,
              (metadata[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (metadata[.posixPermissions] as? NSNumber)?.intValue == 0o700,
              manifest.sshPorts.count == 2, manifest.localPorts.count == 2,
              manifest.installPorts.count == 5, manifest.markers.count == 2,
              (manifest.sshPorts + manifest.localPorts + manifest.installPorts + [manifest.legacyPort])
                .allSatisfy({ (1024...65535).contains($0) }),
              home.path.hasPrefix(shortTemporary.path + "/caih."),
              // Foundation canonicalizes /private/tmp to /tmp on macOS, whereas pathlib
              // retains /private/tmp. Compare generated paths in their manifest spelling.
              manifest.selectedPythonPath == manifest.fixtureHome + "/bin/python 'selected 3",
              manifest.missingPythonPath == manifest.fixtureHome + "/bin/python missing",
              FileManager.default.isExecutableFile(atPath: manifest.selectedPythonPath),
              !FileManager.default.fileExists(atPath: manifest.missingPythonPath),
              (homeMetadata[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (homeMetadata[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {
            throw Failure(description: "Invalid private installation fixture")
        }
        helper = try Data(contentsOf: URL(fileURLWithPath: manifest.helperPath))
        bootstrap = try Data(contentsOf: URL(fileURLWithPath: manifest.installerScriptPath))
    }

    private var context: SSHExecutionContext {
        SSHExecutionContext(knownHostsFile: manifest.root + "/known_hosts", listenerCommand: { port in
            "/usr/sbin/lsof -nP -a -iTCP:\(port) -sTCP:LISTEN -Fn | /usr/bin/awk '/^n/ {print \"LISTEN 0 0 \" substr($0, 2) \" 0.0.0.0:*\"}'"
        }, makeSocketDirectory: { [weak self] in
            guard let self else { throw Failure(description: "Fixture gone") }
            var template = Array((self.root.path + "/ctl.XXXXXXXX").utf8CString)
            let path = try template.withUnsafeMutableBufferPointer { buffer -> String in
                guard let start = buffer.baseAddress, let result = mkdtemp(start) else {
                    throw Failure(description: "Cannot create fixture control directory")
                }
                return String(cString: result)
            }
            self.directories.append(path)
            return path
        })
    }

    private func installer(context override: SSHExecutionContext? = nil) throws -> FixedEntryInstaller {
        try FixedEntryInstaller(helperScript: helper, installerScript: bootstrap, executionContext: override ?? context)
    }

    private func profile(_ id: String, port: Int, server: Int = 0) -> ServerProfile {
        .init(id: id, name: id, host: "127.0.0.1", user: manifest.user, sshPort: manifest.sshPorts[server],
              remotePort: port, localPort: manifest.localPorts[server], autoReconnect: true,
              identityFile: manifest.root + "/client")
    }

    private func controller() -> TunnelController {
        let controller = TunnelController(executionContext: context)
        controller.onEvent = { [weak self] event in
            if case let .status(id, state) = event { self?.phases[id] = state.phase }
        }
        return controller
    }

    private func check(_ name: String, _ passed: Bool) throws {
        checks.append(["name": name, "passed": passed])
        print("\(passed ? "PASS" : "FAIL"): \(name)")
        guard passed else { throw Failure(description: name) }
    }

    private func wait(_ name: String, seconds: Double = 10, _ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        throw Failure(description: name)
    }

    private func expectFailure(_ name: String, _ operation: () async throws -> Void) async throws {
        var failed = false
        do { try await operation() } catch { failed = true }
        try check(name, failed)
    }

    private func marker(_ port: Int, index: Int) async throws {
        let command = ChildCommand()
        let result: CommandResult = await withCheckedContinuation { continuation in
            do {
                try command.start(executable: "/usr/bin/curl", arguments: ["-q", "--silent", "--show-error", "--fail",
                    "--noproxy", "*", "--proxy", "", "--connect-timeout", "1", "--max-time", "3",
                    "http://127.0.0.1:\(port)/installation-marker"], timeout: 5, stdoutLimit: 1024) {
                    continuation.resume(returning: $0)
                }
            } catch { continuation.resume(returning: .init(exitCode: -1, stdout: "", stderr: "")) }
        }
        try check("port \(port) transfers the exact private HTTP marker", result.exitCode == 0 && result.stdout == manifest.markers[index])
    }

    private func ready(_ installation: FixedEntryInstallation) throws -> Data {
        let path = URL(fileURLWithPath: installation.runtimePath).appendingPathComponent("ready.json")
        let home = URL(fileURLWithPath: manifest.fixtureHome).resolvingSymlinksInPath()
        guard path.resolvingSymlinksInPath().path.hasPrefix(home.path + "/") else {
            throw Failure(description: "Installed runtime escaped fixture HOME")
        }
        return try Data(contentsOf: path)
    }

    private func auditRecords() throws -> [[String: Any]] {
        let data = try Data(contentsOf: root.appendingPathComponent("install-audit.jsonl"))
        return try data.split(separator: 10).map {
            guard let record = try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] else {
                throw Failure(description: "Invalid fixture audit record")
            }
            return record
        }
    }

    private func portIsFree(_ port: Int) -> Bool {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private func exerciseSelectedPython() async throws {
        let runner = try installer()
        let original = profile("selected-python", port: manifest.installPorts[3])
        let unavailable = root.appendingPathComponent("old-default-python")
        try Data().write(to: unavailable)
        defer { try? FileManager.default.removeItem(at: unavailable) }
        try await expectFailure("injected old default Python is rejected before installation") {
            _ = try await runner.install(original)
        }
        try check("old default Python creates no installation directory or listener",
                  !FileManager.default.fileExists(atPath: manifest.fixtureHome + "/.catunnel/fixed-entry/\(original.remotePort)")
                  && portIsFree(original.remotePort))

        var selected = original
        selected.fixedEntryPythonPath = manifest.selectedPythonPath
        let installed = try await runner.install(selected)
        let initialReady = try ready(installed)
        try check("quoted existing Python installs and verifies the bundled helper while default Python is unavailable",
                  !installed.reused && (try Data(contentsOf: URL(fileURLWithPath: installed.helperPath))) == helper)
        let beforeConnection = try auditRecords().filter { ($0["port"] as? Int) == selected.remotePort && ($0["injected"] as? Bool) == false }
        try check("installation and independent status both execute the selected Python path",
                  beforeConnection.count == 2
                  && beforeConnection.allSatisfy { ($0["interpreter"] as? String) == manifest.selectedPythonPath }
                  && beforeConnection.contains { ($0["kind"] as? String) == "install" && ($0["ok"] as? Bool) == true }
                  && beforeConnection.contains { ($0["op"] as? String) == "status" && ($0["ok"] as? Bool) == true })

        var enabled = selected
        enabled.useFixedEntry = true
        enabled.fixedEntryHelperPath = installed.helperPath
        enabled.fixedEntryRuntimePath = installed.runtimePath
        fixed = controller()
        fixed?.start(enabled)
        try await wait("selected Python tunnel did not connect") { phases[enabled.id] == .connected }
        try await marker(enabled.remotePort, index: 0)
        try await wait("selected Python tunnel did not renew its real lease", seconds: 12) {
            (try? auditRecords().contains {
                ($0["port"] as? Int) == enabled.remotePort && ($0["op"] as? String) == "renew"
                && ($0["ok"] as? Bool) == true && ($0["interpreter"] as? String) == manifest.selectedPythonPath
            }) == true
        }
        try check("real lease renewal succeeds through the selected Python", phases[enabled.id] == .connected)
        try await marker(enabled.remotePort, index: 0)
        await fixed?.shutdown()
        fixed = nil
        try check("stopping with the selected Python releases its lease", try auditRecords().contains {
            ($0["port"] as? Int) == enabled.remotePort && ($0["op"] as? String) == "release" && ($0["ok"] as? Bool) == true
        })
        let reused = try await runner.install(selected)
        try check("selected Python reinstall preserves the running helper PID and epoch", reused.reused && (try ready(reused)) == initialReady)
        phases[enabled.id] = nil
        fixed = controller()
        fixed?.start(enabled)
        try await wait("selected Python tunnel did not reconnect") { phases[enabled.id] == .connected }
        try await marker(enabled.remotePort, index: 0)
        await fixed?.shutdown()
        fixed = nil
        let records = try auditRecords().filter { ($0["port"] as? Int) == enabled.remotePort }
        let injected = records.filter { ($0["injected"] as? Bool) == true }
        let executed = records.filter { ($0["injected"] as? Bool) == false }
        let operations = Set(executed.compactMap { $0["op"] as? String })
        try check("install, status, begin, activate, renew, release, and reconnect never fall back to default Python",
                  injected.count == 1 && (injected.first?["error"] as? String) == "python_unsupported"
                  && executed.allSatisfy { ($0["interpreter"] as? String) == manifest.selectedPythonPath }
                  && operations == Set(["status", "begin", "activate", "renew", "release"])
                  && executed.filter { ($0["op"] as? String) == "begin" && ($0["ok"] as? Bool) == true }.count == 2
                  && executed.filter { ($0["op"] as? String) == "release" && ($0["ok"] as? Bool) == true }.count == 2)

        var missing = profile("missing-selected-python", port: manifest.installPorts[4])
        missing.fixedEntryPythonPath = manifest.missingPythonPath
        try await expectFailure("missing selected Python fails without a default-interpreter fallback") {
            _ = try await runner.install(missing)
        }
        try check("missing selected Python creates no installation directory or listener",
                  !FileManager.default.fileExists(atPath: manifest.fixtureHome + "/.catunnel/fixed-entry/\(missing.remotePort)")
                  && portIsFree(missing.remotePort))
        let missingRecords = try auditRecords().filter { ($0["port"] as? Int) == missing.remotePort }
        try check("missing selected Python is a real executable-not-found error without fallback",
                  missingRecords.count == 1 && (missingRecords.first?["kind"] as? String) == "missing-selected-python"
                  && (missingRecords.first?["interpreter"] as? String) == manifest.missingPythonPath
                  && (missingRecords.first?["injected"] as? Bool) == false)
        try await marker(manifest.legacyPort, index: 1)
    }

    func run() async -> Int32 {
        var failure: String?
        do { try await exercise() }
        catch { failure = String(describing: error) }
        await fixed?.shutdown()
        await legacy?.shutdown()
        do { try check("both controllers remove every owned SSH control directory", directories.allSatisfy { !FileManager.default.fileExists(atPath: $0) }) }
        catch { failure = failure ?? String(describing: error) }
        var report: [String: Any] = ["checks": checks]
        if let failure { report["error"] = failure; print("ERROR: \(failure)") }
        do {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("install-result.json"))
        } catch { return 1 }
        return failure == nil ? 0 : 1
    }

    private func exercise() async throws {
        let legacyProfile = profile("legacy-control", port: manifest.legacyPort, server: 1)
        legacy = controller()
        legacy?.start(legacyProfile)
        try await wait("legacy control did not connect") { phases[legacyProfile.id] == .connected }
        try await marker(manifest.legacyPort, index: 1)

        let original = profile("installed-entry", port: manifest.installPorts[0])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let saved = try encoder.encode(original)
        let runner = try installer()
        let installed = try await runner.install(original)
        let initialReady = try ready(installed)
        let installedHelper = URL(fileURLWithPath: installed.helperPath)
        try check("real SSH upload installs exactly the bundled helper in private HOME", try Data(contentsOf: installedHelper) == helper)
        try check("first installation returns a new verified detached helper", !installed.reused && installed.port == original.remotePort)
        try check("installation does not modify the input profile or enable a tunnel", try encoder.encode(original) == saved && phases[original.id] == nil)
        let repeated = try await runner.install(original)
        try check("repeated installation reuses the same helper PID and epoch", repeated.reused && (try ready(repeated)) == initialReady)
        try await marker(manifest.legacyPort, index: 1)

        var enabled = original
        enabled.useFixedEntry = true
        enabled.fixedEntryHelperPath = installed.helperPath
        enabled.fixedEntryRuntimePath = installed.runtimePath
        fixed = controller()
        fixed?.start(enabled)
        try await wait("installed helper did not accept the real Swift tunnel") { phases[enabled.id] == .connected }
        try await marker(enabled.remotePort, index: 0)
        try await expectFailure("installation refuses an active helper without taking its lease") { _ = try await runner.install(original) }
        try check("refusing active entry preserves its helper process", try ready(installed) == initialReady)
        try await marker(enabled.remotePort, index: 0)
        try await marker(manifest.legacyPort, index: 1)
        await fixed?.shutdown()
        fixed = nil
        let afterStop = try await runner.install(original)
        try check("stopping the tunnel leaves the installed helper reusable", afterStop.reused && (try ready(afterStop)) == initialReady)

        let occupied = profile("foreign-listener", port: manifest.localPorts[1])
        try await expectFailure("installer refuses a port held by an unrelated live HTTP listener") { _ = try await runner.install(occupied) }
        try await marker(manifest.localPorts[1], index: 1)
        try await marker(manifest.legacyPort, index: 1)

        let other = profile("cancelled-install", port: manifest.installPorts[1])
        let delay = root.appendingPathComponent("delay-install-\(other.remotePort)")
        try Data().write(to: delay)
        let cancelled = try installer()
        let pending = Task { try await cancelled.install(other) }
        do {
            try await wait("installer did not complete before its delayed reply", seconds: 20) {
                FileManager.default.fileExists(atPath: root.appendingPathComponent("installed-before-reply-\(other.remotePort)").path)
            }
        } catch {
            cancelled.cancel()
            _ = await pending.result
            throw error
        }
        cancelled.cancel()
        try await expectFailure("cancelled real SSH install cannot publish a late success") { _ = try await pending.value }
        try FileManager.default.removeItem(at: delay)
        let recovered = try await cancelled.install(other)
        try check("retry after a lost install reply finds the already installed helper", recovered.reused && recovered.port == other.remotePort)
        let recoveredReady = try ready(recovered)
        try check("cancellation leaves the original helper PID and epoch intact", try ready(installed) == initialReady)
        try await marker(manifest.legacyPort, index: 1)

        var unknownContext = context
        unknownContext.knownHostsFile = manifest.root + "/unknown_hosts"
        let unknown = try installer(context: unknownContext)
        try await expectFailure("unknown SSH host key blocks installation without accepting trust") { _ = try await unknown.install(original) }
        try check("unknown host trust file stays empty", try Data(contentsOf: root.appendingPathComponent("unknown_hosts")).isEmpty)

        let missing = root.appendingPathComponent("missing-python")
        try Data().write(to: missing)
        do {
            try await expectFailure("missing Python fails without uploading or enabling") {
                _ = try await runner.install(profile("missing-python", port: manifest.installPorts[2]))
            }
        } catch { try? FileManager.default.removeItem(at: missing); throw error }
        try FileManager.default.removeItem(at: missing)
        try check("missing Python creates no installation directory", !FileManager.default.fileExists(atPath:
            manifest.fixtureHome + "/.catunnel/fixed-entry/\(manifest.installPorts[2])"))

        try await exerciseSelectedPython()

        let tampered = helper + Data("\n# fixture mismatch; must not be overwritten\n".utf8)
        try tampered.write(to: installedHelper)
        try await expectFailure("installer refuses a modified managed helper instead of replacing it") { _ = try await runner.install(original) }
        try check("version conflict preserves existing bytes and helper process", try Data(contentsOf: installedHelper) == tampered && (try ready(installed)) == initialReady)
        try check("failed install leaves the independent installed helper unchanged", try ready(recovered) == recoveredReady)
        try await marker(manifest.legacyPort, index: 1)
        try check("every install attempt preserves the original profile", try encoder.encode(original) == saved && !original.useFixedEntry)
    }
}

@main
@MainActor
struct FixedEntryInstallIntegrationRunner {
    static func main() async {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        do {
            let run = try InstallationRun(URL(fileURLWithPath: CommandLine.arguments[1]))
            exit(await run.run())
        } catch {
            fputs("Installation fixture failed to initialize: \(error)\n", stderr)
            exit(1)
        }
    }
}
