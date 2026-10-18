import Foundation
import CoreFoundation
import Darwin

public enum IPRiskCheckState: String, Codable, Sendable {
    case unchecked, checking, available, failed, skipped
}

public enum IPRiskCheckStage: String, Codable, Sendable {
    case exitIP, riskAssessment
}

public struct IPRiskCheckResult: Codable, Equatable, Sendable {
    public var state: IPRiskCheckState
    public var message: String
    public var stage: IPRiskCheckStage?
    public var assessment: IPRiskAssessment?
    public var ip: String?
    public var countryCode: String?
    public var checkedAt: Date?

    public init(state: IPRiskCheckState = .unchecked, message: String = "尚未检测出口 IP 风险",
                stage: IPRiskCheckStage? = nil, assessment: IPRiskAssessment? = nil,
                ip: String? = nil, countryCode: String? = nil, checkedAt: Date? = nil) {
        self.state = state; self.message = message; self.stage = stage; self.assessment = assessment
        self.ip = ip; self.countryCode = countryCode; self.checkedAt = checkedAt
    }

    public static func skipped(ip: String? = nil, countryCode: String? = nil,
                               checkedAt: Date? = nil) -> IPRiskCheckResult {
        .init(state: .skipped, message: "未开启 Net.Coffee 评分；未向该服务发送出口 IP",
              ip: ip, countryCode: countryCode, checkedAt: checkedAt)
    }
}

enum IPRiskAssessmentPlan {
    case completed(IPRiskCheckResult)
    case request(command: String, ip: String, countryCode: String?)

    static func make(enabled: Bool, networkResult: WebsiteCheckResult, remotePort: Int,
                     checkedAt: Date) throws -> IPRiskAssessmentPlan {
        let ip = networkResult.state == .passed ? networkResult.exitIP.flatMap(RiskIPAddress.canonical) : nil
        let country = ip == nil ? nil : networkResult.countryCode.flatMap(RiskIPAddress.countryCode)
        // Consent is checked before constructing a third-party request, even when the trace fails.
        guard enabled else {
            return .completed(.skipped(ip: ip, countryCode: country, checkedAt: checkedAt))
        }
        guard let ip else {
            return .completed(.init(state: .failed,
                message: "未取得有效 Claude 出口 IP；\(networkResult.message)", stage: .exitIP, checkedAt: checkedAt))
        }
        return .request(command: try SSHCommands.ipRiskAssessmentCommand(port: remotePort, ip: ip),
                        ip: ip, countryCode: country)
    }
}

public struct IPRiskAssessment: Codable, Equatable, Sendable {
    public let ip: String
    public let trustScore: Double?
    public let country: String?
    public let countryCode: String?
    public let city: String?
    public let asn: String?
    public let asOrganization: String?
    public let companyType: String?
    public let isDatacenter: Bool?
    public let isResidential: Bool?
    public let isVPN: Bool?
    public let isProxy: Bool?
    public let isTor: Bool?
    public let isAbuser: Bool?
    public let isCrawler: Bool?
    public let cidr: String?

    public init(ip: String, trustScore: Double? = nil, country: String? = nil, countryCode: String? = nil,
                city: String? = nil, asn: String? = nil, asOrganization: String? = nil, companyType: String? = nil,
                isDatacenter: Bool? = nil, isResidential: Bool? = nil, isVPN: Bool? = nil, isProxy: Bool? = nil,
                isTor: Bool? = nil, isAbuser: Bool? = nil, isCrawler: Bool? = nil, cidr: String? = nil) {
        self.ip = ip; self.trustScore = trustScore; self.country = country; self.countryCode = countryCode
        self.city = city; self.asn = asn; self.asOrganization = asOrganization; self.companyType = companyType
        self.isDatacenter = isDatacenter; self.isResidential = isResidential; self.isVPN = isVPN
        self.isProxy = isProxy; self.isTor = isTor; self.isAbuser = isAbuser; self.isCrawler = isCrawler
        self.cidr = cidr
    }

    public var scoreLabel: String {
        guard let score = trustScore else { return "未提供评分" }
        switch score {
        case 95...: return "极度纯净"
        case 80..<95: return "纯净"
        case 50..<80: return "良好"
        case 25..<50: return "中性"
        default: return "可疑"
        }
    }

