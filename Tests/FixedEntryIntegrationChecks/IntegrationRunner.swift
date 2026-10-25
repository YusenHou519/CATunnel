import Foundation
import Darwin
@testable import TunnelCore

private struct FixtureFailure: Error, CustomStringConvertible {
    let description: String
}

private struct Manifest: Decodable {
    let root: String
    let user: String
    let sshPorts: [Int]
    let localPorts: [Int]
    let entryPorts: [Int]
    let legacyPort: Int
    let helperPath: String
    let missingHelperPath: String
    let runtimePaths: [String]
}

private struct Action: Decodable {
    let action: String
    let id: String?
}

@MainActor
private final class FixtureRun {
    private let manifest: Manifest
    private let eventHandle: FileHandle
    private let actionHandle: FileHandle
    private let started = ProcessInfo.processInfo.systemUptime
    private var pending = Data()
    private var controller: TunnelController?
    private var profiles: [String: ServerProfile] = [:]
    private var directories: [String] = []
    private var shouldExit = false
    private var failed = false

    init(url: URL) throws {
        manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        let root = URL(fileURLWithPath: manifest.root, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let ports = manifest.sshPorts + manifest.localPorts + manifest.entryPorts + [manifest.legacyPort]
        func require(_ condition: Bool, _ reason: String) throws {
            guard condition else {
                throw FixtureFailure(description: "Invalid isolated fixed-entry manifest: " + reason)
            }
        }
        func isInsideRoot(_ path: String) -> Bool {
            path.hasPrefix("/") && URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
                .path.hasPrefix(root.path + "/")
        }
        try require(manifest.root.hasPrefix("/") && root.path.hasPrefix(temporary.path + "/"), "root is outside the temporary directory")
        // URL equality also compares the directory hint; filesystem identity must compare normalized paths.
        try require(root.path == url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path,
                    "manifest is outside its declared root")
        try require(manifest.root.utf8.count + 16 < 104, "root is too long for the SSH control socket")
        try require(manifest.sshPorts.count == 2 && manifest.localPorts.count == 2 && manifest.entryPorts.count == 2,
                    "expected two SSH, local, and entry ports")
        try require(manifest.runtimePaths.count == 2, "expected two helper runtime paths")
        try require(ports.allSatisfy({ (1024...65535).contains($0) }) && Set(ports).count == ports.count,
                    "ports must be distinct unprivileged ports")
        try require(manifest.helperPath.hasPrefix("/"), "helper path must be absolute")
        let missingHelper = URL(fileURLWithPath: manifest.missingHelperPath).standardizedFileURL
        let missingParent = missingHelper.deletingLastPathComponent().resolvingSymlinksInPath()
        try require(manifest.missingHelperPath.hasPrefix("/") && missingParent.path == root.path &&
                    !FileManager.default.fileExists(atPath: missingHelper.path),
                    "missing helper must be an absent file directly inside the fixture root")
        try require(manifest.runtimePaths.allSatisfy(isInsideRoot), "helper runtime path is outside the fixture root")
        func open(_ name: String, write: Bool) throws -> FileHandle {
            let path = root.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: path.path) {
                guard FileManager.default.createFile(atPath: path.path, contents: Data(),
                    attributes: [.posixPermissions: 0o600]) else {
                    throw FixtureFailure(description: "Unable to create fixture IPC file")
                }
            }
            return try write ? FileHandle(forWritingTo: path) : FileHandle(forReadingFrom: path)
        }
        eventHandle = try open("events.jsonl", write: true)
        actionHandle = try open("actions.jsonl", write: false)
    }

