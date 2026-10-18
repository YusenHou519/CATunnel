import Foundation

enum WebsiteProbe {
    struct Evidence: Equatable {
        let connectStatus: Int
        let httpStatus: Int?
        let tlsVerification: Int
        let elapsedMilliseconds: Int
    }

    static func evidence(from output: String, target: WebsiteTarget) -> Evidence? {
        guard let fields = evidenceFields(output) else { return nil }
        guard fields.count == 6,
              fields[1] == Substring(target.rawValue),
              fields[2].count == 3, let connect = Int(fields[2]), (0...599).contains(connect),
              fields[3].count == 3, let status = Int(fields[3]), status == 0 || (100...599).contains(status),
              let tls = Int(fields[4]), tls >= 0,
              let seconds = Double(fields[5]), seconds.isFinite, (0...86_400).contains(seconds) else { return nil }
        return .init(connectStatus: connect, httpStatus: status == 0 ? nil : status,
                     tlsVerification: tls, elapsedMilliseconds: Int((seconds * 1000).rounded()))
    }

    static func evaluate(_ result: CommandResult, target: WebsiteTarget, checkedAt: Date = Date()) -> WebsiteCheckResult {
        let evidence = evidence(from: result.stdout, target: target)
        func check(_ state: WebsiteCheckState, _ message: String) -> WebsiteCheckResult {
            .init(target: target, state: state, message: message, httpStatus: evidence?.httpStatus,
                  elapsedMilliseconds: evidence?.elapsedMilliseconds, checkedAt: checkedAt)
        }
        if result.timedOut || result.exitCode == 28 { return check(.failed, "请求超时") }
        guard !result.stdoutTruncated else { return check(.failed, "检测输出超过长度限制，无法可靠判断") }
        guard target != .claudeNetwork else { return check(.failed, "网络连通检测需要有效的 Claude trace IP") }
        guard let evidence else {
            return check(.failed, result.exitCode == 0 ? "检测返回格式无效" : "请求失败 · 退出码 \(result.exitCode)")
        }
        guard evidence.connectStatus == 200 else {
            return check(.failed, evidence.connectStatus == 0 ? "代理 CONNECT 未建立" : "代理 CONNECT 返回 HTTP \(evidence.connectStatus)")
        }
        guard evidence.tlsVerification == 0 else { return check(.failed, "TLS 证书验证失败") }
        guard result.exitCode == 0 else { return check(.failed, "请求失败 · 退出码 \(result.exitCode)") }
        guard let status = evidence.httpStatus else { return check(.failed, "未收到站点 HTTP 响应") }
        if (200...299).contains(status) {
            return check(.passed, "可达 · HTTP \(status)")
        }
        if status == 401 && target.acceptsUnauthenticatedResponse {
            return check(.passed, "API 可达 · HTTP 401（未携带凭据）")
        }
        // An HTTP rejection is evidence of a reachable website, not a dead tunnel.
        if [401, 403, 429].contains(status) { return check(.restricted, "访问受限 · HTTP \(status)") }
        return check(.failed, "站点返回 HTTP \(status)")
    }

    static func evaluateNetwork(_ result: CommandResult, checkedAt: Date = Date()) -> WebsiteCheckResult {
        do {
            let trace = try IPRiskProbe.trace(from: result)
            return .init(target: .claudeNetwork, state: .passed, message: "网络已通 · HTTP \(trace.httpStatus)",
                httpStatus: trace.httpStatus, elapsedMilliseconds: trace.elapsedMilliseconds, checkedAt: checkedAt,
                exitIP: trace.ip, countryCode: trace.countryCode)
        } catch {
            return .init(target: .claudeNetwork, state: .failed,
                message: "网络检测失败：\(error.localizedDescription)", checkedAt: checkedAt)
        }
    }

    /// Reconstruct only numeric evidence; response headers and stderr never enter logs.
    static func publicEvidenceLog(_ result: CommandResult, target: WebsiteTarget) -> String {
        let process = "exit=\(result.exitCode) timeout=\(result.timedOut) truncated=\(result.stdoutTruncated)"
        guard let value = evidence(from: result.stdout, target: target) else {
            return "TM_WEBSITE_INVALID \(target.rawValue) \(process)"
        }
        return "TM_WEBSITE_V1 \(target.rawValue) CONNECT=\(value.connectStatus) HTTP=\(value.httpStatus ?? 0) " +
            "TLS=\(value.tlsVerification) elapsedMs=\(value.elapsedMilliseconds) \(process)"
    }

    private static func evidenceFields(_ output: String) -> [Substring]? {
        let lines = output.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        let markers = lines.indices.filter { lines[$0].split(whereSeparator: { $0.isWhitespace }).first == "TM_WEBSITE_V1" }
        guard markers.count == 1, let index = markers.first,
              lines.dropFirst(index + 1).allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
        return lines[index].split(whereSeparator: { $0.isWhitespace })
    }

    static func aggregate(_ results: [WebsiteCheckResult]) -> ProxyCheckState {
        guard !results.isEmpty else { return .unchecked }
        if results.allSatisfy({ $0.state == .unchecked }) { return .unchecked }
        if results.contains(where: { $0.state == .checking || $0.state == .unchecked }) { return .checking }
        if results.allSatisfy({ $0.state == .passed }) { return .passed }
        if results.allSatisfy({ $0.state == .failed }) { return .failed }
        return .partial
    }
}
