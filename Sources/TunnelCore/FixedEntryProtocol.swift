import Foundation

struct FixedEntryIdentity: Equatable, Sendable {
    let epoch: String
    let generation: Int
    let ticket: String
}

struct FixedEntryFence: Equatable, Sendable {
    let epoch: String
    let generation: Int

    func check(_ status: FixedEntryStatus) throws {
        guard epoch == status.epoch else { return }
        guard status.generation == generation else {
            throw FixedEntryError("固定入口已被其他会话接管，或此前接管结果无法确认；已停止自动恢复，请确认后手动重连。")
        }
    }
}

struct FixedEntryStatus: Sendable {
    let epoch: String
    let generation: Int
    let port: Int
}

struct FixedEntryError: Error, LocalizedError {
    let failure: SSHFailure
    var errorDescription: String? { failure.message }
    init(_ message: String, retryable: Bool = false) {
        failure = .init(message: message, retryable: retryable)
    }
    init(failure: SSHFailure) { self.failure = failure }
}

enum FixedEntryPythonFailure {
    static func message(_ result: CommandResult) -> String? {
        guard !result.timedOut else { return nil }
        switch result.exitCode {
        case 127: return "远端找不到所选 Python 可执行文件；请检查路径，留空时使用服务器默认的 python3。"
        case 126: return "远端无法执行所选 Python；请检查文件执行权限及其是否适用于此服务器。"
        default: return nil
        }
    }
}

enum FixedEntryRequest: Encodable {
    case status
    case begin(FixedEntryFence)
    case activate(FixedEntryIdentity, backendPort: Int, healthKey: Data)
    case renew(FixedEntryIdentity)
    case release(FixedEntryIdentity)

    private enum CodingKeys: String, CodingKey {
        case op, epoch, generation, ticket
        case expectedGeneration = "expected_generation"
        case backendPort = "backend_port"
        case healthKey = "health_key"
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        let identity: FixedEntryIdentity?
        switch self {
        case .status:
            try values.encode("status", forKey: .op)
            identity = nil
        case let .begin(fence):
            try values.encode("begin", forKey: .op)
            try values.encode(fence.epoch, forKey: .epoch)
            try values.encode(fence.generation, forKey: .expectedGeneration)
            identity = nil
        case let .activate(lease, port, key):
            guard key.count == 32, (1...65535).contains(port) else { throw FixedEntryProtocol.invalidResponse }
            try values.encode("activate", forKey: .op)
            try values.encode(port, forKey: .backendPort)
            try values.encode(key.map { String(format: "%02x", $0) }.joined(), forKey: .healthKey)
            identity = lease
        case let .renew(lease):
            try values.encode("renew", forKey: .op)
            identity = lease
        case let .release(lease):
            try values.encode("release", forKey: .op)
            identity = lease
        }
        if let identity {
            try values.encode(identity.epoch, forKey: .epoch)
            try values.encode(identity.generation, forKey: .generation)
            try values.encode(identity.ticket, forKey: .ticket)
        }
    }
}

enum FixedEntryProtocol {
    static let bodyLimit = 4096
    static var invalidResponse: FixedEntryError {
        .init("固定入口 helper 返回格式无效或版本不兼容；请核对远端 helper。")
    }

    private struct Response: Decodable {
        let ok: Bool
        let error: String?
        let epoch: String?
        let generation: Int?
        let ticket: String?
        let port: Int?
        let activeGeneration: Int?
        let backendPort: Int?
        let leaseSeconds: Double?
        enum CodingKeys: String, CodingKey {
            case ok, error, epoch, generation, ticket, port
            case activeGeneration = "active_generation"
            case backendPort = "backend_port"
            case leaseSeconds = "lease_seconds"
        }
    }

    static func input(_ request: FixedEntryRequest) throws -> Data {
        var data = try JSONEncoder().encode(request)
        data.append(10)
        guard data.count <= bodyLimit else { throw invalidResponse }
        return data
    }

