import SwiftUI
import TunnelCore

@MainActor
protocol FixedEntryDiagnosticsExecuting: AnyObject {
    func run(_ profile: ServerProfile) async -> [SetupCheckItem]
    func cancel()
}

extension FixedEntryDiagnostics: FixedEntryDiagnosticsExecuting {}

@MainActor
final class FixedEntryDiagnosticsModel: ObservableObject {
    @Published private(set) var items: [SetupCheckItem] = []
    @Published private(set) var isChecking = false
    @Published private(set) var checkedAt: Date?
    @Published private(set) var notice: String?
    private let makeExecutor: () -> any FixedEntryDiagnosticsExecuting
    private var executor: (any FixedEntryDiagnosticsExecuting)?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(makeExecutor: (() -> any FixedEntryDiagnosticsExecuting)? = nil) {
        self.makeExecutor = makeExecutor ?? { FixedEntryDiagnostics() }
    }

    func start(profile: ServerProfile, demoMode: Bool) {
        guard !isChecking else { return }
        cancel(clearResults: true)
        isChecking = true
        let current = generation
        if demoMode {
            task = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 150_000_000) }
                catch { return }
                guard let self, self.generation == current, !Task.isCancelled else { return }
                self.complete(Self.demoItems)
            }
        } else {
            let runner = makeExecutor()
            executor = runner
            task = Task { [weak self] in
                let items = await runner.run(profile)
                guard let self, self.generation == current, !Task.isCancelled else { return }
                self.complete(items)
            }
        }
    }

    private func complete(_ results: [SetupCheckItem]) {
        items = results
        checkedAt = Date()
        isChecking = false
        task = nil
        executor = nil
    }

    func cancel(clearResults: Bool = false) {
        let wasChecking = isChecking
        generation = UUID()
        executor?.cancel()
        task?.cancel()
        executor = nil
        task = nil
        isChecking = false
        if clearResults {
            items = []
            checkedAt = nil
            notice = nil
        } else if wasChecking {
            notice = "检查已取消，现有连接未改变。"
        }
    }

    static var demoItems: [SetupCheckItem] {
        [
            .init(id: "localProxy", title: "Mac 本地代理", state: .passed, message: "演示：本地 TCP 端口可达，未检测外网。"),
            .init(id: "ssh", title: "SSH 登录", state: .passed, message: "演示：SSH 认证和主机指纹通过。"),
            .init(id: "python", title: "远端 Python", state: .passed, message: "演示：Python 3.12.0，满足版本要求。"),
            .init(id: "helper", title: "远端转接程序", state: .passed, message: "演示：程序运行中，私有运行目录可用。"),
            .init(id: "entry", title: "固定入口", state: .passed, message: "演示：配置的回环入口正在监听。"),
            .init(id: "backend", title: "当前转发通道", state: .warning, message: "演示：入口空闲，尚未连接后端。")
        ]
    }
}

@MainActor
struct FixedEntryDiagnosticsView: View {
    let profile: ServerProfile
    let demoMode: Bool
    let identifierPrefix: String
    @StateObject private var model: FixedEntryDiagnosticsModel
    @State private var expanded = false

    init(profile: ServerProfile, demoMode: Bool, identifierPrefix: String? = nil,
         model: FixedEntryDiagnosticsModel? = nil) {
        self.profile = profile
        self.demoMode = demoMode
        self.identifierPrefix = identifierPrefix ?? "fixed-entry-diagnostics-\(profile.id)"
        _model = StateObject(wrappedValue: model ?? FixedEntryDiagnosticsModel())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("固定入口状态").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                if model.isChecking {
                    ProgressView().controlSize(.small)
                    Button("取消检查") { model.cancel() }
                        .accessibilityIdentifier("\(identifierPrefix)-cancel")
                } else {
                    Button("检查固定入口") {
                        expanded = true
                        model.start(profile: profile, demoMode: demoMode)
                    }
                    .accessibilityIdentifier("\(identifierPrefix)-check")
                    .captureLayoutEvidence("\(identifierPrefix)-check")
                }
            }
            Text(demoMode ? "离线演示：仅显示示例状态，不访问服务器。"
                 : "按需检查本地代理、SSH、Python 和远端入口；不会重连、安装或修改现有连接。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let checkedAt = model.checkedAt {
                Text("\(demoMode ? "演示结果" : "上次检查") · \(checkedAt.formatted(date: .numeric, time: .standard))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(identifierPrefix)-timestamp")
            }
            if let notice = model.notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.items.isEmpty {
                DisclosureGroup("检查结果", isExpanded: $expanded) {
                    FixedEntryDiagnosticResults(items: model.items, identifierPrefix: identifierPrefix)
                        .padding(.top, 6)
                }
                .font(.system(size: 12))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(identifierPrefix)
        .captureLayoutEvidence(identifierPrefix)
        .onChange(of: profile) { _ in model.cancel(clearResults: true); expanded = false }
        .onChange(of: demoMode) { _ in model.cancel(clearResults: true); expanded = false }
        .onDisappear { model.cancel() }
    }
}

struct FixedEntryDiagnosticResults: View {
    let items: [SetupCheckItem]
    let identifierPrefix: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items) { item in
                let style = presentation(item.state)
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: style.icon).foregroundStyle(style.color).frame(width: 15)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title + " · " + style.title).font(.system(size: 11, weight: .medium))
                        Text(item.message).font(.system(size: 11)).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("\(identifierPrefix)-\(item.id)")
                .captureLayoutEvidence("\(identifierPrefix)-\(item.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func presentation(_ state: SetupCheckState) -> (title: String, icon: String, color: Color) {
        switch state {
        case .passed: return ("通过", "checkmark.circle.fill", .green)
        case .warning: return ("需确认", "exclamationmark.circle", .orange)
        case .failed: return ("未通过", "xmark.circle", .red)
        case .skipped: return ("未检查", "minus.circle", .secondary)
        }
    }
}
