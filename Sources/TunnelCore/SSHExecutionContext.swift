import Foundation

/// Internal dependencies let integration checks use a private SSH trust store and
/// an actual platform listener query without changing the application's defaults.
struct SSHExecutionContext {
    var knownHostsFile: String? = nil
    var listenerCommand: (Int) -> String = SSHCommands.listenerCommand
    var makeSocketDirectory: () throws -> String = SocketDirectory.create

    func arguments(_ arguments: [String]) -> [String] {
        guard let knownHostsFile else { return arguments }
        return ["-o", "UserKnownHostsFile=\(knownHostsFile)",
                "-o", "GlobalKnownHostsFile=/dev/null", "-o", "IdentityAgent=none"] + arguments
    }
}
