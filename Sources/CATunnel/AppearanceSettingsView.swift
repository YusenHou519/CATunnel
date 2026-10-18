import AppKit
import SwiftUI
import TunnelCore

struct AppearanceSettingsView: View {
    @ObservedObject var store: TunnelStore
    @State private var autoConnectError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("设置", systemImage: "gearshape")
                    .font(font(13, weight: .semibold))
                Spacer()
                Button {
                    store.showingAppearanceSettings = false
                } label: {
                    Image(systemName: "xmark")
                        .font(font(11, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("返回服务器页面")
                .accessibilityLabel("关闭设置")
                .accessibilityIdentifier("appearance-close")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LoginSettingsSection(loginItem: store.loginItem,
                                         fontScale: store.panelAppearance.fontScale,
                                         demoMode: store.demoMode)
                    Divider()
                    autoConnectSettings
                    Divider()
                    appearanceSettings
                }
                .padding(.trailing, 3)
                .padding(.bottom, 6)
            }
            .accessibilityIdentifier("settings-scroll")
            .captureLayoutEvidence("settings-scroll")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("appearance-settings")
    }

    private var autoConnectSettings: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("启动后自动连接")
                .font(font(12, weight: .semibold))
            Text("下次启动生效，当前连接不变。与断线后的自动重连独立。")
                .font(font(10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if store.profiles.isEmpty {
                Text("添加服务器后，可在这里选择自动连接的服务器。")
                    .font(font(11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(store.profiles) { profile in
                autoConnectToggle(profile)
            }
            if let message = store.configurationError ?? autoConnectError {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(font(10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-auto-connect-error")
            }
            if store.demoMode {
                Text("离线演示仅在内存中调整，不保存或建立连接。")
                    .font(font(10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func autoConnectToggle(_ profile: ServerProfile) -> some View {
        Toggle(isOn: Binding(
            get: { store.profiles.first(where: { $0.id == profile.id })?.autoConnectOnLaunch ?? false },
            set: { enabled in
                do {
                    try store.setAutoConnectOnLaunch(enabled, for: profile.id)
                    autoConnectError = nil
                } catch {
                    autoConnectError = error.localizedDescription
                }
            }
        )) {
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name)
                    .font(font(11, weight: .medium))
                    .lineLimit(2)
                Text(profile.host)
                    .font(font(10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(store.configurationError != nil)
        .accessibilityLabel("\(profile.name) 启动后自动连接")
        .accessibilityIdentifier("settings-auto-connect-\(profile.id)")
        .captureLayoutEvidence("settings-auto-connect-\(profile.id)")
    }

    private var appearanceSettings: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("外观")
                .font(font(12, weight: .semibold))
            HStack(spacing: 8) {
                Text("面板宽度")
                    .font(font(11, weight: .medium))
                    .frame(width: 56 * store.panelAppearance.fontScale, alignment: .leading)
                Slider(value: Binding(
                    get: { store.panelAppearance.width },
                    set: { store.updatePanelAppearance(width: $0) }
                ), in: PanelAppearance.widthRange, step: 10)
                .accessibilityLabel("面板宽度")
                .accessibilityValue("\(Int(store.panelAppearance.width.rounded())) 点")
                .accessibilityIdentifier("appearance-width-slider")
                .help("面板宽度：300–440 pt")
                Text("\(Int(store.panelAppearance.width.rounded())) pt")
                    .font(font(10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 49 * store.panelAppearance.fontScale, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Text("字体大小")
                    .font(font(11, weight: .medium))
                    .frame(width: 56 * store.panelAppearance.fontScale, alignment: .leading)
                Slider(value: Binding(
                    get: { store.panelAppearance.fontScale },
                    set: { store.updatePanelAppearance(fontScale: $0) }
                ), in: PanelAppearance.fontScaleRange, step: 0.05)
                .accessibilityLabel("面板字体大小")
                .accessibilityValue("\(Int((store.panelAppearance.fontScale * 100).rounded()))%")
                .accessibilityIdentifier("appearance-font-slider")
                .help("字体大小：90%–120%")
                Text("\(Int((store.panelAppearance.fontScale * 100).rounded()))%")
                    .font(font(10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 49 * store.panelAppearance.fontScale, alignment: .trailing)
            }

            HStack(alignment: .center, spacing: 8) {
                Text(store.demoMode ? "立即生效 · 演示中不保存" : "立即生效 · 自动保存")
                    .font(font(10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("恢复默认") { store.resetPanelAppearance() }
                    .font(font(10))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.panelAppearance == .default)
                    .accessibilityIdentifier("appearance-reset")
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func font(_ size: Double, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size * store.panelAppearance.fontScale, weight: weight, design: design)
    }
}

private struct LoginSettingsSection: View {
    @ObservedObject var loginItem: LoginItemManager
    let fontScale: Double
    let demoMode: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { loginItem.isEnabled },
                set: { enabled in Task { await loginItem.setEnabled(enabled) } }
            )) {
                Text("登录时启动")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 12 * fontScale, weight: .semibold))
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(loginItem.isBusy || !loginItem.canChange)
            .accessibilityIdentifier("settings-login-toggle")
            .captureLayoutEvidence("settings-login-toggle")

            Text(demoMode
                 ? "离线演示仅调整示例状态，不更改 Mac 登录项。"
                 : "Mac 登录后启动 CATunnel；连接哪些服务器由下方开关决定。")
                .font(.system(size: 10 * fontScale))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if loginItem.isBusy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在更新登录项…")
                        .font(.system(size: 10 * fontScale))
                        .foregroundStyle(.secondary)
                }
            }
            if let message = loginItem.message, !demoMode {
                Text(message)
                    .font(.system(size: 10 * fontScale))
                    .foregroundStyle(loginItem.needsApproval ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-login-message")
            }
            if loginItem.needsApproval {
                Button("打开系统登录项设置") { loginItem.openSystemSettings() }
                    .font(.system(size: 10 * fontScale))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("settings-login-system-settings")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }
}
