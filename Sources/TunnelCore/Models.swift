import Foundation

public struct ServerProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var host: String
    public var user: String
    public var sshPort: Int
    public var remotePort: Int
    public var localPort: Int
    public var autoReconnect: Bool
    public var keepRetryingForwardingFailure: Bool
    public var identityFile: String?
    public var assessIPRisk: Bool
    // Retained for profile round-tripping; Ping0 now opens only on an explicit browser action.
    public var assessPing0: Bool
    public var autoConnectOnLaunch: Bool
    public var useFixedEntry: Bool
    public var fixedEntryHelperPath: String?
    public var fixedEntryRuntimePath: String?
    public var fixedEntryPythonPath: String?

    public init(id: String, name: String, host: String, user: String, sshPort: Int,
                remotePort: Int, localPort: Int, autoReconnect: Bool,
                identityFile: String? = nil, assessIPRisk: Bool = false, assessPing0: Bool = false,
                autoConnectOnLaunch: Bool = false, keepRetryingForwardingFailure: Bool = false,
                useFixedEntry: Bool = false, fixedEntryHelperPath: String? = nil,
                fixedEntryRuntimePath: String? = nil, fixedEntryPythonPath: String? = nil) {
        self.id = id; self.name = name; self.host = host; self.user = user
        self.sshPort = sshPort; self.remotePort = remotePort; self.localPort = localPort
        self.autoReconnect = autoReconnect
        self.keepRetryingForwardingFailure = keepRetryingForwardingFailure
        self.identityFile = identityFile
        self.assessIPRisk = assessIPRisk
        self.assessPing0 = assessPing0
        self.autoConnectOnLaunch = autoConnectOnLaunch
        self.useFixedEntry = useFixedEntry
        self.fixedEntryHelperPath = fixedEntryHelperPath
        self.fixedEntryRuntimePath = fixedEntryRuntimePath
        self.fixedEntryPythonPath = fixedEntryPythonPath
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, user, sshPort, remotePort, localPort, autoReconnect, identityFile, assessIPRisk
        case autoConnectOnLaunch, assessPing0, keepRetryingForwardingFailure
        case useFixedEntry, fixedEntryHelperPath, fixedEntryRuntimePath, fixedEntryPythonPath
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        host = try values.decode(String.self, forKey: .host)
        user = try values.decode(String.self, forKey: .user)
        sshPort = try values.decode(Int.self, forKey: .sshPort)
        remotePort = try values.decode(Int.self, forKey: .remotePort)
        localPort = try values.decode(Int.self, forKey: .localPort)
        autoReconnect = try values.decode(Bool.self, forKey: .autoReconnect)
        keepRetryingForwardingFailure = try values.decodeIfPresent(Bool.self, forKey: .keepRetryingForwardingFailure) ?? false
        identityFile = try values.decodeIfPresent(String.self, forKey: .identityFile)
        assessIPRisk = try values.decodeIfPresent(Bool.self, forKey: .assessIPRisk) ?? false
        assessPing0 = try values.decodeIfPresent(Bool.self, forKey: .assessPing0) ?? false
        autoConnectOnLaunch = try values.decodeIfPresent(Bool.self, forKey: .autoConnectOnLaunch) ?? false
        useFixedEntry = try values.decodeIfPresent(Bool.self, forKey: .useFixedEntry) ?? false
        fixedEntryHelperPath = try values.decodeIfPresent(String.self, forKey: .fixedEntryHelperPath)
        fixedEntryRuntimePath = try values.decodeIfPresent(String.self, forKey: .fixedEntryRuntimePath)
        fixedEntryPythonPath = try values.decodeIfPresent(String.self, forKey: .fixedEntryPythonPath)
    }

    public var expandedIdentityFile: String? {
        identityFile.map { ($0 as NSString).expandingTildeInPath }
    }

    func resolvedFixedEntryPython() throws -> String {
        guard let path = fixedEntryPythonPath, !path.isEmpty else { return "python3" }
        guard path.hasPrefix("/"), path != "/", path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ProfileValidationError.invalidFixedEntryPythonPath
        }
        return path
    }

    public static let examples: [ServerProfile] = [
        .init(id: "example-a", name: "A", host: "server-a.example", user: "user",
              sshPort: 22, remotePort: 17892, localPort: 7890, autoReconnect: true),
        .init(id: "example-b", name: "B", host: "server-b.example", user: "user",
              sshPort: 22, remotePort: 17892, localPort: 7890, autoReconnect: true)
    ]

    public static func draft() -> ServerProfile {
        .init(id: UUID().uuidString, name: "", host: "", user: "",
              sshPort: 22, remotePort: 17892, localPort: 7890, autoReconnect: true)
    }

    public func validate() throws {
        func matches(_ value: String, _ pattern: String) -> Bool {
            value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex
        }
        guard matches(id, "^[A-Za-z0-9_-]{1,64}$") else {
            throw ProfileValidationError.invalidID
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 80, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ProfileValidationError.invalidName
        }
        guard host.count <= 253,
              matches(host, "^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$"),
              host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-")
              }) else { throw ProfileValidationError.invalidHost }
        if host.allSatisfy({ $0.isNumber || $0 == "." }) {
            let octets = host.split(separator: ".")
            guard octets.count == 4, octets.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) else {
                throw ProfileValidationError.invalidHost
            }
        }
        guard matches(user, "^[A-Za-z_][A-Za-z0-9_.-]{0,63}$") else {
            throw ProfileValidationError.invalidUser
        }
        for port in [sshPort, remotePort, localPort] {
            guard (1...65535).contains(port) else { throw ProfileValidationError.invalidPort }
        }
        if let path = identityFile {
            guard (path.hasPrefix("/") || path.hasPrefix("~/")), path.count <= 4096,
                  !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw ProfileValidationError.invalidIdentityFile
            }
        }
        _ = try resolvedFixedEntryPython()
        if useFixedEntry {
            for path in [fixedEntryHelperPath, fixedEntryRuntimePath] {
                guard let path, path.hasPrefix("/"), path.count <= 4096,
                      !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                    throw ProfileValidationError.invalidFixedEntryPath
                }
            }
        }
    }

    public func validateForConnection() throws {
        try validate()
        let hostname = host.lowercased()
        guard hostname != "example", !hostname.hasSuffix(".example") else {
            throw ProfileValidationError.exampleHost
        }
    }
}

