import Foundation

public struct Ping0Assessment: Codable, Equatable, Sendable {
    public let ip: String
    public let ipType: String?
    public let riskValue: Double?
    public let sharedUsers: String?

    public init(ip: String, ipType: String? = nil, riskValue: Double? = nil, sharedUsers: String? = nil) {
        self.ip = ip; self.ipType = ipType; self.riskValue = riskValue; self.sharedUsers = sharedUsers
    }
}

public struct Ping0CheckResult: Codable, Equatable, Sendable {
    public var state: IPRiskCheckState
    public var message: String
    public var assessment: Ping0Assessment?
    public var ip: String?
    public var checkedAt: Date?

    public init(state: IPRiskCheckState = .unchecked, message: String = "尚未检测 Ping0",
                assessment: Ping0Assessment? = nil, ip: String? = nil, checkedAt: Date? = nil) {
        self.state = state; self.message = message; self.assessment = assessment
        self.ip = ip; self.checkedAt = checkedAt
    }

    public static func skipped(ip: String? = nil, checkedAt: Date? = nil) -> Ping0CheckResult {
        .init(state: .skipped, message: "未开启 Ping0 检测；未向该服务发送出口 IP", ip: ip, checkedAt: checkedAt)
    }
}

enum Ping0AssessmentPlan {
    case completed(Ping0CheckResult)
    case request(command: String, ip: String)

    static func make(enabled: Bool, networkResult: WebsiteCheckResult, remotePort: Int,
                     checkedAt: Date) throws -> Ping0AssessmentPlan {
        let ip = networkResult.state == .passed ? networkResult.exitIP.flatMap(RiskIPAddress.canonical) : nil
        guard enabled else { return .completed(.skipped(ip: ip, checkedAt: checkedAt)) }
        guard let ip else {
            return .completed(.init(state: .failed, message: "未取得有效 Claude 出口 IP；\(networkResult.message)",
                                    checkedAt: checkedAt))
        }
        return .request(command: try SSHCommands.ping0AssessmentCommand(port: remotePort, ip: ip), ip: ip)
    }
}

struct Ping0ProbeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum Ping0Probe {
    static let bodyLimit = 262_144
    private static let changedPage = "Ping0 页面需要验证或结构已变化，未提取检测结果；可在浏览器中手动查看"

