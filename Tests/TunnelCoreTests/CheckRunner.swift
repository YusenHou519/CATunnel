import Foundation
import Darwin
@testable import TunnelCore

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String,
                    file: StaticString = #filePath, line: UInt = #line) throws {
    if !condition() { throw CheckFailure(description: "\(message) (\(file):\(line))") }
}

private func expectThrows(_ message: String, _ operation: () throws -> Void) throws {
    do { try operation() }
    catch { return }
    throw CheckFailure(description: message)
}

@main
@MainActor
struct CheckRunner {
    static func main() async {
        let checks: [(String, () async throws -> Void)] = [
            ("portable example profiles and blank drafts", examples),
            ("server configuration round trip and versioning", configuration),
            ("startup connection preferences and legacy compatibility", startupPreferences),
            ("optional persistent forwarding recovery and legacy compatibility", persistentRecoveryPreferences),
            ("duplicate server identity and listener rejection", duplicateConfiguration),
            ("example profiles fail before connection startup", exampleStart),
            ("input validation and injection rejection", validation),
            ("isolated SSH master arguments", masterArguments),
            ("control-only probes without network fallback", probeArguments),
            ("exclusive loopback listener validation", listenerValidation),
            ("CONNECT, TLS and HTTP proxy evidence", proxyEvidence),
            ("website target commands and HTTPS redirects", websiteCommands),
            ("website rejection versus transport failure", websiteRestrictions),
            ("strict structured evidence and request duration", evidenceValidation),
            ("complete, partial and failed website aggregates", websiteAggregation),
            ("shared Claude trace network evidence and risk independence", claudeNetwork),
            ("transport failures and safe structured website logs", websiteEvidenceSafety),
            ("strict IPv4 and IPv6 identity and safe risk URLs", riskIPIdentity),
            ("Claude trace identity and transport validation", riskTrace),
            ("risk transport limits and HTTPS evidence", riskTransport),
            ("NetCoffee schema, original score and nullable flags", riskAssessment),
            ("risk response identity binding and invalid schema", riskSchemaRejection),
            ("evidence-bound CIDR cached scores and IPv6 prefix boundaries", riskCIDRCache),
            ("risk score labels and evidence-bounded conclusions", riskPresentation),
            ("risk progress model, Codable and reset", riskModelReset),
            ("optional risk consent gates third-party requests", RiskOptionChecks.run),
            ("permanent versus transient failures", failureClassification),
            ("bounded forwarding retries only after a confirmed connection", forwardingRetryPolicy),
            ("opted-in forwarding recovery continues with bounded delays", persistentForwardingRetryPolicy),
            ("credential-safe logs", safeLogs),
            ("private short socket directory and buffer lifetime", socketDirectory),
            ("owned child timeout and exit synchronization", childLifecycle),
            ("parallel owned probes terminate independently", parallelChildCleanup),
            ("response capture is bounded and reports truncation", boundedCapture),
            ("invalid start and idempotent stop", invalidStart)
        ] + SetupChecks.checks + Ping0Checks.checks + FixedEntryProfileChecks.checks
            + FixedEntryGatewayChecks.checks + FixedEntryCoreChecks.checks + FixedEntryInstallerChecks.checks
        var failures = 0
        for (name, check) in checks {
            do { try await check(); print("PASS: \(name)") }
            catch { failures += 1; print("FAIL: \(name): \(error)") }
        }
        print("\(checks.count - failures)/\(checks.count) checks passed")
        if failures > 0 { Darwin.exit(1) }
    }

    static func examples() throws {
        let draft = ServerProfile.draft()
        try expect(UUID(uuidString: draft.id) != nil && draft.id != ServerProfile.draft().id,
                   "Draft identity must be a fresh UUID")
        try expect(draft.name.isEmpty && draft.host.isEmpty && draft.user.isEmpty,
                   "A new profile must require user-provided connection details")
        try expect(draft.sshPort == 22 && draft.remotePort == 17892 && draft.localPort == 7890 && draft.autoReconnect,
                   "Draft port and reconnection defaults changed")
        try expectThrows("An empty draft was accepted as a configured server") { try draft.validate() }
        try expect(ServerProfile.examples.map(\.id) == ["example-a", "example-b"], "Example slot identities changed")
        try expect(ServerProfile.examples.map(\.name) == ["A", "B"], "Example labels changed")
        try expect(ServerProfile.examples.map(\.host) == ["server-a.example", "server-b.example"], "Defaults must use reserved example hosts")
        try expect(ServerProfile.examples.allSatisfy { $0.user == "user" }, "Defaults include a non-example username")
        let encoded = try JSONEncoder().encode(ServerProfile.examples)
        let decoded = try JSONDecoder().decode([ServerProfile].self, from: encoded)
        try expect(decoded == ServerProfile.examples, "Example profiles did not survive configuration serialization")
        for profile in ServerProfile.examples {
            try profile.validate()
            try expect(profile.sshPort == 22, "Default SSH port mismatch")
            try expect(profile.remotePort == 17892, "Default remote proxy port mismatch")
            try expect(profile.localPort == 7890, "Default local proxy port mismatch")
        }
    }

    static func configuration() throws {
        let empty = ServerConfiguration(profiles: [])
        let emptyData = try empty.encoded()
        let decodedEmpty = try ServerConfiguration.decode(emptyData)
        try expect(decodedEmpty.profiles.isEmpty, "Empty configuration did not round trip")
        let object = try JSONSerialization.jsonObject(with: emptyData) as? [String: Any]
        try expect(object?["version"] as? Int == 1 && (object?["profiles"] as? [Any])?.isEmpty == true,
                   "Configuration must use a versioned envelope")
        let profiles = (0..<12).map { index -> ServerProfile in
            var profile = ServerProfile.examples[0]
            profile.id = "fixture-\(index)"
            profile.host = "server-\(index).example"
            return profile
        }
        let configuration = ServerConfiguration(profiles: profiles)
        try configuration.validate()
        let data = try configuration.encoded()
        let decoded = try ServerConfiguration.decode(data)
        try expect(decoded.profiles == profiles, "More than two servers did not round trip")
        let legacy = try JSONEncoder().encode(profiles)
        let decodedLegacy = try ServerConfiguration.decode(legacy)
        try expect(decodedLegacy.profiles == profiles, "Legacy array could not be read")
        for invalid in [Data("{".utf8), Data("null".utf8), Data("{}".utf8),
                        Data("{\"version\":2,\"profiles\":[]}".utf8),
                        Data("{\"version\":1,\"profiles\":{}}".utf8)] {
            try expectThrows("Malformed or unsupported configuration was accepted") {
                _ = try ServerConfiguration.decode(invalid)
            }
        }
        var invalidProfile = profiles[0]
        invalidProfile.host = "-oProxyCommand=fixture"
        try expectThrows("Configuration accepted an unsafe profile") {
            try ServerConfiguration(profiles: [invalidProfile]).validate()
        }
    }

