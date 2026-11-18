import Foundation

public struct ServerConfiguration: Codable, Equatable, Sendable {
    public let version: Int
    public var profiles: [ServerProfile]
    public var excludedSSHConfigAliases: [String]?

    public init(profiles: [ServerProfile], excludedSSHConfigAliases: [String] = []) {
        version = 1
        self.profiles = profiles
        self.excludedSSHConfigAliases = excludedSSHConfigAliases.isEmpty ? nil : excludedSSHConfigAliases.sorted()
    }

    public func validate() throws {
        guard version == 1 else { throw ServerConfigurationError.unsupportedVersion(version) }
        var ids = Set<String>()
        var endpoints = Set<String>()
        var aliases = Set<String>()
        for alias in excludedSSHConfigAliases ?? [] {
            guard ServerProfile.isValidSSHConfigAlias(alias) else { throw ProfileValidationError.invalidSSHConfigAlias }
        }
        for profile in profiles {
            try profile.validate()
            guard ids.insert(profile.id).inserted else { throw ServerConfigurationError.duplicateID }
            let endpoint = "\(profile.host.lowercased()):\(profile.sshPort):\(profile.remotePort)"
            guard endpoints.insert(endpoint).inserted else { throw ServerConfigurationError.duplicateEndpoint }
            if let alias = profile.sshConfigAlias, !aliases.insert(alias.lowercased()).inserted {
                throw ServerConfigurationError.duplicateSSHConfigAlias
            }
        }
    }

    public static func decode(_ data: Data) throws -> ServerConfiguration {
        let decoder = JSONDecoder()
        let configuration: ServerConfiguration
        if let legacyProfiles = try? decoder.decode([ServerProfile].self, from: data) {
            configuration = ServerConfiguration(profiles: legacyProfiles)
        } else {
            configuration = try decoder.decode(ServerConfiguration.self, from: data)
        }
        try configuration.validate()
        return configuration
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

public enum ServerConfigurationError: LocalizedError {
    case duplicateID, duplicateEndpoint, duplicateSSHConfigAlias, unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .duplicateID: return "服务器标识重复，请为每台服务器使用不同的标识。"
        case .duplicateEndpoint: return "两条连接不能占用同一台服务器上的同一个端口。"
        case .duplicateSSHConfigAlias: return "一个 SSH 配置别名只能关联一条服务器。"
        case let .unsupportedVersion(version): return "不支持服务器配置版本 \(version)。"
        }
    }
}
