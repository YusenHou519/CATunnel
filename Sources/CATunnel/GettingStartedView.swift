import AppKit
import SwiftUI

@MainActor
final class GettingStartedWindow: NSObject, NSWindowDelegate {
    static let shared = GettingStartedWindow()
    private var window: NSWindow?

    func show(store: TunnelStore) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = GettingStartedView(canAdd: store.configurationError == nil) { [weak self] in
            self?.window?.close()
            ProfileEditorWindow.shared.show(profile: .draft(), isNew: true, store: store)
        }
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "CATunnel 使用引导"
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
        closing.contentView = nil
        window = nil
    }
}

struct GettingStartedView: View {
    var canAdd = true
    var onAdd: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("开始使用 CATunnel")
                    .font(.system(size: 22, weight: .semibold))
                Text("让服务器通过 SSH 隧道使用 Mac 上的本地代理。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    step(1, title: "开启 Mac 本地代理", icon: "laptopcomputer") {
                        Text("在 Clash 或其他代理工具中开启 HTTP / Mixed 端口，并将端口填入服务器设置。")
                        Text("CATunnel 连接 Mac 的 127.0.0.1，无需为此开启代理工具的局域网访问。仅 SOCKS 端口不适用当前 HTTP 检测。")
                            .foregroundStyle(.secondary)
                    }
                    step(2, title: "准备 SSH 登录", icon: "key") {
                        Text("填写真实主机地址、SSH 用户和端口。使用已有的默认密钥 / SSH agent，或选择指定的私钥文件。")
                        Text("首次连接请复制编辑窗口中的 SSH 验证命令，在终端核对主机指纹后手动确认。加密密钥请先在终端解锁并加入 SSH agent。")
                            .foregroundStyle(.secondary)
                        Text("然后点击“检查连接准备”，检查本地端口、密钥、无交互 SSH 登录，以及远端 ss / curl。检查不会建立隧道或访问外部检测网站。")
                            .foregroundStyle(.secondary)
                    }
                    step(3, title: "保存后手动连接", icon: "arrow.left.arrow.right") {
                        Text("保存服务器后打开隧道开关。连接成功后，可手动检测服务连通性。")
                        Text("最后按程序的启动方式，将服务器上的 Codex、Claude 等程序指向对应的 http://127.0.0.1:服务器代理端口。开启隧道本身不会自动改变程序代理。")
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    Label("本应用不保存密码或私钥内容，不自动接受 SSH 主机指纹，也不修改 SSH、Cursor 或服务器程序配置。", systemImage: "lock.shield")
                        .foregroundStyle(.secondary)
                    Text("目前使用明确的主机、端口与密钥设置，暂不读取 ~/.ssh/config 中的 Host 别名或 ProxyJump。需跳板机的连接暂不支持。")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
            }
            .accessibilityIdentifier("getting-started-scroll")
            .captureLayoutEvidence("getting-started-scroll")
            Divider()
            HStack {
                Text("添加和保存不会自动连接。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("添加服务器", action: onAdd)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdd)
                    .accessibilityIdentifier("getting-started-add")
                    .captureLayoutEvidence("getting-started-add")
            }
        }
        .padding(24)
        .frame(width: 510, height: min(690, (NSScreen.main?.visibleFrame.height ?? 800) - 90))
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("getting-started")
    }

    private func step<Content: View>(_ number: Int, title: String, icon: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(String(number))
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(Color.accentColor.opacity(0.15), in: Circle())
                Label(title, systemImage: icon)
                    .font(.system(size: 14, weight: .semibold))
            }
            content()
        }
        .accessibilityIdentifier("getting-started-step-\(number)")
        .captureLayoutEvidence("getting-started-step-\(number)")
    }
}
