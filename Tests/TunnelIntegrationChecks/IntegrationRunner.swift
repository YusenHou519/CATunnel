import Foundation
import Darwin
@testable import TunnelCore

private struct IntegrationFailure: Error, CustomStringConvertible {
    let description: String
}

private struct Fixture: Decodable {
    let root: String
    let user: String
    let sshPorts: [Int]
    let localPorts: [Int]
    let remotePorts: [Int]
    let occupiedPort: Int
    let markers: [String]
}

private struct Check: Encodable {
    let name: String
    let passed: Bool
    let detail: String
}

@main
@MainActor
struct IntegrationRunner {
    static func main() async {
        guard CommandLine.arguments.count == 3 else {
            fputs("Use scripts/check-integration.sh to create an isolated SSH fixture.\n", stderr)
            exit(2)
        }
        do {
            let fixture = try JSONDecoder().decode(Fixture.self,
                from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            let checks = try IntegrationChecks(fixture)
            let success = await checks.run()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(checks.results).write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
            exit(success ? 0 : 1)
        } catch {
            fputs("Integration fixture error: \(error)\n", stderr)
            exit(1)
        }
    }
}

@MainActor
private final class IntegrationChecks {
    let fixture: Fixture
    var results: [Check] = []
    private var controllers: [TunnelController] = []
    private var statuses: [String: TunnelStatus] = [:]
    private var phases: [String: [TunnelPhase]] = [:]
    private var directories: [String] = []

    init(_ fixture: Fixture) throws {
        guard let canonicalTemporaryRoot = Darwin.realpath(NSTemporaryDirectory(), nil) else {
            throw IntegrationFailure(description: "Unable to resolve the private temporary directory")
        }
        let temporaryRoot = String(cString: canonicalTemporaryRoot)
        Darwin.free(canonicalTemporaryRoot)
        guard fixture.sshPorts.count == 2, fixture.localPorts.count == 2,
              fixture.remotePorts.count == 2, fixture.markers.count == 2,
              fixture.root.hasPrefix(temporaryRoot + "/"), fixture.root.utf8.count + 16 < 104 else {
            throw IntegrationFailure(description: "Unexpected fixture manifest")
        }
        self.fixture = fixture
    }