    static func startupPreferences() throws {
        try expect(!ServerProfile.draft().autoConnectOnLaunch &&
                   ServerProfile.examples.allSatisfy { !$0.autoConnectOnLaunch },
                   "New and example profiles must require opt-in before connecting at launch")
        let historicalProfile = """
        {"id":"legacy","name":"Legacy","host":"server.example","user":"user",
         "sshPort":22,"remotePort":17892,"localPort":7890,"autoReconnect":true}
        """
        let decodedProfile = try JSONDecoder().decode(ServerProfile.self, from: Data(historicalProfile.utf8))
        try expect(!decodedProfile.autoConnectOnLaunch && decodedProfile.autoReconnect,
                   "Loading a historical profile must not turn reconnection into startup opt-in")
        for historicalConfiguration in ["[\(historicalProfile)]",
                                        "{\"version\":1,\"profiles\":[\(historicalProfile)]}"] {
            let decoded = try ServerConfiguration.decode(Data(historicalConfiguration.utf8))
            try expect(decoded.profiles == [decodedProfile],
                       "Historical array or versioned configuration changed during loading")
            let saved = try decoded.encoded()
            let reloaded = try ServerConfiguration.decode(saved)
            try expect(reloaded.profiles == [decodedProfile],
                       "Saving a historical configuration changed its startup preference")
        }

        for autoConnect in [false, true] {
            for autoReconnect in [false, true] {
                let profile = ServerProfile(id: "startup", name: "Startup", host: "server.example", user: "user",
                                            sshPort: 22, remotePort: 17892, localPort: 7890,
                                            autoReconnect: autoReconnect, autoConnectOnLaunch: autoConnect)
                let encoded = try JSONEncoder().encode(profile)
                let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
                try expect(object?["autoConnectOnLaunch"] as? Bool == autoConnect,
                           "Startup preference was not explicitly persisted")
                let decoded = try JSONDecoder().decode(ServerProfile.self, from: encoded)
                try expect(decoded == profile && decoded.autoReconnect == autoReconnect &&
                           decoded.autoConnectOnLaunch == autoConnect,
                           "Startup opt-in and connection retry preferences must remain independent")
            }
        }
        let invalidType = historicalProfile.dropLast() + ",\"autoConnectOnLaunch\":\"true\"}"
        try expectThrows("Non-boolean startup preference was silently accepted") {
            _ = try JSONDecoder().decode(ServerProfile.self, from: Data(invalidType.utf8))
        }
    }

    static func duplicateConfiguration() throws {
        let first = ServerProfile.examples[0]
        var duplicateID = ServerProfile.examples[1]
        duplicateID.id = first.id
        try expectThrows("Duplicate ID was accepted") {
            try ServerConfiguration(profiles: [first, duplicateID]).validate()
        }
        var duplicateEndpoint = ServerProfile.examples[1]
        duplicateEndpoint.host = first.host.uppercased()
        duplicateEndpoint.user = "otheruser"
        try expectThrows("Case variation and another SSH user hid a listener conflict") {
            try ServerConfiguration(profiles: [first, duplicateEndpoint]).validate()
        }
        duplicateEndpoint.remotePort += 1
        try ServerConfiguration(profiles: [first, duplicateEndpoint]).validate()
        duplicateEndpoint.remotePort = first.remotePort
        duplicateEndpoint.sshPort += 1
        try ServerConfiguration(profiles: [first, duplicateEndpoint]).validate()
    }

    static func persistentRecoveryPreferences() throws {
        try expect(!ServerProfile.draft().keepRetryingForwardingFailure &&
                   ServerProfile.examples.allSatisfy { !$0.keepRetryingForwardingFailure },
                   "Persistent forwarding recovery must require opt-in")
        let legacy = """
        {"id":"legacy","name":"Legacy","host":"server.example","user":"user",
         "sshPort":22,"remotePort":17892,"localPort":7890,"autoReconnect":true}
        """
        for json in ["[\(legacy)]", "{\"version\":1,\"profiles\":[\(legacy)]}"] {
            let decoded = try ServerConfiguration.decode(Data(json.utf8))
            try expect(!decoded.profiles[0].keepRetryingForwardingFailure && decoded.profiles[0].autoReconnect,
                       "Legacy configurations must preserve bounded reconnection behavior")
            let roundTrip = try ServerConfiguration.decode(decoded.encoded())
            try expect(roundTrip == decoded, "Legacy configuration round trip changed preferences")
        }
        for enabled in [false, true] {
            for autoReconnect in [false, true] {
                var profile = ServerProfile.examples[0]
                profile.keepRetryingForwardingFailure = enabled
                profile.autoReconnect = autoReconnect
                let decoded = try JSONDecoder().decode(ServerProfile.self, from: JSONEncoder().encode(profile))
                try expect(decoded == profile, "Recovery preference did not persist independently")
            }
        }
        let invalid = legacy.dropLast() + ",\"keepRetryingForwardingFailure\":\"true\"}"
        try expectThrows("Non-boolean persistent recovery preference was accepted") {
            _ = try JSONDecoder().decode(ServerProfile.self, from: Data(invalid.utf8))
        }
    }

