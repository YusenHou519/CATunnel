import AppKit
import SwiftUI
import TunnelCore

@MainActor
final class ProfileEditorWindow: NSObject, NSWindowDelegate {
    static let shared = ProfileEditorWindow()
    private var window: NSWindow?
    private var setupModel: SetupCheckModel?

    func show(profile: ServerProfile, isNew: Bool, store: TunnelStore) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard store.configurationError == nil, isNew || store.canModify(profile.id) else { return }
        let setupModel = SetupCheckModel()
        self.setupModel = setupModel
        let editor = ProfileEditor(profile: profile, isNew: isNew, store: store, setupModel: setupModel) { [weak self] in
            self?.window?.close()
        }
        let hosting = NSHostingView(rootView: editor)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = isNew ? "添加服务器" : "编辑服务器 · \(profile.name)"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        setupModel?.cancel()
        setupModel = nil
        closing.contentView = nil
        window = nil
    }
}

@MainActor
struct ProfileEditor: View {
    let profile: ServerProfile
    let isNew: Bool
    @ObservedObject var store: TunnelStore
    let onClose: () -> Void

    @State private var name: String
    @State private var host: String
    @State private var user: String
    @State private var sshPort: String
    @State private var remotePort: String
    @State private var localPort: String
    @State private var autoReconnect: Bool
    @State private var identityFile: String?
    @State private var assessIPRisk: Bool
    @State private var errorMessage: String?
    @State private var copiedCommand = false
    @StateObject private var setup: SetupCheckModel
    @FocusState private var focusedField: String?

    init(profile: ServerProfile, isNew: Bool, store: TunnelStore,
         setupModel: SetupCheckModel? = nil, onClose: @escaping () -> Void = {}) {
        self.profile = profile
        self.isNew = isNew
        self.store = store
        self.onClose = onClose
        _name = State(initialValue: profile.name)
        _host = State(initialValue: profile.host)
        _user = State(initialValue: profile.user)
        _sshPort = State(initialValue: String(profile.sshPort))
        _remotePort = State(initialValue: String(profile.remotePort))
        _localPort = State(initialValue: String(profile.localPort))
        _autoReconnect = State(initialValue: profile.autoReconnect)
        _identityFile = State(initialValue: profile.identityFile)
        _assessIPRisk = State(initialValue: profile.assessIPRisk)
        _setup = StateObject(wrappedValue: setupModel ?? SetupCheckModel())
    }

    private var blockedReason: String? {
        if let error = store.configurationError { return error }
        if !isNew && !store.profiles.contains(where: { $0.id == profile.id }) {
            return "这台服务器已被删除，请关闭此窗口。"
        }
        if !isNew && !store.canModify(profile.id) {
            return "请先断开隧道并等待检测结束，再修改服务器。"
        }
        return nil
    }

