import Foundation
@testable import TunnelCore

private struct RenewalCheckFailure: Error {
    let message: String
}

@MainActor
enum FixedEntryRenewalChecks {
    static let checks: [(String, () async throws -> Void)] = [
        ("renewal deadlines use request start and leave lease safety margin", leaseDeadline),
        ("renewal attempts stay inside the last confirmed lease", boundedAttempts),
        ("only unknown control outcomes can retry an existing lease", errorClassification)
    ]

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw RenewalCheckFailure(message: message) }
    }

    private static func leaseDeadline() throws {
        let window = FixedEntryLeaseWindow(requestStartedAt: 100, leaseSeconds: 20)
        try require(window.deadline == 119, "Lease deadline did not include conservative safety margin")
        try require(window.deadline < 106 + 20, "A reply delayed by six seconds extended the confirmed lease")
        let short = FixedEntryLeaseWindow(requestStartedAt: 10, leaseSeconds: 0.2)
        try require(abs(short.deadline - 10.18) < 0.0001, "Short leases received an oversized safety margin")
    }

    private static func boundedAttempts() throws {
        let window = FixedEntryLeaseWindow(requestStartedAt: 100, leaseSeconds: 20)
        try require(window.requestTimeout(at: 106) == 6, "Healthy lease lost its normal control budget")
        try require(window.requestTimeout(at: 116) == 2.75, "Retry could overrun the confirmed lease")
        try require(window.requestTimeout(at: 118.3) == nil, "A new retry started without a useful safe budget")
        try require(window.requestTimeout(at: 119) == nil && window.requestTimeout(at: 120) == nil,
                    "An expired lease permitted a control retry")
        try require(window.deadline == 119, "Unknown outcomes changed the confirmed deadline")
    }

    private static func failure(_ result: CommandResult) throws -> FixedEntryError {
        do {
            _ = try FixedEntryProtocol.renewed(result)
        } catch let error as FixedEntryError {
            return error
        }
        throw RenewalCheckFailure(message: "Invalid renewal unexpectedly succeeded")
    }

    private static func errorClassification() throws {
        for code in ["health_unavailable", "control_timeout", "control_io_failed"] {
            let body = try JSONSerialization.data(withJSONObject: ["ok": false, "error": code])
            let error = try failure(.init(exitCode: 1, stdout: String(decoding: body, as: UTF8.self) + "\n", stderr: ""))
            try require(error.canRetryRenewal && error.failure.retryable, "A temporary unknown outcome lost bounded retry")
        }
        for code in ["health_failed", "stale_lease", "epoch_mismatch", "superseded", "stale_generation", "helper_unavailable"] {
            let body = try JSONSerialization.data(withJSONObject: ["ok": false, "error": code])
            let error = try failure(.init(exitCode: 1, stdout: String(decoding: body, as: UTF8.self) + "\n", stderr: ""))
            try require(!error.canRetryRenewal, "An invalid or superseded lease was preserved")
            let lateExit = try failure(.init(exitCode: 15, stdout: String(decoding: body, as: UTF8.self) + "\n", stderr: "", timedOut: true))
            try require(!lateExit.canRetryRenewal, "A timed-out process hid a complete lease rejection")
        }
        let timedOut = try failure(.init(exitCode: 15, stdout: "", stderr: "", timedOut: true))
        try require(timedOut.canRetryRenewal, "A lost control reply cannot retry before its existing deadline")
        let lateSuccess = try failure(.init(exitCode: 15, stdout: "{\"ok\":true,\"lease_seconds\":20}\n", stderr: "", timedOut: true))
        try require(lateSuccess.canRetryRenewal, "A timed-out success was trusted to extend the confirmed lease")
        let malformed = try failure(.init(exitCode: 0, stdout: "{}\n", stderr: ""))
        try require(!malformed.canRetryRenewal, "Malformed protocol data preserved a lease")
    }
}