    static func exampleStart() async throws {
        let controller = TunnelController()
        var statuses: [(String, TunnelStatus)] = []
        controller.onEvent = { event in
            if case let .status(id, status) = event { statuses.append((id, status)) }
        }
        for profile in ServerProfile.examples {
            controller.start(profile)
            try expect(statuses.last?.0 == profile.id && statuses.last?.1.phase == .failed,
                       "Example profile entered connection startup")
            try expect(statuses.last?.1.message == ProfileValidationError.exampleHost.localizedDescription,
                       "Example profile lacks configuration guidance")
        }
        try expect(statuses.count == ServerProfile.examples.count, "Example startup emitted connection progress")
        await controller.shutdown()

        var profile = ServerProfile.examples[0]
        for hostname in ["EXAMPLE", "SERVER-A.EXAMPLE", "nested.server.example"] {
            profile.host = hostname
            try profile.validate()
            try expectThrows("Reserved example hostname was allowed to connect") {
                try profile.validateForConnection()
            }
        }
        // Check syntax and policy only: never connect to fixture addresses.
        for hostname in ["192.0.2.10", "server.example.com", "example.internal"] {
            profile.host = hostname
            try profile.validateForConnection()
        }
    }

    static func validation() throws {
        for host in ["-oProxyCommand=evil", "host;touch /tmp/x", "x$(whoami)", "192.0.2.999", "a..b", "[::1]", "a\nb"] {
            var profile = ServerProfile.examples[0]
            profile.host = host
            try expectThrows("Accepted unsafe host: \(host)") { try profile.validate() }
        }
        for user in ["-root", "root@other", "root;id", "root\n"] {
            var profile = ServerProfile.examples[0]
            profile.user = user
            try expectThrows("Accepted unsafe user") { try profile.validate() }
        }
        for port in [-1, 0, 65536] {
            var profile = ServerProfile.examples[0]
            profile.remotePort = port
            try expectThrows("Accepted invalid port") { try profile.validate() }
        }
    }

    static func masterArguments() throws {
        let arguments = SSHCommands.master(ServerProfile.examples[0], socket: "/tmp/tm.test/c")
        try expect(Array(arguments.prefix(2)) == ["-F", "/dev/null"], "Inherited SSH configuration must be ignored")
        for option in ["StrictHostKeyChecking=yes", "UpdateHostKeys=no", "ControlPersist=no", "ExitOnForwardFailure=yes", "-M"] {
            try expect(arguments.contains(option), "Missing SSH option: \(option)")
        }
        try expect(!arguments.contains("-f") && !arguments.contains("-g"), "Master must stay owned and local")
        let forwarding = arguments[arguments.firstIndex(of: "-R")! + 1]
        try expect(forwarding == "127.0.0.1:17892:127.0.0.1:7890", "Unexpected forwarding address")
    }

    static func probeArguments() throws {
        let arguments = SSHCommands.remote(ServerProfile.examples[0], socket: "/tmp/tm.test/c", command: "ss -H -ltn")
        for option in ["ProxyCommand=/usr/bin/false", "ClearAllForwardings=yes", "ControlMaster=no"] {
            try expect(arguments.contains(option), "Missing probe isolation: \(option)")
        }
        try expect(!arguments.contains("-R"), "Probe must not create forwarding")
        try expect(arguments[arguments.firstIndex(of: "-S")! + 1] == "/tmp/tm.test/c", "Probe socket mismatch")
    }

    static func listenerValidation() throws {
        let exact = "LISTEN 0 128 127.0.0.1:17892 0.0.0.0:*"
        try expect(SSHCommands.hasLoopbackListener(exact, port: 17892), "Exact listener rejected")
        for output in ["LISTEN 0 128 0.0.0.0:17892 0.0.0.0:*", "LISTEN 0 128 127.0.0.1:7890 0.0.0.0:*", "LISTEN 0 128 [::]:17892 [::]:*", "127.0.0.1:17892", exact + "\nLISTEN 0 128 0.0.0.0:17892 0.0.0.0:*"] {
            try expect(!SSHCommands.hasLoopbackListener(output, port: 17892), "Unsafe or unrelated listener accepted")
        }
    }

    static func proxyEvidence() throws {
        for target in [WebsiteTarget.openAI, .claudeAPI] {
            try expect(websiteResult(target, http: 401).state == .passed, "Expected unauthenticated API response rejected")
        }
        for target in WebsiteTarget.allCases {
            try expect(websiteResult(target, http: 200).state == .passed, "Successful HTTPS response rejected")
            try expect(websiteResult(target, connect: 0, http: 200).state == .failed, "Missing CONNECT accepted")
            try expect(websiteResult(target, connect: 403, http: 200).state == .failed, "Proxy rejection accepted as origin response")
            try expect(websiteResult(target, http: 200, tls: 60).state == .failed, "TLS verification failure accepted")
            try expect(websiteResult(target, http: 200, exitCode: 28).state == .failed, "Timed-out request accepted")
            try expect(websiteResult(target, http: 200, exitCode: 255).state == .failed, "SSH failure accepted")
            try expect(websiteResult(target, http: 200, timedOut: true).state == .failed, "Host timeout accepted")
        }
        try expect(websiteResult(.google, http: 204).state == .passed, "Google 204 rejected")
    }

    static func websiteResult(_ target: WebsiteTarget, connect: Int = 200, http: Int = 200,
                              tls: Int = 0, exitCode: Int32 = 0, timedOut: Bool = false) -> WebsiteCheckResult {
        if target == .claudeNetwork {
            return WebsiteProbe.evaluateNetwork(riskResponse("ip=203.0.113.12\nloc=US\n", payload: .trace,
                connect: connect, http: http, tls: tls, exitCode: exitCode, timedOut: timedOut))
        }
        let output = String(format: "TM_WEBSITE_V1 %@ %03d %03d %d 0.1234\n", target.rawValue, connect, http, tls)
        return WebsiteProbe.evaluate(.init(exitCode: exitCode, stdout: output, stderr: "", timedOut: timedOut), target: target)
    }

