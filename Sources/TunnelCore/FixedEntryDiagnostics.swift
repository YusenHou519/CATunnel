import Foundation

/// Explicit, read-only observations; success never installs, connects, or takes a lease.
@MainActor
public final class FixedEntryDiagnostics {
    typealias Executor = RemoteInspection.Executor
    private let inspection: RemoteInspection
    static let ids = ["localProxy", "ssh", "python", "helper", "entry", "backend"]
    static let marker = "CATUNNEL_FIXED_INSPECTION_V1"

    public convenience init() { self.init(executionContext: SSHExecutionContext()) }

    init(executionContext: SSHExecutionContext, executor: Executor? = nil) {
        inspection = RemoteInspection(context: executionContext, executor: executor)
    }

    public func cancel() { inspection.cancel() }

    public func run(_ profile: ServerProfile) async -> [SetupCheckItem] {
        do {
            return try await inspection.run { try await self.inspect(profile) }
        } catch {
            return Self.completed([], reason: error.localizedDescription)
        }
    }

    private func inspect(_ profile: ServerProfile) async throws -> [SetupCheckItem] {
        var base = profile
        base.useFixedEntry = false
        do { try base.validateForConnection() }
        catch { return Self.completed([Self.item("ssh", .failed, error.localizedDescription)]) }
        let local = try await inspection.execute("/usr/bin/nc",
            ["-z", "-G", "2", "127.0.0.1", String(base.localPort)], timeout: 4)
        var items = [Self.item("localProxy", local.exitCode == 0 && !local.timedOut ? .passed : .failed,
            local.exitCode == 0 && !local.timedOut
                ? "本机 127.0.0.1:\(base.localPort) TCP 端口可达；尚未验证 HTTP 代理或外网。"
                : "本机代理 TCP 端口不可达，请检查代理是否启动及端口是否正确。")]
        let identity = SetupDiagnostics.identityReadiness(base)
        guard identity.state != .failed else {
            return Self.completed(items + [Self.item("ssh", .failed, identity.message)])
        }
        let environment = try await inspection.remote(base, command: Self.environmentCommand(base))
        guard !environment.timedOut, environment.exitCode != 255,
              !environment.stdoutTruncated, Self.hasMarker(environment.stdout) else {
            let message = environment.timedOut || environment.exitCode == 255
                ? SSHFailure.classify(environment.stderr, timedOut: environment.timedOut).message
                : "未获得可靠的远端检查结果；请检查 SSH 登录环境。"
            return Self.completed(items + [Self.item("ssh", .failed, message)])
        }
        items.append(Self.item("ssh", .passed, "SSH 认证与主机身份检查通过；未建立转发或更改现有连接。"))
        let evidence = Self.parseEnvironment(environment)
        if let evidence {
            items.append(Self.item("python", evidence.supported ? .passed : .failed,
                "所选解释器为 Python \(evidence.version.map(String.init).joined(separator: "."))。" +
                (evidence.supported ? "满足 Python 3.9+ 要求。" : "请查找并选择已有 Python 3.9+；本次不会升级环境。")))
        } else {
            items.append(Self.item("python", .failed, FixedEntryPythonFailure.message(environment)
                ?? "无法确认所选 Python 的版本；请检查解释器路径及其可执行性。"))
        }

        let listener = try await inspection.remote(base, command: inspection.context.listenerCommand(base.remotePort))
        let entry = Self.listenerItem(listener, id: "entry", port: base.remotePort)
        items.append(entry)
        guard let helper = base.fixedEntryHelperPath, RemoteInspection.validPath(helper),
              let runtime = base.fixedEntryRuntimePath, RemoteInspection.validPath(runtime) else {
            items.append(Self.item("helper", .failed, "尚未配置有效的远端程序和私有运行目录；请安装并保存，或填写已有部署路径。"))
            return Self.completed(items)
        }
        guard let evidence, evidence.supported else { return Self.completed(items) }
        guard evidence.helperReadable, evidence.runtimeSafe else {
            items.append(Self.item("helper", .failed, !evidence.helperReadable
                ? "远端程序文件不存在或不可读取；本次未安装、启动或替换程序。"
                : "私有运行目录不存在，或其所有权、权限、类型不符合要求；本次未修改目录。"))
            return Self.completed(items)
        }
        let status = try await inspection.remote(base, command: Self.statusCommand(base), timeout: 10,
                                                input: try FixedEntryProtocol.input(.status), limit: FixedEntryProtocol.bodyLimit)
        do { _ = try FixedEntryProtocol.status(status, expectedPort: base.remotePort) }
        catch {
            items.append(Self.item("helper", .failed, error.localizedDescription))
            if entry.state == .passed {
                items.removeAll { $0.id == "entry" }
                items.append(Self.item("entry", .warning,
                    "入口端口有监听，但无法确认属于兼容的转接程序；本次未释放端口或结束任何进程。"))
            }
            return Self.completed(items)
        }
        items.append(Self.item("helper", .passed, "兼容的远端程序响应正常，入口端口与配置一致；本次仅查询状态。"))
        guard let active = try? JSONDecoder().decode(ActiveState.self, from: Data(status.stdout.utf8)) else {
            return Self.completed(items)
        }
        guard let backendPort = active.backendPort else {
            items.append(Self.item("backend", .warning, "远端当前没有活动后端；可能尚未连接或租约已过期。本次未尝试重连。"))
            return Self.completed(items)
        }
        let backend = try await inspection.remote(base, command: inspection.context.listenerCommand(backendPort))
        items.append(Self.listenerItem(backend, id: "backend", port: backendPort))
        return Self.completed(items)
    }