    static func assessment(from result: CommandResult, expectedIP: String) throws -> Ping0Assessment {
        guard let expected = RiskIPAddress.canonical(expectedIP) else { throw failure("待查询 IP 无效") }
        let html = try body(from: result)
        let page = try Ping0HTML(html)
        let titles = page.matching(tag: "title")
        guard titles.count == 1 else { throw failure(changedPage) }
        let title = page.text(titles[0])
        guard let separator = title.firstIndex(of: "-"),
              let reported = RiskIPAddress.canonical(String(title[..<separator]).trimmingCharacters(in: .whitespaces)) else {
            throw failure(changedPage)
        }
        guard reported == expected else { throw failure("Ping0 返回的 IP 与当前出口不一致") }
        let panels = page.matching(classes: ["info", "asninfo"])
        guard panels.count == 1 else { throw failure(changedPage) }
        let panel = panels[0]
        let ipRows = page.matching(classes: ["line", "ip"], inside: panel)
        guard ipRows.count == 1 else { throw failure(changedPage) }
        let traceIPs = page.matching(tag: "a", inside: ipRows[0]).compactMap { index -> String? in
            guard let href = page.nodes[index].attributes["href"], let url = URLComponents(string: href),
                  url.scheme == "https", url.host == "ping0.cc", url.port == nil,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.path.hasPrefix("/trace/") else { return nil }
            return RiskIPAddress.canonical(String(url.path.dropFirst("/trace/".count)))
        }
        guard traceIPs == [expected] else { throw failure("Ping0 页面缺少一致的查询 IP 证据") }

        func row(_ name: String) throws -> Int? {
            let rows = page.matching(classes: ["line", name], inside: panel)
            guard rows.count <= 1 else { throw failure(changedPage) }
            return rows.first
        }
        func content(_ row: Int) throws -> Int {
            let contents = page.nodes[row].children.filter { page.nodes[$0].classes.contains("content") }
            guard contents.count == 1 else { throw failure(changedPage) }
            return contents[0]
        }
        let typeRow = try row("line-iptype"), riskRow = try row("line-risk"), sharedRow = try row("line-usecount")
        guard typeRow != nil || riskRow != nil || sharedRow != nil else { throw failure(changedPage) }
        var ipType: String?, riskValue: Double?, sharedUsers: String?
        if let typeRow {
            let box = try content(typeRow)
            let labels = page.matching(classes: ["label"], inside: box).map { page.text($0) }
            guard labels.count <= 8 else { throw failure(changedPage) }
            if labels.isEmpty {
                guard isMissing(page.text(box)) else { throw failure(changedPage) }
            } else {
                let values = try labels.compactMap { try field($0, limit: 128) }
                if !values.isEmpty { ipType = values.joined(separator: "、") }
            }
        }
        if let riskRow {
            let box = try content(riskRow)
            let current = page.matching(classes: ["riskcurrent"], inside: box)
            guard current.count <= 1 else { throw failure(changedPage) }
            if let current = current.first {
                let values = page.matching(classes: ["value"], inside: current)
                guard values.count == 1 else { throw failure(changedPage) }
                if let value = try field(page.text(values[0]), limit: 24) {
                    guard value.range(of: "^[0-9]{1,3}(?:\\.[0-9]{1,3})?%$", options: .regularExpression) != nil,
                          let score = Double(value.dropLast()), score.isFinite, (0...100).contains(score) else {
                        throw failure("Ping0 风控值格式无效")
                    }
                    riskValue = score
                }
            } else if !isMissing(page.text(box)) {
                throw failure(changedPage)
            }
        }
        if let sharedRow {
            let box = try content(sharedRow)
            let bars = page.matching(classes: ["usecountbar"], inside: box)
            guard bars.count <= 1 else { throw failure(changedPage) }
            if let bar = bars.first {
                if let value = try field(page.text(bar), limit: 64) {
                    let pattern = "^(?:1\\s*-\\s*10|10\\s*-\\s*100|100\\s*-\\s*1000|1000\\s*-\\s*10000|10000\\s*\\+)(?:\\s*[（(][^()（）]{1,16}[)）])?$"
                    guard value.range(of: pattern, options: .regularExpression) != nil else {
                        throw failure("Ping0 共享人数分档格式无效")
                    }
                    if let attribute = page.nodes[bar].attributes["usecount"], Ping0HTML.normalized(attribute) != value {
                        throw failure("Ping0 共享人数证据不一致")
                    }
                    sharedUsers = value
                }
            } else if !isMissing(page.text(box)) {
                throw failure(changedPage)
            }
        }
        return .init(ip: expected, ipType: ipType, riskValue: riskValue, sharedUsers: sharedUsers)
    }

    private static func body(from result: CommandResult) throws -> String {
        guard !result.timedOut, result.exitCode != 28 else { throw failure("Ping0 请求超时") }
        guard !result.stdoutTruncated else { throw failure("Ping0 响应超过长度限制") }
        guard result.exitCode == 0 else { throw failure("Ping0 请求失败（退出码 \(result.exitCode)）") }
        let pieces = result.stdout.components(separatedBy: "\nTM_PING0_V1 ")
        guard pieces.count == 2, pieces[0].utf8.count <= bodyLimit else { throw failure("Ping0 响应格式无效或超过长度限制") }
        let fields = pieces[1].split(whereSeparator: { $0.isWhitespace })
        guard fields.count == 5, fields[0] == "assessment",
              fields[1].count == 3, let connect = Int(fields[1]), (0...599).contains(connect),
              fields[2].count == 3, let http = Int(fields[2]), (0...599).contains(http),
              let tls = Int(fields[3]), tls >= 0,
              let seconds = Double(fields[4]), seconds.isFinite, (0...86_400).contains(seconds) else {
            throw failure("Ping0 检测证据格式无效")
        }
        guard connect == 200 else { throw failure("Ping0 代理 CONNECT 未建立（\(connect)）") }
        guard tls == 0 else { throw failure("Ping0 TLS 证书验证失败") }
        guard (200...299).contains(http) else { throw failure("Ping0 返回 HTTP \(http)，可能需要验证或暂不可用") }
        return pieces[0]
    }

