import Foundation

/// Internal dependencies let integration checks use a private SSH trust store and
/// an actual platform listener query without changing the application's defaults.
struct SSHExecutionContext {
    var knownHostsFile: String? = nil
    var listenerCommand: (Int) -> String = SSHCommands.listenerCommand
    var makeSocketDirectory: () throws -> String = SocketDirectory.create
    var sleepBeforeRetry: @MainActor (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func arguments(_ arguments: [String]) -> [String] {
        guard let knownHostsFile else { return arguments }
        return ["-o", "UserKnownHostsFile=\(knownHostsFile)",
                "-o", "GlobalKnownHostsFile=/dev/null", "-o", "IdentityAgent=none"] + arguments
    }
}
