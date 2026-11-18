import Foundation
import Darwin

public struct SSHConfigImportEntry: Equatable, Sendable {
    public let alias: String
    public let host: String
    public let user: String
    public let sshPort: Int
    public let identityFile: String?

    public init(alias: String, host: String, user: String, sshPort: Int, identityFile: String?) {
        self.alias = alias; self.host = host; self.user = user
        self.sshPort = sshPort; self.identityFile = identityFile
    }
}

public enum SSHConfigImportAvailability: Equatable, Sendable {
    case available, missing, unavailable
}

public struct SSHConfigImportResult: Equatable, Sendable {
    public let availability: SSHConfigImportAvailability
    public let entries: [SSHConfigImportEntry]
    public let skippedAliases: [String]
    public let message: String?

    public init(availability: SSHConfigImportAvailability, entries: [SSHConfigImportEntry] = [],
                skippedAliases: [String] = [], message: String? = nil) {
        self.availability = availability; self.entries = entries
        self.skippedAliases = skippedAliases; self.message = message
    }
}

/// A bounded, read-only importer for concrete aliases, not an OpenSSH evaluator.
public enum SSHConfigImport {
    static let maximumBytes = 524_288
    static let maximumLines = 10_000
    static let maximumLineBytes = 8_192
    static let maximumAliases = 512

