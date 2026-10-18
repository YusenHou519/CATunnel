import SwiftUI
import TunnelCore

private enum TunnelPalette {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let ink = Color.primary
    static let muted = Color.secondary
    static let accent = Color.accentColor
    static let border = Color(nsColor: .separatorColor)
    static let subtle = Color.primary.opacity(0.035)
    static let card = Color(nsColor: .textBackgroundColor)
    static let logTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
    static let checkTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}

struct DashboardView: View {
    @ObservedObject var store: TunnelStore
    @State private var pendingDeletion: ServerProfile?
    @State private var showingDeleteConfirmation = false
    @State private var operationError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                if let message = store.configurationError {
                    ProfileConfigurationErrorView(message: message)
                }
                if let operationError {
                    Label(operationError, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("dashboard-profile-error")
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("服务器")
                            .font(.system(size: 15, weight: .semibold))
                        Text("\(store.profiles.count) 台")
                            .font(.system(size: 12))
                            .foregroundColor(TunnelPalette.muted)
                        Spacer()
                        Text("可同时连接")
                            .font(.system(size: 12))
                            .foregroundColor(TunnelPalette.muted)
                        Button(action: addServer) {
                            Label("添加服务器", systemImage: "plus")
                        }
                        .disabled(store.configurationError != nil)
                        .accessibilityIdentifier("dashboard-add-server")
                    }

                    if store.profiles.isEmpty {
                        ServerListEmptyState(compact: false, canAdd: store.configurationError == nil,
                                             identifierPrefix: "dashboard", onAdd: addServer,
                                             onGuide: { GettingStartedWindow.shared.show(store: store) })
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: 16, alignment: .top)],
                                  alignment: .leading, spacing: 16) {
                            ForEach(store.profiles) { profile in
                                serverCard(profile)
                            }
                        }
                    }
                }

                if let profile = store.selectedProfile {
                    logPanel(profile)
                }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .padding(.top, 1)
                    Text("开启隧道后，请将服务器上需要联网的程序指向对应代理地址。管理器不会自动修改 Cursor 或服务器代理配置。")
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundColor(TunnelPalette.muted)
            }
            .padding(26)
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(TunnelPalette.background)
        .foregroundColor(TunnelPalette.ink)
        .tint(TunnelPalette.accent)
        .alert("删除服务器？", isPresented: $showingDeleteConfirmation, presenting: pendingDeletion) { profile in
            Button("取消", role: .cancel) { pendingDeletion = nil }
            Button("删除", role: .destructive) { removeServer(profile) }
        } message: { profile in
            Text("将从 CATunnel 移除“\(profile.name)”的本机配置和日志。服务器上的文件不会被修改。")
        }
    }

    private func addServer() {
        guard store.configurationError == nil else { return }
        ProfileEditorWindow.shared.show(profile: .draft(), isNew: true, store: store)
    }

    private func removeServer(_ profile: ServerProfile) {
        defer { pendingDeletion = nil }
        do {
            try store.remove(profile.id)
            operationError = nil
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func modificationHelp(_ profile: ServerProfile) -> String {
        if store.configurationError != nil { return "请先修复本机配置，再修改服务器。" }
        return store.canModify(profile.id) ? "编辑服务器和端口设置" : "请先断开隧道并等待检测结束，再编辑或删除。"
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(TunnelPalette.accent)
                    .frame(width: 48, height: 48)
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("CATunnel")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("独立管理 SSH 隧道，连接到 Mac 上的本地代理")
                    .font(.system(size: 12))
                    .foregroundColor(TunnelPalette.muted)
            }
            Spacer()
            Button {
                GettingStartedWindow.shared.show(store: store)
            } label: {
                Label("使用引导", systemImage: "questionmark.circle")
            }
            .accessibilityIdentifier("dashboard-getting-started")
            Label("SSH 反向端口转发", systemImage: "arrow.left.arrow.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(TunnelPalette.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(TunnelPalette.card.opacity(0.85), in: Capsule())
        }
    }

    private func serverCard(_ profile: ServerProfile) -> some View {
        let status = store.presentationStatus(for: profile.id)
        let presentation = phasePresentation(status.phase)
        let active = isActive(status.phase)
        let selected = store.selectedID == profile.id

        return VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "server.rack")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(TunnelPalette.accent)
                    .frame(width: 38, height: 38)
                    .background(TunnelPalette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    Text(profile.host)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(TunnelPalette.muted)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 4)
                Label(presentation.title, systemImage: presentation.icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(presentation.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(presentation.color.opacity(0.08), in: Capsule())
            }

            VStack(spacing: 10) {
                HStack {
                    Text("服务器代理")
                        .foregroundColor(TunnelPalette.muted)
                    Spacer(minLength: 4)
                    Text("127.0.0.1:\(String(profile.remotePort))")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                    Button {
                        store.copyProxy(profile.id)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(TunnelPalette.accent)
                    .help("复制代理地址 http://127.0.0.1:\(String(profile.remotePort))")
                    .accessibilityLabel("复制 \(profile.name) 的代理地址")
                    .accessibilityIdentifier("copy-\(profile.id)")
                }
                Rectangle()
                    .fill(TunnelPalette.border.opacity(0.7))
                    .frame(height: 1)
                HStack {
                    Text("本机代理")
                        .foregroundColor(TunnelPalette.muted)
                    Spacer(minLength: 4)
                    Text("127.0.0.1:\(String(profile.localPort))")
                        .font(.system(size: 12, design: .monospaced))
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 12))
                        .foregroundColor(TunnelPalette.muted)
                }
            }
            .font(.system(size: 12))
            .padding(12)
            .background(TunnelPalette.subtle, in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 6) {
                Text(status.message.isEmpty ? "等待开启隧道" : status.message)
                    .font(.system(size: 12))
                    .foregroundColor(statusColor(status.phase))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(status.message)
                proxyStatus(status)
            }
            .frame(minHeight: 37, alignment: .topLeading)

            HStack(spacing: 8) {
                Button {
                    store.selectedID = profile.id
                    if active {
                        store.stop(profile.id)
                    } else {
                        store.start(profile.id)
                    }
                } label: {
                    Label(active ? "关闭隧道" : "开启隧道", systemImage: active ? "stop.fill" : "play.fill")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.borderedProminent)
                .tint(active ? Color.secondary : TunnelPalette.accent)
                .accessibilityIdentifier("\(active ? "stop" : "start")-\(profile.id)")

                Button {
                    store.selectedID = profile.id
                    store.testProxy(profile.id)
                } label: {
                    Label("测试连接", systemImage: "network")
                        .font(.system(size: 12))
                        .padding(.vertical, 3)
                }
                .buttonStyle(.bordered)
                .disabled(!canTest(status))
                .help(profile.assessIPRisk ? "通过服务器隧道检测服务，并获取 Net.Coffee 出口 IP 风险评分" : "通过服务器隧道检测服务；Net.Coffee 评分未开启")
                .accessibilityIdentifier("test-\(profile.id)")

                Button {
                    store.selectedID = profile.id
                    ProfileEditorWindow.shared.show(profile: profile, isNew: false, store: store)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 19, height: 21)
                }
                .buttonStyle(.bordered)
                .disabled(!store.canModify(profile.id))
                .help(modificationHelp(profile))
                .accessibilityLabel("\(profile.name) 设置")
                .accessibilityIdentifier("settings-\(profile.id)")

                Button(role: .destructive) {
                    pendingDeletion = profile
                    showingDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 19, height: 21)
                }
                .buttonStyle(.bordered)
                .disabled(!store.canModify(profile.id))
                .help(store.canModify(profile.id) ? "删除本机服务器配置" : modificationHelp(profile))
                .accessibilityLabel("删除 \(profile.name)")
                .accessibilityIdentifier("delete-\(profile.id)")
            }

            if store.isShowingHistoricalResults(for: profile.id) {
                Label("以下为上次连接的历史检测结果", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }
            if let checkedAt = store.lastCompletedCheckAt(for: profile.id) {
                Text("上次检测：\(TunnelPalette.checkTime.string(from: checkedAt))")
                    .font(.system(size: 10))
                    .foregroundColor(TunnelPalette.muted)
            }
            websiteResults(status, serverID: profile.id)
            ipRiskResult(status.ipRisk, serverID: profile.id)

            HStack {
                Label(profile.autoReconnect ? "自动重连" : "手动连接", systemImage: profile.autoReconnect ? "arrow.triangle.2.circlepath" : "hand.tap")
                    .font(.system(size: 11))
                    .foregroundColor(TunnelPalette.muted)
                Spacer()
                Button {
                    store.selectedID = profile.id
                } label: {
                    HStack(spacing: 4) {
                        Text(selected ? "正在查看日志" : "查看日志")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .font(.system(size: 11, weight: selected ? .medium : .regular))
                }
                .buttonStyle(.plain)
                .foregroundColor(TunnelPalette.accent)
                .accessibilityIdentifier("logs-\(profile.id)")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(TunnelPalette.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(selected ? TunnelPalette.accent.opacity(0.35) : TunnelPalette.border, lineWidth: 1)
        }
        .shadow(color: TunnelPalette.ink.opacity(0.025), radius: 12, x: 0, y: 4)
    }

    private func websiteResults(_ status: TunnelStatus, serverID: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("站点连通性")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .help("请求通过服务器隧道发出。Claude 网络连通读取 trace 响应，显示出口 IP 与地区。API 的 HTTP 401 表示已到达服务，但请求未携带认证。未测试账户登录或模型调用。")
            }
            .foregroundColor(TunnelPalette.muted)

            VStack(spacing: 7) {
                ForEach(status.websiteResults) { result in
                    websiteResultRow(result, serverID: serverID)
                }
            }

            Text("网络连通与下方的 IP 风险分别检测。")
                .font(.system(size: 10))
                .foregroundColor(TunnelPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .background(TunnelPalette.subtle, in: RoundedRectangle(cornerRadius: 10))
    }

    private func ipRiskResult(_ result: IPRiskCheckResult, serverID: String) -> some View {
        let enabled = store.profiles.first(where: { $0.id == serverID })?.assessIPRisk == true
        let presentation = ipRiskPresentation(!enabled && result.state == .unchecked ? .skipped : result.state)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "shield.lefthalf.filled")
                    .foregroundColor(TunnelPalette.accent)
                Text("Claude IP 风险 · Net.Coffee")
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 4)
                Label(presentation.title, systemImage: presentation.icon)
                    .font(.system(size: 10))
                    .foregroundColor(presentation.color)
            }

            switch result.state {
            case .available:
                if let assessment = result.assessment {
                    ipRiskAssessment(assessment, exitIP: result.ip)
                } else {
                    Text("未返回可展示的风险详情。")
                        .font(.system(size: 11))
                        .foregroundColor(TunnelPalette.muted)
                }
            case .unchecked:
                Text(enabled ? "点击“测试连接”获取代理出口的 IP 风险评估。" : "未开启 Net.Coffee 评分，可在服务器设置中选择启用。")
                    .font(.system(size: 11))
                    .foregroundColor(TunnelPalette.muted)
            case .checking, .failed, .skipped:
                VStack(alignment: .leading, spacing: 6) {
                    if let ip = result.ip {
                        HStack(spacing: 6) {
                            Text("出口 IP")
                                .foregroundColor(TunnelPalette.muted)
                            Text(ip)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .textSelection(.enabled)
                            if let countryCode = result.countryCode, !countryCode.isEmpty {
                                Text(countryCode)
                                    .foregroundColor(TunnelPalette.muted)
                            }
                        }
                        .font(.system(size: 11))
                    }
                    Text(ipRiskMessage(result))
                        .font(.system(size: 11))
                        .foregroundColor(presentation.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if case .available = result.state {
                Text("数据：Net.Coffee；评分仅供参考，不代表 Claude 账户或模型可用。")
                    .font(.system(size: 10))
                    .foregroundColor(TunnelPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("等级按信任分划分：95 分及以上为极度纯净，80 分及以上为纯净，50 分及以上为良好，25 分及以上为中性，其余为可疑。未进行 Claude 登录或模型调用测试。")
            }
        }
        .padding(11)
        .background(TunnelPalette.subtle, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("ip-risk-\(serverID)")
    }

    private func ipRiskAssessment(_ assessment: IPRiskAssessment, exitIP: String?) -> some View {
        let displayedIP = exitIP ?? assessment.ip

        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(displayedIP)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Text(ipRiskLocation(assessment))
                        .font(.system(size: 11))
                        .foregroundColor(TunnelPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 2)
                VStack(alignment: .trailing, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(assessment.trustScore.map { ipRiskScore($0) } ?? "—")
                            .font(.system(size: 23, weight: .semibold, design: .rounded))
                        Text("/100")
                            .font(.system(size: 10))
                            .foregroundColor(TunnelPalette.muted)
                    }
                    .foregroundColor(ipRiskScoreColor(assessment.trustScore))
                    Text("信任分 · \(assessment.scoreLabel) · 仅供参考")
                        .font(.system(size: 10))
                        .foregroundColor(TunnelPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .help("Net.Coffee 第三方评分，不代表 Claude 登录或模型调用一定可用。")
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            if displayedIP != assessment.ip {
                VStack(alignment: .leading, spacing: 4) {
                    Text("评分、地区及以下详情为该网段缓存记录。")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.orange)
                    Text("网段缓存：\(assessment.cidr ?? "未提供")")
                    Text("记录 IP：\(assessment.ip)")
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(TunnelPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .help("主 IP 是本次检测到的代理出口 IP；评分、地区和风险标记来自 Net.Coffee 对该网段的缓存记录，不是对当前 IP 的实时测量。")
            }

            VStack(alignment: .leading, spacing: 5) {
                ipRiskDetail("ASN", value: joinedRiskValues([assessment.asn, assessment.asOrganization]))
                ipRiskDetail("IP 类型", value: assessment.ipType)
            }

            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    ipRiskFlag("VPN", value: assessment.isVPN)
                    ipRiskFlag("代理", value: assessment.isProxy)
                    ipRiskFlag("Tor", value: assessment.isTor)
                }
                HStack(spacing: 8) {
                    ipRiskFlag("滥用", value: assessment.isAbuser)
                    ipRiskFlag("爬虫", value: assessment.isCrawler)
                    Color.clear.frame(maxWidth: .infinity, minHeight: 1, maxHeight: 1)
                }
            }

            Text(assessment.conclusion)
                .font(.system(size: 11))
                .foregroundColor(TunnelPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func ipRiskDetail(_ title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .foregroundColor(TunnelPalette.muted)
                .frame(width: 42, alignment: .leading)
            Text(value.isEmpty ? "未知" : value)
                .foregroundColor(TunnelPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .font(.system(size: 11))
    }

    private func ipRiskFlag(_ title: String, value: Bool?) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundColor(TunnelPalette.muted)
            Text(value.map { $0 ? "是" : "否" } ?? "未知")
                .foregroundColor(value == true ? Color.orange : TunnelPalette.ink)
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func joinedRiskValues(_ values: [String?]) -> String {
        let present = values.compactMap { value -> String? in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }
        return present.isEmpty ? "未知" : present.joined(separator: " · ")
    }

    private func ipRiskLocation(_ assessment: IPRiskAssessment) -> String {
        let country = assessment.country?.isEmpty == false ? assessment.country : assessment.countryCode
        return joinedRiskValues([country, assessment.city])
    }

    private func ipRiskScore(_ score: Double) -> String {
        String(format: score.rounded() == score ? "%.0f" : "%.1f", locale: Locale(identifier: "en_US_POSIX"), score)
    }

    private func ipRiskScoreColor(_ score: Double?) -> Color {
        guard let score else { return TunnelPalette.muted }
        if score >= 80 { return Color.green }
        if score >= 50 { return Color.orange }
        if score >= 25 { return Color.orange }
        return Color.red
    }

    private func ipRiskMessage(_ result: IPRiskCheckResult) -> String {
        if !result.message.isEmpty { return result.message }
        switch result.state {
        case .checking:
            switch result.stage {
            case .riskAssessment: return "正在查询 Net.Coffee 风险数据…"
            case .exitIP, .none: return "正在识别代理出口 IP…"
            }
        case .failed: return "风险评估未完成，请查看日志或重新测试。"
        case .unchecked: return "尚未测试。"
        case .available: return "已获取风险数据。"
        case .skipped: return "未开启 Net.Coffee 评分；未向该服务发送出口 IP。"
        }
    }

    private func ipRiskPresentation(_ state: IPRiskCheckState) -> (title: String, icon: String, color: Color) {
        switch state {
        case .unchecked: return ("未测试", "circle.dotted", TunnelPalette.muted)
        case .checking: return ("获取中", "arrow.triangle.2.circlepath", TunnelPalette.accent)
        case .available: return ("已获取", "checkmark.circle", TunnelPalette.accent)
        case .failed: return ("未完成", "exclamationmark.circle", Color.orange)
        case .skipped: return ("未开启", "minus.circle", TunnelPalette.muted)
        }
    }

    private func websiteResultRow(_ result: WebsiteCheckResult, serverID: String) -> some View {
        let presentation = websitePresentation(result)
        let metadata = websiteMetadata(result)

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Text(result.target.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(metadata)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(TunnelPalette.muted)
                    .lineLimit(1)
                Label(presentation.title, systemImage: presentation.icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(presentation.color)
                    .fixedSize(horizontal: true, vertical: false)
            }
            if result.target == .claudeNetwork, let exitIP = result.exitIP {
                Text("出口 IP：\(exitIP) · 地区：\(result.countryCode ?? "未知")")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(TunnelPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(minHeight: 16)
        .help(websiteHelp(result))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("website-\(serverID)-\(result.target.rawValue)")
    }

    private func websiteHelp(_ result: WebsiteCheckResult) -> String {
        let detail: String
        switch result.target {
        case .claudeNetwork:
            detail = "读取 Claude 边缘网络的 trace 响应，验证网络可达性并识别出口 IP 与地区。"
        default:
            detail = "仅检查连通性。"
        }
        return "\(result.target.url)\n\(result.message)\n\(detail)\n未测试账户登录或模型调用。"
    }

    private func websiteMetadata(_ result: WebsiteCheckResult) -> String {
        var values: [String] = []
        if let httpStatus = result.httpStatus {
            values.append("HTTP \(httpStatus)")
        }
        if let elapsedMilliseconds = result.elapsedMilliseconds {
            values.append("\(elapsedMilliseconds) ms")
        }
        return values.joined(separator: " · ")
    }

    private func websitePresentation(_ result: WebsiteCheckResult) -> (title: String, icon: String, color: Color) {
        switch result.state {
        case .unchecked: return ("未测试", "circle.dotted", TunnelPalette.muted)
        case .checking: return ("测试中", "arrow.triangle.2.circlepath", TunnelPalette.accent)
        case .passed: return (result.target == .claudeNetwork ? "正常" : "可达", "checkmark.circle.fill", Color.green)
        case .restricted: return ("访问受限", "exclamationmark.circle", Color.orange)
        case .failed: return ("失败", "xmark.circle", Color.red)
        }
    }

    private func logPanel(_ profile: ServerProfile) -> some View {
        let entries = store.logs[profile.id] ?? []

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "text.alignleft")
                    .foregroundColor(TunnelPalette.accent)
                Text("连接日志")
                    .font(.system(size: 14, weight: .semibold))
                Text(profile.host)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(TunnelPalette.muted)
                Spacer()
                Button("清空") {
                    store.clearLogs(profile.id)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(entries.isEmpty ? TunnelPalette.muted.opacity(0.5) : TunnelPalette.accent)
                .disabled(entries.isEmpty)
                .accessibilityIdentifier("clear-logs-\(profile.id)")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 15)

            Rectangle()
                .fill(TunnelPalette.border)
                .frame(height: 1)

            if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.system(size: 23, weight: .light))
                        .foregroundColor(TunnelPalette.muted.opacity(0.6))
                    Text("等待第一次连接")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(TunnelPalette.muted)
                    Text("开启隧道后，这里会记录连接状态和测试结果。")
                        .font(.system(size: 12))
                        .foregroundColor(TunnelPalette.muted.opacity(0.85))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 132)
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 9) {
                            ForEach(entries) { entry in
                                HStack(alignment: .top, spacing: 14) {
                                    Text(TunnelPalette.logTime.string(from: entry.date))
                                        .foregroundColor(TunnelPalette.muted)
                                        .frame(width: 65, alignment: .leading)
                                    Text(entry.message)
                                        .foregroundColor(TunnelPalette.ink)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                                .font(.system(size: 11, design: .monospaced))
                                .id(entry.id)
                            }
                        }
                        .padding(16)
                    }
                    .frame(height: 132)
                    .onChange(of: entries.count) { _ in
                        if let last = entries.last {
                            reader.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .background(TunnelPalette.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(TunnelPalette.border, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func proxyStatus(_ status: TunnelStatus) -> some View {
        switch status.proxyCheck {
        case .unchecked:
            Label("代理尚未测试", systemImage: "circle.dotted")
                .font(.system(size: 11))
                .foregroundColor(TunnelPalette.muted)
        case .checking:
            Label("正在验证代理出口…", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: 11))
                .foregroundColor(TunnelPalette.accent)
        case .passed:
            Label(status.proxyMessage.isEmpty ? "代理测试通过" : status.proxyMessage, systemImage: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(Color.green)
                .lineLimit(1)
                .help(status.proxyMessage)
        case .partial:
            Label(status.proxyMessage.isEmpty ? "部分站点受限或不可达" : status.proxyMessage, systemImage: "exclamationmark.circle")
                .font(.system(size: 11))
                .foregroundColor(Color.orange)
                .lineLimit(1)
                .help(status.proxyMessage)
        case .failed:
            Label(status.proxyMessage.isEmpty ? "代理测试未通过，请查看日志" : status.proxyMessage, systemImage: "exclamationmark.circle")
                .font(.system(size: 11))
                .foregroundColor(Color.red)
                .lineLimit(1)
                .help(status.proxyMessage)
        }
    }

    private func isActive(_ phase: TunnelPhase) -> Bool {
        switch phase {
        case .checking, .connecting, .connected, .reconnecting: return true
        case .stopped, .failed: return false
        }
    }

    private func canTest(_ status: TunnelStatus) -> Bool {
        guard case .connected = status.phase else { return false }
        if case .checking = status.proxyCheck { return false }
        if case .checking = status.ipRisk.state { return false }
        return true
    }

    private func statusColor(_ phase: TunnelPhase) -> Color {
        if case .failed = phase {
            return Color.red
        }
        return TunnelPalette.muted
    }

    private func phasePresentation(_ phase: TunnelPhase) -> (title: String, icon: String, color: Color) {
        switch phase {
        case .stopped: return ("未开启", "circle", TunnelPalette.muted)
        case .checking: return ("检查中", "ellipsis.circle", TunnelPalette.accent)
        case .connecting: return ("连接中", "arrow.left.arrow.right", TunnelPalette.accent)
        case .connected: return ("已连接", "checkmark.circle.fill", Color.green)
        case .reconnecting: return ("重连中", "arrow.triangle.2.circlepath", Color.orange)
        case .failed: return ("连接失败", "exclamationmark.circle", Color.red)
        }
    }
}