    private static func response(_ result: CommandResult) throws -> Response {
        if result.timedOut {
            throw FixedEntryError("固定入口控制请求超时，等待连接恢复。", retryable: true)
        }
        if result.exitCode == 255 { throw FixedEntryError(failure: SSHFailure.classify(result.stderr)) }
        if let message = FixedEntryPythonFailure.message(result) { throw FixedEntryError(message) }
        let stderr = result.stderr.lowercased()
        if result.exitCode != 0, stderr.contains("can't open file") {
            throw FixedEntryError("远端 Python 无法打开固定入口程序；请检查程序路径及读取权限。")
        }
        if result.exitCode != 0, stderr.contains("traceback") || stderr.contains("syntaxerror") {
            throw FixedEntryError("远端 Python 无法运行固定入口程序；请确认所选解释器为 Python 3.9 或更高版本，并检查程序文件。")
        }
        guard !result.stdoutTruncated, result.stdout.utf8.count <= bodyLimit,
              result.stdout.hasSuffix("\n"), !result.stdout.dropLast().contains("\n"),
              let decoded = try? JSONDecoder().decode(Response.self, from: Data(result.stdout.utf8)) else {
            if result.exitCode == 255 { throw FixedEntryError(failure: SSHFailure.classify(result.stderr)) }
            throw invalidResponse
        }
        if !decoded.ok, result.exitCode != 255 {
            switch decoded.error {
            case "superseded", "stale_generation":
                throw FixedEntryError("固定入口已被其他会话接管；已停止自动恢复，请确认后手动重连。")
            case "runtime_missing", "helper_unavailable", "runtime_unsafe", "runtime_busy", "runtime_not_clean":
                throw FixedEntryError("固定入口 helper 未就绪或私有运行目录不安全；请手动检查远端部署。")
            case "epoch_mismatch", "stale_candidate", "stale_lease", "health_failed", "control_timeout", "control_io_failed":
                throw FixedEntryError("固定入口租约或通道健康检查失效，等待连接恢复。", retryable: true)
            default:
                throw invalidResponse
            }
        }
        guard result.exitCode == 0 else {
            if result.exitCode == 255 { throw FixedEntryError(failure: SSHFailure.classify(result.stderr)) }
            throw invalidResponse
        }
        guard decoded.ok else { throw invalidResponse }
        return decoded
    }

    private static func validEpoch(_ epoch: String) -> Bool {
        !epoch.isEmpty && epoch.utf8.count <= 128 && epoch.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    static func status(_ result: CommandResult, expectedPort: Int) throws -> FixedEntryStatus {
        let value = try response(result)
        guard let epoch = value.epoch, validEpoch(epoch), let generation = value.generation,
              generation >= 0, generation < Int.max, let port = value.port, (1...65535).contains(port),
              (value.activeGeneration == nil) == (value.backendPort == nil),
              value.activeGeneration.map({ $0 > 0 && $0 <= generation }) ?? true,
              value.backendPort.map({ (1...65535).contains($0) }) ?? true else { throw invalidResponse }
        guard port == expectedPort else {
            throw FixedEntryError("远端 helper 的固定入口端口与此服务器设置不一致；尚未接管任何租约。")
        }
        return .init(epoch: epoch, generation: generation, port: port)
    }

    static func candidate(_ result: CommandResult, after fence: FixedEntryFence) throws -> FixedEntryIdentity {
        let value = try response(result)
        guard fence.generation < Int.max, value.epoch == fence.epoch, value.generation == fence.generation + 1,
              let ticket = value.ticket, ticket.utf8.count == 64,
              ticket.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw invalidResponse
        }
        return .init(epoch: fence.epoch, generation: fence.generation + 1, ticket: ticket)
    }

    private static func lease(_ value: Response) throws -> TimeInterval {
        guard let seconds = value.leaseSeconds, seconds.isFinite, seconds > 0, seconds <= 3600 else {
            throw invalidResponse
        }
        return seconds
    }

    static func activated(_ result: CommandResult, identity: FixedEntryIdentity, backendPort: Int) throws -> TimeInterval {
        let value = try response(result)
        guard value.epoch == identity.epoch, value.generation == identity.generation,
              value.backendPort == backendPort else { throw invalidResponse }
        return try lease(value)
    }

    static func renewed(_ result: CommandResult) throws -> TimeInterval {
        try lease(response(result))
    }

    static func allocatedPort(_ result: CommandResult) throws -> Int {
        guard result.exitCode == 0, !result.timedOut else {
            throw FixedEntryError(failure: SSHFailure.classify(result.stderr, timedOut: result.timedOut))
        }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.stdoutTruncated, result.stdout.utf8.count <= 32,
              !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let port = Int(text), (1...65535).contains(port) else { throw invalidResponse }
        return port
    }
}
