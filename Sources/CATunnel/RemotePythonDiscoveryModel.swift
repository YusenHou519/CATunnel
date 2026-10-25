import SwiftUI
import TunnelCore

@MainActor
protocol RemotePythonDiscoveryExecuting: AnyObject {
    func run(_ profile: ServerProfile) async throws -> RemotePythonDiscoveryResult
    func cancel()
}

extension RemotePythonDiscovery: RemotePythonDiscoveryExecuting {}

@MainActor
final class RemotePythonDiscoveryModel: ObservableObject {
    @Published private(set) var result: RemotePythonDiscoveryResult?
    @Published private(set) var isSearching = false
    @Published private(set) var message: String?
    @Published private(set) var checkedAt: Date?
    private let makeExecutor: () -> any RemotePythonDiscoveryExecuting
    private var executor: (any RemotePythonDiscoveryExecuting)?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(makeExecutor: (() -> any RemotePythonDiscoveryExecuting)? = nil) {
        self.makeExecutor = makeExecutor ?? { RemotePythonDiscovery() }
    }

    func start(profile: ServerProfile, demoMode: Bool) {
        guard !isSearching else { return }
        cancel(clearResults: true)
        isSearching = true
        let current = generation
        if demoMode {
            task = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 150_000_000) }
                catch { return }
                guard let self, self.generation == current, !Task.isCancelled else { return }
                self.complete(Self.demoResult)
            }
        } else {
            let runner = makeExecutor()
            executor = runner
            task = Task { [weak self] in
                do {
                    let result = try await runner.run(profile)
                    guard let self, self.generation == current, !Task.isCancelled else { return }
                    self.complete(result)
                } catch {
                    guard let self, self.generation == current, !Task.isCancelled else { return }
                    self.message = error.localizedDescription
                    self.isSearching = false
                    self.checkedAt = Date()
                    self.task = nil
                    self.executor = nil
                }
            }
        }
    }

    private func complete(_ result: RemotePythonDiscoveryResult) {
        self.result = result
        message = result.message
        checkedAt = Date()
        isSearching = false
        task = nil
        executor = nil
    }

    func selectedPath(for candidate: RemotePythonCandidate) -> String? {
        guard !isSearching, result?.candidates.contains(candidate) == true, candidate.isSupported,
              candidate.path.hasPrefix("/"), candidate.path != "/", candidate.path.utf8.count <= 4096,
              !candidate.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return candidate.path
    }

    func cancel(clearResults: Bool = false) {
        let wasSearching = isSearching
        generation = UUID()
        executor?.cancel()
        task?.cancel()
        executor = nil
        task = nil
        isSearching = false
        if clearResults {
            result = nil
            message = nil
            checkedAt = nil
        } else if wasSearching {
            message = "查找已取消，Python 路径和配置未改变。"
        }
    }

    static var demoResult: RemotePythonDiscoveryResult {
        .init(candidates: [
            .init(path: "/usr/bin/python3", version: "3.8.10", isSupported: false),
            .init(path: "/opt/tools/bin/python3", version: "3.12.0", isSupported: true)
        ], message: "演示：发现 2 个已有解释器；请选择符合要求的版本。", isPartial: false)
    }
}

@MainActor
struct RemotePythonSelectionView: View {
    @ObservedObject var model: RemotePythonDiscoveryModel
    let demoMode: Bool
    let blockedReason: String?
    let onSearch: () -> Void
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if model.isSearching {
                    ProgressView().controlSize(.small)
                    Text(demoMode ? "演示查找中…" : "正在查找已有 Python…").font(.system(size: 11))
                    Spacer(minLength: 4)
                    Button("取消查找") { model.cancel() }
                        .accessibilityIdentifier("profile-python-discovery-cancel")
                } else {
                    Button("查找可用 Python", action: onSearch)
                        .disabled(blockedReason != nil)
                        .accessibilityIdentifier("profile-python-discovery-search")
                        .captureLayoutEvidence("profile-python-discovery-search")
                }
            }
            Text(demoMode ? "离线演示不访问服务器，选择后只填入当前表单。"
                 : "按需检查默认路径和常见环境，不安装或升级 Python。查找范围有限，也可手动填写路径。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let blockedReason {
                Text(blockedReason).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = model.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("profile-python-discovery-result")
            }
            if let checkedAt = model.checkedAt {
                Text("上次查找 · \(checkedAt.formatted(date: .numeric, time: .standard))")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let result = model.result {
                if result.isPartial {
                    Text("仅显示本次已确认的部分结果；未列出不代表未安装。")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(result.candidates) { candidate in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(candidate.path).font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Text("Python \(candidate.version) · \(candidate.isSupported ? "满足要求" : "不满足 3.9+ 要求")")
                                .font(.system(size: 11)).foregroundStyle(candidate.isSupported ? Color.secondary : .orange)
                            Spacer(minLength: 4)
                            Button("使用此 Python") {
                                if let path = model.selectedPath(for: candidate) { onSelect(path) }
                            }
                            .disabled(blockedReason != nil || model.isSearching || !candidate.isSupported)
                            .accessibilityIdentifier("profile-python-choice-\(candidate.path)")
                        }
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
                }
                if !result.candidates.isEmpty {
                    Text("选择只填入当前表单；保存或安装仍需单独点击。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("profile-python-discovery")
        .captureLayoutEvidence("profile-python-discovery")
    }
}