    func run() async -> Bool {
        let controller = makeController()
        let a = profile("fixture-a", index: 0)
        let b = profile("fixture-b", index: 1)
        do {
            try await check("production SSH defaults remain unchanged") {
                let args = SSHCommands.master(a, socket: "/tmp/fixture-control")
                try self.require(SSHExecutionContext().arguments(args) == args, "Default context changed SSH arguments")
                try self.require(args.contains("StrictHostKeyChecking=yes") && args.contains("UpdateHostKeys=no"),
                                 "Strict host verification is required")
            }
            try await check("two independent SSH servers establish verified loopback forwards") {
                controller.start(a); controller.start(b)
                try await self.wait(a.id, phase: .connected)
                try await self.wait(b.id, phase: .connected)
                try self.require(self.directories.count == 2, "Connections must own separate control directories")
            }
            try await check("forward A transfers the exact fixture response") { try await self.transfer(a, marker: self.fixture.markers[0]) }
            try await check("forward B transfers the exact fixture response") { try await self.transfer(b, marker: self.fixture.markers[1]) }

            try await check("stopping A leaves B connected and forwarding") {
                controller.stop(id: a.id)
                try await self.waitForClosedPort(a.remotePort)
                try self.require(self.statuses[a.id]?.phase == .stopped, "A did not stop")
                try self.require(self.statuses[b.id]?.phase == .connected, "Stopping A changed B")
                try await self.transfer(b, marker: self.fixture.markers[1])
            }
            try await check("immediate stop then restart waits for owned SSH exit") {
                controller.start(a)
                controller.stop(id: a.id)
                controller.start(a)
                try await self.wait(a.id, phase: .connected)
                try await self.transfer(a, marker: self.fixture.markers[0])
            }
            try await check("occupied remote port fails without retrying or disturbing listeners") {
                var collision = self.profile("collision", index: 0)
                collision.remotePort = self.fixture.occupiedPort
                controller.start(collision)
                try await self.permanentFailure(collision.id)
                try self.require(self.statuses[collision.id]?.message.contains("端口") == true, "Missing port conflict diagnosis")
                try await self.transfer(a, marker: self.fixture.markers[0])
                try await self.transfer(b, marker: self.fixture.markers[1])
            }
            try await check("unauthorized key fails without retrying") {
                var rejected = self.profile("rejected-key", index: 0)
                rejected.identityFile = self.fixture.root + "/rejected_client"
                controller.start(rejected)
                try await self.permanentFailure(rejected.id)
                try self.require(self.statuses[rejected.id]?.message.contains("认证") == true, "Missing authentication diagnosis")
            }
            try await check("unknown host key is rejected without adding trust") {
                let untrusted = self.makeController(knownHosts: "empty_known_hosts")
                let profile = self.profile("unknown-host", index: 0)
                untrusted.start(profile)
                try await self.permanentFailure(profile.id)
                try self.require(self.statuses[profile.id]?.message.contains("主机密钥") == true, "Missing host key diagnosis")
            }
            try await check("changed host key is rejected without replacing trust") {
                let mismatched = self.makeController(knownHosts: "mismatched_known_hosts")
                let profile = self.profile("changed-host", index: 0)
                mismatched.start(profile)
                try await self.permanentFailure(profile.id)
                try self.require(self.statuses[profile.id]?.message.contains("主机密钥") == true, "Missing changed-host diagnosis")
            }
            try await check("lost owned master enters reconnect while the other server still forwards") {
                let socket = try await self.findMasterSocket(a)
                let result = await self.command("/usr/bin/ssh", self.context().arguments(
                    SSHCommands.base(a, socket: socket) + ["-o", "ProxyCommand=/usr/bin/false", "-O", "exit", "\(a.user)@127.0.0.1"]))
                try self.require(result.exitCode == 0, "Unable to exit this fixture's owned master")
                try await self.wait(a.id, phase: .reconnecting, timeout: 4)
                try await self.transfer(b, marker: self.fixture.markers[1])
            }
            try await check("automatic reconnect restores actual forwarding") {
                try await self.wait(a.id, phase: .connected, timeout: 16)
                try await self.transfer(a, marker: self.fixture.markers[0])
                try await self.transfer(b, marker: self.fixture.markers[1])
                try self.require(self.phases[a.id, default: []].filter { $0 == .connected }.count >= 3,
                                 "No new connected event after reconnect")
            }
            try await check("injected third-party failure leaves SSH connected and forwarding") {
                controller.testProxy(id: a.id)
                let deadline = Date().addingTimeInterval(15)
                while self.statuses[a.id]?.proxyCheck == .checking && Date() < deadline {
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                try self.require(self.statuses[a.id]?.phase == .connected, "Diagnostic failure disconnected SSH")
                try self.require(self.statuses[a.id]?.ipRisk.state == .failed, "Expected injected Net.Coffee failure")
                try self.require(self.statuses[a.id]?.proxyCheck == .partial, "Expected partial fixture diagnostics")
                try await self.transfer(a, marker: self.fixture.markers[0])
            }
            try await check("shutdown closes both forwards and all owned control directories") {
                for instance in self.controllers { await instance.shutdown() }
                try await self.waitForClosedPort(a.remotePort)
                try await self.waitForClosedPort(b.remotePort)
                try self.require(self.directories.allSatisfy { !FileManager.default.fileExists(atPath: $0) },
                                 "Owned SSH control directories remain after shutdown")
            }
        } catch {
            // Every exit path waits for the same owned children as the real app.
        }
        for controller in controllers { await controller.shutdown() }
        let passed = !results.isEmpty && results.allSatisfy(\.passed)
        print("\(results.filter(\.passed).count)/\(results.count) real SSH integration checks passed")
        return passed
    }

    private func context(knownHosts: String = "known_hosts") -> SSHExecutionContext {
        SSHExecutionContext(knownHostsFile: fixture.root + "/" + knownHosts,
            listenerCommand: { port in
                // The fixture runs macOS sshd. Query actual sockets with lsof and
                // normalize to the Linux ss columns consumed by the application.
                "/usr/sbin/lsof -nP -a -iTCP:\(port) -sTCP:LISTEN -Fn | /usr/bin/awk '/^n/ {print \"LISTEN 0 0 \" substr($0, 2) \" 0.0.0.0:*\"}'"
            }, makeSocketDirectory: { [unowned self] in
                var template = Array((self.fixture.root + "/ctl.XXXXXXXX").utf8CString)
                let directory = try template.withUnsafeMutableBufferPointer { buffer -> String in
                    guard let address = buffer.baseAddress, let path = Darwin.mkdtemp(address) else {
                        throw IntegrationFailure(description: "Unable to create private fixture control directory")
                    }
                    return String(cString: path)
                }
                self.directories.append(directory)
                return directory
            })
    }

    private func makeController(knownHosts: String = "known_hosts") -> TunnelController {
        let controller = TunnelController(executionContext: context(knownHosts: knownHosts))
        controller.onEvent = { [weak self] event in
            if case let .status(id, status) = event {
                self?.statuses[id] = status
                self?.phases[id, default: []].append(status.phase)
            }
        }
        controllers.append(controller)
        return controller
    }

    private func profile(_ id: String, index: Int) -> ServerProfile {
        ServerProfile(id: id, name: id, host: "127.0.0.1", user: fixture.user,
                      sshPort: fixture.sshPorts[index], remotePort: fixture.remotePorts[index],
                      localPort: fixture.localPorts[index], autoReconnect: true,
                      identityFile: fixture.root + "/client", assessIPRisk: index == 0)
    }

    private func check(_ name: String, _ body: () async throws -> Void) async throws {
        do {
            try await body()
            results.append(Check(name: name, passed: true, detail: "passed"))
            print("PASS: \(name)")
        } catch {
            let message = String(describing: error)
            results.append(Check(name: name, passed: false, detail: message))
            print("FAIL: \(name): \(message)")
            throw error
        }
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw IntegrationFailure(description: message) }
    }