    private struct Environment: Decodable {
        let version: [Int]
        let helperReadable: Bool
        let runtimeSafe: Bool
        var supported: Bool { version[0] == 3 && version[1] >= 9 }
        enum CodingKeys: String, CodingKey {
            case version
            case helperReadable = "helper_readable", runtimeSafe = "runtime_safe"
        }
    }

    private struct ActiveState: Decodable {
        let backendPort: Int?
        enum CodingKeys: String, CodingKey { case backendPort = "backend_port" }
    }

    private static func hasMarker(_ text: String) -> Bool {
        text.split(separator: "\n").filter { $0 == Substring(marker) }.count == 1
    }

    private static func parseEnvironment(_ result: CommandResult) -> Environment? {
        guard result.exitCode == 0, !result.timedOut, !result.stdoutTruncated,
              result.stdout.utf8.count <= 16_384, result.stdout.hasSuffix("\n") else { return nil }
        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
        guard let index = lines.firstIndex(of: Substring(marker)), index + 2 == lines.count - 1,
              let value = try? JSONDecoder().decode(Environment.self, from: Data(lines[index + 1].utf8)),
              value.version.count == 3, value.version.allSatisfy({ (0...999).contains($0) }) else { return nil }
        return value
    }

    private static func listenerItem(_ result: CommandResult, id: String, port: Int) -> SetupCheckItem {
        guard result.exitCode == 0, !result.timedOut, !result.stdoutTruncated else {
            return item(id, .warning, "无法确认远端端口监听；可能缺少 ss、权限不足或检查超时。")
        }
        let lines = result.stdout.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.allSatisfy({ line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.count >= 5 && fields.first == "LISTEN"
        }) else {
            return item(id, .warning, "监听检查返回格式无法确认；本次未修改端口或连接。")
        }
        guard SSHCommands.hasLoopbackListener(result.stdout, port: port) else {
            return item(id, .failed, result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "远端 127.0.0.1:\(port) 未发现监听。"
                : "端口检查结果不符合独立 IPv4 回环监听要求；本次未修改监听。")
        }
        return item(id, .passed, id == "entry"
            ? "远端 127.0.0.1:\(port) 正在监听；进程归属还需结合程序状态判断。"
            : "活动后端 127.0.0.1:\(port) 正在监听；可能属于其他会话，尚未验证网关或外网。")
    }

    private static func item(_ id: String, _ state: SetupCheckState, _ message: String) -> SetupCheckItem {
        let titles = ["localProxy": "本机代理端口", "ssh": "SSH 连接", "python": "远端 Python",
                      "helper": "远端转接程序", "entry": "固定入口端口", "backend": "活动后端"]
        return .init(id: id, title: titles[id] ?? id, state: state, message: message)
    }

    private static func completed(_ items: [SetupCheckItem], reason: String = "前置检查未通过，尚未验证此项。") -> [SetupCheckItem] {
        ids.map { id in
            if id == "entry", items.first(where: { $0.id == id })?.state == .passed,
               items.first(where: { $0.id == "helper" })?.state != .passed {
                return item(id, .warning, "入口端口有监听，但尚未确认属于兼容的转接程序；本次未释放端口或结束任何进程。")
            }
            return items.first { $0.id == id } ?? item(id, .skipped, reason)
        }
    }

    static func environmentCommand(_ profile: ServerProfile) throws -> String {
        let helper = profile.fixedEntryHelperPath.flatMap { RemoteInspection.validPath($0) ? $0 : nil } ?? ""
        let runtime = profile.fixedEntryRuntimePath.flatMap { RemoteInspection.validPath($0) ? $0 : nil } ?? ""
        return "printf '" + marker + "\\n'; " +
            [try profile.resolvedFixedEntryPython(), "-I", "-S", "-B", "-c", environmentScript, helper, runtime]
                .map(RemoteInspection.quote).joined(separator: " ")
    }

    static func statusCommand(_ profile: ServerProfile) throws -> String {
        guard let helper = profile.fixedEntryHelperPath, RemoteInspection.validPath(helper),
              let runtime = profile.fixedEntryRuntimePath, RemoteInspection.validPath(runtime) else {
            throw RemoteInspectionError(message: "请填写远端程序和私有运行目录的绝对路径。")
        }
        return [try profile.resolvedFixedEntryPython(), "-I", "-S", "-B", helper, "control", "--runtime-dir", runtime]
            .map(RemoteInspection.quote).joined(separator: " ")
    }

    static let environmentScript = #"""
import json, os, stat, sys
helper, runtime = sys.argv[1:3]
safe = False
try:
    info = os.lstat(runtime)
    safe = stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700
except OSError:
    pass
print(json.dumps({"version": list(sys.version_info[:3]), "helper_readable": bool(helper) and os.path.isfile(helper) and os.access(helper, os.R_OK), "runtime_safe": safe}))
"""#
}
