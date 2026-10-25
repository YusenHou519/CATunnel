import Foundation
import Combine
import TunnelCore

@MainActor
protocol FixedEntryInstallExecuting: AnyObject {
    func install(_ profile: ServerProfile) async throws -> FixedEntryInstallation
    func cancel()
}

extension FixedEntryInstaller: FixedEntryInstallExecuting {}

enum FixedEntryInstallState: Equatable {
    case idle
    case installing
    case succeeded(FixedEntryInstallation, demo: Bool)
    case failed(String)
    case cancelled

    var isInstalling: Bool { self == .installing }
}

@MainActor
final class FixedEntryInstallModel: ObservableObject {
    @Published private(set) var state: FixedEntryInstallState = .idle
    var isInstalling: Bool { state.isInstalling }

    private let makeExecutor: () throws -> any FixedEntryInstallExecuting
    private var executor: (any FixedEntryInstallExecuting)?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(makeExecutor: (() throws -> any FixedEntryInstallExecuting)? = nil) {
        self.makeExecutor = makeExecutor ?? { try Self.bundledExecutor() }
    }

    static func blockedReason(editorReason: String?, phase: TunnelPhase?, checking: Bool) -> String? {
        if let editorReason { return editorReason }
        if checking { return "请先结束连接准备检查，再安装固定入口。" }
        if let phase, phase != .stopped { return "请先停止这台服务器的连接，再安装固定入口。" }
        return nil
    }

    static func validateCandidate(_ profile: ServerProfile, isNew: Bool,
                                  existingProfiles: [ServerProfile]) throws -> ServerProfile {
        var candidate = profile
        candidate.useFixedEntry = false
        var updated = existingProfiles
        if isNew {
            updated.append(candidate)
        } else {
            guard let index = updated.firstIndex(where: { $0.id == candidate.id }) else {
                throw StoreError.unknownServer
            }
            updated[index] = candidate
        }
        // Reserve no remote port for a draft that could not be saved locally.
        try ServerConfiguration(profiles: updated).validate()
        return candidate
    }

    func start(profile: ServerProfile, demoMode: Bool,
               onSuccess: @escaping (FixedEntryInstallation) -> Void) {
        guard !isInstalling else { return }
        cancel(clearState: true)
        var candidate = profile
        candidate.useFixedEntry = false
        do { try candidate.validate() }
        catch {
            state = .failed(error.localizedDescription)
            return
        }
        state = .installing
        let current = generation
        if demoMode {
            // Offline modes must not load scripts or create an SSH executor.
            task = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 250_000_000) }
                catch { return }
                guard let self, self.generation == current, !Task.isCancelled else { return }
                let result = FixedEntryInstallation(helperPath: "/tmp/catunnel-demo-home/.catunnel/fixed-entry/\(candidate.remotePort)/relay.py",
                    runtimePath: "/tmp/catunnel-demo-home/.catunnel/fixed-entry/\(candidate.remotePort)/r",
                    port: candidate.remotePort, reused: false)
                self.state = .succeeded(result, demo: true)
                self.task = nil
                onSuccess(result)
            }
            return
        }
        do {
            let executor = try makeExecutor()
            self.executor = executor
            task = Task { [weak self] in
                do {
                    let result = try await executor.install(candidate)
                    guard let self, self.generation == current, !Task.isCancelled else { return }
                    self.state = .succeeded(result, demo: false)
                    self.executor = nil
                    self.task = nil
                    onSuccess(result)
                } catch {
                    guard let self, self.generation == current, !Task.isCancelled else { return }
                    self.state = .failed(error.localizedDescription)
                    self.executor = nil
                    self.task = nil
                }
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func cancel(clearState: Bool = false) {
        let wasInstalling = isInstalling
        generation = UUID()
        executor?.cancel()
        task?.cancel()
        executor = nil
        task = nil
        if clearState { state = .idle }
        else if wasInstalling { state = .cancelled }
    }

    private static func bundledExecutor() throws -> any FixedEntryInstallExecuting {
        guard let resources = Bundle.main.resourceURL else { throw MissingInstallerResources() }
        let directory = resources.appendingPathComponent("FixedEntry", isDirectory: true)
        do {
            return try FixedEntryInstaller(helperScript: Data(contentsOf: directory.appendingPathComponent("relay.py")),
                installerScript: Data(contentsOf: directory.appendingPathComponent("install.py")))
        } catch {
            throw MissingInstallerResources()
        }
    }
}

private struct MissingInstallerResources: LocalizedError {
    var errorDescription: String? { "此应用缺少有效的固定入口安装文件，请使用完整构建的 CATunnel 应用。" }
}
