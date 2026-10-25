import Foundation
@testable import TunnelCore

@MainActor
enum Ping0Checks {
    static let checks: [(String, () async throws -> Void)] = [
        ("Ping0 static fields, nesting and original risk direction", fields),
        ("Ping0 missing values and official shared-user bands", missingValues),
        ("Ping0 rejects malformed fields and ambiguous result sections", invalidFields),
        ("Ping0 binds title and result IP while ignoring executable content", identityAndMarkup),
        ("Ping0 rejects challenges, changed markup and parser resource excess", changedPages),
        ("Ping0 HTTPS evidence and body limits", transport),
        ("Ping0 consent defaults, serialization and independent provider choices", consent),
        ("Ping0 safe fixed-host commands and encoded IP paths", commands),
        ("custom child stdout capture remains bounded with separate stderr", capture)
    ]

    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try condition() == false { throw Failure(description: message) }
    }
    private static func rejects(_ message: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw Failure(description: message)
    }

    nonisolated private static let ip = "203.0.113.12"
    private static func html(ip: String = ip, type: String = "家庭宽带 IP", risk: String = "23%",
                             shared: String? = "1 - 10 (极好)") -> String {
        let sharedRow = shared.map {
            "<div class='line line-usecount'><div class='content'><div class='usecountbar' usecount='\($0)'>\($0)</div></div></div>"
        } ?? ""
        return """
        <!doctype html><html><head><title>\(ip)-IP查询</title></head><body>
        <div class="info asninfo"><div class="content">
        <div class="line ip"><div class="content"><a href="https://ping0.cc/trace/\(ip)">trace</a></div></div>
        <div class="line line-iptype"><div class="content"><span class="label orange">\(type)</span></div></div>
        <div class="line line-risk"><div class="content"><div class="riskbar">
        <div class="riskitem"><span class="lab">100</span></div>
        <div class="riskitem riskcurrent"><span class="value">\(risk)</span><span class="lab">纯净</span></div>
        </div></div></div>\(sharedRow)</div></div></body></html>
        """
    }
    private static func response(_ html: String, marker: String = "assessment 200 200 0 1.250") -> CommandResult {
        .init(exitCode: 0, stdout: html + "\nTM_PING0_V1 \(marker)\n", stderr: "")
    }
    private static func parse(_ html: String, expected: String = ip) throws -> Ping0Assessment {
        try Ping0Probe.assessment(from: response(html), expectedIP: expected)
    }

    private static func fields() throws {
        let page = html(type: "IDC机房 IP</span><span class='label'>CloudFlare DNS IP")
        let result = try parse(page)
        try expect(result.ip == ip && result.ipType == "IDC机房 IP、CloudFlare DNS IP", "Result labels were truncated at nested divs")
        try expect(result.riskValue == 23 && result.sharedUsers == "1 - 10 (极好)", "Original provider fields changed")
        for score in [0, 15, 23, 70, 100] {
            let assessment = try parse(html(risk: "\(score)%"))
            try expect(assessment.riskValue == Double(score), "Risk must remain higher-is-riskier, not 100 minus the original")
        }
        let entity = try parse(html(type: "家庭宽带&nbsp;IP", risk: "23&#37;"))
        try expect(entity.ipType == "家庭宽带 IP" && entity.riskValue == 23, "HTML entities were not decoded")
    }

    private static func missingValues() throws {
        let result = try parse(html(type: "未知", risk: "--", shared: nil))
        try expect(result.ipType == nil && result.riskValue == nil && result.sharedUsers == nil, "Unknown values became false data")
        for shared in ["", "--", "未知", "暂无数据"] {
            try expect(try parse(html(shared: shared)).sharedUsers == nil, "Unavailable shared count became a numeric count")
        }
        for band in ["1 - 10 (极好)", "10-100(一般)", "100 - 1000 (风险)", "1000-10000 (高危)", "10000+ (极度风险)"] {
            try expect(try parse(html(shared: band)).sharedUsers == band, "Official shared-user band was not preserved")
        }
    }

    private static func invalidFields() throws {
        for risk in ["-1%", "101%", "nan%", "1e2%", "23", "23% extra"] {
            try rejects("Invalid risk value accepted") { _ = try parse(html(risk: risk)) }
        }
        for share in ["0", "5", "1-10000", "10000+ injected", String(repeating: "x", count: 65)] {
            try rejects("Unsupported shared count accepted") { _ = try parse(html(shared: share)) }
        }
        try rejects("Duplicate result panel accepted") { _ = try parse(html() + html()) }
        try rejects("Disagreeing shared-user attribute accepted") {
            _ = try parse(html().replacingOccurrences(of: "usecount='1 - 10 (极好)'", with: "usecount='10000+'"))
        }
        try rejects("Duplicate selected score accepted") {
            _ = try parse(html(risk: "23%</span><span class='value'>90%"))
        }
    }

    private static func identityAndMarkup() throws {
        try rejects("Wrong title IP accepted") { _ = try parse(html(ip: "203.0.113.13")) }
        try rejects("Wrong trace IP accepted") {
            _ = try parse(html().replacingOccurrences(of: "https://ping0.cc/trace/\(ip)", with: "https://ping0.cc/trace/203.0.113.13"))
        }
        try rejects("Third-party trace link accepted") {
            _ = try parse(html().replacingOccurrences(of: "https://ping0.cc/trace/", with: "https://ping0.cc.example/trace/"))
        }
        let forged = html(ip: "203.0.113.99", risk: "100%")
        for hidden in ["<!--\(forged)-->", "<script>\(forged)</script>", "<style>\(forged)</style>",
                       "<template><template>\(forged)</template>\(forged)</template>",
                       "<script>\(forged)</scriptfake>\(forged)</script>"] {
            let assessment = try parse(hidden + html())
            try expect(assessment.ip == ip && assessment.riskValue == 23, "Hidden markup altered visible evidence")
            try rejects("Hidden-only result accepted") { _ = try parse(hidden) }
        }
        let ipv6 = "2001:db8::1"
        try expect(try parse(html(ip: ipv6), expected: "2001:0DB8::1").ip == ipv6, "Canonical IPv6 binding failed")
    }

    private static func changedPages() throws {
        for page in ["<html><title>Just a moment...</title><body>Verify you are human</body></html>",
                     "<html><title>\(ip)-IP查询</title><body>验证码</body></html>",
                     html().replacingOccurrences(of: "line-risk", with: "new-risk").replacingOccurrences(of: "line-iptype", with: "new-type").replacingOccurrences(of: "line-usecount", with: "new-share"),
                     "<!-- unclosed" + html(),
                     String(repeating: "<div>", count: 130) + html() + String(repeating: "</div>", count: 130)] {
            try rejects("Challenge or unsupported page accepted") { _ = try parse(page) }
        }
    }

    private static func transport() throws {
        for marker in ["assessment 000 200 0 1", "assessment 200 403 0 1", "assessment 200 302 0 1",
                       "assessment 200 200 1 1", "trace 200 200 0 1", "assessment 200 200 0 nan",
                       "assessment 200 200 0 1 extra"] {
            try rejects("Invalid transport evidence accepted") {
                _ = try Ping0Probe.assessment(from: response(html(), marker: marker), expectedIP: ip)
            }
        }
        for bad in 0..<4 {
            var result = response(html())
            if bad == 0 { result.exitCode = 28 }
            if bad == 1 { result.timedOut = true }
            if bad == 2 { result.stdoutTruncated = true }
            if bad == 3 { result.stdout += "\nTM_PING0_V1 assessment 200 200 0 1\n" }
            try rejects("Failed or ambiguous response accepted") { _ = try Ping0Probe.assessment(from: result, expectedIP: ip) }
        }
        try rejects("Oversized body accepted") { _ = try parse(String(repeating: " ", count: Ping0Probe.bodyLimit) + html()) }
    }

    private static func consent() throws {
        let legacy = """
        {"id":"legacy","name":"Legacy","host":"server.example","user":"user",
        "sshPort":22,"remotePort":17892,"localPort":7890,"autoReconnect":true,"assessIPRisk":true}
        """
        let profile = try JSONDecoder().decode(ServerProfile.self, from: Data(legacy.utf8))
        try expect(!profile.assessPing0 && profile.assessIPRisk && !ServerProfile.draft().assessPing0, "Ping0 opt-in was silently enabled")
        let date = Date(timeIntervalSince1970: 1)
        let network = WebsiteCheckResult(target: .claudeNetwork, state: .passed, exitIP: ip)
        for ping0 in [false, true] {
            for netCoffee in [false, true] {
                var edited = profile
                edited.assessPing0 = ping0; edited.assessIPRisk = netCoffee
                let restored = try JSONDecoder().decode(ServerProfile.self, from: JSONEncoder().encode(edited))
                try expect(restored == edited, "Provider preferences did not persist independently")
                let plan = try Ping0AssessmentPlan.make(enabled: ping0, networkResult: network, remotePort: 17892, checkedAt: date)
                switch plan {
                case let .completed(result):
                    try expect(!ping0 && result.state == .skipped && result.ip == ip && result.checkedAt == date, "Disabled provider did not skip")
                case let .request(command, requestedIP):
                    try expect(ping0 && requestedIP == ip && command.contains("https://ping0.cc/ip/"), "Enabled provider lost request binding")
                }
            }
        }
        let failed = WebsiteCheckResult(target: .claudeNetwork, state: .failed, message: "HTTP 403", exitIP: ip)
        for enabled in [false, true] {
            guard case let .completed(result) = try Ping0AssessmentPlan.make(enabled: enabled, networkResult: failed, remotePort: 17892, checkedAt: date) else {
                throw Failure(description: "Failed trace generated a Ping0 request")
            }
            try expect(result.state == (enabled ? .failed : .skipped) && result.ip == nil, "Failed trace fabricated a current IP")
        }
        let result = Ping0CheckResult(state: .available, assessment: try parse(html()), ip: ip, checkedAt: date)
        let restored = try JSONDecoder().decode(Ping0CheckResult.self, from: JSONEncoder().encode(result))
        try expect(restored == result && TunnelStatus().ping0 == .init(), "Ping0 result serialization or reset failed")
    }

    private static func commands() throws {
        let command = try SSHCommands.ping0AssessmentCommand(port: 17892, ip: "2001:DB8::1")
        for required in ["curl -q", "--noproxy ''", "--proxy http://127.0.0.1:17892", "--proto '=https'",
                         "--max-filesize \(Ping0Probe.bodyLimit)", "--user-agent 'CATunnel/0.6.0'",
                         "TM_PING0_V1 assessment", "https://ping0.cc/ip/2001%3Adb8%3A%3A1"] {
            try expect(command.contains(required), "Missing safe command option: \(required)")
        }
        try expect(!command.contains("--insecure") && !command.contains("--location") && !command.contains("Authorization"), "Command bypassed trust or followed arbitrary redirects")
        for address in ["203.0.113.12; touch /tmp/unexpected", "$(id)", "https://example.org", "203.0.113.12/extra"] {
            try rejects("Unsafe IP entered shell command") { _ = try SSHCommands.ping0AssessmentCommand(port: 17892, ip: address) }
        }
        try rejects("Invalid proxy port accepted") { _ = try SSHCommands.ping0AssessmentCommand(port: 0, ip: ip) }
    }

    private static func capture() async throws {
        func run(count: Int, limit: Int) async throws -> CommandResult {
            let command = ChildCommand()
            return try await withCheckedThrowingContinuation { continuation in
                do {
                    try command.start(executable: "/usr/bin/awk", arguments: [
                        "BEGIN { for (i=0;i<\(count);i++) printf \"x\"; for (i=0;i<40000;i++) printf \"e\" > \"/dev/stderr\" }"
                    ], timeout: 5, stdoutLimit: limit) { continuation.resume(returning: $0) }
                } catch { continuation.resume(throwing: error) }
            }
        }
        let expanded = try await run(count: 40_000, limit: 65_536)
        try expect(expanded.exitCode == 0 && !expanded.stdoutTruncated && expanded.stdout.utf8.count == 40_000,
                   "Larger stdout capture truncated a valid page")
        try expect(expanded.stderr.utf8.count == 32_768, "Custom stdout size expanded stderr too")
        let bounded = try await run(count: 70_000, limit: 65_536)
        try expect(bounded.stdoutTruncated && bounded.stdout.utf8.count == 65_536, "Custom capture exceeded its configured bound")
        let capped = try await run(count: 1_100_000, limit: Int.max)
        try expect(capped.stdoutTruncated && capped.stdout.utf8.count == 1_048_576, "Custom capture escaped the absolute 1 MiB limit")
    }
}
