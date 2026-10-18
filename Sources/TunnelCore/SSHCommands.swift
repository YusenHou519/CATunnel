import Foundation

enum SSHCommands {
    static func base(_ profile: ServerProfile, socket: String) -> [String] {
        ["-F", "/dev/null", "-S", socket,
         "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "UpdateHostKeys=no",
         "-o", "CheckHostIP=no",
         "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1", "-p", String(profile.sshPort)] + identity(profile)
    }

    static func identity(_ profile: ServerProfile) -> [String] {
        guard let path = profile.expandedIdentityFile else { return [] }
        return ["-i", path, "-o", "IdentitiesOnly=yes"]
    }

    static func setup(_ profile: ServerProfile, command: String) -> [String] {
        base(profile, socket: "none") + [
            "-o", "ControlMaster=no", "-o", "ClearAllForwardings=yes", "-T",
            "\(profile.user)@\(profile.host)", command
        ]
    }

    static func master(_ profile: ServerProfile, socket: String) -> [String] {
        base(profile, socket: socket) + [
            "-M", "-o", "ControlPersist=no", "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "-o", "LogLevel=ERROR",
            "-N", "-T", "-R", "127.0.0.1:\(profile.remotePort):127.0.0.1:\(profile.localPort)",
            "\(profile.user)@\(profile.host)"
        ]
    }

    static func check(_ profile: ServerProfile, socket: String) -> [String] {
        base(profile, socket: socket) + ["-O", "check", "\(profile.user)@\(profile.host)"]
    }

    static func remote(_ profile: ServerProfile, socket: String, command: String) -> [String] {
        base(profile, socket: socket) + [
            "-o", "ControlMaster=no", "-o", "ClearAllForwardings=yes",
            // A lost master must not silently create a second SSH connection.
            "-o", "ProxyCommand=/usr/bin/false", "-T", "\(profile.user)@\(profile.host)", command
        ]
    }

    static func listenerCommand(port: Int) -> String {
        "ss -H -ltn 'sport = :\(port)'"
    }

    static func hasLoopbackListener(_ output: String, port: Int) -> Bool {
        let addresses = output.split(separator: "\n").compactMap { line -> Substring? in
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            return fields.count >= 4 ? fields[3] : nil
        }
        return !addresses.isEmpty && addresses.allSatisfy { $0 == "127.0.0.1:\(port)" }
    }

    static func proxyCommand(port: Int, target: WebsiteTarget) -> String {
        let publicHeaders = target == .claudeAPI ? "--header 'anthropic-version: 2023-06-01' " : ""
        // Ignore .curlrc and NO_PROXY, request no credentials, and discard the response body.
        return "curl -q --silent --show-error --noproxy '' --proxy http://127.0.0.1:\(port) " +
        "--connect-timeout 8 --max-time 20 --location --max-redirs 4 " +
        "--proto '=https' --proto-redir '=https' --output /dev/null " + publicHeaders +
        "--write-out '\\nTM_WEBSITE_V1 \(target.rawValue) %{http_connect} %{http_code} %{ssl_verify_result} %{time_total}\\n' " +
        "'\(target.url)'"
    }

    static func ipRiskTraceCommand(port: Int) -> String {
        ipRiskCommand(port: port, payload: .trace, url: "https://claude.ai/cdn-cgi/trace")
    }

    static func ipRiskAssessmentCommand(port: Int, ip: String) throws -> String {
        guard let encoded = RiskIPAddress.encodedPath(ip) else { throw IPRiskProbeError(message: "待查询 IP 无效") }
        return ipRiskCommand(port: port, payload: .assessment, url: "https://ip.net.coffee/api/iprisk/" + encoded)
    }

    private static func ipRiskCommand(port: Int, payload: IPRiskPayload, url: String) -> String {
        "curl -q --silent --show-error --noproxy '' --proxy http://127.0.0.1:\(port) " +
        "--connect-timeout 8 --max-time 20 --max-filesize \(IPRiskProbe.bodyLimit) " +
        "--location --max-redirs 3 --proto '=https' --proto-redir '=https' " +
        "--write-out '\\nTM_IPRISK_V1 \(payload.rawValue) %{http_connect} %{http_code} %{ssl_verify_result} %{time_total}\\n' " +
        "'\(url)'"
    }
}

struct SSHFailure: Equatable {
    let message: String
    let retryable: Bool

    static func classify(_ stderr: String, timedOut: Bool = false) -> SSHFailure {
        let value = stderr.lowercased()
        if value.contains("remote port forwarding failed") || value.contains("cannot listen to port") ||
            value.contains("address already in use") {
            return .init(message: "服务器端口已占用或转发被拒绝；请更换入口端口或检查 SSH 转发权限。", retryable: false)
        }
        if value.contains("permission denied") || value.contains("authentication failed") || value.contains("no supported authentication") {
            return .init(message: "SSH 密钥认证失败。请检查用户名、所选私钥或 SSH agent；加密私钥需先在终端用 ssh-add 加入 agent。应用不弹出密码输入。", retryable: false)
        }
        if value.contains("invalid format") || value.contains("error in libcrypto") || value.contains("bad permissions") {
            return .init(message: "SSH 无法读取所选私钥，请检查文件格式和权限；应用不会修改密钥。", retryable: false)
        }
        if value.contains("agent refused operation") || value.contains("incorrect passphrase") {
            return .init(message: "SSH agent 无法使用此密钥。请先在终端用 ssh-add 解锁私钥，再重试。", retryable: false)
        }
        if value.contains("host key verification failed") || value.contains("host identification has changed") ||
            value.contains("no host key is known") {
            return .init(message: "SSH 主机密钥未确认或已变化。请先在终端核实服务器身份。", retryable: false)
        }
        if value.contains("administratively prohibited") {
            return .init(message: "服务器 SSH 策略禁止此转发。", retryable: false)
        }
        return .init(message: timedOut ? "SSH 连接超时，请检查网络和服务器可达性。" : "SSH 连接已断开，请查看日志。", retryable: true)
    }
}

enum SafeLog {
    static func clean(_ input: String) -> String {
        let plain = input.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
        }.map(String.init).joined()
        let patterns = [
            "(?i)(authorization\\s*[:=]\\s*(?:bearer\\s+)?)[^\\s]+",
            "(?i)((?:api[_-]?key|access[_-]?token|password|secret)\\s*[:=]\\s*)[^\\s]+",
            "(?i)(https?://)[^\\s/@]+:[^\\s/@]+@",
            "\\b(?:sk|sess)-[A-Za-z0-9_-]{12,}"
        ]
        var text = String(plain.prefix(4000))
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            text = expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "[已隐藏]")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