    static func websiteCommands() throws {
        try expect(WebsiteTarget.allCases == [.openAI, .claudeNetwork, .claudeAPI, .google], "Expected four ordered connectivity rows")
        try expect(TunnelStatus.stopped.websiteResults.map(\.target) == WebsiteTarget.allCases, "Default rows missing or unordered")
        try expect(WebsiteTarget.independentRequestTargets == [.openAI, .claudeAPI, .google], "Unexpected independent requests")
        for removedURL in ["https://claude.ai/", "https://ip.net.coffee/claude/"] {
            try expect(!WebsiteTarget.allCases.map(\.url).contains(removedURL), "Removed page remains a connectivity target")
        }
        try expect(WebsiteTarget.independentRequestTargets.count == WebsiteTarget.allCases.count - 1 && !WebsiteTarget.independentRequestTargets.contains(.claudeNetwork), "Claude trace would be requested twice")
        for target in WebsiteTarget.independentRequestTargets {
            let command = SSHCommands.proxyCommand(port: 17892, target: target)
            try expect(command.hasPrefix("curl -q "), "curl must ignore user configuration")
            for required in ["--noproxy ''", "--proxy http://127.0.0.1:17892", "--proto '=https'", "--proto-redir '=https'", "--location --max-redirs 4", "--output /dev/null", target.url, "%{time_total}"] {
                try expect(command.contains(required), "Missing website probe constraint: \(required)")
            }
            for forbidden in ["--insecure", "--fail", "--cookie", "--netrc", "Authorization", "x-api-key", "--location-trusted", "--dump-header"] {
                try expect(!command.contains(forbidden), "Unexpected credential or unsafe redirect option")
            }
        }
        try expect(SSHCommands.proxyCommand(port: 17892, target: .claudeAPI).contains("anthropic-version: 2023-06-01"), "Missing public Anthropic version header")
    }

    static func websiteRestrictions() throws {
        try expect(websiteResult(.google, http: 401).state == .restricted, "Non-API HTTP 401 must not pass")
        for target in WebsiteTarget.independentRequestTargets {
            for status in [403, 429] {
                let result = websiteResult(target, http: status)
                try expect(result.state == .restricted && result.httpStatus == status && result.message.contains(String(status)), "HTTP rejection lost its actual status")
            }
            for status in [404, 503] {
                let result = websiteResult(target, http: status)
                try expect(result.state == .failed && result.httpStatus == status && result.message.contains(String(status)), "HTTP error must remain distinct from access restrictions")
            }
        }
        try expect(websiteResult(.google, http: 302, exitCode: 47).state == .failed, "Redirect limit must fail the request")
    }

    static func evidenceValidation() throws {
        let valid = "TM_WEBSITE_V1 google 200 204 0 1.23456\n"
        let parsed = WebsiteProbe.evidence(from: "server banner\n" + valid, target: .google)
        try expect(WebsiteProbe.evidence(from: valid.replacingOccurrences(of: "\n", with: "\r\n"), target: .google) == parsed, "CRLF marker was rejected")
        try expect(parsed?.httpStatus == 204 && parsed?.elapsedMilliseconds == 1235, "Valid HTTP or duration was lost")
        for invalid in [valid + valid, valid + "extra", "TM_WEBSITE_V1 openAI 200 204 0 1.2", "TM_WEBSITE_V1 google 200 204 0 NaN", "TM_WEBSITE_V1 google 200 204 0 inf", "TM_WEBSITE_V1 google 200 204 0 -1", "TM_WEBSITE_V1 google 200 204 0 999999", "TM_WEBSITE_V1 google 200 999 0 1", "TM_WEBSITE_V1 google 200 204 -1 1", valid.trimmingCharacters(in: .newlines) + " extra", "no marker"] {
            try expect(WebsiteProbe.evidence(from: invalid, target: .google) == nil, "Malformed evidence accepted")
        }
        let malformed = WebsiteProbe.evaluate(.init(exitCode: 0, stdout: "bad", stderr: ""), target: .google)
        try expect(malformed.state == .failed && malformed.httpStatus == nil, "Malformed output reported success")
    }

    static func websiteAggregation() throws {
        let allPassed = WebsiteTarget.allCases.map { websiteResult($0) }
        let allFailed = WebsiteTarget.allCases.map { websiteResult($0, connect: 0) }
        let allRestricted = WebsiteTarget.independentRequestTargets.map { websiteResult($0, http: 403) }
        try expect(WebsiteProbe.aggregate(allPassed) == .passed, "All success must pass")
        try expect(WebsiteProbe.aggregate(allFailed) == .failed, "All transport failures must fail")
        try expect(WebsiteProbe.aggregate(allRestricted) == .partial, "Reachable restricted websites must not imply dead tunnel")
        try expect(WebsiteProbe.aggregate([allPassed[0], allFailed[1]]) == .partial, "Mixed transport results must be partial")
        try expect(WebsiteProbe.aggregate([allPassed[0], allRestricted[1]]) == .partial, "Restricted response must prevent aggregate success")
        try expect(WebsiteProbe.aggregate(TunnelStatus.stopped.websiteResults) == .unchecked, "Untested rows must stay unchecked")
        try expect(WebsiteProbe.aggregate([.init(target: .google, state: .checking)]) == .checking, "In-flight rows must stay checking")
    }

    static func riskResponse(_ body: String, payload: IPRiskPayload = .assessment,
                             connect: Int = 200, http: Int = 200, tls: Int = 0,
                             exitCode: Int32 = 0, timedOut: Bool = false, truncated: Bool = false) -> CommandResult {
        let marker = String(format: "\nTM_IPRISK_V1 %@ %03d %03d %d 0.123\n", payload.rawValue, connect, http, tls)
        return .init(exitCode: exitCode, stdout: body + marker, stderr: "", timedOut: timedOut, stdoutTruncated: truncated)
    }