    private var inputs: [String] {
        [name, host, user, sshPort, remotePort, localPort, identityFile ?? "",
         String(autoReconnect), String(assessIPRisk)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(isNew ? "添加服务器" : "编辑服务器")
                        .font(.system(size: 21, weight: .semibold))
                    Text(isNew ? "保存到 CATunnel；添加后由你手动连接。" : "更新 CATunnel 的本机连接设置。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { GettingStartedWindow.shared.show(store: store) } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .help("使用引导")
                .accessibilityLabel("使用引导")
                .accessibilityIdentifier("profile-guide")
            }
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        addressFields
                        Divider()
                        identityFields
                        Divider()
                        proxyFields
                        Divider()
                        setupFields
                            .id("setup-section")
                    }
                    .padding(.horizontal, 4)
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
                }
                .accessibilityIdentifier("profile-editor-scroll")
                .captureLayoutEvidence("profile-editor-scroll")
                .onAppear {
                    if !setup.items.isEmpty {
                        DispatchQueue.main.async { reader.scrollTo("setup-section", anchor: .top) }
                    }
                }
                .onChange(of: setup.items) { items in
                    if !items.isEmpty {
                        focusedField = nil
                        reader.scrollTo("setup-section", anchor: .top)
                    }
                }
            }

            // Keep error text and action buttons outside the scrolling form.
            ScrollView {
                if let message = blockedReason ?? errorMessage {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("profile-editor-error")
                        .captureLayoutEvidence("profile-editor-error")
                }
            }
            .frame(height: 30)
            HStack {
                if setup.isChecking {
                    ProgressView().controlSize(.small)
                    Button("取消检查") { setup.cancel() }
                        .accessibilityIdentifier("profile-cancel-setup")
                        .captureLayoutEvidence("profile-cancel-setup")
                } else {
                    Button("检查连接准备", action: checkSetup)
                        .disabled(blockedReason != nil)
                        .accessibilityIdentifier("profile-check-setup")
                        .captureLayoutEvidence("profile-check-setup")
                }
                Spacer()
                Button("取消") { close() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("cancel-profile")
                Button(isNew ? "添加服务器" : "保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(blockedReason != nil)
                    .accessibilityIdentifier("save-profile")
                    .captureLayoutEvidence("save-profile")
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24)
        .frame(width: 510, height: min(760, (NSScreen.main?.visibleFrame.height ?? 850) - 90))
        .background(Color(nsColor: .windowBackgroundColor))
        .foregroundStyle(Color.primary)
        .accessibilityIdentifier("profile-editor")
        .onAppear {
            if setup.items.isEmpty { focusedField = "profile-name" }
        }
        .onChange(of: inputs) { _ in
            setup.cancel()
            errorMessage = nil
            copiedCommand = false
        }
        .onChange(of: blockedReason) { reason in
            if reason != nil { setup.cancel() }
        }
        .onDisappear { setup.cancel() }
    }

    private var addressFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            editorField("显示名称", text: $name, placeholder: "例如 Dev", identifier: "profile-name")
            HStack(alignment: .top, spacing: 14) {
                editorField("服务器地址", text: $host, placeholder: "真实主机名或 IPv4", identifier: "profile-host")
                editorField("SSH 端口", text: $sshPort, identifier: "profile-ssh-port")
                    .frame(width: 96)
            }
            editorField("SSH 用户", text: $user, placeholder: "登录服务器的用户名", identifier: "profile-user")
            Text("填写真实主机地址；当前不读取 ~/.ssh/config 的别名或跳板设置。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var identityFields: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("SSH 密钥")
                .font(.system(size: 13, weight: .semibold))
            HStack {
                Text(identityFile == nil ? "默认密钥 / SSH agent" : "使用指定私钥")
                    .font(.system(size: 12))
                Spacer()
                Button("选择私钥…", action: chooseIdentity)
                    .accessibilityIdentifier("profile-select-identity")
                    .captureLayoutEvidence("profile-select-identity")
                if identityFile != nil {
                    Button("恢复默认") { identityFile = nil }
                        .accessibilityIdentifier("profile-reset-identity")
                }
            }
            if let identityFile {
                Text(identityFile)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("profile-identity-path")
            }
            Text("仅保存文件路径，不复制私钥内容。加密密钥请先在终端解锁并加入 SSH agent；应用不会弹出密码输入。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var proxyFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    editorField("服务器代理端口", text: $remotePort, identifier: "profile-remote-port")
                    Text("服务器上的程序连接此端口")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    editorField("Mac 本地代理端口", text: $localPort, identifier: "profile-local-port")
                    Text("Mac 的 HTTP / Mixed 端口")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Toggle("意外断开后自动重连", isOn: $autoReconnect)
                .font(.system(size: 12))
                .accessibilityIdentifier("profile-auto-reconnect")
            VStack(alignment: .leading, spacing: 5) {
                Toggle("启用 Net.Coffee 出口 IP 评分", isOn: $assessIPRisk)
                    .font(.system(size: 12))
                    .accessibilityIdentifier("profile-assess-ip-risk")
                    .captureLayoutEvidence("profile-assess-ip-risk")
                Text("可选，默认关闭。手动检测时会向 Net.Coffee 发送代理出口的公网 IP，不发送 SSH 密钥或凭据。评分仅供参考。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var setupFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("连接准备")
                .font(.system(size: 13, weight: .semibold))
            Text(store.demoMode
                 ? "离线演示仅显示示例结果，不访问网络或 SSH。"
                 : "点击后检查本地端口和 SSH 登录，并查询远端 ss / curl。不建立隧道，不访问外部检测网站。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !setup.items.isEmpty {
                SetupCheckResultsView(items: setup.items)
            }
            DisclosureGroup("首次连接 / SSH 指纹验证") {
                VStack(alignment: .leading, spacing: 9) {
                    Text("请在终端运行下列命令，核对服务器指纹后手动确认。CATunnel 不自动接受新指纹，也不修改 known_hosts。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if let command = verificationCommand {
                        Text(command)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .accessibilityIdentifier("profile-ssh-command")
                        Button(copiedCommand ? "已复制" : "复制 SSH 验证命令") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                            copiedCommand = true
                        }
                        .accessibilityIdentifier("profile-copy-ssh-command")
                    } else {
                        Text("填写完整的真实服务器信息后，可复制终端验证命令。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 7)
            }
            .font(.system(size: 12))
            .accessibilityIdentifier("profile-ssh-verification")
        }
    }

    private var verificationCommand: String? {
        guard let candidate = try? editedProfile() else { return nil }
        return try? SetupDiagnostics.terminalVerificationCommand(for: candidate)
    }

    private func chooseIdentity() {
        let panel = NSOpenPanel()
        panel.title = "选择已有的 SSH 私钥"
        panel.message = "仅保存文件路径。请选择私钥文件，不要选择 .pub 公钥。"
        panel.prompt = "使用此私钥"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            identityFile = url.path
        }
    }

    private func editorField(_ title: String, text: Binding<String>, placeholder: String = "",
                             identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
            TextField(placeholder.isEmpty ? title : placeholder, text: text)
                .focused($focusedField, equals: identifier)
                .accessibilityLabel(title)
                .accessibilityIdentifier(identifier)
                .captureLayoutEvidence(identifier)
        }
    }

    private func editedProfile() throws -> ServerProfile {
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let sshPortValue = Int(trim(sshPort)),
              let remotePortValue = Int(trim(remotePort)),
              let localPortValue = Int(trim(localPort)),
              [sshPortValue, remotePortValue, localPortValue].allSatisfy({ (1...65535).contains($0) }) else {
            throw EditorValidationError("端口需填写 1 到 65535 之间的整数。")
        }
        guard !trim(name).isEmpty, !trim(host).isEmpty, !trim(user).isEmpty else {
            throw EditorValidationError("请填写显示名称、服务器地址和 SSH 用户。")
        }
        let edited = ServerProfile(id: profile.id, name: trim(name), host: trim(host), user: trim(user),
                                   sshPort: sshPortValue, remotePort: remotePortValue, localPort: localPortValue,
                                   autoReconnect: autoReconnect, identityFile: identityFile, assessIPRisk: assessIPRisk)
        try edited.validate()
        return edited
    }

    private func checkSetup() {
        guard blockedReason == nil else { return }
        do {
            let candidate = try editedProfile()
            errorMessage = nil
            setup.start(profile: candidate, demoMode: store.demoMode)
        } catch {
            setup.cancel()
            errorMessage = error.localizedDescription
        }
    }

    private func save() {
        guard blockedReason == nil else { return }
        do {
            let edited = try editedProfile()
            if isNew { try store.add(edited) }
            else { try store.save(edited) }
            close()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func close() {
        setup.cancel()
        onClose()
    }
}

private struct EditorValidationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct SetupCheckResultsView: View {
    let items: [SetupCheckItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items) { item in
                let style = presentation(item.state)
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: style.icon)
                        .foregroundStyle(style.color)
                        .frame(width: 15)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title + " · " + style.title)
                            .font(.system(size: 12, weight: .medium))
                        Text(item.message)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("setup-result-\(item.id)")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("setup-results")
        .captureLayoutEvidence("setup-results")
    }

    private func presentation(_ state: SetupCheckState) -> (title: String, icon: String, color: Color) {
        switch state {
        case .passed: return ("就绪", "checkmark.circle.fill", .green)
        case .warning: return ("需确认", "exclamationmark.circle", .orange)
        case .failed: return ("未通过", "xmark.circle", .red)
        case .skipped: return ("已跳过", "minus.circle", .secondary)
        }
    }
}

struct ServerListEmptyState: View {
    let compact: Bool
    let canAdd: Bool
    let identifierPrefix: String
    let onAdd: () -> Void
    let onGuide: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "server.rack")
                .font(.system(size: compact ? 30 : 38, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("还没有服务器")
                .font(.system(size: compact ? 17 : 20, weight: .semibold))
            Text("添加一台服务器，通过 SSH 隧道使用 Mac 上的本地代理。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 330)
            VStack(alignment: .leading, spacing: 9) {
                Label("开启 Mac 的 HTTP / Mixed 代理", systemImage: "1.circle")
                Label("准备 SSH 密钥与主机指纹", systemImage: "2.circle")
                Label("手动连接，再设置远端程序代理", systemImage: "3.circle")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Button(action: onAdd) {
                Label("添加服务器", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canAdd)
            .accessibilityIdentifier("\(identifierPrefix)-empty-add-server")
            .captureLayoutEvidence("\(identifierPrefix)-empty-add-server")
            Button("使用引导", action: onGuide)
                .buttonStyle(.link)
                .accessibilityIdentifier("\(identifierPrefix)-empty-guide")
                .captureLayoutEvidence("\(identifierPrefix)-empty-guide")
        }
        .padding(.horizontal, compact ? 8 : 30)
        .padding(.vertical, compact ? 30 : 40)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("\(identifierPrefix)-empty-state")
    }
}

struct ProfileConfigurationErrorView: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("服务器配置无法读取", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold))
            Text(message)
                .textSelection(.enabled)
            Text("原文件已保留。请修复本机配置后重新启动，再添加或修改服务器。")
        }
        .font(.system(size: 11))
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("profile-configuration-error")
    }
}
