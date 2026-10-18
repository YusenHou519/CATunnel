import SwiftUI
import TunnelCore

struct MenuBarPanelView: View {
    @ObservedObject var store: TunnelStore
    let showDetails: () -> Void
    let showAbout: () -> Void
    let quit: () -> Void

    @State private var expandedRisk: Set<String> = []
    @State private var pendingDeletion: ServerProfile?
    @State private var showingDeleteConfirmation = false
    @State private var operationError: String?
    private static let checkTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            if store.demoMode {
                Label("离线演示 · 连接与检测均为示例", systemImage: "play.rectangle")
                    .font(panelFont(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
            }
            serverTabs
            Divider()
            if store.showingAppearanceSettings {
                AppearanceSettingsView(store: store)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let message = store.configurationError {
                        ProfileConfigurationErrorView(message: message)
                    }
                    if let operationError {
                        Label(operationError, systemImage: "exclamationmark.circle")
                            .font(panelFont(size: 11))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("panel-profile-error")
                    }
                    if let profile = store.selectedProfile {
                        serverPage(profile)
                    } else {
                        ServerListEmptyState(compact: true, canAdd: store.configurationError == nil,
                                             identifierPrefix: "panel", onAdd: addServer,
                                             onGuide: { GettingStartedWindow.shared.show(store: store) })
                    }
                }
                .padding(18)
            }
            Divider()
            footer
        }
        .frame(width: store.panelAppearance.width, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        // A transient status-item popover need not be the application's main window.
        .environment(\.controlActiveState, .active)
        .accessibilityIdentifier("catunnel-panel")
        .alert("删除服务器？", isPresented: $showingDeleteConfirmation, presenting: pendingDeletion) { profile in
            Button("取消", role: .cancel) { pendingDeletion = nil }
            Button("删除", role: .destructive) { removeServer(profile) }
        } message: { profile in
            Text("将从 CATunnel 移除“\(profile.name)”的本机配置和日志。服务器上的文件不会被修改。")
        }
    }