    static func claudeNetwork() throws {
        let trace = riskResponse("h=claude.ai\nip=203.0.113.12\nloc=us\n", payload: .trace)
        let network = WebsiteProbe.evaluateNetwork(trace)
        try expect(network.target == .claudeNetwork && network.state == .passed && network.exitIP == "203.0.113.12" && network.countryCode == "US", "Shared trace did not establish network identity")
        try expect(network.httpStatus == 200 && network.elapsedMilliseconds == 123, "Shared trace transport evidence was lost")
        let missingIP = WebsiteProbe.evaluateNetwork(riskResponse("h=claude.ai\nloc=US\n", payload: .trace))
        try expect(missingIP.state == .failed && missingIP.exitIP == nil, "HTTP 200 without trace IP falsely passed")
        let generic = WebsiteProbe.evaluate(.init(exitCode: 0, stdout: "TM_WEBSITE_V1 claudeNetwork 200 200 0 1\n", stderr: ""), target: .claudeNetwork)
        try expect(generic.state == .failed, "Generic HTTP response replaced required trace proof")
        var status = TunnelStatus(websiteResults: WebsiteTarget.allCases.map { $0 == .claudeNetwork ? network : websiteResult($0) })
        status.ipRisk = .init(state: .failed, message: "评分查询失败", stage: .riskAssessment, ip: network.exitIP, countryCode: network.countryCode)
        try expect(status.websiteResults.first(where: { $0.target == .claudeNetwork }) == network && WebsiteProbe.aggregate(status.websiteResults) == .passed, "Score failure changed proven network reachability")
        let cleared = TunnelStatus.stopped.websiteResults.first(where: { $0.target == .claudeNetwork })
        try expect(cleared?.state == .unchecked && cleared?.exitIP == nil && cleared?.countryCode == nil, "Stop/reset retained old Claude exit identity")
    }

    static func websiteEvidenceSafety() throws {
        let headers = "HTTP/2 403\r\nSet-Cookie: session=header-secret\r\nAuthorization: Bearer header-token\r\n\r\n"
        func response(connect: Int = 200, tls: Int = 0, exitCode: Int32 = 0,
                      timedOut: Bool = false, truncated: Bool = false) -> CommandResult {
            let marker = String(format: "\nTM_WEBSITE_V1 google %03d 403 %d 0.1234\n", connect, tls)
            return .init(exitCode: exitCode, stdout: headers + marker, stderr: "Set-Cookie: session=stderr-secret",
                         timedOut: timedOut, stdoutTruncated: truncated)
        }
        for raw in [response(connect: 0), response(tls: 20), response(exitCode: 28), response(exitCode: 255),
                    response(timedOut: true), response(truncated: true)] {
            try expect(WebsiteProbe.evaluate(raw, target: .google).state == .failed, "Transport or truncation failure was masked by HTTP status")
        }
        let log = WebsiteProbe.publicEvidenceLog(response(), target: .google)
        for forbidden in ["Set-Cookie", "header-secret", "header-token", "stderr-secret", "Authorization"] {
            try expect(!log.contains(forbidden), "Raw response header or stderr leaked into public logs")
        }
        try expect(log.contains("HTTP=403") && log.contains("TLS=0"), "Safe log discarded relevant numeric evidence")
    }

    static func riskIPIdentity() throws {
        try expect(RiskIPAddress.canonical("203.0.113.12") == "203.0.113.12", "IPv4 rejected")
        try expect(RiskIPAddress.canonical("2001:0DB8:0000:0000:0000:0000:0000:0001") == "2001:db8::1", "IPv6 was not canonicalized")
        try expect(RiskIPAddress.encodedPath("2001:DB8::1") == "2001%3Adb8%3A%3A1", "IPv6 URL path was not encoded")
        for invalid in ["192.0.2.999", "127.1", "0127.0.0.1", "192.0.2.1;id", "192.0.2.1'", "$(id)", "[::1]", "fe80::1%en0", "2001::db8::1", "localhost", " 192.0.2.1", "192.0.2.1\n", "https://192.0.2.1"] {
            try expect(RiskIPAddress.canonical(invalid) == nil, "Unsafe IP was accepted: \(invalid)")
            try expectThrows("Unsafe IP was interpolated into risk command") {
                _ = try SSHCommands.ipRiskAssessmentCommand(port: 17892, ip: invalid)
            }
        }
        let commands = [SSHCommands.ipRiskTraceCommand(port: 17892),
                        try SSHCommands.ipRiskAssessmentCommand(port: 17892, ip: "2001:db8::1")]
        for command in commands {
            try expect(command.hasPrefix("curl -q "), "Risk curl inherited user config")
            for required in ["--proxy http://127.0.0.1:17892", "--noproxy ''", "--proto '=https'", "--proto-redir '=https'", "--max-filesize 16384", "--max-time 20"] {
                try expect(command.contains(required), "Risk request lacks transport constraint")
            }
            for forbidden in ["--insecure", "--cookie", "--netrc", "Authorization", "x-api-key", "secret", "mihomo"] {
                try expect(!command.contains(forbidden), "Risk request contains unwanted authentication or control access")
            }
        }
        try expect(commands[0].contains("https://claude.ai/cdn-cgi/trace"), "Wrong identity endpoint")
        try expect(commands[1].contains("https://ip.net.coffee/api/iprisk/2001%3Adb8%3A%3A1"), "Risk URL is not tied to validated IP")
    }

    static func riskTrace() throws {
        let parsed = try IPRiskProbe.trace(from: riskResponse("h=claude.ai\nip=203.0.113.12\nloc=us\n", payload: .trace))
        try expect(parsed.ip == "203.0.113.12" && parsed.countryCode == "US", "Trace IP or country lost")
        let unknownCountry = try IPRiskProbe.trace(from: riskResponse("ip=2001:0DB8::1\n", payload: .trace))
        try expect(unknownCountry.ip == "2001:db8::1" && unknownCountry.countryCode == nil, "Missing country was invented")
        for body in ["<html>error</html>", "loc=US\n", "ip=invalid\nloc=US", "ip=192.0.2.1\nip=198.51.100.2", "ip=192.0.2.1\nloc=US\nloc=GB", "ip=192.0.2.1\nloc=USA"] {
            try expectThrows("Malformed trace accepted") { _ = try IPRiskProbe.trace(from: riskResponse(body, payload: .trace)) }
        }
    }

