import Foundation
import CryptoKit

public struct FixedEntryInstallation: Equatable, Sendable {
    public let helperPath: String
    public let runtimePath: String
    public let port: Int
    public let reused: Bool

    public init(helperPath: String, runtimePath: String, port: Int, reused: Bool) {
        self.helperPath = helperPath
        self.runtimePath = runtimePath
        self.port = port
        self.reused = reused
    }
}

private struct FixedEntryInstallationError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Explicit installation owns separate SSH children; it never changes a profile or starts a tunnel.
@MainActor
public final class FixedEntryInstaller {
    typealias Executor = @MainActor (String, [String], TimeInterval, Data, Int) async -> CommandResult
    static let uploadLimit = 262_144
    private static let scriptLimit = 65_536
    private let helperScript: Data
    private let installerScript: String
    private let digest: String
    private let executionContext: SSHExecutionContext
    private let executor: Executor?
    private var activeCommand: ChildCommand?
    private var activeRun: UUID?
    private var cancellationRequested = false

    public convenience init(helperScript: Data, installerScript: Data) throws {
        try self.init(helperScript: helperScript, installerScript: installerScript,
                      executionContext: SSHExecutionContext())
    }

    init(helperScript: Data, installerScript: Data, executionContext: SSHExecutionContext = SSHExecutionContext(),
         executor: Executor? = nil) throws {
        guard Self.validScript(helperScript, limit: Self.uploadLimit),
              Self.validScript(installerScript, limit: Self.scriptLimit),
              let script = String(data: installerScript, encoding: .utf8) else {
            throw Self.error("应用内的固定入口安装文件缺失、损坏或过大；请重新构建应用。")
        }
        self.helperScript = helperScript
        self.installerScript = script
        digest = SHA256.hash(data: helperScript).map { String(format: "%02x", $0) }.joined()
        self.executionContext = executionContext
        self.executor = executor
    }

    public func cancel() {
        guard let activeRun else { return }
        cancel(run: activeRun)
    }

    private func cancel(run: UUID) {
        guard activeRun == run else { return }
        cancellationRequested = true
        activeCommand?.stop()
    }