    public static func load(from url: URL, defaultUser: String = NSUserName()) -> SSHConfigImportResult {
        guard url.isFileURL else { return unavailable("SSH 配置路径无效，未同步服务器。") }
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NONBLOCK) }
        guard descriptor >= 0 else {
            return errno == ENOENT
                ? .init(availability: .missing, message: "SSH 配置文件不存在，保留现有服务器。")
                : unavailable("无法读取 SSH 配置，保留现有服务器。")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size <= maximumBytes else {
            return unavailable("SSH 配置不是普通文件或已超过读取上限，未同步服务器。")
        }
        do {
            let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8) else {
                return unavailable("SSH 配置过大或不是有效 UTF-8，未同步服务器。")
            }
            return parse(text, defaultUser: defaultUser)
        } catch {
            return unavailable("无法完整读取 SSH 配置，保留现有服务器。")
        }
    }

    public static func parse(_ text: String, defaultUser: String) -> SSHConfigImportResult {
        guard text.utf8.count <= maximumBytes else {
            return unavailable("SSH 配置超过读取上限，未同步服务器。")
        }
        guard !text.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" && $0 != "\t"
        }) else { return unavailable("SSH 配置含不支持的控制字符，未同步服务器。") }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.count <= maximumLines else {
            return unavailable("SSH 配置超过行数上限，未同步服务器。")
        }
        var directives: [Directive] = []
        var aliases: [String] = []
        var discovered = Set<String>()
        for line in lines {
            guard line.utf8.count <= maximumLineBytes, let directive = tokenize(line) else {
                return unavailable("SSH 配置语法不受支持或已超过行长度上限，未同步服务器。")
            }
            guard let directive else { continue }
            if directive.key == "include" || directive.key == "match" {
                return unavailable("SSH 配置含 Include 或 Match；当前只支持直接 Host 配置，未同步服务器。")
            }
            directives.append(directive)
            if directive.key == "host" {
                guard !directive.values.isEmpty else {
                    return unavailable("SSH 配置的 Host 条目不完整，未同步服务器。")
                }
                for alias in directive.values where ServerProfile.isValidSSHConfigAlias(alias) {
                    if discovered.insert(alias.lowercased()).inserted { aliases.append(alias) }
                }
                guard aliases.count <= maximumAliases else {
                    return unavailable("SSH 配置别名数量超过上限，未同步服务器。")
                }
            }
        }
        var entries: [SSHConfigImportEntry] = []
        var skipped: [String] = []
        for alias in aliases {
            if let entry = resolve(alias: alias, directives: directives, defaultUser: defaultUser) {
                entries.append(entry)
            } else {
                skipped.append(alias)
            }
        }
        return .init(availability: .available, entries: entries, skippedAliases: skipped,
                     message: skipped.isEmpty ? nil : "已跳过包含不支持或无效连接设置的 SSH 别名。")
    }

    private struct Directive {
        let key: String
        let values: [String]
        let patterns: [HostPattern]

        init(key: String, values: [String]) {
            self.key = key; self.values = values
            patterns = key == "host" ? values.map(HostPattern.init) : []
        }
    }

    private struct HostPattern {
        let negated: Bool
        let bytes: [UInt8]
        let literal: Bool

        init(_ value: String) {
            negated = value.hasPrefix("!")
            let pattern = negated ? String(value.dropFirst()) : value
            var result: [UInt8] = []
            for byte in pattern.lowercased().utf8 where byte != 42 || result.last != 42 { result.append(byte) }
            bytes = result
            literal = !result.contains(42) && !result.contains(63)
        }
    }

    // A double optional distinguishes blank/comment lines from invalid syntax.
    private static func tokenize(_ line: String) -> Directive?? {
        guard !line.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) && $0 != "\t"
        }) else { return nil }
        var remainder = line[...].drop(while: { $0 == " " || $0 == "\t" })
        guard !remainder.isEmpty, remainder.first != "#" else { return .some(nil) }
        let key = remainder.prefix(while: { $0 != " " && $0 != "\t" && $0 != "=" })
        guard !key.isEmpty else { return nil }
        remainder = remainder.dropFirst(key.count).drop(while: { $0 == " " || $0 == "\t" })
        if remainder.first == "=" {
            remainder = remainder.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
        }
        var values: [String] = []
        var value = ""
        var quote: Character?
        var started = false
        var index = remainder.startIndex
        while index < remainder.endIndex {
            let character = remainder[index]
            remainder.formIndex(after: &index)
            if character == "\\", index < remainder.endIndex {
                let next = remainder[index]
                if next == "\\" || next == "\"" || next == "'" || (quote == nil && next == " ") {
                    value.append(next)
                    remainder.formIndex(after: &index)
                    started = true
                    continue
                }
            }
            if character == quote {
                quote = nil
            } else if quote == nil && (character == "\"" || character == "'") {
                quote = character
                started = true
            } else if character == "#" && quote == nil && !started {
                break
            } else if (character == " " || character == "\t") && quote == nil {
                if started { values.append(value); value = ""; started = false }
            } else {
                value.append(character); started = true
            }
        }
        guard quote == nil else { return nil }
        if started { values.append(value) }
        return .some(.init(key: key.lowercased(), values: values))
    }

    private static func resolve(alias: String, directives: [Directive], defaultUser: String) -> SSHConfigImportEntry? {
        var matching = true
        var fields: [String: String] = [:]
        var identities: [String] = []
        var proxy: [String: String] = [:]
        let aliasBytes = Array(alias.lowercased().utf8)
        for directive in directives {
            if directive.key == "host" {
                matching = matches(aliasBytes, patterns: directive.patterns)
                continue
            }
            guard matching else { continue }
            switch directive.key {
            case "hostname", "user", "port":
                if fields[directive.key] == nil {
                    guard directive.values.count == 1 else { return nil }
                    fields[directive.key] = directive.values[0]
                }
            case "identityfile":
                guard directive.values.count == 1 else { return nil }
                let value = directive.values[0]
                if !identities.contains(value) { identities.append(value) }
            case "proxyjump", "proxycommand":
                if proxy[directive.key] == nil {
                    guard !directive.values.isEmpty else { return nil }
                    proxy[directive.key] = directive.values.joined(separator: " ")
                }
            case "canonicalizehostname":
                if fields[directive.key] == nil {
                    guard directive.values.count == 1 else { return nil }
                    fields[directive.key] = directive.values[0]
                }
            case "hostkeyalias", "identityagent", "certificatefile", "knownhostscommand":
                return nil
            default: break
            }
        }
        guard proxy.values.allSatisfy({ $0.lowercased() == "none" }), identities.count <= 1,
              fields["canonicalizehostname"].map({ $0.lowercased() == "no" }) ?? true else { return nil }
        let host = fields["hostname"] ?? alias
        let user = fields["user"] ?? defaultUser
        guard [host, user].allSatisfy({ !$0.contains("%") && !$0.contains("$") }),
              let port = Int(fields["port"] ?? "22") else { return nil }
        let identity = identities.first
        if identity?.lowercased() == "none" { return nil }
        if let identity, identity.contains("%") || identity.contains("$") { return nil }
        if identity == "" { return nil }
        let profile = ServerProfile(id: "ssh-import", name: alias, host: host, user: user, sshPort: port,
                                    remotePort: 17892, localPort: 7890, autoReconnect: true, identityFile: identity)
        guard (try? profile.validate()) != nil else { return nil }
        return .init(alias: alias, host: host, user: user, sshPort: port, identityFile: identity)
    }

    private static func matches(_ alias: [UInt8], patterns: [HostPattern]) -> Bool {
        var positive = false
        for pattern in patterns where globMatches(alias, pattern: pattern) {
            if pattern.negated { return false }
            positive = true
        }
        return positive
    }

    private static func globMatches(_ alias: [UInt8], pattern: HostPattern) -> Bool {
        if pattern.literal { return alias == pattern.bytes }
        let bytes = pattern.bytes
        var input = 0
        var current = 0
        var star: Int?
        var retry = 0
        while input < alias.count {
            if current < bytes.count && (bytes[current] == 63 || bytes[current] == alias[input]) {
                current += 1; input += 1
            } else if current < bytes.count && bytes[current] == 42 {
                star = current; current += 1; retry = input
            } else if let star {
                retry += 1; input = retry; current = star + 1
            } else {
                return false
            }
        }
        while current < bytes.count && bytes[current] == 42 { current += 1 }
        return current == bytes.count
    }

    private static func unavailable(_ message: String) -> SSHConfigImportResult {
        .init(availability: .unavailable, message: message)
    }
}