    static func riskTransport() throws {
        let trace = "ip=203.0.113.12\nloc=US\n"
        for result in [riskResponse(trace, payload: .trace, connect: 403), riskResponse(trace, payload: .trace, tls: 20),
                       riskResponse(trace, payload: .trace, http: 403), riskResponse(trace, payload: .trace, http: 429),
                       riskResponse(trace, payload: .trace, http: 500), riskResponse(trace, payload: .trace, exitCode: 255),
                       riskResponse(trace, payload: .trace, timedOut: true), riskResponse(trace, payload: .trace, truncated: true),
                       riskResponse(String(repeating: "x", count: IPRiskProbe.bodyLimit + 1), payload: .trace)] {
            try expectThrows("Invalid risk transport accepted") { _ = try IPRiskProbe.body(from: result, payload: .trace) }
        }
        for output in [trace + "\nTM_IPRISK_V1 trace 200 200 0 NaN\n", trace + "\nTM_IPRISK_V1 trace 200 200 0 -1\n",
                       trace + "\nTM_IPRISK_V1 assessment 200 200 0 1\n", trace + "\nTM_IPRISK_V1 trace 200 200 0 1\nextra",
                       trace + "\nTM_IPRISK_V1 trace 200 200 0 1\n\nTM_IPRISK_V1 trace 200 200 0 1\n"] {
            try expectThrows("Bad risk marker accepted") {
                _ = try IPRiskProbe.body(from: .init(exitCode: 0, stdout: output, stderr: ""), payload: .trace)
            }
        }
        do {
            _ = try IPRiskProbe.body(from: riskResponse(trace, payload: .trace, http: 403), payload: .trace)
            throw CheckFailure(description: "HTTP rejection accepted")
        } catch let error as IPRiskProbeError {
            try expect(error.message.contains("HTTP 403"), "Actual HTTP rejection status was lost")
        }
    }

    static let sampleRiskJSON = """
    {"ip":"203.0.113.12","trust_score":89,"country":"United States","countryCode":"us","city":"","asn":64496,"asOrganization":"Example Network","company_type":"hosting","is_datacenter":true,"isResidential":false,"is_vpn":false,"is_proxy":false,"is_tor":false,"is_abuser":false,"is_crawler":false}
    """

    static func riskAssessment() throws {
        let assessment = try IPRiskProbe.assessment(from: riskResponse(sampleRiskJSON), expectedIP: "203.0.113.12")
        try expect(assessment.trustScore == 89 && assessment.scoreLabel == "纯净", "Original score was altered")
        try expect(assessment.asn == "64496" && assessment.countryCode == "US" && assessment.city == nil, "API schema normalization failed")
        try expect(assessment.isDatacenter == true && assessment.isResidential == false && assessment.isVPN == false, "Actual booleans were changed")
        try expect(assessment.ipType.contains("机房") && assessment.ipType.contains("hosting"), "Hosting evidence was omitted")
        let unknown = try IPRiskProbe.assessment(from: riskResponse("{\"ip\":\"203.0.113.12\",\"trust_score\":null,\"is_datacenter\":true,\"is_vpn\":null}"), expectedIP: "203.0.113.12")
        try expect(unknown.trustScore == nil && unknown.isVPN == nil && unknown.isProxy == nil, "Missing score or flags became zero/false")
        try expect(unknown.scoreLabel == "未提供评分", "Missing score was assigned a grade")
        let decimal = try IPRiskProbe.assessment(from: riskResponse("{\"ip\":\"203.0.113.12\",\"trust_score\":89.5,\"asn\":\"64496\"}"), expectedIP: "203.0.113.12")
        try expect(decimal.trustScore == 89.5 && decimal.asn == "64496", "Decimal score or string ASN was lost")
        let ipv6 = try IPRiskProbe.assessment(from: riskResponse("{\"ip\":\"2001:db8::1\",\"trust_score\":85}"), expectedIP: "2001:0DB8:0:0:0:0:0:1")
        try expect(ipv6.ip == "2001:db8::1", "Semantically equal IPv6 response was rejected")
    }

    static func riskSchemaRejection() throws {
        let prefix = "\"ip\":\"203.0.113.12\""
        let invalid = ["<html>error</html>", "[]", "{\"error\":\"rate limited\"}", "{\"ip\":\"203.0.113.12\"}",
                       "{\(prefix),\"trust_score\":true}", "{\(prefix),\"trust_score\":false}", "{\(prefix),\"trust_score\":\"89\"}",
                       "{\(prefix),\"trust_score\":-1}", "{\(prefix),\"trust_score\":100.1}",
                       "{\(prefix),\"trust_score\":89,\"is_vpn\":\"false\"}", "{\(prefix),\"trust_score\":89,\"is_vpn\":0}",
                       "{\(prefix),\"trust_score\":89,\"asn\":true}", "{\(prefix),\"trust_score\":89,\"asn\":1.5}",
                       "{\(prefix),\"trust_score\":89,\"asn\":-1}", "{\(prefix),\"trust_score\":89,\"asn\":4294967296}",
                       "{\(prefix),\"trust_score\":89,\"countryCode\":\"USA\"}", "{\(prefix),\"trust_score\":89,\"city\":[]}",
                       "{\(prefix),\"trust_score\":89,\"error\":\"failed\"}", "{\(prefix),\"trust_score\":89,\"success\":false}",
                       "{\(prefix),\"trust_score\":89,\"success\":\"false\"}", "{\(prefix),\"trust_score\":89,\"success\":1}"]
        for body in invalid {
            try expectThrows("Malformed or error JSON was accepted") {
                _ = try IPRiskProbe.assessment(from: riskResponse(body), expectedIP: "203.0.113.12")
            }
        }
        try expectThrows("Assessment for another IP was accepted") {
            _ = try IPRiskProbe.assessment(from: riskResponse(sampleRiskJSON), expectedIP: "203.0.113.13")
        }
    }

    static func riskPresentation() throws {
        for (score, label) in [(0.0, "可疑"), (24.9, "可疑"), (25.0, "中性"), (49.9, "中性"), (50.0, "良好"),
                               (79.9, "良好"), (80.0, "纯净"), (94.9, "纯净"), (95.0, "极度纯净"), (100.0, "极度纯净")] {
            let assessment = IPRiskAssessment(ip: "203.0.113.12", trustScore: score, countryCode: "HK", isDatacenter: true)
            try expect(assessment.trustScore == score && assessment.scoreLabel == label, "Score threshold or country-independent original value changed")
        }
        try expect(IPRiskAssessment(ip: "192.0.2.1", trustScore: 20, isDatacenter: true, isVPN: true).conclusion.contains("VPN"), "Explicit risk flag lost priority")
        try expect(IPRiskAssessment(ip: "192.0.2.1", trustScore: 20, isDatacenter: true).conclusion.contains("偏低"), "Low score was omitted")
        try expect(IPRiskAssessment(ip: "192.0.2.1", trustScore: 89, isDatacenter: true).conclusion.contains("机房"), "Datacenter qualification was omitted")
    }