    private func wait(_ id: String, phase: TunnelPhase, timeout: TimeInterval = 15) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if statuses[id]?.phase == phase { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw IntegrationFailure(description: "Expected \(phase.rawValue) for \(id); got \(statuses[id]?.phase.rawValue ?? "none"): \(statuses[id]?.message ?? "")")
    }

    private func permanentFailure(_ id: String) async throws {
        try await wait(id, phase: .failed)
        try await Task.sleep(nanoseconds: 3_300_000_000)
        try require(statuses[id]?.phase == .failed && !phases[id, default: []].contains(.reconnecting),
                    "Permanent failure retried")
    }

    private func transfer(_ profile: ServerProfile, marker: String) async throws {
        let result = await command("/usr/bin/curl", ["-q", "--silent", "--show-error", "--noproxy", "*",
            "--max-time", "3", "--fail", "http://127.0.0.1:\(profile.remotePort)/fixture"])
        try require(result.exitCode == 0 && result.stdout == marker, "Forwarded fixture response did not match for \(profile.id)")
    }

    private func waitForClosedPort(_ port: Int) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let result = await command("/usr/bin/nc", ["-z", "-G", "1", "127.0.0.1", String(port)])
            if result.exitCode != 0 { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw IntegrationFailure(description: "Owned forwarding port remained open")
    }

    private func findMasterSocket(_ profile: ServerProfile) async throws -> String {
        // Probe only paths created by this test; never discover user SSH sockets.
        for directory in directories.reversed() where FileManager.default.fileExists(atPath: directory + "/c") {
            let socket = directory + "/c"
            let check = await command("/usr/bin/ssh", context().arguments(SSHCommands.check(profile, socket: socket)))
            if check.exitCode == 0 {
                let forwarded = await command("/usr/bin/ssh", context().arguments(SSHCommands.remote(profile, socket: socket,
                    command: "printf '%s' \"$SSH_CONNECTION\"")))
                // Control requests alone do not validate the requested target.
                // The remote environment identifies the actual server port.
                if forwarded.exitCode == 0, let serverPort = forwarded.stdout.split(separator: " ").last,
                   String(serverPort) == String(profile.sshPort) { return socket }
            }
        }
        throw IntegrationFailure(description: "No owned master control socket found")
    }

    private func command(_ executable: String, _ arguments: [String]) async -> CommandResult {
        let command = ChildCommand()
        return await withCheckedContinuation { continuation in
            do {
                try command.start(executable: executable, arguments: arguments, timeout: 8) { result in
                    withExtendedLifetime(command) { continuation.resume(returning: result) }
                }
            } catch {
                continuation.resume(returning: .init(exitCode: 255, stdout: "", stderr: error.localizedDescription))
            }
        }
    }
}
