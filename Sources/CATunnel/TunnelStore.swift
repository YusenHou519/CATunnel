import AppKit
import Combine
import Darwin
import Foundation
import TunnelCore

struct TunnelLogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let message: String
}

enum StoreError: LocalizedError {
    case activeConnection, unknownServer, configurationUnavailable

    var errorDescription: String? {
        switch self {
        case .activeConnection: return "请先停止这台服务器的隧道，再修改连接设置。"
        case .unknownServer: return "找不到这台服务器。"
        case .configurationUnavailable: return "服务器配置无法读取。为保护原文件，修改已禁用；请修复配置文件后重新启动 CATunnel。"
        }
    }
}

@MainActor
final class TunnelStore: ObservableObject {
    @Published private(set) var profiles: [ServerProfile]
    @Published private(set) var configurationError: String?
    @Published var statuses: [String: TunnelStatus] = [:]
    @Published var logs: [String: [TunnelLogEntry]] = [:]
    @Published private(set) var panelAppearance: PanelAppearance = .default
    @Published var showingAppearanceSettings = false
    @Published var selectedID: String {
        didSet {
            guard (profiles.isEmpty && selectedID.isEmpty) || profiles.contains(where: { $0.id == selectedID }) else {
                selectedID = profiles.contains(where: { $0.id == oldValue }) ? oldValue : profiles.first?.id ?? ""
                return
            }
            if hasLoadedPreferences && selectedID != oldValue { savePreferences() }
        }
    }

    let controller: TunnelController?
    let demoMode: Bool
    private let persistSettings: Bool
    private let settingsURL: URL
    private let preferencesURL: URL
    private var completedChecks: [String: CompletedCheck] = [:]
    private var demoTasks: [String: Task<Void, Never>] = [:]
    private var demoGenerations: [String: UUID] = [:]
    private var isShuttingDown = false
    private var hasLoadedPreferences = false

    private struct Preferences: Codable {
        var selectedID: String
        var panelAppearance: PanelAppearance

        private enum CodingKeys: String, CodingKey { case selectedID, panelAppearance }

        init(selectedID: String, panelAppearance: PanelAppearance) {
            self.selectedID = selectedID
            self.panelAppearance = panelAppearance.normalized
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            selectedID = (try? container.decode(String.self, forKey: .selectedID)) ?? ""
            panelAppearance = (try? container.decode(PanelAppearance.self, forKey: .panelAppearance)) ?? .default
        }
    }

    private struct CompletedCheck {
        var status: TunnelStatus
        var completedAt: Date
    }

    var selectedProfile: ServerProfile? { profiles.first { $0.id == selectedID } }

