import Foundation
import Darwin

public enum SetupCheckState: String, Sendable {
    case passed, warning, failed, skipped
}

public struct SetupCheckItem: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var state: SetupCheckState
    public var message: String

    public init(id: String, title: String, state: SetupCheckState, message: String) {
        self.id = id; self.title = title; self.state = state; self.message = message
    }
}

/// Explicit setup checks never open a forward, reuse another SSH connection, or request an external website.
@MainActor
public final class SetupDiagnostics {
    typealias Executor = @MainActor (String, [String], TimeInterval) async -> CommandResult
    private let executor: Executor?
    private var activeCommand: ChildCommand?
    private var activeRun: UUID?
    private var cancellationRequested = false

    public init() { executor = nil }

    init(executor: @escaping Executor) { self.executor = executor }

    public func cancel() {
        guard let activeRun else { return }
        cancel(run: activeRun)
    }

    private func cancel(run: UUID) {
        guard activeRun == run else { return }
        cancellationRequested = true
        activeCommand?.stop()
    }

    public func run(_ profile: ServerProfile) async -> [SetupCheckItem] {
        guard activeRun == nil else { return Self.remaining(after: [], message: "已有检查正在进行。") }
        let token = UUID()
        activeRun = token
        cancellationRequested = Task.isCancelled
        defer { activeRun = nil; activeCommand = nil }
        return await withTaskCancellationHandler {
            await runChecks(profile)
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancel(run: token) }
        }
    }

    public static func terminalVerificationCommand(for profile: ServerProfile) throws -> String {
        try profile.validateForConnection()
        let args = ["/usr/bin/ssh", "-F", "/dev/null", "-S", "none",
                    "-o", "ControlMaster=no", "-o", "ClearAllForwardings=yes",
                    "-o", "StrictHostKeyChecking=ask", "-o", "UpdateHostKeys=no",
                    "-o", "CheckHostIP=no",
                    "-o", "PreferredAuthentications=publickey", "-o", "PasswordAuthentication=no",
                    "-o", "KbdInteractiveAuthentication=no", "-p", String(profile.sshPort)] +
            SSHCommands.identity(profile) + ["-T", "\(profile.user)@\(profile.host)", "true"]
        return args.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
    }

    private var isCancelled: Bool { cancellationRequested || Task.isCancelled }

    private func runChecks(_ profile: ServerProfile) async -> [SetupCheckItem] {
        guard !isCancelled else { return Self.remaining(after: [], message: "检查已取消。") }
        do { try profile.validateForConnection() }
        catch {
            return Self.remaining(after: [Self.item("ssh", .failed, error.localizedDescription)],
                                  message: "请先修正服务器配置。")
        }
        let identity = Self.identityReadiness(profile)
        let local = await execute("/usr/bin/nc", ["-z", "-G", "2", "127.0.0.1", String(profile.localPort)], timeout: 4)
        guard !isCancelled else { return Self.remaining(after: [], message: "检查已取消。") }
        var results = [Self.item("localProxy", local.exitCode == 0 && !local.timedOut ? .passed : .failed,
                                local.exitCode == 0 && !local.timedOut
                                ? "本机 127.0.0.1:\(profile.localPort) TCP 端口可达；尚未验证 HTTP 代理或外网访问。"
                                : "本机 127.0.0.1:\(profile.localPort) 未能建立 TCP 连接，请启动本地代理并核对端口。"), identity]
        guard identity.state != .failed else {
            return Self.remaining(after: results, message: "请先修正私钥文件，再检查 SSH。")
        }
        guard !isCancelled else { return Self.remaining(after: results, message: "检查已取消。") }
        let ssh = await execute("/usr/bin/ssh", SSHCommands.setup(profile, command: Self.dependencyCommand), timeout: 15)
        guard !isCancelled else { return Self.remaining(after: results, message: "检查已取消。") }
        guard ssh.exitCode == 0, !ssh.timedOut else {
            let failure = SSHFailure.classify(ssh.stderr, timedOut: ssh.timedOut)
            results.append(Self.item("ssh", .failed, failure.message))
            return Self.remaining(after: results, message: "SSH 连接未通过，尚未检查远端命令。")
        }
        guard !ssh.stdoutTruncated, let dependencies = Self.parseDependencies(ssh.stdout) else {
            results.append(Self.item("ssh", .failed, "SSH 已返回，但检查结果缺失或格式不符；请核查远端 shell。"))
            return Self.remaining(after: results, message: "未获得可靠的远端命令检查结果。")
        }
        results.append(Self.item("ssh", .passed, "SSH 密钥认证及主机身份验证通过；本次未建立隧道。"))
        results.append(Self.item("remoteSS", dependencies.ss ? .passed : .failed,
                                 dependencies.ss ? "远端可找到 ss 命令。" : "远端未找到 ss；隧道启动需要它检查监听端口。"))
        results.append(Self.item("remoteCurl", dependencies.curl ? .passed : .warning,
                                 dependencies.curl ? "远端可找到 curl 命令；本次未请求外部网站。" : "远端未找到 curl；连接后无法执行网站及出口检测。"))
        return Self.ordered(results)
    }

    private func execute(_ executable: String, _ arguments: [String], timeout: TimeInterval) async -> CommandResult {
        if let executor { return await executor(executable, arguments, timeout) }
        let command = ChildCommand()
        activeCommand = command
        defer { activeCommand = nil }
        return await withCheckedContinuation { continuation in
            do {
                try command.start(executable: executable, arguments: arguments, timeout: timeout) {
                    continuation.resume(returning: $0)
                }
            } catch {
                continuation.resume(returning: .init(exitCode: -1, stdout: "", stderr: error.localizedDescription))
            }
        }
    }

    static func identityReadiness(_ profile: ServerProfile) -> SetupCheckItem {
        guard let path = profile.expandedIdentityFile else {
            return item("identity", .warning, "未指定私钥，将使用 OpenSSH 默认密钥或 SSH agent；是否可用由 SSH 认证确认。")
        }
        // Inspect metadata only. Key bytes never enter CATunnel or its logs.
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            return item("identity", .failed, "所选私钥不存在或不是普通文件。")
        }
        guard FileManager.default.isReadableFile(atPath: resolved) else {
            return item("identity", .failed, "所选私钥不可读取，请检查文件权限。")
        }
        guard let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0 else {
            return item("identity", .failed, "私钥对其他用户开放了权限；请自行将权限限制为 600 或 400，再检查。")
        }
        return item("identity", .passed, "私钥是可读的普通文件，权限仅限所有者；未读取文件内容，密钥有效性将在 SSH 认证时验证。")
    }

    static let dependencyCommand = "printf 'CATUNNEL_SETUP_V1 ssh ready\\n'; " +
        "if command -v ss >/dev/null 2>&1; then printf 'CATUNNEL_SETUP_V1 remoteSS yes\\n'; " +
        "else printf 'CATUNNEL_SETUP_V1 remoteSS no\\n'; fi; " +
        "if command -v curl >/dev/null 2>&1; then printf 'CATUNNEL_SETUP_V1 remoteCurl yes\\n'; " +
        "else printf 'CATUNNEL_SETUP_V1 remoteCurl no\\n'; fi"

    static func parseDependencies(_ output: String) -> (ss: Bool, curl: Bool)? {
        var evidence: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.first == "CATUNNEL_SETUP_V1" else { continue }
            guard parts.count == 3, evidence[String(parts[1])] == nil,
                  ["ssh", "remoteSS", "remoteCurl"].contains(String(parts[1])) else { return nil }
            evidence[String(parts[1])] = String(parts[2])
        }
        guard evidence["ssh"] == "ready", let ss = evidence["remoteSS"], let curl = evidence["remoteCurl"],
              ["yes", "no"].contains(ss), ["yes", "no"].contains(curl) else { return nil }
        return (ss == "yes", curl == "yes")
    }

    private static let titles = [("localProxy", "本地代理端口"), ("identity", "SSH 私钥"),
                                 ("ssh", "SSH 连接"), ("remoteSS", "远端 ss"), ("remoteCurl", "远端 curl")]

    private static func item(_ id: String, _ state: SetupCheckState, _ message: String) -> SetupCheckItem {
        .init(id: id, title: titles.first { $0.0 == id }?.1 ?? id, state: state, message: message)
    }

    private static func ordered(_ items: [SetupCheckItem]) -> [SetupCheckItem] {
        titles.compactMap { id, _ in items.first { $0.id == id } }
    }

    private static func remaining(after items: [SetupCheckItem], message: String) -> [SetupCheckItem] {
        ordered(items + titles.filter { id, _ in !items.contains { $0.id == id } }.map {
            item($0.0, .skipped, message)
        })
    }
}
