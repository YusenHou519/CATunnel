import AppKit
import SwiftUI
import TunnelCore

@MainActor
enum Ping0BrowserAction {
    static func open(ip: String?, demoMode: Bool, opener: (URL) -> Bool) -> Bool {
        guard !demoMode else { return false }
        return opener(Ping0Website.url(for: ip))
    }

    static func exitIP(in status: TunnelStatus) -> String? {
        guard let result = status.websiteResults.first(where: { $0.target == .claudeNetwork }),
              result.state == .passed else { return nil }
        return Ping0Website.publicIP(result.exitIP)
    }
}

@MainActor
struct Ping0WebsiteButton: View {
    let ip: String?
    var historical = false
    var demoMode = false
    var fontScale: CGFloat = 1
    var identifierPrefix = "ping0-website"
    var opener: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    @State private var openFailed = false

    private var publicIP: String? { Ping0Website.publicIP(ip) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                openFailed = !Ping0BrowserAction.open(ip: ip, demoMode: demoMode, opener: opener)
            } label: {
                Label(publicIP == nil ? "打开 Ping0 网站" : "在 Ping0 查看出口 IP", systemImage: "arrow.up.right.square")
                    .font(.system(size: 12 * fontScale))
            }
            .disabled(demoMode)
            .help(demoMode ? "离线演示不会打开浏览器。" : "点击后在默认浏览器中打开 Ping0；浏览器使用本机网络。")
            .accessibilityIdentifier(identifierPrefix)
            .captureLayoutEvidence(identifierPrefix)
            if let publicIP {
                Text((historical ? "上次检测的出口 IP：" : "检测到的出口 IP：") + publicIP)
                    .font(.system(size: 10 * fontScale))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .captureLayoutEvidence(identifierPrefix + "-ip")
            }
            if openFailed {
                Text("无法打开默认浏览器，请检查系统浏览器设置。")
                    .font(.system(size: 11 * fontScale))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: ip) { _ in openFailed = false }
    }
}
