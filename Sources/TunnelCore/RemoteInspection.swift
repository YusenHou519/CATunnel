import Foundation

struct RemoteInspectionError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Owns only short-lived inspection children, never a tunnel or a forwarding master.
@MainActor
final class RemoteInspection {
    typealias Executor = @MainActor (String, [String], TimeInterval, Data?, Int) async -> CommandResult
    let context: SSHExecutionContext
    private let executor: Executor?
    private var activeCommand: ChildCommand?
    private var activeRun: UUID?
    private var cancelled = false

    init(context: SSHExecutionContext, executor: Executor?) {
        self.context = context
        self.executor = executor
    }

    func cancel() {
        guard let activeRun else { return }
        cancel(activeRun)
    }

    private func cancel(_ token: UUID) {
        guard activeRun == token else { return }
        cancelled = true
        activeCommand?.stop()
    }

    func requireActive() throws {
        guard !cancelled, !Task.isCancelled else {
            throw RemoteInspectionError(message: "检查已取消；现有连接和配置未改变。")
        }
    }

    func run<T>(_ operation: @MainActor () async throws -> T) async throws -> T {
        guard activeRun == nil else { throw RemoteInspectionError(message: "已有检查正在进行，请等待结束后再试。") }
        let token = UUID()
        activeRun = token
        cancelled = Task.isCancelled
        defer { activeRun = nil; activeCommand = nil }
        return try await withTaskCancellationHandler {
            try requireActive()
            let result = try await operation()
            try requireActive()
            return result
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(token) }
        }
    }

    func execute(_ executable: String, _ arguments: [String], timeout: TimeInterval,
                 input: Data? = nil, limit: Int = 16_384) async throws -> CommandResult {
        try requireActive()
        let arguments = executable == "/usr/bin/ssh" ? context.arguments(arguments) : arguments
        let result: CommandResult
        if let executor {
            result = await executor(executable, arguments, timeout, input, limit)
        } else {
            let command = ChildCommand()
            activeCommand = command
            defer { activeCommand = nil }
            result = await withCheckedContinuation { continuation in
                do {
                    try command.start(executable: executable, arguments: arguments, timeout: timeout,
                                      stdoutLimit: limit, stdin: input) { continuation.resume(returning: $0) }
                } catch {
                    continuation.resume(returning: .init(exitCode: -1, stdout: "", stderr: ""))
                }
            }
        }
        try requireActive()
        return result
    }

    func remote(_ profile: ServerProfile, command: String, timeout: TimeInterval = 12,
                input: Data? = nil, limit: Int = 16_384) async throws -> CommandResult {
        try await execute("/usr/bin/ssh", SSHCommands.setup(profile, command: command),
                          timeout: timeout, input: input, limit: limit)
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func validPath(_ value: String) -> Bool {
        value.hasPrefix("/") && value != "/" && value.utf8.count <= 4096 &&
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
