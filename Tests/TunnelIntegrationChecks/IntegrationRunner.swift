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

private enum ListenerFault: String {
    case delayOnce = "delay-once"
    case unavailable
}

private enum DiagnosticFixtureFlag: String {
    case passingWebsites = "diagnostic-websites-pass"
    case ping0Failure = "ping0-fail"
    case ping0Delay = "ping0-delay"
}

private struct DiagnosticAudit: Decodable {
    let category: String
    let url: String
    let proxyPort: Int
    let executedPublicRequest: Bool

    enum CodingKeys: String, CodingKey {
        case category, url
        case proxyPort = "proxy_port"
        case executedPublicRequest = "executed_public_request"
    }
}

@MainActor
private final class RetryClock {
    private(set) var requestedDelays: [TimeInterval] = []
    private var paused = false
    private var permits = 0

    func pause() { paused = true; permits = 0 }
    func permitOne() { permits += 1 }
    func resume() { paused = false; permits = 0 }

    func sleep(_ seconds: TimeInterval) async throws {
        requestedDelays.append(seconds)
        while paused && permits == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        if paused { permits -= 1 }
        try await Task.sleep(nanoseconds: 200_000_000)
    }
}

private final class LoopbackPortOccupancy {
    private var descriptor: Int32

    init(port: Int) throws {
        descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw IntegrationFailure(description: "Unable to create fixture listener") }
        var reuse: Int32 = 1
        guard Darwin.fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              Darwin.setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse,
                                socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            close()
            throw IntegrationFailure(description: "Unable to configure fixture listener")
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(descriptor, 8) == 0 else {
            close()
            throw IntegrationFailure(description: "Unable to occupy this fixture's released loopback port")
        }
    }

    func close() {
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
    }

    deinit { close() }
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
    private let retryClock = RetryClock()

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
            try await check("listener timeout retries and restores forwarding without interrupting the other server") {
                controller.stop(id: a.id)
                try await self.waitForClosedPort(a.remotePort)
                let delayed = self.profile("listener-timeout-retry", index: 0)
                let fault = try self.injectListenerFault(.delayOnce, port: delayed.remotePort)
                let retryStart = self.retryClock.requestedDelays.count
                self.retryClock.pause()
                defer {
                    self.retryClock.resume()
                    try? FileManager.default.removeItem(at: fault)
                }
                controller.start(delayed)
                try await self.wait(delayed.id, phase: .reconnecting, timeout: 12)
                try self.require(self.statuses[delayed.id]?.message.contains("入口检查超时") == true,
                                 "Listener timeout did not retain its diagnosis")
                try self.require(!FileManager.default.fileExists(atPath: fault.path), "Listener delay was not consumed")
                let retryDeadline = Date().addingTimeInterval(2)
                while self.retryClock.requestedDelays.count == retryStart && Date() < retryDeadline {
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                try self.require(Array(self.retryClock.requestedDelays.dropFirst(retryStart)) == [3],
                                 "Listener timeout did not schedule a normal network retry")
                try self.require(self.statuses[b.id]?.phase == .connected, "Listener timeout changed the other server")
                try await self.transfer(b, marker: self.fixture.markers[1])
                self.retryClock.resume()
                try await self.wait(delayed.id, phase: .connected)
                try await self.transfer(delayed, marker: self.fixture.markers[0])
                try await self.transfer(b, marker: self.fixture.markers[1])
                controller.stop(id: delayed.id)
                try await self.waitForClosedPort(delayed.remotePort)
                controller.start(a)
                try await self.wait(a.id, phase: .connected)
            }
            try await check("listener timeout respects disabled automatic reconnect") {
                controller.stop(id: a.id)
                try await self.waitForClosedPort(a.remotePort)
                var delayed = self.profile("listener-timeout-no-retry", index: 0)
                delayed.autoReconnect = false
                let fault = try self.injectListenerFault(.delayOnce, port: delayed.remotePort)
                defer { try? FileManager.default.removeItem(at: fault) }
                let retryStart = self.retryClock.requestedDelays.count
                controller.start(delayed)
                try await self.permanentFailure(delayed.id)
                try self.require(self.statuses[delayed.id]?.message.contains("入口检查超时") == true,
                                 "Disabled reconnect lost the listener timeout diagnosis")
                try self.require(self.retryClock.requestedDelays.count == retryStart,
                                 "Disabled reconnect scheduled a retry")
                try await self.waitForClosedPort(delayed.remotePort)
                try await self.transfer(b, marker: self.fixture.markers[1])
                controller.stop(id: delayed.id)
                controller.start(a)
                try await self.wait(a.id, phase: .connected)
            }
            try await check("missing listener command remains a permanent failure") {
                controller.stop(id: a.id)
                try await self.waitForClosedPort(a.remotePort)
                let unavailable = self.profile("listener-unavailable", index: 0)
                let fault = try self.injectListenerFault(.unavailable, port: unavailable.remotePort)
                defer { try? FileManager.default.removeItem(at: fault) }
                let retryStart = self.retryClock.requestedDelays.count
                controller.start(unavailable)
                try await self.permanentFailure(unavailable.id)
                try self.require(self.statuses[unavailable.id]?.message.contains("ss 命令") == true,
                                 "Missing listener command lost its diagnosis")
                try self.require(self.retryClock.requestedDelays.count == retryStart,
                                 "Missing listener command scheduled a retry")
                try await self.waitForClosedPort(unavailable.remotePort)
                try await self.transfer(b, marker: self.fixture.markers[1])
                controller.stop(id: unavailable.id)
                try FileManager.default.removeItem(at: fault)
                controller.start(a)
                try await self.wait(a.id, phase: .connected)
            }
            try await check("occupied remote port fails without retrying or disturbing listeners") {
                var collision = self.profile("collision", index: 0)
                collision.remotePort = self.fixture.occupiedPort
                collision.keepRetryingForwardingFailure = true
                controller.start(collision)
                try await self.permanentFailure(collision.id)
                try self.require(self.statuses[collision.id]?.message.contains("端口") == true, "Missing port conflict diagnosis")
                try await self.transfer(a, marker: self.fixture.markers[0])
                try await self.transfer(b, marker: self.fixture.markers[1])
            }
            try await check("unauthorized key fails without retrying") {
                var rejected = self.profile("rejected-key", index: 0)
                rejected.identityFile = self.fixture.root + "/rejected_client"
                rejected.keepRetryingForwardingFailure = true
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
                self.retryClock.pause()
                try await self.exitOwnedMaster(a)
                try await self.wait(a.id, phase: .reconnecting, timeout: 4)
                try await self.transfer(b, marker: self.fixture.markers[1])
                self.retryClock.resume()
            }
            try await check("automatic reconnect restores actual forwarding") {
                try await self.wait(a.id, phase: .connected, timeout: 16)
                try await self.transfer(a, marker: self.fixture.markers[0])
                try await self.transfer(b, marker: self.fixture.markers[1])
                try self.require(self.phases[a.id, default: []].filter { $0 == .connected }.count >= 3,
                                 "No new connected event after reconnect")
            }
            try await check("temporary port conflict after disconnect retries and restores actual forwarding") {
                let occupied = try await self.holdForwardingRetry(a)
                defer { occupied.close(); self.retryClock.resume() }
                try await self.transfer(b, marker: self.fixture.markers[1])
                occupied.close()
                self.retryClock.resume()
                try await self.wait(a.id, phase: .connected)
                try await self.transfer(a, marker: self.fixture.markers[0])
                try await self.transfer(b, marker: self.fixture.markers[1])
            }
            try await check("a successful recovery resets the five-attempt port-conflict budget") {
                let retryStart = self.retryClock.requestedDelays.count
                let occupied = try await self.holdForwardingRetry(a)
                defer { occupied.close(); self.retryClock.resume() }
                self.retryClock.resume()
                try await self.wait(a.id, phase: .failed, timeout: 20)
                let expected: [TimeInterval] = [3, 15, 30, 60, 60, 60]
                try self.require(Array(self.retryClock.requestedDelays.dropFirst(retryStart)) == expected,
                                 "Expected one disconnect retry and exactly five bounded forwarding retries")
                let directoryCount = self.directories.count
                try await Task.sleep(nanoseconds: 500_000_000)
                try self.require(self.statuses[a.id]?.phase == .failed && self.directories.count == directoryCount,
                                 "Exhausted forwarding recovery kept reconnecting")
                try await self.transfer(b, marker: self.fixture.markers[1])
                occupied.close()
                controller.stop(id: a.id)
                controller.start(a)
                try await self.wait(a.id, phase: .connected)
                try await self.transfer(a, marker: self.fixture.markers[0])
            }
            try await check("manual stop cancels delayed port recovery without affecting the other tunnel") {
                let occupied = try await self.holdForwardingRetry(a)
                defer { occupied.close(); self.retryClock.resume() }
                let directoryCount = self.directories.count
                controller.stop(id: a.id)
                occupied.close()
                self.retryClock.resume()
                try await Task.sleep(nanoseconds: 500_000_000)
                try await self.waitForClosedPort(a.remotePort)
                try self.require(self.statuses[a.id]?.phase == .stopped && self.directories.count == directoryCount,
                                 "Stopped forwarding recovery launched another SSH child")
                try self.require(self.statuses[b.id]?.phase == .connected, "Stopping recovery changed the other tunnel")
                try await self.transfer(b, marker: self.fixture.markers[1])
                controller.start(a)
                try await self.wait(a.id, phase: .connected)
            }
            try await check("synchronous stop during recovery preparation prevents another owned SSH launch") {
                let occupied = try await self.holdForwardingRetry(a)
                let observer = controller.onEvent
                defer {
                    controller.onEvent = observer
                    occupied.close()
                    self.retryClock.resume()
                }
                let directoryCount = self.directories.count
                var stoppedDuringPreparation = false
                controller.onEvent = { [weak controller] event in
                    observer?(event)
                    if case let .status(id, status) = event,
                       id == a.id, status.phase == .checking, !stoppedDuringPreparation {
                        stoppedDuringPreparation = true
                        controller?.onEvent = observer
                        controller?.stop(id: a.id)
                    }
                }
                occupied.close()
                self.retryClock.resume()
                try await self.wait(a.id, phase: .stopped)
                try await Task.sleep(nanoseconds: 500_000_000)
                try await self.waitForClosedPort(a.remotePort)
                try self.require(stoppedDuringPreparation && self.statuses[a.id]?.phase == .stopped,
                                 "Recovery preparation did not honor synchronous stop")
                try self.require(self.directories.count == directoryCount,
                                 "Cancelled recovery preparation created a new control directory")
                let liveSockets = self.directories.filter { FileManager.default.fileExists(atPath: $0 + "/c") }
                try self.require(liveSockets.count == 1, "Cancelled recovery left an extra master control socket")
                try self.require(self.statuses[b.id]?.phase == .connected, "Synchronous stop changed the other tunnel")
                try await self.transfer(b, marker: self.fixture.markers[1])
                controller.onEvent = observer
                controller.start(a)
                try await self.wait(a.id, phase: .connected)
            }
            try await checkContinuousForwardingRecovery(controller, a: a, b: b)
            try await checkSleepRecovery(controller, a: a, b: b)
            try await check("injected third-party failure leaves SSH connected and forwarding") {
                let auditStart = try self.diagnosticAudit().count
                controller.testProxy(id: a.id)
                try await self.waitForDiagnostics(a.id)
                try self.require(self.statuses[a.id]?.phase == .connected, "Diagnostic failure disconnected SSH")
                try self.require(self.statuses[a.id]?.ipRisk.state == .failed, "Expected injected Net.Coffee failure")
                try self.require(self.statuses[a.id]?.ping0.state == .skipped, "Existing profile unexpectedly enabled Ping0")
                try self.require(self.statuses[a.id]?.proxyCheck == .partial, "Expected partial fixture diagnostics")
                try self.requireDiagnosticRequests(since: auditStart, port: a.remotePort, netCoffee: true, ping0: false)
                try await self.transfer(a, marker: self.fixture.markers[0])
            }
            let passingWebsites = try injectDiagnosticFlag(.passingWebsites)
            defer { try? FileManager.default.removeItem(at: passingWebsites) }
            try await check("legacy profile without Ping0 consent makes no risk-provider requests") {
                guard var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(b)) as? [String: Any] else {
                    throw IntegrationFailure(description: "Unable to construct a legacy profile fixture")
                }
                object.removeValue(forKey: "assessPing0")
                let legacy = try JSONDecoder().decode(ServerProfile.self,
                    from: JSONSerialization.data(withJSONObject: object))
                try self.require(!legacy.assessPing0 && !legacy.assessIPRisk, "Legacy profile acquired risk consent")
                try await self.restart(legacy, using: controller)
                let auditStart = try self.diagnosticAudit().count
                controller.testProxy(id: legacy.id)
                try await self.waitForDiagnostics(legacy.id)
                try self.requirePassedWebsites(legacy.id)
                try self.require(self.statuses[legacy.id]?.ping0.state == .skipped
                                 && self.statuses[legacy.id]?.ipRisk.state == .skipped,
                                 "Disabled provider results were not skipped")
                try self.requireDiagnosticRequests(since: auditStart, port: legacy.remotePort, netCoffee: false, ping0: false)
                try await self.transfer(a, marker: self.fixture.markers[0])
                try await self.transfer(legacy, marker: self.fixture.markers[1])
            }
            try await check("Ping0-only consent parses a controlled page without requesting Net.Coffee") {
                var ping0Only = a
                ping0Only.assessIPRisk = false
                ping0Only.assessPing0 = true
                try await self.restart(ping0Only, using: controller)
                let auditStart = try self.diagnosticAudit().count
                controller.testProxy(id: ping0Only.id)
                try await self.waitForDiagnostics(ping0Only.id)
                try self.requirePassedWebsites(ping0Only.id)
                try self.requirePing0Assessment(ping0Only.id)
                try self.require(self.statuses[ping0Only.id]?.ipRisk.state == .skipped,
                                 "Ping0 consent unexpectedly enabled Net.Coffee")
                try self.requireDiagnosticRequests(since: auditStart, port: ping0Only.remotePort, netCoffee: false, ping0: true)
                try await self.transfer(ping0Only, marker: self.fixture.markers[0])
                try await self.transfer(b, marker: self.fixture.markers[1])
            }
            try await check("both risk providers share one exit trace and retain independent results") {
                var both = a
                both.assessPing0 = true
                try await self.restart(both, using: controller)
                let auditStart = try self.diagnosticAudit().count
                controller.testProxy(id: both.id)
                try await self.waitForDiagnostics(both.id)
                try self.requirePassedWebsites(both.id)
                try self.requirePing0Assessment(both.id)
                try self.require(self.statuses[both.id]?.ipRisk.state == .failed,
                                 "Controlled Net.Coffee failure was not retained independently")
                try self.requireDiagnosticRequests(since: auditStart, port: both.remotePort, netCoffee: true, ping0: true)
                try await self.transfer(both, marker: self.fixture.markers[0])
            }
            try await check("Ping0 request failure preserves the four-site aggregate and actual forwarding") {
                var ping0Only = a
                ping0Only.assessIPRisk = false
                ping0Only.assessPing0 = true
                try await self.restart(ping0Only, using: controller)
                let failure = try self.injectDiagnosticFlag(.ping0Failure)
                defer { try? FileManager.default.removeItem(at: failure) }
                let auditStart = try self.diagnosticAudit().count
                controller.testProxy(id: ping0Only.id)
                try await self.waitForDiagnostics(ping0Only.id)
                try self.requirePassedWebsites(ping0Only.id)
                try self.require(self.statuses[ping0Only.id]?.ping0.state == .failed
                                 && self.statuses[ping0Only.id]?.ping0.assessment == nil,
                                 "Failed Ping0 response exposed an assessment")
                try self.requireDiagnosticRequests(since: auditStart, port: ping0Only.remotePort, netCoffee: false, ping0: true)
                try await self.transfer(ping0Only, marker: self.fixture.markers[0])
                try await self.transfer(b, marker: self.fixture.markers[1])
            }
            try await check("stopping delayed Ping0 cancels its result before restarting the same server ID") {
                var delayed = a
                delayed.assessIPRisk = false
                delayed.assessPing0 = true
                try await self.restart(delayed, using: controller)
                let delay = try self.injectDiagnosticFlag(.ping0Delay)
                let started = URL(fileURLWithPath: self.fixture.root).appendingPathComponent("ping0-delay-started")
                let observer = controller.onEvent
                defer {
                    controller.onEvent = observer
                    try? FileManager.default.removeItem(at: delay)
                    try? FileManager.default.removeItem(at: started)
                }
                let auditStart = try self.diagnosticAudit().count
                controller.testProxy(id: delayed.id)
                let deadline = Date().addingTimeInterval(6)
                while Date() < deadline {
                    let sites = self.statuses[delayed.id]?.websiteResults ?? []
                    if FileManager.default.fileExists(atPath: started.path), sites.count == 4,
                       sites.allSatisfy({ $0.state == .passed }) { break }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                let completedSites = self.statuses[delayed.id]?.websiteResults ?? []
                try self.require(FileManager.default.fileExists(atPath: started.path)
                                 && self.statuses[delayed.id]?.ping0.state == .checking
                                 && completedSites.count == 4 && completedSites.allSatisfy { $0.state == .passed },
                                 "Ping0 did not remain in flight before cancellation")
                try self.requireDiagnosticRequests(since: auditStart, port: delayed.remotePort, netCoffee: false, ping0: true)
                var sawStaleAssessment = false
                controller.onEvent = { event in
                    observer?(event)
                    if case let .status(id, status) = event, id == delayed.id, status.ping0.assessment != nil {
                        sawStaleAssessment = true
                    }
                }
                var replacement = a
                replacement.assessIPRisk = false
                replacement.assessPing0 = false
                try await self.restart(replacement, using: controller)
                try FileManager.default.removeItem(at: delay)
                let replacementAuditStart = try self.diagnosticAudit().count
                controller.testProxy(id: replacement.id)
                try await self.waitForDiagnostics(replacement.id)
                try self.requirePassedWebsites(replacement.id)
                try self.requireDiagnosticRequests(since: replacementAuditStart, port: replacement.remotePort,
                                                  netCoffee: false, ping0: false)
                let replacementStatus = self.statuses[replacement.id]
                try await Task.sleep(nanoseconds: 1_000_000_000)
                try self.require(!sawStaleAssessment && self.statuses[replacement.id] == replacementStatus
                                 && replacementStatus?.ping0.state == .skipped,
                                 "Cancelled Ping0 result modified the replacement session")
                try await self.transfer(replacement, marker: self.fixture.markers[0])
                try await self.transfer(b, marker: self.fixture.markers[1])
            }
            try await check("shutdown cancels delayed port recovery and closes all owned forwards and directories") {
                let occupied = try await self.holdForwardingRetry(a)
                defer { occupied.close(); self.retryClock.resume() }
                let directoryCount = self.directories.count
                for instance in self.controllers { await instance.shutdown() }
                occupied.close()
                self.retryClock.resume()
                try await Task.sleep(nanoseconds: 500_000_000)
                try await self.waitForClosedPort(a.remotePort)
                try await self.waitForClosedPort(b.remotePort)
                try self.require(self.directories.count == directoryCount, "Shutdown allowed another recovery attempt")
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

    private func checkContinuousForwardingRecovery(_ controller: TunnelController,
                                                  a: ServerProfile, b: ServerProfile) async throws {
        var persistent = a
        persistent.keepRetryingForwardingFailure = true
        try await check("opt-in forwarding recovery continues beyond five retries and restores actual forwarding") {
            try await self.restart(persistent, using: controller)
            let retryStart = self.retryClock.requestedDelays.count
            let phaseStart = self.phases[a.id, default: []].count
            let occupied = try await self.holdForwardingRetry(persistent)
            defer { occupied.close(); self.retryClock.resume() }
            try await self.advanceForwardingRetries(since: retryStart, to: 8)
            try self.require(Array(self.retryClock.requestedDelays.dropFirst(retryStart))
                             == [3, 15, 30, 60, 60, 60, 60, 60],
                             "Opt-in recovery did not retain the initial budget and continue at sixty seconds")
            try self.require(self.statuses[a.id]?.phase == .reconnecting
                             && !self.phases[a.id, default: []].dropFirst(phaseStart).contains(.failed),
                             "Opt-in forwarding recovery exhausted its retry budget")
            try await self.transfer(b, marker: self.fixture.markers[1])
            occupied.close()
            self.retryClock.resume()
            try await self.wait(a.id, phase: .connected)
            try await self.transfer(a, marker: self.fixture.markers[0])
            try await self.transfer(b, marker: self.fixture.markers[1])
        }
        try await check("manual stop cancels opt-in recovery after the original retry budget is exhausted") {
            let retryStart = self.retryClock.requestedDelays.count
            let occupied = try await self.holdForwardingRetry(persistent)
            defer { occupied.close(); self.retryClock.resume() }
            try await self.advanceForwardingRetries(since: retryStart, to: 8)
            let directoryCount = self.directories.count
            controller.stop(id: a.id)
            occupied.close()
            self.retryClock.resume()
            try await Task.sleep(nanoseconds: 500_000_000)
            try await self.waitForClosedPort(a.remotePort)
            try self.require(self.statuses[a.id]?.phase == .stopped && self.directories.count == directoryCount,
                             "Stopping opt-in recovery allowed another SSH launch")
            try self.require(self.statuses[b.id]?.phase == .connected, "Stopping opt-in recovery changed B")
            try await self.transfer(b, marker: self.fixture.markers[1])
            controller.start(a)
            try await self.wait(a.id, phase: .connected)
        }
    }

    private func checkSleepRecovery(_ controller: TunnelController,
                                   a: ServerProfile, b: ServerProfile) async throws {
        try await check("sleep closes owned forwards and duplicate wake restores each desired tunnel exactly once") {
            let connectedA = self.connectedCount(a.id)
            let connectedB = self.connectedCount(b.id)
            let directoryCount = self.directories.count
            let oldSockets = self.liveControlSockets()
            controller.suspendForSleep()
            controller.suspendForSleep()
            try await self.waitForClosedPort(a.remotePort)
            try await self.waitForClosedPort(b.remotePort)
            try await Task.sleep(nanoseconds: 300_000_000)
            try self.require(self.directories.count == directoryCount && self.liveControlSockets().isEmpty,
                             "Sleeping controller launched or retained an SSH master")
            controller.resumeAfterWake()
            controller.resumeAfterWake()
            try await self.wait(a.id, phase: .connected)
            try await self.wait(b.id, phase: .connected)
            try await self.transfer(a, marker: self.fixture.markers[0])
            try await self.transfer(b, marker: self.fixture.markers[1])
            try self.require(self.connectedCount(a.id) == connectedA + 1 && self.connectedCount(b.id) == connectedB + 1
                             && self.directories.count == directoryCount + 2 && self.liveControlSockets().count == 2,
                             "Duplicate sleep or wake created duplicate sessions")
            try self.require(oldSockets.allSatisfy { !FileManager.default.fileExists(atPath: $0) },
                             "A pre-sleep control socket survived the restored sessions")
        }
        try await check("wake retains successful-connection history when the old forwarding port remains occupied") {
            let retryStart = self.retryClock.requestedDelays.count
            self.retryClock.pause()
            defer { self.retryClock.resume() }
            controller.suspendForSleep()
            try await self.waitForClosedPort(a.remotePort)
            try await self.waitForClosedPort(b.remotePort)
            let occupied = try LoopbackPortOccupancy(port: a.remotePort)
            defer { occupied.close() }
            controller.resumeAfterWake()
            try await self.waitForRetryCount(retryStart + 1)
            try self.require(Array(self.retryClock.requestedDelays.dropFirst(retryStart)) == [15]
                             && self.statuses[a.id]?.phase == .reconnecting,
                             "Wake lost the previously connected state and treated a temporary conflict as permanent")
            try await self.wait(b.id, phase: .connected)
            try await self.transfer(b, marker: self.fixture.markers[1])
            occupied.close()
            self.retryClock.resume()
            try await self.wait(a.id, phase: .connected)
            try await self.transfer(a, marker: self.fixture.markers[0])
        }
        try await check("stop during sleep cancels wake intent and an explicit start cannot launch while sleeping") {
            controller.suspendForSleep()
            try await self.waitForClosedPort(a.remotePort)
            try await self.waitForClosedPort(b.remotePort)
            controller.stop(id: a.id)
            let directoryCount = self.directories.count
            let connectedA = self.connectedCount(a.id)
            controller.start(a)
            try await Task.sleep(nanoseconds: 300_000_000)
            try self.require(self.directories.count == directoryCount && self.liveControlSockets().isEmpty,
                             "Starting during sleep launched an SSH master")
            controller.stop(id: a.id)
            controller.resumeAfterWake()
            controller.resumeAfterWake()
            try await self.wait(b.id, phase: .connected)
            try await Task.sleep(nanoseconds: 300_000_000)
            try await self.waitForClosedPort(a.remotePort)
            try self.require(self.statuses[a.id]?.phase == .stopped && self.connectedCount(a.id) == connectedA
                             && self.directories.count == directoryCount + 1,
                             "Wake restarted a tunnel whose pending start had been cancelled")
            try await self.transfer(b, marker: self.fixture.markers[1])
            controller.start(a)
            try await self.wait(a.id, phase: .connected)
        }
        try await check("wake respects disabled automatic reconnect while restoring the other tunnel") {
            var manual = b
            manual.autoReconnect = false
            try await self.restart(manual, using: controller)
            let connectedB = self.connectedCount(b.id)
            let directoryCount = self.directories.count
            controller.suspendForSleep()
            try await self.waitForClosedPort(a.remotePort)
            try await self.waitForClosedPort(b.remotePort)
            controller.resumeAfterWake()
            try await self.wait(a.id, phase: .connected)
            try await Task.sleep(nanoseconds: 300_000_000)
            try await self.waitForClosedPort(b.remotePort)
            try self.require(self.statuses[b.id]?.phase == .stopped && self.connectedCount(b.id) == connectedB
                             && self.directories.count == directoryCount + 1,
                             "Wake launched a profile with automatic reconnect disabled")
            try await self.transfer(a, marker: self.fixture.markers[0])
            controller.start(b)
            try await self.wait(b.id, phase: .connected)
            try await self.transfer(b, marker: self.fixture.markers[1])
        }
        try await check("starting a manual-only profile during sleep does not queue a wake connection") {
            controller.stop(id: a.id)
            try await self.waitForClosedPort(a.remotePort)
            controller.suspendForSleep()
            try await self.waitForClosedPort(b.remotePort)
            var manual = a
            manual.autoReconnect = false
            let directoryCount = self.directories.count
            let connectedA = self.connectedCount(a.id)
            let connectedB = self.connectedCount(b.id)
            controller.start(manual)
            try await Task.sleep(nanoseconds: 300_000_000)
            try self.require(self.statuses[a.id]?.phase == .stopped && self.directories.count == directoryCount,
                             "A manual-only profile was queued or launched during sleep")
            controller.resumeAfterWake()
            try await self.wait(b.id, phase: .connected)
            try await Task.sleep(nanoseconds: 300_000_000)
            try await self.waitForClosedPort(a.remotePort)
            try self.require(self.statuses[a.id]?.phase == .stopped && self.connectedCount(a.id) == connectedA
                             && self.connectedCount(b.id) == connectedB + 1
                             && self.directories.count == directoryCount + 1,
                             "Wake started the manual-only profile or failed to restore B once")
            try await self.transfer(b, marker: self.fixture.markers[1])
            controller.start(a)
            try await self.wait(a.id, phase: .connected)
            try await self.transfer(a, marker: self.fixture.markers[0])
        }
        try await check("synchronous wake from the first suspension event restores every active tunnel exactly once") {
            let observer = controller.onEvent
            defer { controller.onEvent = observer }
            let directoryCount = self.directories.count
            let connectedA = self.connectedCount(a.id)
            let connectedB = self.connectedCount(b.id)
            let oldSockets = self.liveControlSockets()
            var wokeDuringSuspension = false
            controller.onEvent = { [weak controller] event in
                observer?(event)
                if case let .status(id, status) = event,
                   [a.id, b.id].contains(id), status.phase == .reconnecting, !wokeDuringSuspension {
                    wokeDuringSuspension = true
                    controller?.resumeAfterWake()
                }
            }
            controller.suspendForSleep()
            try self.require(wokeDuringSuspension, "The first suspension event did not synchronously request wake")
            try await self.wait(a.id, phase: .connected)
            try await self.wait(b.id, phase: .connected)
            controller.resumeAfterWake()
            try await Task.sleep(nanoseconds: 300_000_000)
            try self.require(self.connectedCount(a.id) == connectedA + 1 && self.connectedCount(b.id) == connectedB + 1
                             && self.directories.count == directoryCount + 2 && self.liveControlSockets().count == 2,
                             "Reentrant wake left a tunnel suspended or created duplicate sessions")
            try self.require(oldSockets.allSatisfy { !FileManager.default.fileExists(atPath: $0) },
                             "Reentrant wake retained a pre-sleep control socket")
            try await self.transfer(a, marker: self.fixture.markers[0])
            try await self.transfer(b, marker: self.fixture.markers[1])
        }
        try await check("synchronous wake publishes stopped for manual-only peers while restoring automatic peers") {
            let observer = controller.onEvent
            defer { controller.onEvent = observer }
            var exercisedDeferredStop = false
            // Exchange modes so the manual-only peer is tested on either side of the batch's event order.
            for (automatic, originalManual, marker) in [(a, b, self.fixture.markers[0]), (b, a, self.fixture.markers[1])] {
                var manual = originalManual
                manual.autoReconnect = false
                try await self.restart(manual, using: controller)
                let directoryCount = self.directories.count
                let connectedAutomatic = self.connectedCount(automatic.id)
                let connectedManual = self.connectedCount(manual.id)
                let manualID = manual.id
                var wokeDuringSuspension = false
                var sawManualStopped = false
                controller.onEvent = { [weak controller] event in
                    observer?(event)
                    if case let .status(id, status) = event {
                        if id == manualID && status.phase == .stopped { sawManualStopped = true }
                        if id == automatic.id && status.phase == .reconnecting && !wokeDuringSuspension {
                            wokeDuringSuspension = true
                            if !sawManualStopped { exercisedDeferredStop = true }
                            controller?.resumeAfterWake()
                        }
                    }
                }
                controller.suspendForSleep()
                try self.require(wokeDuringSuspension, "Mixed-mode suspension did not trigger synchronous wake")
                try await self.wait(automatic.id, phase: .connected)
                try await self.waitForClosedPort(manual.remotePort)
                controller.resumeAfterWake()
                try await Task.sleep(nanoseconds: 300_000_000)
                try self.require(sawManualStopped && self.statuses[manual.id]?.phase == .stopped
                                 && self.connectedCount(manual.id) == connectedManual,
                                 "The manual-only peer stopped internally without publishing its stopped state")
                try self.require(self.connectedCount(automatic.id) == connectedAutomatic + 1
                                 && self.directories.count == directoryCount + 1 && self.liveControlSockets().count == 1,
                                 "Mixed-mode wake duplicated or failed to restore the automatic peer")
                try await self.transfer(automatic, marker: marker)
                controller.onEvent = observer
                controller.start(originalManual)
                try await self.wait(originalManual.id, phase: .connected)
            }
            try self.require(exercisedDeferredStop, "Mixed-mode regression did not exercise wake before the peer's stopped event")
            try await self.transfer(a, marker: self.fixture.markers[0])
            try await self.transfer(b, marker: self.fixture.markers[1])
        }
        try await check("sleep during a delayed listener probe isolates its callbacks from the resumed session") {
            controller.stop(id: a.id)
            try await self.waitForClosedPort(a.remotePort)
            let fault = try self.injectListenerFault(.delayOnce, port: a.remotePort)
            defer { try? FileManager.default.removeItem(at: fault) }
            controller.start(a)
            let deadline = Date().addingTimeInterval(8)
            while FileManager.default.fileExists(atPath: fault.path) && Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            try self.require(!FileManager.default.fileExists(atPath: fault.path)
                             && self.statuses[a.id]?.phase == .connecting,
                             "Listener delay was not reached before suspending")
            let connectedA = self.connectedCount(a.id)
            let phaseStart = self.phases[a.id, default: []].count
            let directoryCount = self.directories.count
            let oldSockets = self.liveControlSockets()
            controller.suspendForSleep()
            controller.resumeAfterWake()
            controller.resumeAfterWake()
            try await self.wait(a.id, phase: .connected)
            try await self.wait(b.id, phase: .connected)
            try await Task.sleep(nanoseconds: 6_200_000_000)
            try self.require(self.connectedCount(a.id) == connectedA + 1
                             && !self.phases[a.id, default: []].dropFirst(phaseStart).contains(.failed)
                             && self.statuses[a.id]?.phase == .connected && self.directories.count == directoryCount + 2,
                             "An old listener result corrupted or relaunched the resumed session")
            try self.require(oldSockets.allSatisfy { !FileManager.default.fileExists(atPath: $0) },
                             "Immediate wake retained a pre-sleep master")
            try await self.transfer(a, marker: self.fixture.markers[0])
            try await self.transfer(b, marker: self.fixture.markers[1])
        }
        try await check("shutdown while suspended clears wake intent without disturbing a different controller") {
            controller.stop(id: a.id)
            try await self.waitForClosedPort(a.remotePort)
            let isolated = self.makeController()
            let suspended = self.profile("shutdown-during-sleep", index: 0)
            isolated.start(suspended)
            try await self.wait(suspended.id, phase: .connected)
            isolated.suspendForSleep()
            try await self.waitForClosedPort(suspended.remotePort)
            await isolated.shutdown()
            let directoryCount = self.directories.count
            let connected = self.connectedCount(suspended.id)
            isolated.resumeAfterWake()
            try await Task.sleep(nanoseconds: 500_000_000)
            try await self.waitForClosedPort(suspended.remotePort)
            try self.require(self.directories.count == directoryCount && self.connectedCount(suspended.id) == connected,
                             "Wake relaunched a shutdown controller")
            try self.require(self.statuses[b.id]?.phase == .connected, "Suspending another controller changed B")
            try await self.transfer(b, marker: self.fixture.markers[1])
            controller.start(a)
            try await self.wait(a.id, phase: .connected)
        }
    }

    private func connectedCount(_ id: String) -> Int {
        phases[id, default: []].filter { $0 == .connected }.count
    }

    private func liveControlSockets() -> [String] {
        directories.map { $0 + "/c" }.filter { FileManager.default.fileExists(atPath: $0) }
    }

    private func waitForRetryCount(_ count: Int) async throws {
        let deadline = Date().addingTimeInterval(10)
        while retryClock.requestedDelays.count < count && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try require(retryClock.requestedDelays.count == count, "Expected exactly \(count) recorded retry delays")
    }

    private func advanceForwardingRetries(since offset: Int, to count: Int) async throws {
        while retryClock.requestedDelays.count < offset + count {
            let nextCount = retryClock.requestedDelays.count + 1
            retryClock.permitOne()
            try await waitForRetryCount(nextCount)
        }
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
            }, sleepBeforeRetry: { [unowned self] delay in
                try await self.retryClock.sleep(delay)
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

    private func injectListenerFault(_ fault: ListenerFault, port: Int) throws -> URL {
        try require(fixture.remotePorts.contains(port), "Refused a listener fault outside the fixture")
        let url = URL(fileURLWithPath: fixture.root).appendingPathComponent("listener-\(fault.rawValue)-\(port)")
        try Data().write(to: url, options: .withoutOverwriting)
        return url
    }

    private func injectDiagnosticFlag(_ flag: DiagnosticFixtureFlag) throws -> URL {
        let url = URL(fileURLWithPath: fixture.root).appendingPathComponent(flag.rawValue)
        try Data().write(to: url, options: .withoutOverwriting)
        return url
    }

    private func diagnosticAudit() throws -> [DiagnosticAudit] {
        let url = URL(fileURLWithPath: fixture.root).appendingPathComponent("diagnostic-audit.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(DiagnosticAudit.self, from: Data($0.utf8))
        }
    }

    private func requireDiagnosticRequests(since offset: Int, port: Int, netCoffee: Bool, ping0: Bool) throws {
        let entries = Array(try diagnosticAudit().dropFirst(offset))
        var expected = ["https://api.openai.com/v1/models": 1,
                        "https://api.anthropic.com/v1/models": 1,
                        "https://www.google.com/generate_204": 1,
                        "https://claude.ai/cdn-cgi/trace": 1]
        if netCoffee { expected["https://ip.net.coffee/api/iprisk/192.0.2.1"] = 1 }
        if ping0 { expected["https://ping0.cc/ip/192.0.2.1"] = 1 }
        let actual = Dictionary(grouping: entries, by: \.url).mapValues { $0.count }
        try require(actual == expected, "Diagnostic requests did not match independent provider consent: \(actual)")
        try require(entries.allSatisfy { !$0.executedPublicRequest && $0.proxyPort == port },
                    "Diagnostic request escaped the controlled fixture proxy")
    }

    private func waitForDiagnostics(_ id: String) async throws {
        let deadline = Date().addingTimeInterval(15)
        while statuses[id]?.proxyCheck == .checking && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try require(statuses[id]?.proxyCheck != .checking && statuses[id]?.proxyCheck != .unchecked,
                    "Diagnostics did not finish for \(id)")
    }

    private func requirePassedWebsites(_ id: String) throws {
        let websites = statuses[id]?.websiteResults ?? []
        try require(statuses[id]?.phase == .connected && statuses[id]?.proxyCheck == .passed
                    && websites.count == 4 && websites.allSatisfy { $0.state == .passed },
                    "Risk-provider result changed the four-site aggregate or SSH state")
    }

    private func requirePing0Assessment(_ id: String) throws {
        let result = statuses[id]?.ping0
        try require(result?.state == .available && result?.assessment?.ip == "192.0.2.1"
                    && result?.assessment?.ipType == "家庭宽带 IP" && result?.assessment?.riskValue == 23
                    && result?.assessment?.sharedUsers == "1 - 10 (极好)",
                    "Ping0 did not parse the controlled IP, type, risk, and shared-user fields")
    }

    private func restart(_ profile: ServerProfile, using controller: TunnelController) async throws {
        controller.stop(id: profile.id)
        try await waitForClosedPort(profile.remotePort)
        controller.start(profile)
        try await wait(profile.id, phase: .connected)
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

    private func exitOwnedMaster(_ profile: ServerProfile) async throws {
        let socket = try await findMasterSocket(profile)
        let result = await command("/usr/bin/ssh", context().arguments(
            SSHCommands.base(profile, socket: socket) + ["-o", "ProxyCommand=/usr/bin/false", "-O", "exit", "\(profile.user)@127.0.0.1"]))
        try require(result.exitCode == 0, "Unable to exit this fixture's owned master")
    }

    private func holdForwardingRetry(_ profile: ServerProfile) async throws -> LoopbackPortOccupancy {
        try require(statuses[profile.id]?.phase == .connected, "Port recovery requires a previously verified connection")
        try require(fixture.remotePorts.contains(profile.remotePort), "Refused to occupy a non-fixture port")
        let retryStart = retryClock.requestedDelays.count
        retryClock.pause()
        try await exitOwnedMaster(profile)
        try await wait(profile.id, phase: .reconnecting, timeout: 4)
        try await waitForClosedPort(profile.remotePort)
        let occupied = try LoopbackPortOccupancy(port: profile.remotePort)
        retryClock.permitOne()
        let deadline = Date().addingTimeInterval(10)
        while retryClock.requestedDelays.count < retryStart + 2 && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try require(statuses[profile.id]?.phase == .reconnecting,
                    "Port conflict after disconnect did not enter bounded recovery")
        try require(Array(retryClock.requestedDelays.dropFirst(retryStart)) == [3, 15],
                    "Expected a normal disconnect delay followed by the first forwarding recovery delay")
        return occupied
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