    private static func field(_ value: String, limit: Int) throws -> String? {
        guard value.count <= limit, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw failure(changedPage)
        }
        return isMissing(value) ? nil : value
    }

    private static func isMissing(_ value: String) -> Bool {
        ["", "-", "--", "未知", "暂无", "暂无数据", "未提供", "不提供", "N/A", "n/a"].contains(value)
    }

    private static func failure(_ message: String) -> Ping0ProbeError { .init(message: message) }
}

/// A bounded static tag reader, not a browser. Raw script/template text never becomes result nodes.
private struct Ping0HTML {
    struct Node {
        var tag: String
        var attributes: [String: String]
        var children: [Int] = []
        var pieces: [Piece] = []
        var classes: Set<String> { Set((attributes["class"] ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init)) }
    }
    enum Piece { case text(String), node(Int) }
    var nodes = [Node(tag: "", attributes: [:])]

    init(_ html: String) throws {
        let voidTags: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
        let ignoredTags: Set<String> = ["script", "style", "template", "noscript", "textarea", "iframe", "object", "svg", "math"]
        let attributes = try NSRegularExpression(pattern: #"([^\s"'<>/=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?"#)
        var stack = [0], cursor = html.startIndex
        func invalid() -> Ping0ProbeError { .init(message: "Ping0 页面结构无效或超过解析限制") }
        while cursor < html.endIndex {
            if html[cursor] != "<" {
                let end = html[cursor...].firstIndex(of: "<") ?? html.endIndex
                nodes[stack.last!].pieces.append(.text(Self.entities(String(html[cursor..<end]))))
                cursor = end
                continue
            }
            if html[cursor...].hasPrefix("<!--") {
                guard let end = html.range(of: "-->", range: cursor..<html.endIndex) else { throw invalid() }
                cursor = end.upperBound
                continue
            }
            guard let end = Self.tagEnd(html, from: cursor) else { throw invalid() }
            let token = String(html[html.index(after: cursor)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            cursor = html.index(after: end)
            if token.hasPrefix("!") || token.hasPrefix("?") { continue }
            let closing = token.hasPrefix("/")
            let source = closing ? String(token.dropFirst()) : token
            let name = String(source.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ":") }).lowercased()
            guard !name.isEmpty else { throw invalid() }
            if closing {
                if let position = stack.lastIndex(where: { nodes[$0].tag == name }) { stack.removeSubrange(position...) }
                continue
            }
            if ignoredTags.contains(name) {
                guard let close = Self.ignoredEnd(html, tag: name, from: cursor) else { throw invalid() }
                cursor = close
                continue
            }
            guard nodes.count < 10_000, stack.count < 128 else { throw invalid() }
            let rawAttributes = String(source.dropFirst(name.count))
            var values: [String: String] = [:]
            for match in attributes.matches(in: rawAttributes, range: NSRange(rawAttributes.startIndex..., in: rawAttributes)) {
                guard let keyRange = Range(match.range(at: 1), in: rawAttributes) else { continue }
                let key = String(rawAttributes[keyRange]).lowercased()
                guard ["class", "href", "usecount"].contains(key) else { continue }
                guard values[key] == nil else { throw invalid() }
                let valueRange = (2...4).compactMap { Range(match.range(at: $0), in: rawAttributes) }.first
                values[key] = Self.entities(valueRange.map { String(rawAttributes[$0]) } ?? "")
            }
            let index = nodes.count, parent = stack.last!
            nodes.append(Node(tag: name, attributes: values))
            nodes[parent].children.append(index); nodes[parent].pieces.append(.node(index))
            if !voidTags.contains(name), !token.hasSuffix("/") { stack.append(index) }
        }
    }

    func matching(tag: String? = nil, classes: Set<String> = [], inside root: Int = 0) -> [Int] {
        var result: [Int] = []
        func visit(_ index: Int) {
            for child in nodes[index].children {
                if (tag == nil || nodes[child].tag == tag), classes.isSubset(of: nodes[child].classes) { result.append(child) }
                visit(child)
            }
        }
        visit(root)
        return result
    }

    func text(_ index: Int) -> String {
        Self.normalized(nodes[index].pieces.map { piece in
            switch piece { case let .text(value): return value; case let .node(child): return text(child) }
        }.joined(separator: " "))
    }

    static func normalized(_ value: String) -> String { value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }

    private static func tagEnd(_ html: String, from start: String.Index) -> String.Index? {
        var cursor = html.index(after: start), quote: Character?
        while cursor < html.endIndex {
            let value = html[cursor]
            if let current = quote { if value == current { quote = nil } }
            else if value == "\"" || value == "'" { quote = value }
            else if value == ">" { return cursor }
            cursor = html.index(after: cursor)
        }
        return nil
    }

    private static func ignoredEnd(_ html: String, tag: String, from start: String.Index, depth: Int = 0) -> String.Index? {
        guard depth < 128 else { return nil }
        let rawTags: Set<String> = ["script", "style", "noscript", "textarea", "iframe"]
        let nestedTags = rawTags.union(["template", "object", "svg", "math"])
        var cursor = start
        while let next = html[cursor...].firstIndex(of: "<") {
            if !rawTags.contains(tag), html[next...].hasPrefix("<!--") {
                guard let end = html.range(of: "-->", range: next..<html.endIndex) else { return nil }
                cursor = end.upperBound
                continue
            }
            // Raw text can contain arbitrary '<' and quotes; only an exact closing tag ends it.
            if rawTags.contains(tag), !html[next...].prefix(tag.count + 2).lowercased().hasPrefix("</" + tag) {
                cursor = html.index(after: next)
                continue
            }
            guard let end = tagEnd(html, from: next) else { return nil }
            let token = String(html[html.index(after: next)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            let closing = token.hasPrefix("/")
            let source = closing ? String(token.dropFirst()) : token
            let name = String(source.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ":") }).lowercased()
            cursor = html.index(after: end)
            if closing, name == tag { return cursor }
            if !rawTags.contains(tag), !closing, nestedTags.contains(name), !token.hasSuffix("/") {
                guard let end = ignoredEnd(html, tag: name, from: cursor, depth: depth + 1) else { return nil }
                cursor = end
            }
        }
        return nil
    }

    private static func entities(_ value: String) -> String {
        guard value.contains("&"), let expression = try? NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]{1,6}|#[0-9]{1,7}|amp|lt|gt|quot|apos|nbsp);"#) else { return value }
        let names = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
        var result = value
        for match in expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard let full = Range(match.range, in: value), let part = Range(match.range(at: 1), in: value) else { continue }
            let name = String(value[part])
            var replacement = names[name]
            if name.hasPrefix("#") {
                let hexadecimal = name.hasPrefix("#x")
                if let number = UInt32(name.dropFirst(hexadecimal ? 2 : 1), radix: hexadecimal ? 16 : 10),
                   let scalar = UnicodeScalar(number) { replacement = String(scalar) }
            }
            if let replacement { result.replaceSubrange(full, with: replacement) }
        }
        return result
    }
}