    static func riskCIDRCache() throws {
        let body = "{\"ip\":\"203.0.113.216\",\"cidr\":\"203.0.113.0/24\",\"trust_score\":89,\"is_datacenter\":true}"
        let cached = try IPRiskProbe.assessment(from: riskResponse(body), expectedIP: "203.0.113.156")
        try expect(cached.ip == "203.0.113.216" && cached.cidr == "203.0.113.0/24" && cached.trustScore == 89,
                   "CIDR cache source identity or original score was overwritten")
        for expected in ["198.51.100.156", "2001:db8::1", "::ffff:203.0.113.156"] {
            try expectThrows("Cross-network or cross-family cache score accepted") {
                _ = try IPRiskProbe.assessment(from: riskResponse(body), expectedIP: expected)
            }
        }
        let outsideSource = "{\"ip\":\"198.51.100.216\",\"cidr\":\"203.0.113.0/24\",\"trust_score\":89}"
        try expectThrows("Cache source outside claimed CIDR accepted") {
            _ = try IPRiskProbe.assessment(from: riskResponse(outsideSource), expectedIP: "203.0.113.156")
        }
        for cidr in ["0.0.0.0/0", "::/0", "203.0.113.1/24", "203.0.113.0/33", "203.0.113.0/024", "203.0.113.0/-1", "203.0.113.0/24/1", "203.0.113.0/24 ", "2001:db8::1/65", "2001:db8::/129"] {
            try expect(RiskIPCIDR(cidr) == nil, "Invalid or overbroad CIDR accepted")
        }
        guard let ipv6 = RiskIPCIDR("2001:db8::/65") else { throw CheckFailure(description: "Valid IPv6 CIDR rejected") }
        try expect(ipv6.contains("2001:db8:0:0:7fff:ffff:ffff:ffff"), "Inside non-byte-aligned IPv6 boundary rejected")
        try expect(!ipv6.contains("2001:db8:0:0:8000::"), "Outside non-byte-aligned IPv6 boundary accepted")
        let v6Body = "{\"ip\":\"2001:db8:0:0:7fff::1\",\"cidr\":\"2001:db8::/65\",\"trust_score\":85}"
        let v6Cache = try IPRiskProbe.assessment(from: riskResponse(v6Body), expectedIP: "2001:0DB8::2")
        try expect(v6Cache.trustScore == 85, "Valid IPv6 cached assessment rejected")
        let encoded = try JSONEncoder().encode(cached)
        let decoded = try JSONDecoder().decode(IPRiskAssessment.self, from: encoded)
        try expect(decoded == cached, "CIDR evidence did not survive report encoding")
    }

    static func riskModelReset() throws {
        let assessment = try IPRiskProbe.assessment(from: riskResponse(sampleRiskJSON), expectedIP: "203.0.113.12")
        let result = IPRiskCheckResult(state: .available, message: "complete", stage: .riskAssessment,
            assessment: assessment, ip: assessment.ip, countryCode: "US", checkedAt: Date(timeIntervalSince1970: 1))
        let decoded = try JSONDecoder().decode(IPRiskCheckResult.self, from: JSONEncoder().encode(result))
        try expect(decoded == result, "Risk report Codable roundtrip lost data")
        try expect(TunnelStatus.stopped.ipRisk == IPRiskCheckResult(), "Stopped state retained prior risk evidence")
        let failed = IPRiskCheckResult(state: .failed, message: "score unavailable", stage: .riskAssessment, ip: assessment.ip, countryCode: "US")
        try expect(failed.ip == assessment.ip && failed.assessment == nil && failed.stage == .riskAssessment, "Assessment-stage failure discarded known exit identity")
    }

    static func failureClassification() throws {
        for error in ["Permission denied (publickey).", "Host key verification failed.", "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!", "Error: remote port forwarding failed for listen port 17892", "open failed: administratively prohibited"] {
            try expect(!SSHFailure.classify(error).retryable, "Permanent failure would loop: \(error)")
        }
        try expect(SSHFailure.classify("Connection reset by peer").retryable, "Network reset should permit retry")
        try expect(SSHFailure.classify("", timedOut: true).retryable, "Timeout should permit retry")
        for error in ["remote port forwarding failed for listen port 17892", "cannot listen to port", "bind: Address already in use"] {
            try expect(SSHFailure.classify(error).isForwardingFailure, "Forwarding failure lost its recovery category")
        }
        for error in ["Permission denied (publickey).", "Host key verification failed.", "open failed: administratively prohibited"] {
            let failure = SSHFailure.classify("remote port forwarding failed\n" + error)
            try expect(!failure.retryable && !failure.isForwardingFailure,
                       "Explicit security/policy rejection must take priority over forwarding failure")
        }
    }

    static func forwardingRetryPolicy() throws {
        let forwarding = SSHFailure.classify("remote port forwarding failed for listen port 17892")
        let network = SSHFailure.classify("Connection reset by peer")
        var policy = SSHReconnectPolicy()
        try expect(policy.retryDelay(after: forwarding) == nil,
                   "An initial port conflict must not trigger automatic forwarding retries")
        for delay in [3, 6, 12, 24, 48, 60, 60] {
            try expect(policy.retryDelay(after: network) == delay, "Ordinary network backoff changed")
        }
        try expect(policy.retryDelay(after: forwarding) == nil,
                   "Network retries alone must not enable forwarding recovery")

        policy.didConnect()
        try expect(policy.retryDelay(after: network) == 3, "Connection success must reset network backoff")
        for delay in [15, 30, 60, 60, 60] {
            try expect(policy.retryDelay(after: forwarding) == delay, "Unexpected bounded forwarding backoff")
            _ = policy.retryDelay(after: network)
        }
        try expect(policy.forwardingRetryCount == 5, "Forwarding retry budget was not counted independently")
        for _ in 0..<3 {
            try expect(policy.retryDelay(after: forwarding) == nil, "Exhausted forwarding retries must stop")
        }

        policy.didConnect()
        try expect(policy.retryDelay(after: forwarding) == 15, "A successful recovery must reset the forwarding budget")
        for error in ["Permission denied (publickey).", "Host key verification failed.",
                      "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!", "open failed: administratively prohibited"] {
            try expect(policy.retryDelay(after: SSHFailure.classify(error)) == nil,
                       "A previous connection must not bypass permanent failures")
        }
        var restarted = SSHReconnectPolicy()
        try expect(restarted.retryDelay(after: forwarding) == nil, "A fresh session must require its own successful connection")
    }

