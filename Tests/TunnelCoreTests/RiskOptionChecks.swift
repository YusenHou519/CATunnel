import Foundation
@testable import TunnelCore

enum RiskOptionChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    static func run() throws {
        let date = Date(timeIntervalSince1970: 1)
        let network = WebsiteCheckResult(target: .claudeNetwork, state: .passed, message: "网络可达",
            httpStatus: 200, checkedAt: date, exitIP: "203.0.113.12", countryCode: "US")
        let disabled = try IPRiskAssessmentPlan.make(enabled: false, networkResult: network,
            remotePort: 17892, checkedAt: date)
        guard case let .completed(skipped) = disabled else {
            throw Failure(description: "Disabled assessment constructed a third-party request")
        }
        try expect(skipped.state == .skipped && skipped.assessment == nil && skipped.stage == nil,
                   "A disabled assessment fabricated a score or failed state")
        try expect(skipped.ip == network.exitIP && skipped.countryCode == network.countryCode && skipped.checkedAt == date,
                   "Skipping assessment discarded Claude exit identity")
        let reloaded = try JSONDecoder().decode(IPRiskCheckResult.self, from: JSONEncoder().encode(skipped))
        try expect(reloaded == skipped, "Skipped result failed serialization")

        var failedNetwork = network
        failedNetwork.state = .failed
        failedNetwork.message = "HTTP 403"
        for result in [network, failedNetwork] {
            var unsafe = result
            unsafe.exitIP = "203.0.113.12; unexpected"
            let plan = try IPRiskAssessmentPlan.make(enabled: false, networkResult: unsafe,
                remotePort: 17892, checkedAt: date)
            guard case let .completed(result) = plan else {
                throw Failure(description: "Disabled assessment reached request construction")
            }
            try expect(result.state == .skipped && result.assessment == nil,
                       "Disabled choice was changed by trace outcome")
        }
        let enabled = try IPRiskAssessmentPlan.make(enabled: true, networkResult: network,
            remotePort: 17892, checkedAt: date)
        guard case let .request(command, ip, country) = enabled else {
            throw Failure(description: "Explicitly enabled assessment did not produce a request")
        }
        try expect(command.contains("https://ip.net.coffee/api/iprisk/203.0.113.12")
            && command.contains("--proxy http://127.0.0.1:17892") && ip == network.exitIP && country == "US",
                   "Enabled request lost proxy route or trace IP binding")
        let failed = try IPRiskAssessmentPlan.make(enabled: true, networkResult: failedNetwork,
            remotePort: 17892, checkedAt: date)
        guard case let .completed(failure) = failed else {
            throw Failure(description: "Failed Claude trace still produced a risk request")
        }
        try expect(failure.state == .failed && failure.stage == .exitIP && failure.ip == nil,
                   "Enabled failed trace did not preserve the failure stage")
        let allPassed = WebsiteTarget.allCases.map { target in
            WebsiteCheckResult(target: target, state: .passed, message: "网络可达", checkedAt: date)
        }
        try expect(WebsiteProbe.aggregate(allPassed) == .passed,
                   "Optional assessment must not alter network aggregation")
    }
}