    func run() async -> Int32 {
        defer { try? eventHandle.close(); try? actionHandle.close() }
        do {
            let root = manifest.root
            let context = SSHExecutionContext(knownHostsFile: root + "/known_hosts", listenerCommand: { port in
                "/usr/sbin/lsof -nP -a -iTCP:\(port) -sTCP:LISTEN -Fn | /usr/bin/awk '/^n/ {print \"LISTEN 0 0 \" substr($0, 2) \" 0.0.0.0:*\"}'"
            }, makeSocketDirectory: { [weak self] in
                var template = Array((root + "/ctl.XXXXXXXX").utf8CString)
                let path = try template.withUnsafeMutableBufferPointer { buffer -> String in
                    guard let address = buffer.baseAddress, let result = Darwin.mkdtemp(address) else {
                        throw FixtureFailure(description: "Unable to create a private SSH control directory")
                    }
                    return String(cString: result)
                }
                self?.directories.append(path)
                self?.event("directory", fields: ["path": path])
                return path
            })
            let controller = TunnelController(executionContext: context)
            self.controller = controller
            controller.onEvent = { [weak self] event in
                switch event {
                case let .status(id, status):
                    self?.event("status", id: id, fields: ["phase": status.phase.rawValue, "message": status.message])
                case let .log(id, message):
                    self?.event("log", id: id, fields: ["message": message])
                }
            }
            for (index, id) in ["fixed-a", "fixed-b"].enumerated() {
                var profile = ServerProfile(id: id, name: id, host: "127.0.0.1", user: manifest.user,
                    sshPort: manifest.sshPorts[index], remotePort: manifest.entryPorts[index],
                    localPort: manifest.localPorts[index], autoReconnect: index == 0, identityFile: root + "/client")
                profile.useFixedEntry = true
                profile.fixedEntryHelperPath = manifest.helperPath
                profile.fixedEntryRuntimePath = manifest.runtimePaths[index]
                profiles[id] = profile
            }
            // Decode an actual old-style profile with no fixed-entry fields, then exercise its real SSH path.
            let legacyJSON: [String: Any] = ["id": "legacy", "name": "legacy", "host": "127.0.0.1", "user": manifest.user,
                "sshPort": manifest.sshPorts[1], "remotePort": manifest.legacyPort, "localPort": manifest.localPorts[1],
                "autoReconnect": true, "identityFile": root + "/client"]
            let legacy = try JSONDecoder().decode(ServerProfile.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
            guard !legacy.useFixedEntry else { throw FixtureFailure(description: "Old JSON unexpectedly enables fixed entry") }
            profiles[legacy.id] = legacy
            var missing = profiles["fixed-a"]!
            missing.id = "missing-helper"; missing.name = missing.id
            missing.fixedEntryHelperPath = manifest.missingHelperPath
            profiles[missing.id] = missing
            var wrong = profiles["fixed-a"]!
            wrong.id = "wrong-port"; wrong.name = wrong.id
            wrong.remotePort = manifest.legacyPort
            profiles[wrong.id] = wrong
            event("legacy-default", id: "legacy", fields: ["useFixedEntry": legacy.useFixedEntry])
            for id in ["fixed-a", "fixed-b", "legacy"] { start(id) }
            while !shouldExit {
                if ProcessInfo.processInfo.systemUptime - started >= 170 {
                    throw FixtureFailure(description: "Swift fixture exceeded its 170-second deadline")
                }
                try await pollActions()
                if !shouldExit { try await Task.sleep(nanoseconds: 50_000_000) }
            }
        } catch {
            failed = true
            event("error", fields: ["message": String(describing: error)])
        }
        await controller?.shutdown()
        let removed = directories.allSatisfy { !FileManager.default.fileExists(atPath: $0) }
        if !removed { failed = true }
        event("shutdown", fields: ["directories_removed": removed, "directory_count": directories.count])
        return failed ? 1 : 0
    }

    private func pollActions() async throws {
        if let bytes = try actionHandle.read(upToCount: 65_536), !bytes.isEmpty { pending.append(bytes) }
        guard pending.count <= 131_072 else { throw FixtureFailure(description: "Fixture action input is oversized") }
        while let newline = pending.firstIndex(of: 0x0a) {
            let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
            if line.isEmpty { continue }
            let action = try JSONDecoder().decode(Action.self, from: line)
            if ["sleep", "wake", "shutdown", "shutdown-controller"].contains(action.action) {
                guard action.id == nil || action.id == "all" else { throw FixtureFailure(description: "Invalid lifecycle target") }
                switch action.action {
                case "sleep": controller?.suspendForSleep()
                case "wake": controller?.resumeAfterWake()
                case "shutdown-controller": await controller?.shutdown()
                default: shouldExit = true
                }
                event(action.action == "shutdown" ? "shutdown-requested" : action.action)
                if shouldExit { break }
                continue
            }
            guard let id = action.id, profiles[id] != nil else { throw FixtureFailure(description: "Unknown fixture profile") }
            switch action.action {
            case "start": start(id)
            case "stop": controller?.stop(id: id); event("stop", id: id)
            default: throw FixtureFailure(description: "Unknown fixture action")
            }
        }
    }

    private func start(_ id: String) {
        guard let profile = profiles[id] else { return }
        event("start", id: id)
        controller?.start(profile)
    }

    private func event(_ type: String, id: String = "all", fields: [String: Any] = [:]) {
        var value = fields
        value["type"] = type; value["id"] = id
        value["elapsed"] = ProcessInfo.processInfo.systemUptime - started
        do {
            var line = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
            line.append(0x0a)
            try eventHandle.write(contentsOf: line)
        } catch { failed = true; shouldExit = true }
    }
}

@main
@MainActor
struct FixedEntryIntegrationRunner {
    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            fputs("Use scripts/check-fixed-entry.py --binary PATH --output REPORT with a disposable fixture.\n", stderr)
            exit(2)
        }
        do {
            let run = try FixtureRun(url: URL(fileURLWithPath: CommandLine.arguments[1]))
            exit(await run.run())
        } catch {
            fputs("Swift fixed-entry fixture initialization failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