    private var serverTabs: some View {
        HStack(spacing: 6) {
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(store.profiles.enumerated()), id: \.element.id) { index, profile in
                            serverTab(profile, index: index)
                                .id(profile.id)
                        }
                    }
                }
                .onAppear { reader.scrollTo(store.selectedID, anchor: .trailing) }
                .onChange(of: store.selectedID) { id in reader.scrollTo(id, anchor: .trailing) }
                .onChange(of: store.profiles.map(\.id)) { _ in
                    reader.scrollTo(store.selectedID, anchor: .trailing)
                }
                .accessibilityIdentifier("server-tabs")
                .captureLayoutEvidence("server-tabs")
            }
            Button(action: addServer) {
                Image(systemName: "plus")
                    .font(panelFont(size: 14, weight: .medium))
                    .frame(width: 28, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.configurationError != nil)
            .help(store.configurationError == nil ? "添加服务器" : "请先修复本机配置，再添加服务器。")
            .accessibilityLabel("添加服务器")
            .accessibilityIdentifier("panel-add-server")
            .captureLayoutEvidence("panel-add-server")
        }
        .frame(height: 42 * store.panelAppearance.fontScale)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func serverTab(_ profile: ServerProfile, index: Int) -> some View {
        let phase = phasePresentation(store.status(for: profile.id).phase)
        let selected = store.selectedID == profile.id
        return Button {
            store.selectedID = profile.id
        } label: {
            VStack(spacing: 1) {
                Image(systemName: index == 0 ? "server.rack" : "externaldrive.connected.to.line.below")
                    .font(panelFont(size: 16, weight: .medium))
                    .frame(width: 24, height: 18 * store.panelAppearance.fontScale)
                    .overlay(alignment: .topTrailing) {
                        Circle()
                            .fill(phase.color)
                            .frame(width: 5, height: 5)
                            .offset(x: 4)
                            .accessibilityHidden(true)
                    }
                Text(profile.name)
                    .font(panelFont(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
            .frame(width: 60)
            .padding(.vertical, 4)
            .foregroundStyle(Color.primary)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(profile.name)，\(profile.host)，\(phase.title)")
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityIdentifier("server-tab-\(profile.id)")
        .captureLayoutEvidence("server-tab-\(profile.id)")
        .help("\(profile.host) · \(phase.title)；切换页面不会改变连接")
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

    private func serverPage(_ profile: ServerProfile) -> some View {
        let current = store.status(for: profile.id)
        let status = store.presentationStatus(for: profile.id)
        let phase = phasePresentation(current.phase)
        let historical = store.isShowingHistoricalResults(for: profile.id)
        let checking = current.proxyCheck == .checking || current.ipRisk.state == .checking

        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile.host)
                            .font(panelFont(size: 20, weight: .semibold))
                            .lineLimit(1)
                        Text("\(profile.user) · SSH \(String(profile.sshPort))")
                            .font(panelFont(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 6)
                    Toggle("开启隧道", isOn: Binding(
                        get: { isActive(current.phase) },
                        set: { enabled in enabled ? store.start(profile.id) : store.stop(profile.id) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel("\(profile.name) 的隧道开关")
                    .accessibilityIdentifier("tunnel-switch-\(profile.id)")
                    .padding(.top, 4)
                }
                HStack(spacing: 6) {
                    Label(phase.title, systemImage: phase.icon)
                        .foregroundStyle(phase.color)
                    Spacer()
                    if profile.autoReconnect {
                        Text("自动重连已开启").foregroundStyle(.secondary)
                    }
                }
                .font(panelFont(size: 11))

                if current.phase == .failed || current.phase == .reconnecting {
                    Text(current.message)
                        .font(panelFont(size: 11))
                        .foregroundStyle(phase.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            HStack(alignment: .top, spacing: 4) {
                route(profile)
                Spacer(minLength: 0)
                serverActions(profile)
            }
            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("服务连通性").font(panelFont(size: 13, weight: .semibold))
                    Spacer()
                    Button {
                        store.testProxy(profile.id)
                    } label: {
                        Label(checking ? "检测中" : "检测", systemImage: "arrow.clockwise")
                            .font(panelFont(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!canTest(current))
                    .help(profile.assessIPRisk ? "通过该服务器的隧道检测服务与出口风险" : "通过该服务器的隧道检测服务；Net.Coffee 评分未开启")
                    .accessibilityIdentifier("panel-test-\(profile.id)")
                }
                HStack(spacing: 4) {
                    if historical {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    Text(checkTimestamp(profile.id, historical: historical, checking: checking))
                }
                .font(panelFont(size: 10))
                .foregroundStyle(historical ? Color.orange : Color.secondary)
                .accessibilityIdentifier("check-timestamp-\(profile.id)")

                VStack(spacing: 11) {
                    ForEach(status.websiteResults) { result in
                        websiteRow(result, serverID: profile.id)
                    }
                }
                Text("API 可达不代表账户或模型调用可用。")
                    .font(panelFont(size: 10))
                    .foregroundStyle(.secondary)
            }

            Divider()
            riskSection(status.ipRisk, profile: profile, historical: historical)

        }
    }

    private func serverActions(_ profile: ServerProfile) -> some View {
        Menu {
            Button("编辑服务器…") {
                ProfileEditorWindow.shared.show(profile: profile, isNew: false, store: store)
            }
            .disabled(!store.canModify(profile.id))
            Button("删除服务器…", role: .destructive) {
                pendingDeletion = profile
                showingDeleteConfirmation = true
            }
            .disabled(!store.canModify(profile.id))
            if !store.canModify(profile.id) {
                Divider()
                Text(store.configurationError == nil ? "请先断开隧道并等待检测结束" : "请先修复本机配置")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(panelFont(size: 12))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("\(profile.name) 的服务器设置")
        .accessibilityIdentifier("panel-server-settings-\(profile.id)")
        .help(store.canModify(profile.id) ? "编辑或删除服务器" : "请先断开隧道并等待检测结束，再修改服务器。")
    }

    private func route(_ profile: ServerProfile) -> some View {
        ViewThatFits(in: .horizontal) {
            routeLine(profile)
            VStack(alignment: .leading, spacing: 4) {
                Label("服务器 :\(String(profile.remotePort))", systemImage: "arrow.left.arrow.right")
                Label("Mac · 本地代理 :\(String(profile.localPort))", systemImage: "arrow.right")
            }
        }
        .font(panelFont(size: 11))
        .foregroundStyle(.secondary)
        .help("服务器 127.0.0.1:\(profile.remotePort) → Mac 127.0.0.1:\(profile.localPort)")
        .accessibilityElement(children: .combine)
    }

    private func routeLine(_ profile: ServerProfile) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.left.arrow.right")
            Text("服务器 :\(String(profile.remotePort))")
            Image(systemName: "arrow.right")
            Text("Mac · 本地代理 :\(String(profile.localPort))")
        }
        .fixedSize()
    }

    private func websiteRow(_ result: WebsiteCheckResult, serverID: String) -> some View {
        let presentation = websitePresentation(result.state)
        return HStack(spacing: 7) {
            Image(systemName: presentation.icon)
                .foregroundStyle(presentation.color)
                .frame(width: 14)
            Text(result.target == .claudeNetwork ? "Claude 网络" : result.target.title)
                .font(panelFont(size: 12))
            Spacer(minLength: 3)
            if let milliseconds = result.elapsedMilliseconds {
                Text(milliseconds >= 1000 ? String(format: "%.2f s", Double(milliseconds) / 1000) : "\(milliseconds) ms")
                    .font(panelFont(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(presentation.title)
                .font(panelFont(size: 11, weight: .medium))
                .foregroundStyle(presentation.color)
                .frame(minWidth: 34, alignment: .trailing)
        }
        .help(websiteHelp(result))
        .accessibilityElement(children: .combine)
        .accessibilityHint(websiteHelp(result))
        .accessibilityIdentifier("panel-website-\(serverID)-\(result.target.rawValue)")
    }

    private func riskSection(_ result: IPRiskCheckResult, profile: ServerProfile, historical: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(historical ? "历史出口 IP 风险" : "出口 IP 风险", systemImage: "shield.lefthalf.filled")
                    .font(panelFont(size: 13, weight: .semibold))
                Spacer()
                Text("Net.Coffee").font(panelFont(size: 10)).foregroundStyle(.secondary)
            }

            if let assessment = result.assessment, result.state == .available {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(result.ip ?? "出口 IP 未提供")
                        .font(panelFont(size: 12, weight: .medium, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text(joined([result.countryCode, assessment.ipType]))
                        .font(panelFont(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("信任分").font(panelFont(size: 11)).foregroundStyle(.secondary)
                        Text(assessment.trustScore.map(scoreText) ?? "—")
                            .font(panelFont(size: 20, weight: .semibold, design: .rounded))
                        Text("/100").font(panelFont(size: 10)).foregroundStyle(.secondary)
                        Text("仅供参考")
                            .font(panelFont(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .help("Net.Coffee 第三方评分，仅供参考，不代表 Claude 登录或模型调用一定可用。")
                        Spacer()
                        Text(assessment.scoreLabel)
                            .font(panelFont(size: 11))
                            .foregroundStyle(scoreColor(assessment.trustScore))
                    }
                    if let score = assessment.trustScore {
                        ProgressView(value: score, total: 100)
                            .progressViewStyle(.linear)
                            .tint(scoreColor(score))
                            .accessibilityLabel("Net.Coffee 信任分")
                            .accessibilityValue("\(scoreText(score))，满分100")
                    }
                }
                if let exitIP = result.ip, exitIP != assessment.ip {
                    Text("评分来自网段缓存；记录 IP 与出口 IP 不同。")
                        .font(panelFont(size: 10))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup(isExpanded: Binding(
                    get: { expandedRisk.contains(profile.id) },
                    set: { expanded in
                        if expanded { expandedRisk.insert(profile.id) } else { expandedRisk.remove(profile.id) }
                    }
                )) {
                    riskDetails(assessment, result: result)
                        .padding(.top, 7)
                } label: {
                    Text("风险详情").font(panelFont(size: 11))
                }
                .accessibilityIdentifier("panel-risk-details-\(profile.id)")
            } else {
                if let ip = result.ip {
                    Text("出口 IP：\(ip)\(result.countryCode.map { " · \($0)" } ?? "")")
                        .font(panelFont(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Label(profile.assessIPRisk ? riskMessage(result) : "未开启 Net.Coffee 评分，可在服务器设置中选择启用。", systemImage: result.state == .failed ? "exclamationmark.circle" : "circle.dotted")
                    .font(panelFont(size: 11))
                    .foregroundStyle(result.state == .failed ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .accessibilityIdentifier("panel-ip-risk-\(profile.id)")
    }

    private func riskDetails(_ assessment: IPRiskAssessment, result: IPRiskCheckResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let exitIP = result.ip, exitIP != assessment.ip {
                detail("网段缓存", assessment.cidr ?? "未提供")
                detail("记录 IP", assessment.ip)
                Text("以下地区、ASN 和风险标记来自缓存记录。")
                    .foregroundStyle(.secondary)
            }
            detail("地区", joined([assessment.country ?? assessment.countryCode, assessment.city]))
            detail("ASN", joined([assessment.asn, assessment.asOrganization]))
            detail("类型", assessment.ipType)
            HStack(spacing: 12) {
                riskFlag("VPN", assessment.isVPN)
                riskFlag("代理", assessment.isProxy)
                riskFlag("Tor", assessment.isTor)
            }
            HStack(spacing: 12) {
                riskFlag("滥用", assessment.isAbuser)
                riskFlag("爬虫", assessment.isCrawler)
            }
            Text(assessment.conclusion)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(panelFont(size: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func riskFlag(_ title: String, _ value: Bool?) -> some View {
        Text("\(title) \(value.map { $0 ? "是" : "否" } ?? "未知")")
            .foregroundStyle(value == true ? Color.orange : Color.secondary)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("CATunnel")
                .font(panelFont(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button(action: showDetails) {
                Label("连接详情", systemImage: "sidebar.right")
            }
            .accessibilityIdentifier("panel-details")
            Button {
                store.copyProxy(store.selectedID)
            } label: {
                Label("复制代理", systemImage: "doc.on.doc")
                    .labelStyle(.iconOnly)
            }
            .help("复制当前服务器的 HTTP 代理地址")
            .disabled(store.selectedProfile == nil)
            .accessibilityIdentifier("panel-copy-proxy")
            Button {
                store.showingAppearanceSettings.toggle()
            } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(store.showingAppearanceSettings ? Color.accentColor : Color.primary)
            }
            .help("外观设置：面板宽度与字体大小")
            .accessibilityLabel("外观设置")
            .accessibilityValue(store.showingAppearanceSettings ? "已展开" : "已收起")
            .accessibilityIdentifier("panel-appearance-settings")
            Menu {
                Button("使用引导…") { GettingStartedWindow.shared.show(store: store) }
                    .accessibilityIdentifier("panel-getting-started")
                Button("外观设置…") { store.showingAppearanceSettings = true }
                Button("添加服务器…", action: addServer)
                    .disabled(store.configurationError != nil)
                Button("连接设置与日志…", action: showDetails)
                Button("关于 CATunnel", action: showAbout)
                Divider()
                Button("退出并停止隧道", action: quit)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("更多操作")
            .accessibilityIdentifier("panel-more")
        }
        .font(panelFont(size: 11))
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func panelFont(size: CGFloat, weight: Font.Weight = .regular,
                           design: Font.Design = .default) -> Font {
        .system(size: size * store.panelAppearance.fontScale, weight: weight, design: design)
    }

    private func checkTimestamp(_ id: String, historical: Bool, checking: Bool) -> String {
        if checking { return "正在检测当前连接…" }
        guard let date = store.lastCompletedCheckAt(for: id) else { return "尚未检测 · 手动点击检测" }
        let prefix = historical ? "历史结果" : "上次检测"
        return "\(prefix) · \(Self.checkTime.string(from: date))"
    }

    private func isActive(_ phase: TunnelPhase) -> Bool {
        [.checking, .connecting, .connected, .reconnecting].contains(phase)
    }

    private func canTest(_ status: TunnelStatus) -> Bool {
        status.phase == .connected && status.proxyCheck != .checking && status.ipRisk.state != .checking
    }

    private func phasePresentation(_ phase: TunnelPhase) -> (title: String, icon: String, color: Color) {
        switch phase {
        case .stopped: return ("未开启", "circle", .secondary)
        case .checking: return ("检查中", "ellipsis.circle", .accentColor)
        case .connecting: return ("连接中", "arrow.left.arrow.right", .accentColor)
        case .connected: return ("已连接", "checkmark.circle.fill", .green)
        case .reconnecting: return ("重连中", "arrow.triangle.2.circlepath", .orange)
        case .failed: return ("连接失败", "exclamationmark.circle.fill", .red)
        }
    }

    private func websitePresentation(_ state: WebsiteCheckState) -> (title: String, icon: String, color: Color) {
        switch state {
        case .unchecked: return ("未检测", "circle.dotted", .secondary)
        case .checking: return ("检测中", "arrow.triangle.2.circlepath", .accentColor)
        case .passed: return ("可达", "checkmark.circle.fill", .green)
        case .restricted: return ("受限", "exclamationmark.circle", .orange)
        case .failed: return ("失败", "xmark.circle", .red)
        }
    }

    private func websiteHelp(_ result: WebsiteCheckResult) -> String {
        var lines = [result.target.url, result.message]
        if let http = result.httpStatus { lines.append("HTTP \(http)") }
        if let ip = result.exitIP { lines.append("出口 IP：\(ip) · 地区：\(result.countryCode ?? "未知")") }
        lines.append("仅检测网络连通，未验证账户登录或模型调用。")
        return lines.joined(separator: "\n")
    }

    private func riskMessage(_ result: IPRiskCheckResult) -> String {
        if result.state == .unchecked { return "点击检测，获取出口 IP 和风险评分。" }
        if !result.message.isEmpty { return result.message }
        return result.state == .checking ? "正在查询出口风险…" : "未返回风险数据，请查看日志。"
    }

    private func joined(_ values: [String?]) -> String {
        let present = values.compactMap { $0 }.filter { !$0.isEmpty }
        return present.isEmpty ? "未知" : present.joined(separator: " · ")
    }

    private func scoreText(_ score: Double) -> String {
        String(format: score.rounded() == score ? "%.0f" : "%.1f", score)
    }

    private func scoreColor(_ score: Double?) -> Color {
        guard let score else { return .secondary }
        return score >= 80 ? .green : score >= 25 ? .orange : .red
    }
}