    public var ipType: String {
        let sourceType = companyType.map { " (\($0))" } ?? ""
        if isResidential == true && isDatacenter == true { return "住宅与机房标记并存" + sourceType }
        if isResidential == true { return "住宅 IP" + sourceType }
        if isDatacenter == true { return "机房 IP" + sourceType }
        return companyType ?? "类型未知"
    }

    public var conclusion: String {
        let flags: [(String, Bool?)] = [("VPN", isVPN), ("代理", isProxy), ("Tor", isTor), ("滥用", isAbuser), ("爬虫", isCrawler)]
        let marked = flags.filter { $0.1 == true }.map(\.0)
        if !marked.isEmpty { return "服务标记：" + marked.joined(separator: "、") + "。仅供参考，不代表 Claude 账号可用性。" }
        if let trustScore, trustScore < 50 { return "信任分偏低，请结合风险标记评估当前出口；不代表 Claude 账号可用性。" }
        if isDatacenter == true { return "机房 IP；高信任分也不代表 Claude 登录或模型调用一定成功。" }
        if flags.allSatisfy({ $0.1 == false }) { return "服务未标记 VPN、代理、Tor、滥用或爬虫；不代表 Claude 账号可用性。" }
        return "缺失的风险标记仍为未知；评分仅供参考，不代表 Claude 账号可用性。"
    }

    enum CodingKeys: String, CodingKey {
        case ip, country, countryCode, city, asn, asOrganization, isResidential, cidr
        case trustScore = "trust_score", companyType = "company_type", isDatacenter = "is_datacenter"
        case isVPN = "is_vpn", isProxy = "is_proxy", isTor = "is_tor", isAbuser = "is_abuser", isCrawler = "is_crawler"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys, limit: Int = 512) throws -> String? {
            guard let raw = try values.decodeIfPresent(String.self, forKey: key) else { return nil }
            guard raw.count <= limit, !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: values, debugDescription: "Invalid text field")
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let rawIP = try values.decode(String.self, forKey: .ip)
        guard let canonicalIP = RiskIPAddress.canonical(rawIP) else {
            throw DecodingError.dataCorruptedError(forKey: .ip, in: values, debugDescription: "Invalid IP address")
        }
        ip = canonicalIP
        trustScore = try values.decodeIfPresent(Double.self, forKey: .trustScore)
        if let score = trustScore, !score.isFinite || !(0...100).contains(score) {
            throw DecodingError.dataCorruptedError(forKey: .trustScore, in: values, debugDescription: "Invalid score")
        }
        country = try text(.country); city = try text(.city)
        asOrganization = try text(.asOrganization); companyType = try text(.companyType)
        let rawCountryCode = try text(.countryCode, limit: 2)
        if let rawCountryCode, RiskIPAddress.countryCode(rawCountryCode) == nil {
            throw DecodingError.dataCorruptedError(forKey: .countryCode, in: values, debugDescription: "Invalid country code")
        }
        countryCode = rawCountryCode?.uppercased()
        if try !values.contains(.asn) || values.decodeNil(forKey: .asn) {
            asn = nil
        } else if let number = try? values.decode(UInt32.self, forKey: .asn) {
            asn = String(number)
        } else {
            let rawASN = try values.decode(String.self, forKey: .asn)
            guard !rawASN.isEmpty, rawASN.utf8.allSatisfy({ (48...57).contains($0) }), let number = UInt32(rawASN) else {
                throw DecodingError.dataCorruptedError(forKey: .asn, in: values, debugDescription: "Invalid ASN")
            }
            asn = String(number)
        }
        isDatacenter = try values.decodeIfPresent(Bool.self, forKey: .isDatacenter)
        isResidential = try values.decodeIfPresent(Bool.self, forKey: .isResidential)
        isVPN = try values.decodeIfPresent(Bool.self, forKey: .isVPN)
        isProxy = try values.decodeIfPresent(Bool.self, forKey: .isProxy)
        isTor = try values.decodeIfPresent(Bool.self, forKey: .isTor)
        isAbuser = try values.decodeIfPresent(Bool.self, forKey: .isAbuser)
        isCrawler = try values.decodeIfPresent(Bool.self, forKey: .isCrawler)
        if let rawCIDR = try values.decodeIfPresent(String.self, forKey: .cidr) {
            guard let network = RiskIPCIDR(rawCIDR) else {
                throw DecodingError.dataCorruptedError(forKey: .cidr, in: values, debugDescription: "Invalid CIDR")
            }
            cidr = network.description
        } else {
            cidr = nil
        }
    }
}