    public func install(_ profile: ServerProfile) async throws -> FixedEntryInstallation {
        guard activeRun == nil else { throw Self.error("已有固定入口安装正在进行，请等待结束后再试。") }
        let run = UUID()
        activeRun = run
        cancellationRequested = Task.isCancelled
        defer { activeRun = nil; activeCommand = nil }
        return try await withTaskCancellationHandler {
            try await performInstallation(profile)
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancel(run: run) }
        }
    }

    private func requireNotCancelled() throws {
        guard !cancellationRequested, !Task.isCancelled else {
            throw Self.error("安装已取消；远端操作可能已经完成，可稍后重新点击安装检查状态。")
        }
    }

    private func performInstallation(_ profile: ServerProfile) async throws -> FixedEntryInstallation {
        try requireNotCancelled()
        var target = profile
        target.useFixedEntry = false
        try target.validateForConnection()
        let identity = SetupDiagnostics.identityReadiness(target)
        guard identity.state != .failed else { throw Self.error(identity.message) }
        let python = try target.resolvedFixedEntryPython()
        let command = [python, "-c", installerScript, "--port", String(target.remotePort), "--sha256", digest]
            .map(Self.quote).joined(separator: " ")
        let result = await execute(SSHCommands.setup(target, command: command), timeout: 45,
                                   input: helperScript, inputLimit: Self.uploadLimit)
        try requireNotCancelled()
        let installation = try decodeInstallation(result, expectedPort: target.remotePort)

        // A detached helper must remain alive after the installing SSH session exits.
        let control = [python, installation.helperPath, "control", "--runtime-dir", installation.runtimePath]
            .map(Self.quote).joined(separator: " ")
        let status = await execute(SSHCommands.setup(target, command: control), timeout: 15,
                                  input: try FixedEntryProtocol.input(.status), inputLimit: FixedEntryProtocol.bodyLimit)
        try requireNotCancelled()
        do {
            _ = try FixedEntryProtocol.status(status, expectedPort: target.remotePort)
        } catch {
            if let message = FixedEntryPythonFailure.message(status) {
                throw Self.error(message + " 安装已执行，但验证未通过；未启用固定入口，请修正 Python 路径后重试。")
            }
            throw Self.error("安装操作已结束，但无法确认远端程序持续运行；未启用固定入口。可重试安装检查状态。")
        }
        let readiness = try? JSONDecoder().decode(Readiness.self, from: Data(status.stdout.utf8))
        guard let readiness, readiness.activeGeneration == nil else {
            throw Self.error(Self.remoteError("active_entry"))
        }
        return installation
    }

    private func execute(_ arguments: [String], timeout: TimeInterval, input: Data, inputLimit: Int) async -> CommandResult {
        let arguments = executionContext.arguments(arguments)
        if let executor { return await executor("/usr/bin/ssh", arguments, timeout, input, inputLimit) }
        let command = ChildCommand()
        activeCommand = command
        defer { activeCommand = nil }
        return await withCheckedContinuation { continuation in
            do {
                try command.start(arguments: arguments, timeout: timeout, stdoutLimit: 16_384,
                                  stdin: input, stdinLimit: inputLimit) {
                    continuation.resume(returning: $0)
                }
            } catch {
                continuation.resume(returning: .init(exitCode: -1, stdout: "", stderr: ""))
            }
        }
    }

    private struct Response: Decodable {
        let version: Int
        let ok: Bool
        let error: String?
        let port: Int?
        let helperPath: String?
        let runtimePath: String?
        let sha256: String?
        let pid: Int?
        let reused: Bool?
        enum CodingKeys: String, CodingKey {
            case version, ok, error, port, sha256, pid, reused
            case helperPath = "helper_path", runtimePath = "runtime_path"
        }
    }

    private struct Readiness: Decodable {
        let activeGeneration: Int?
        enum CodingKeys: String, CodingKey { case activeGeneration = "active_generation" }
    }

    private func decodeInstallation(_ result: CommandResult, expectedPort: Int) throws -> FixedEntryInstallation {
        if result.timedOut {
            throw Self.error("安装连接超时；远端操作可能已经完成，可重试安装检查状态。")
        }
        if result.exitCode == 255 {
            throw Self.error(SSHFailure.classify(result.stderr).message + " 远端安装状态尚未确认，可重试检查。")
        }
        if let message = FixedEntryPythonFailure.message(result) {
            throw Self.error(message + " 安装程序尚未运行；请修正 Python 路径后重试。")
        }
        guard !result.stdoutTruncated, result.stdout.utf8.count <= 16_384,
              result.stdout.hasSuffix("\n"), !result.stdout.dropLast().contains("\n"),
              let response = try? JSONDecoder().decode(Response.self, from: Data(result.stdout.utf8)),
              response.version == 1 else { throw Self.invalidResponse }
        guard response.ok else { throw Self.error(Self.remoteError(response.error)) }
        guard result.exitCode == 0, response.error == nil,
              let port = response.port, port == expectedPort,
              let helper = response.helperPath, let runtime = response.runtimePath,
              Self.validPath(helper), Self.validPath(runtime), helper != runtime,
              response.sha256 == digest, let pid = response.pid, (1...Int(Int32.max)).contains(pid),
              let reused = response.reused else { throw Self.invalidResponse }
        return .init(helperPath: helper, runtimePath: runtime, port: port, reused: reused)
    }

    private static func validScript(_ data: Data, limit: Int) -> Bool {
        guard !data.isEmpty, data.count <= limit, !data.contains(0),
              let text = String(data: data, encoding: .utf8) else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path != "/" && path.utf8.count <= 4096 &&
            !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static var invalidResponse: FixedEntryInstallationError {
        error("远端安装结果无效或版本不兼容，未启用固定入口；远端操作可能已完成，请重试检查。")
    }

    private static func error(_ message: String) -> FixedEntryInstallationError { .init(message: message) }

    private static func remoteError(_ code: String?) -> String {
        switch code {
        case "python_unsupported": return "当前选择的远端 Python 不满足安装要求；请选择服务器上已有的 Python 3.9 或更高版本，并填写其绝对路径。应用不会升级系统 Python。"
        case "home_unsafe", "directory_unsafe", "file_unsafe", "path_too_long":
            return "远端用户目录或安装目录的路径、所有权或权限不安全；请检查后重试。"
        case "install_busy": return "远端已有安装正在进行，请稍后重试。"
        case "installation_unknown", "installation_mismatch", "helper_identity_mismatch":
            return "远端已有无法确认归属或版本不一致的安装；已保留现有文件和进程，请手动检查。"
        case "runtime_not_clean": return "远端运行目录有未确认的残留文件；已保留现场，请手动检查。"
        case "active_entry": return "固定入口正在被其他连接使用；未接管或停止该连接，也未启用此草稿。"
        case "port_in_use": return "服务器入口端口已被占用；安装不会关闭或替换现有监听，请选择空闲端口。"
        case "helper_unavailable", "start_failed": return "远端程序未能正常启动；未启用固定入口，请重试检查状态。"
        case "payload_too_large", "payload_invalid", "payload_hash_mismatch", "arguments_invalid":
            return "远端拒绝了安装文件或参数；请重新构建应用后重试。"
        case "interrupted": return "远端安装被中断，当前安装状态尚未确认；可稍后重试检查。"
        default: return "远端安装未完成或结果无法确认；未启用固定入口，请检查服务器权限后重试。"
        }
    }
}
