import Foundation
import Combine
import TunnelCore

@MainActor
final class SetupCheckModel: ObservableObject {
    @Published private(set) var items: [SetupCheckItem] = []
    @Published private(set) var isChecking = false
    private var task: Task<Void, Never>?
    private var diagnostics: SetupDiagnostics?
    private var generation = UUID()

    func start(profile: ServerProfile, demoMode: Bool) {
        cancel()
        isChecking = true
        let current = generation
        if demoMode {
            // Demo mode never constructs a runner or touches SSH configuration.
            task = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 250_000_000) }
                catch { return }
                guard let self, self.generation == current, !Task.isCancelled else { return }
                self.items = Self.demoItems
                self.isChecking = false
                self.task = nil
            }
        } else {
            let runner = SetupDiagnostics()
            diagnostics = runner
            task = Task { [weak self] in
                let results = await runner.run(profile)
                guard let self, self.generation == current, !Task.isCancelled else { return }
                self.items = results
                self.isChecking = false
                self.diagnostics = nil
                self.task = nil
            }
        }
    }

    func cancel(clearResults: Bool = true) {
        generation = UUID()
        diagnostics?.cancel()
        task?.cancel()
        diagnostics = nil
        task = nil
        isChecking = false
        if clearResults { items = [] }
    }

    static var demoItems: [SetupCheckItem] {
        [
            .init(id: "localProxy", title: "Mac 本地代理", state: .passed, message: "演示：本地代理端口可以连接。"),
            .init(id: "identity", title: "SSH 密钥", state: .passed, message: "演示：已有可用的 SSH 密钥。"),
            .init(id: "ssh", title: "SSH 登录与主机指纹", state: .passed, message: "演示：无交互登录成功，主机指纹已信任。"),
            .init(id: "remoteSS", title: "服务器端口检查", state: .passed, message: "演示：服务器提供 ss 命令。"),
            .init(id: "remoteCurl", title: "服务器网络检测工具", state: .passed, message: "演示：服务器提供 curl 命令。")
        ]
    }
}
