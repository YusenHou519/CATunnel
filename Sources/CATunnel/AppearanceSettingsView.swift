import SwiftUI

struct AppearanceSettingsView: View {
    @ObservedObject var store: TunnelStore

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("外观设置", systemImage: "textformat.size")
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
                .accessibilityLabel("关闭外观设置")
                .accessibilityIdentifier("appearance-close")
            }

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
        .accessibilityIdentifier("appearance-settings")
    }

    private func font(_ size: Double, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size * store.panelAppearance.fontScale, weight: weight, design: design)
    }
}