enum RiskIPAddress {
    static func canonical(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.utf8.count <= 45,
              raw.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) || $0 == 46 || $0 == 58 }) else { return nil }
        if raw.contains(".") {
            let dotted = raw.split(separator: ":", omittingEmptySubsequences: false).last ?? ""
            let octets = dotted.split(separator: ".", omittingEmptySubsequences: false)
            guard octets.count == 4, octets.allSatisfy({ part in
                guard let number = Int(part), (0...255).contains(number) else { return false }
                return String(number) == part
            }) else { return nil }
        }
        var ipv4 = in_addr(), ipv6 = in6_addr()
        if raw.withCString({ Darwin.inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return withUnsafePointer(to: &ipv4) { format($0, family: AF_INET) }
        }
        if raw.withCString({ Darwin.inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            return withUnsafePointer(to: &ipv6) { format($0, family: AF_INET6) }
        }
        return nil
    }

    private static func format<T>(_ address: UnsafePointer<T>, family: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        return buffer.withUnsafeMutableBufferPointer { output in
            guard let start = output.baseAddress,
                  let written = Darwin.inet_ntop(family, address, start, socklen_t(output.count)) else { return nil }
            return String(cString: written)
        }
    }

    static func encodedPath(_ raw: String) -> String? {
        canonical(raw)?.replacingOccurrences(of: ":", with: "%3A")
    }

    static func countryCode(_ raw: String) -> String? {
        guard raw.utf8.count == 2, raw.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }) else { return nil }
        return raw.uppercased()
    }
}

enum IPRiskPayload: String {
    case trace, assessment
}

struct RiskIPCIDR {
    let description: String
    private let networkBytes: [UInt8]
    private let masks: [UInt8]

    init?(_ raw: String) {
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let network = RiskIPAddress.canonical(String(parts[0])),
              let bytes = Self.bytes(network), let prefix = Int(parts[1]),
              String(prefix) == parts[1], prefix > 0, prefix <= bytes.count * 8 else { return nil }
        let masks = bytes.indices.map { index -> UInt8 in
            let remaining = prefix - index * 8
            if remaining >= 8 { return 0xff }
            if remaining <= 0 { return 0 }
            return UInt8(truncatingIfNeeded: 0xff << (8 - remaining))
        }
        // Require a network address, not an arbitrary host decorated with a prefix.
        guard zip(bytes, masks).allSatisfy({ $0.0 & ~$0.1 == 0 }) else { return nil }
        self.networkBytes = bytes
        self.masks = masks
        description = "\(network)/\(prefix)"
    }

    func contains(_ ip: String) -> Bool {
        guard let address = Self.bytes(ip), address.count == networkBytes.count else { return false }
        return address.indices.allSatisfy { address[$0] & masks[$0] == networkBytes[$0] }
    }