    init(persistSettings: Bool = true, controller: TunnelController? = nil,
         demoMode: Bool = false, settingsDirectory: URL? = nil) {
        self.persistSettings = persistSettings && !demoMode
        self.controller = demoMode ? nil : (controller ?? TunnelController())
        self.demoMode = demoMode
        let directory = settingsDirectory ?? AppIdentity.settingsDirectory()
        settingsURL = directory.appendingPathComponent("profiles.json")
        preferencesURL = directory.appendingPathComponent("ui-preferences.json")
        var loaded = demoMode ? ServerProfile.examples : []
        var configurationLoadError: String?
        if self.persistSettings && FileManager.default.fileExists(atPath: settingsURL.path) {
            do {
                loaded = try ServerConfiguration.decode(Data(contentsOf: settingsURL)).profiles
            } catch {
                configurationLoadError = "无法读取服务器配置：\(error.localizedDescription)\n原文件已保留，新增、编辑和删除已禁用。请修复 \(settingsURL.path) 后重新启动 CATunnel。"
            }
        }
        profiles = loaded
        selectedID = loaded.first?.id ?? ""
        configurationError = configurationLoadError
        var preferenceError: String?
        if self.persistSettings && FileManager.default.fileExists(atPath: preferencesURL.path) {
            do {
                let preferences = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: preferencesURL))
                if loaded.contains(where: { $0.id == preferences.selectedID }) {
                    selectedID = preferences.selectedID
                }
                panelAppearance = preferences.panelAppearance
            } catch {
                preferenceError = "未能读取界面偏好，已使用默认页签与外观。"
            }
        }
        hasLoadedPreferences = true
        for profile in loaded {
            statuses[profile.id] = .stopped
            logs[profile.id] = []
        }
        self.controller?.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case let .status(id, status):
                guard !self.demoMode else { return }
                self.receiveStatus(id, status)
            case let .log(id, message): self.appendLog(id, message)
            }
        }
        if let preferenceError { appendLog(selectedID, preferenceError) }
        if demoMode { prepareDemo() }
    }

    func status(for id: String) -> TunnelStatus { statuses[id] ?? .stopped }

    func presentationStatus(for id: String) -> TunnelStatus {
        var current = status(for: id)
        guard isShowingHistoricalResults(for: id), let completed = completedChecks[id] else { return current }
        current.proxyCheck = completed.status.proxyCheck
        current.proxyMessage = "历史检测 · " + completed.status.proxyMessage
        current.websiteResults = completed.status.websiteResults
        current.ipRisk = completed.status.ipRisk
        return current
    }

    func isShowingHistoricalResults(for id: String) -> Bool {
        guard completedChecks[id] != nil else { return false }
        let current = status(for: id)
        return current.phase != .connected || current.proxyCheck == .unchecked
    }

    func lastCompletedCheckAt(for id: String) -> Date? { completedChecks[id]?.completedAt }

    func start(_ id: String) {
        guard !isShuttingDown, let profile = profiles.first(where: { $0.id == id }) else { return }
        if demoMode {
            startDemo(id)
            return
        }
        controller?.start(profile)
    }

    func stop(_ id: String) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        if demoMode {
            cancelDemoTask(id)
            receiveStatus(id, .stopped)
            appendLog(id, "演示：已停止模拟隧道，没有操作真实 SSH 连接。")
            return
        }
        controller?.stop(id: id)
    }

    func testProxy(_ id: String) {
        guard !isShuttingDown, profiles.contains(where: { $0.id == id }) else { return }
        if demoMode {
            testDemo(id)
            return
        }
        controller?.testProxy(id: id)
    }

    func canModify(_ id: String) -> Bool {
        guard configurationError == nil, profiles.contains(where: { $0.id == id }) else { return false }
        let current = status(for: id)
        return [.stopped, .failed].contains(current.phase) && current.proxyCheck != .checking
    }

    func add(_ profile: ServerProfile) throws {
        let updated = profiles + [profile]
        try persistProfiles(updated)
        profiles = updated
        statuses[profile.id] = .stopped
        logs[profile.id] = []
        selectedID = profile.id
        appendLog(profile.id, demoMode ? "演示：服务器仅添加到内存中，没有写入配置文件。" : "服务器已添加，尚未开启隧道。")
    }

    func save(_ profile: ServerProfile) throws {
        try ensureConfigurationAvailable()
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { throw StoreError.unknownServer }
        guard canModify(profile.id) else { throw StoreError.activeConnection }
        var updated = profiles
        updated[index] = profile
        try persistProfiles(updated)
        profiles = updated
        cancelDemoTask(profile.id)
        completedChecks.removeValue(forKey: profile.id)
        statuses[profile.id] = .stopped
        appendLog(profile.id, demoMode ? "演示：设置仅更新在内存中，没有写入配置文件。" : "连接设置已保存；下次开启隧道时生效。")
    }

    func remove(_ id: String) throws {
        try ensureConfigurationAvailable()
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw StoreError.unknownServer }
        guard canModify(id) else { throw StoreError.activeConnection }
        var updated = profiles
        updated.remove(at: index)
        try persistProfiles(updated)
        profiles = updated
        cancelDemoTask(id)
        statuses.removeValue(forKey: id)
        logs.removeValue(forKey: id)
        completedChecks.removeValue(forKey: id)
        if selectedID == id {
            selectedID = updated.isEmpty ? "" : updated[min(index, updated.count - 1)].id
        }
    }

    private func ensureConfigurationAvailable() throws {
        guard configurationError == nil else { throw StoreError.configurationUnavailable }
    }

    private func persistProfiles(_ updated: [ServerProfile]) throws {
        try ensureConfigurationAvailable()
        let data = try ServerConfiguration(profiles: updated).encoded()
        guard persistSettings else { return }
        let folder = settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let temporaryURL = folder.appendingPathComponent(".profiles-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
        // Install the complete, private file atomically; failed writes leave memory and the prior file intact.
        guard rename(temporaryURL.path, settingsURL.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    func clearLogs(_ id: String) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        logs[id] = []
    }

    func updatePanelAppearance(width: Double? = nil, fontScale: Double? = nil) {
        let updated = PanelAppearance(width: width ?? panelAppearance.width,
                                      fontScale: fontScale ?? panelAppearance.fontScale)
        guard updated != panelAppearance else { return }
        panelAppearance = updated
        savePreferences()
    }

    func resetPanelAppearance() {
        updatePanelAppearance(width: PanelAppearance.default.width,
                              fontScale: PanelAppearance.default.fontScale)
    }

    func copyProxy(_ id: String) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("http://127.0.0.1:\(profile.remotePort)", forType: .string)
    }

    func shutdown() async {
        isShuttingDown = true
        if demoMode {
            for id in profiles.map(\.id) { stop(id) }
            return
        }
        await controller?.shutdown()
    }

    private func receiveStatus(_ id: String, _ status: TunnelStatus) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        if [.passed, .partial, .failed].contains(status.proxyCheck),
           status.websiteResults.count == WebsiteTarget.allCases.count,
           status.websiteResults.allSatisfy({ [.passed, .restricted, .failed].contains($0.state) }),
           [.available, .failed, .skipped].contains(status.ipRisk.state) {
            let dates = status.websiteResults.compactMap(\.checkedAt) + [status.ipRisk.checkedAt].compactMap { $0 }
            completedChecks[id] = CompletedCheck(status: status, completedAt: dates.max() ?? Date())
        }
        statuses[id] = status
    }

    private func savePreferences() {
        guard persistSettings else { return }
        do {
            let folder = preferencesURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(Preferences(selectedID: selectedID, panelAppearance: panelAppearance))
            try data.write(to: preferencesURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: preferencesURL.path)
        } catch {
            appendLog(selectedID, "无法保存界面偏好：\(error.localizedDescription)")
        }
    }

    private func prepareDemo() {
        guard let profile = profiles.first else { return }
        let date = Date().addingTimeInterval(-120)
        receiveStatus(profile.id, demoResult(profile, checkedAt: date, connectedAt: date.addingTimeInterval(-240)))
        for profile in profiles {
            appendLog(profile.id, "演示模式：此页面中的连接与检测均为模拟数据。")
        }
    }

    private func startDemo(_ id: String) {
        guard [.stopped, .failed].contains(status(for: id).phase) else { return }
        cancelDemoTask(id)
        let generation = UUID()
        demoGenerations[id] = generation
        receiveStatus(id, .init(phase: .connecting, message: "演示：正在模拟建立隧道…"))
        demoTasks[id] = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            guard let self, !Task.isCancelled, self.demoGenerations[id] == generation else { return }
            self.receiveStatus(id, .init(phase: .connected, message: "演示：模拟隧道已连接", connectedAt: Date()))
            self.demoTasks.removeValue(forKey: id)
            self.appendLog(id, "演示：模拟连接完成，没有启动 SSH。")
        }
    }

    private func testDemo(_ id: String) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        var current = status(for: id)
        guard current.phase == .connected, current.proxyCheck != .checking else { return }
        cancelDemoTask(id)
        let generation = UUID()
        demoGenerations[id] = generation
        current.proxyCheck = .checking
        current.proxyMessage = "演示：正在模拟四项检测…"
        current.websiteResults = WebsiteTarget.allCases.map { .init(target: $0, state: .checking, message: "演示检测中…") }
        current.ipRisk = profile.assessIPRisk
            ? .init(state: .checking, message: "演示：正在模拟出口评分…", stage: .exitIP)
            : .skipped()
        receiveStatus(id, current)
        let connectedAt = current.connectedAt
        demoTasks[id] = Task { [weak self] in
            for target in WebsiteTarget.allCases {
                do { try await Task.sleep(nanoseconds: 220_000_000) } catch { return }
                guard let self, !Task.isCancelled, self.demoGenerations[id] == generation else { return }
                var progress = self.status(for: id)
                let result = self.demoResult(profile, checkedAt: Date(), connectedAt: connectedAt)
                if let index = progress.websiteResults.firstIndex(where: { $0.target == target }),
                   let completed = result.websiteResults.first(where: { $0.target == target }) {
                    progress.websiteResults[index] = completed
                }
                let count = progress.websiteResults.filter { $0.state == .passed }.count
                progress.proxyMessage = "演示检测进度 · \(count)/4"
                self.receiveStatus(id, progress)
            }
            do { try await Task.sleep(nanoseconds: 220_000_000) } catch { return }
            guard let self, !Task.isCancelled, self.demoGenerations[id] == generation else { return }
            self.receiveStatus(id, self.demoResult(profile, checkedAt: Date(), connectedAt: connectedAt))
            self.demoTasks.removeValue(forKey: id)
            self.appendLog(id, "演示：四项模拟检测完成，没有发起网络请求。")
        }
    }

    private func cancelDemoTask(_ id: String) {
        demoTasks.removeValue(forKey: id)?.cancel()
        demoGenerations.removeValue(forKey: id)
    }

    private func demoResult(_ profile: ServerProfile, checkedAt: Date, connectedAt: Date?) -> TunnelStatus {
        // Documentation-only addresses prevent sample data from identifying a real exit IP.
        let ip = profile.id == "example-a" ? "198.51.100.10" : "198.51.100.20"
        let assessment = IPRiskAssessment(ip: ip, trustScore: 89, country: "United States", countryCode: "US",
            asOrganization: "Example Network", companyType: "hosting", isDatacenter: true,
            isResidential: false, isVPN: false, isProxy: false, isTor: false, isAbuser: false, isCrawler: false)
        let results = WebsiteTarget.allCases.map { target in
            WebsiteCheckResult(target: target, state: .passed, message: "演示：网络可达",
                httpStatus: target == .google ? 204 : ((target == .openAI || target == .claudeAPI) ? 401 : 200),
                elapsedMilliseconds: 180, checkedAt: checkedAt,
                exitIP: target == .claudeNetwork ? ip : nil, countryCode: target == .claudeNetwork ? "US" : nil)
        }
        return .init(phase: .connected, message: "演示：模拟隧道已连接", proxyCheck: .passed,
            proxyMessage: "演示：4/4 项模拟检测通过", connectedAt: connectedAt, websiteResults: results,
            ipRisk: profile.assessIPRisk
                ? .init(state: .available, message: "演示：信任分 89 · 纯净", stage: .riskAssessment,
                        assessment: assessment, ip: ip, countryCode: "US", checkedAt: checkedAt)
                : .skipped(ip: ip, countryCode: "US", checkedAt: checkedAt))
    }

    private func appendLog(_ id: String, _ message: String) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        var entries = logs[id] ?? []
        entries.append(TunnelLogEntry(date: Date(), message: message))
        logs[id] = Array(entries.suffix(160))
    }
}
