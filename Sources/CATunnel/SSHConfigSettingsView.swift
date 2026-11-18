import SwiftUI

struct SSHConfigSettingsView: View {
    @ObservedObject var store: TunnelStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("SSH 配置同步", isOn: Binding(
                get: { store.sshConfigSyncEnabled },
                set: { store.setSSHConfigSyncEnabled($0) }
            ))
            .font(font(12, weight: .semibold))
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!store.canSyncSSHConfig)
            .accessibilityIdentifier("settings-ssh-config-sync")

            Text(store.demoMode
                 ? "离线演示不读取 SSH 配置。"
                 : "开启后会在启动时和运行期间同步 ~/.ssh/config。")
                .font(font(10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("扫描并更新一次") { Task { await store.syncSSHConfigNow() } }
                .font(font(11))
                .controlSize(.small)
                .disabled(!store.canSyncSSHConfig || store.sshConfigRefreshing)
                .accessibilityIdentifier("settings-ssh-config-refresh")
                .captureLayoutEvidence("settings-ssh-config-refresh")
            if !store.excludedSSHConfigAliases.isEmpty {
                Button("恢复已跳过的别名（\(store.excludedSSHConfigAliases.count)）") {
                    Task { await store.restoreExcludedSSHConfigAliases() }
                }
                .font(font(11))
                .controlSize(.small)
                .disabled(!store.canSyncSSHConfig || store.sshConfigRefreshing)
                .accessibilityIdentifier("settings-ssh-config-restore")
            }
            if let message = store.sshConfigMessage {
                Text(message)
                    .font(font(10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-ssh-config-result")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func font(_ size: Double, weight: Font.Weight = .regular) -> Font {
        .system(size: size * store.panelAppearance.fontScale, weight: weight)
    }
}