    private static func bytes(_ raw: String) -> [UInt8]? {
        guard let ip = RiskIPAddress.canonical(raw) else { return nil }
        var ipv4 = in_addr(), ipv6 = in6_addr()
        if ip.withCString({ Darwin.inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return withUnsafeBytes(of: &ipv4) { Array($0) }
        }
        if ip.withCString({ Darwin.inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            return withUnsafeBytes(of: &ipv6) { Array($0) }
        }
        return nil
    }
}

struct IPRiskProbeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum IPRiskProbe {
    static let bodyLimit = 16_384

    struct ExitIP: Equatable {
        let ip: String
        let countryCode: String?
        let httpStatus: Int
        let elapsedMilliseconds: Int
    }

    private struct Response {
        let body: String
        let httpStatus: Int
        let elapsedMilliseconds: Int
    }

    static func body(from result: CommandResult, payload: IPRiskPayload) throws -> String {
        try response(from: result, payload: payload).body
    }

    private static func response(from result: CommandResult, payload: IPRiskPayload) throws -> Response {
        func failure(_ message: String) -> IPRiskProbeError { .init(message: message) }
        guard !result.timedOut, result.exitCode != 28 else { throw failure("请求超时") }
        guard !result.stdoutTruncated else { throw failure("响应超过长度限制") }
        guard result.exitCode == 0 else { throw failure("请求失败（退出码 \(result.exitCode)）") }
        let delimiter = "\nTM_IPRISK_V1 "
        let pieces = result.stdout.components(separatedBy: delimiter)
        guard pieces.count == 2, pieces[0].utf8.count <= bodyLimit else { throw failure("响应格式无效或超过长度限制") }
        let fields = pieces[1].split(whereSeparator: { $0.isWhitespace })
        guard fields.count == 5, fields[0] == Substring(payload.rawValue),
              fields[1].count == 3, let connect = Int(fields[1]), (0...599).contains(connect),
              fields[2].count == 3, let http = Int(fields[2]), (0...599).contains(http),
              let tls = Int(fields[3]), tls >= 0,
              let seconds = Double(fields[4]), seconds.isFinite, (0...86_400).contains(seconds) else {
            throw failure("检测证据格式无效")
        }
        guard connect == 200 else { throw failure(connect == 0 ? "代理 CONNECT 未建立" : "代理 CONNECT 返回 HTTP \(connect)") }
        guard tls == 0 else { throw failure("TLS 证书验证失败（\(tls)）") }
        guard (200...299).contains(http) else { throw failure("HTTP \(http)，请求未通过") }
        return .init(body: pieces[0], httpStatus: http, elapsedMilliseconds: Int((seconds * 1000).rounded()))
    }

    static func trace(from result: CommandResult) throws -> ExitIP {
        let response = try response(from: result, payload: .trace)
        let trace = response.body
        var ip: String?, country: String?
        var seenIP = false, seenCountry = false
        for line in trace.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else { throw IPRiskProbeError(message: "出口 IP 响应格式无效") }
            let key = String(line[..<separator]), value = String(line[line.index(after: separator)...])
            guard !key.isEmpty, key.utf8.allSatisfy({ (97...122).contains($0) || $0 == 95 }) else {
                throw IPRiskProbeError(message: "出口 IP 响应格式无效")
            }
            if key == "ip" {
                guard !seenIP, let parsed = RiskIPAddress.canonical(value) else { throw IPRiskProbeError(message: "出口 IP 无效或重复") }
                seenIP = true; ip = parsed
            } else if key == "loc" {
                guard !seenCountry, let parsed = RiskIPAddress.countryCode(value) else { throw IPRiskProbeError(message: "出口地区格式无效或重复") }
                seenCountry = true; country = parsed
            }
        }
        guard let ip else { throw IPRiskProbeError(message: "响应未包含有效出口 IP") }
        return .init(ip: ip, countryCode: country, httpStatus: response.httpStatus,
                     elapsedMilliseconds: response.elapsedMilliseconds)
    }

    static func assessment(from result: CommandResult, expectedIP: String) throws -> IPRiskAssessment {
        guard let expected = RiskIPAddress.canonical(expectedIP) else { throw IPRiskProbeError(message: "待查询 IP 无效") }
        let response = try body(from: result, payload: .assessment)
        let data = Data(response.utf8)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["error"] == nil || object["error"] is NSNull else {
            throw IPRiskProbeError(message: "评分服务返回错误或非 JSON 数据")
        }
        if let success = object["success"], !(success is NSNull) {
            guard let flag = success as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(), flag.boolValue else {
                throw IPRiskProbeError(message: "评分服务返回失败状态或无效状态字段")
            }
        }
        let assessment: IPRiskAssessment
        do { assessment = try JSONDecoder().decode(IPRiskAssessment.self, from: data) }
        catch { throw IPRiskProbeError(message: "评分字段格式无效") }
        let cachedNetwork = assessment.cidr.flatMap(RiskIPCIDR.init)
        if let cachedNetwork, !cachedNetwork.contains(assessment.ip) {
            throw IPRiskProbeError(message: "评分来源 IP 不在服务返回的 CIDR 网段内")
        }
        guard assessment.ip == expected || cachedNetwork?.contains(expected) == true else {
            throw IPRiskProbeError(message: "评分响应 IP 与本次出口 IP 不一致，且无有效网段缓存证据")
        }
        let flags = [assessment.isDatacenter, assessment.isResidential, assessment.isVPN, assessment.isProxy,
                     assessment.isTor, assessment.isAbuser, assessment.isCrawler]
        guard assessment.trustScore != nil || flags.contains(where: { $0 != nil }) else {
            throw IPRiskProbeError(message: "评分服务未提供评分或风险标记")
        }
        return assessment
    }
}