    static func persistentForwardingRetryPolicy() throws {
        let conflict = SSHFailure.classify("remote port forwarding failed for listen port 17892")
        var policy = SSHReconnectPolicy()
        try expect(policy.retryDelay(after: conflict, keepRetryingForwardingFailure: true) == nil,
                   "Opt-in must not enable recovery for an initial conflict")
        policy.didConnect()
        for delay in [15, 30, 60, 60, 60] {
            try expect(policy.retryDelay(after: conflict, keepRetryingForwardingFailure: true) == delay &&
                       !policy.isWaitingForForwardingRelease, "Opt-in changed the initial bounded backoff")
        }
        for _ in 0..<100 {
            try expect(policy.retryDelay(after: conflict, keepRetryingForwardingFailure: true) == 60 &&
                       policy.isWaitingForForwardingRelease, "Persistent recovery stopped or accelerated")
        }
        try expect(policy.forwardingRetryCount == 5, "Persistent retry counter must not grow without bound")
        try expect(policy.retryDelay(after: conflict, keepRetryingForwardingFailure: false) == nil &&
                   !policy.isWaitingForForwardingRelease, "Disabling persistent recovery must restore the limit")
        for error in ["Permission denied (publickey).", "Host key verification failed.",
                      "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!", "open failed: administratively prohibited"] {
            let failure = SSHFailure.classify("remote port forwarding failed\n" + error)
            try expect(policy.retryDelay(after: failure, keepRetryingForwardingFailure: true) == nil,
                       "Persistent recovery bypassed an explicit security or forwarding rejection")
        }
        try expect(policy.retryDelay(after: SSHFailure.classify("Connection reset by peer"),
                                    keepRetryingForwardingFailure: true) == 3,
                   "Persistent forwarding waits changed network failure backoff")
        policy.didConnect()
        try expect(!policy.isWaitingForForwardingRelease && policy.forwardingRetryCount == 0 &&
                   policy.retryDelay(after: conflict, keepRetryingForwardingFailure: true) == 15,
                   "Successful recovery must reset the next forwarding recovery cycle")
    }

    static func safeLogs() throws {
        let log = SafeLog.clean("Authorization: Bearer abc123\napi_key=abcdef\nhttps://alice:password@example.com\nsk-123456789abcdef\u{1b}")
        for secret in ["abc123", "abcdef", "alice:password", "sk-123456789abcdef", "\u{1b}"] {
            try expect(!log.contains(secret), "Sensitive text leaked")
        }
    }

    static func childLifecycle() async throws {
        let command = ChildCommand()
        let result: CommandResult = try await withCheckedThrowingContinuation { continuation in
            do {
                try command.start(executable: "/bin/sleep", arguments: ["10"], timeout: 0.05) {
                    continuation.resume(returning: $0)
                }
            } catch { continuation.resume(throwing: error) }
        }
        try expect(result.timedOut && !command.isRunning, "Timeout did not stop owned child")

        let restarting = ChildCommand()
        var completed = false
        try restarting.start(executable: "/bin/sleep", arguments: ["10"]) { _ in completed = true }
        restarting.stop()
        await restarting.waitForExit()
        try expect(completed && !restarting.isRunning, "Restart barrier resumed before child exit callback")
        await restarting.waitForExit()
    }

    static func socketDirectory() throws {
        for _ in 0..<8 {
            let directory = try SocketDirectory.create()
            defer { try? FileManager.default.removeItem(atPath: directory) }
            try expect(directory.hasPrefix("/tmp/tm.") && directory.count > "/tmp/tm.".count,
                       "mkdtemp returned an empty or unexpected path")
            try expect((directory + "/c").utf8.count < 100, "Control socket path exceeds Unix limit")
            let attributes = try FileManager.default.attributesOfItem(atPath: directory)
            try expect(attributes[.type] as? FileAttributeType == .typeDirectory, "Socket directory does not exist")
            try expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "Socket directory permissions are not private")
            try expect((attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(), "Socket directory owner mismatch")
        }
    }

    static func parallelChildCleanup() async throws {
        let children = (0..<5).map { _ in ChildCommand() }
        var completions = 0
        for child in children {
            try child.start(executable: "/bin/sleep", arguments: ["10"]) { _ in completions += 1 }
        }
        children[0].stop()
        await children[0].waitForExit()
        try expect(children.dropFirst().allSatisfy(\.isRunning), "Stopping one probe stopped unrelated probes")
        for child in children.dropFirst() { child.stop() }
        for child in children { await child.waitForExit() }
        try expect(completions == 5 && children.allSatisfy { !$0.isRunning }, "Parallel probe cleanup leaked a child")
    }

    static func boundedCapture() async throws {
        let command = ChildCommand()
        let result: CommandResult = try await withCheckedThrowingContinuation { continuation in
            do {
                try command.start(executable: "/usr/bin/printf", arguments: ["%s", String(repeating: "x", count: 40_000)]) {
                    continuation.resume(returning: $0)
                }
            } catch { continuation.resume(throwing: error) }
        }
        try expect(result.exitCode == 0 && result.stdoutTruncated && result.stdout.utf8.count <= 32_768, "Large response was not bounded or truncation not reported")
    }

    static func invalidStart() async throws {
        let controller = TunnelController()
        var statuses: [TunnelStatus] = []
        controller.onEvent = { event in
            if case let .status(_, status) = event { statuses.append(status) }
        }
        var profile = ServerProfile.examples[0]
        profile.remotePort = 0
        controller.start(profile)
        try expect(statuses.last?.phase == .failed, "Invalid start did not fail")
        controller.stop(id: profile.id)
        controller.stop(id: profile.id)
        try expect(statuses.last?.phase == .stopped, "Repeated stop changed terminal state")
        await controller.shutdown()
    }
}