public enum ProfileValidationError: LocalizedError {
    case invalidID, invalidName, invalidHost, invalidUser, invalidPort, invalidIdentityFile, invalidFixedEntryPath, invalidFixedEntryPythonPath, exampleHost
    public var errorDescription: String? {
        switch self {
        case .invalidID: return "服务器标识格式无效。"
        case .invalidName: return "请输入 1–80 字的服务器名称，且不要包含控制字符。"
        case .invalidHost: return "请输入有效的 IPv4 地址或主机名。"
        case .invalidUser: return "SSH 用户名格式无效。"
        case .invalidPort: return "端口必须在 1–65535 之间。"
        case .invalidIdentityFile: return "私钥路径必须以 / 或 ~/ 开头，且不要包含控制字符。"
        case .invalidFixedEntryPath: return "固定入口模式需填写两条以 / 开头的远端绝对路径，每条最多 4096 字，且不要包含控制字符；不支持 ~/。"
        case .invalidFixedEntryPythonPath: return "远端 Python 路径请留空使用 python3，或填写以 / 开头的可执行文件绝对路径，最多 4096 字节，且不要包含控制字符；不支持 ~/ 或命令参数。"
        case .exampleHost: return "这是示例服务器，请先在服务器设置中填写真实主机和 SSH 用户名，再开启隧道。"
        }
    }
}

public enum TunnelPhase: String, Codable, Sendable {
    case stopped, checking, connecting, connected, reconnecting, failed
}

public enum ProxyCheckState: String, Codable, Sendable {
    case unchecked, checking, passed, partial, failed
}

public enum WebsiteTarget: String, CaseIterable, Identifiable, Sendable {
    case openAI, claudeNetwork, claudeAPI, google

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .openAI: return "OpenAI API"
        case .claudeNetwork: return "Claude 网络连通"
        case .claudeAPI: return "Claude API"
        case .google: return "Google"
        }
    }
    public var url: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1/models"
        case .claudeNetwork: return "https://claude.ai/cdn-cgi/trace"
        case .claudeAPI: return "https://api.anthropic.com/v1/models"
        case .google: return "https://www.google.com/generate_204"
        }
    }
    var acceptsUnauthenticatedResponse: Bool { self == .openAI || self == .claudeAPI }
    static var independentRequestTargets: [WebsiteTarget] { allCases.filter { $0 != .claudeNetwork } }
}

public enum WebsiteCheckState: String, Sendable {
    case unchecked, checking, passed, restricted, failed
}

public struct WebsiteCheckResult: Identifiable, Equatable, Sendable {
    public var target: WebsiteTarget
    public var state: WebsiteCheckState
    public var message: String
    public var httpStatus: Int?
    public var elapsedMilliseconds: Int?
    public var checkedAt: Date?
    public var exitIP: String?
    public var countryCode: String?
    public var id: String { target.rawValue }

    public init(target: WebsiteTarget, state: WebsiteCheckState = .unchecked, message: String = "尚未检测",
                httpStatus: Int? = nil, elapsedMilliseconds: Int? = nil, checkedAt: Date? = nil,
                exitIP: String? = nil, countryCode: String? = nil) {
        self.target = target; self.state = state; self.message = message
        self.httpStatus = httpStatus; self.elapsedMilliseconds = elapsedMilliseconds; self.checkedAt = checkedAt
        self.exitIP = exitIP; self.countryCode = countryCode
    }
}

public struct TunnelStatus: Equatable, Sendable {
    public var phase: TunnelPhase
    public var message: String
    public var proxyCheck: ProxyCheckState
    public var proxyMessage: String
    public var connectedAt: Date?
    public var websiteResults: [WebsiteCheckResult]
    public var ipRisk: IPRiskCheckResult

    public init(phase: TunnelPhase = .stopped, message: String = "未开启",
                proxyCheck: ProxyCheckState = .unchecked, proxyMessage: String = "尚未测试代理出口",
                connectedAt: Date? = nil,
                websiteResults: [WebsiteCheckResult] = WebsiteTarget.allCases.map { .init(target: $0) },
                ipRisk: IPRiskCheckResult = .init()) {
        self.phase = phase; self.message = message; self.proxyCheck = proxyCheck
        self.proxyMessage = proxyMessage; self.connectedAt = connectedAt
        self.websiteResults = websiteResults
        self.ipRisk = ipRisk
    }
    public static let stopped = TunnelStatus()
}

public enum TunnelEvent {
    case status(id: String, status: TunnelStatus)
    case log(id: String, message: String)
}
