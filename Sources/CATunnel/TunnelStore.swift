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
    case activeConnection, unknownServer, configurationUnavailable, mismatchedOriginalProfile
    case sshConfigManaged, staleEditor

    var errorDescription: String? {
        switch self {
        case .activeConnection: return "请先停止这台服务器的隧道，再修改连接设置。"
        case .unknownServer: return "找不到这台服务器。"
        case .configurationUnavailable: return "服务器配置无法读取。为保护原文件，修改已禁用；请修复配置文件后重新启动 CATunnel。"
        case .mismatchedOriginalProfile: return "服务器编辑信息不匹配，请关闭编辑窗口后重试。"
        case .sshConfigManaged: return "SSH 连接信息由配置文件同步。请在 SSH 配置中修改。"
        case .staleEditor: return "服务器配置已更新。请关闭编辑窗口，重新打开后再修改。"
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
    @Published private(set) var hiddenPanelIDs: Set<String> = []
    @Published private(set) var sshConfigSyncEnabled = false
    @Published private(set) var sshConfigRefreshing = false
    @Published private(set) var sshConfigMessage: String?
    @Published private(set) var excludedSSHConfigAliases: Set<String> = []
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
    let loginItem: LoginItemManager
    let demoMode: Bool
    private let persistSettings: Bool
    private let settingsURL: URL
    private let preferencesURL: URL
    private let sshConfigURL: URL?
    private var sshConfigMonitor: Task<Void, Never>?
    private var completedChecks: [String: CompletedCheck] = [:]
    private var demoTasks: [String: Task<Void, Never>] = [:]
    private var demoGenerations: [String: UUID] = [:]
    private var isShuttingDown = false
    private var hasLoadedPreferences = false

    private struct Preferences: Codable {
        var selectedID: String
        var panelAppearance: PanelAppearance
        var hiddenPanelIDs: [String]
        var sshConfigSyncEnabled: Bool

        private enum CodingKeys: String, CodingKey { case selectedID, panelAppearance, hiddenPanelIDs, sshConfigSyncEnabled }

        init(selectedID: String, panelAppearance: PanelAppearance, hiddenPanelIDs: Set<String>, sshConfigSyncEnabled: Bool) {
            self.selectedID = selectedID
            self.panelAppearance = panelAppearance.normalized
            self.hiddenPanelIDs = hiddenPanelIDs.sorted()
            self.sshConfigSyncEnabled = sshConfigSyncEnabled
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            selectedID = (try? container.decode(String.self, forKey: .selectedID)) ?? ""
            panelAppearance = (try? container.decode(PanelAppearance.self, forKey: .panelAppearance)) ?? .default
            hiddenPanelIDs = (try? container.decode([String].self, forKey: .hiddenPanelIDs)) ?? []
            sshConfigSyncEnabled = (try? container.decode(Bool.self, forKey: .sshConfigSyncEnabled)) ?? false
        }
    }

    private struct CompletedCheck {
        var status: TunnelStatus
        var completedAt: Date
    }

    var selectedProfile: ServerProfile? { profiles.first { $0.id == selectedID } }
    var panelProfiles: [ServerProfile] { profiles.filter { isVisibleInPanel($0.id) } }
    var panelSelectedProfile: ServerProfile? {
        if let selectedProfile, isVisibleInPanel(selectedProfile.id) { return selectedProfile }
        return panelProfiles.first
    }
    var panelSelectedID: String { panelSelectedProfile?.id ?? "" }
    var canSyncSSHConfig: Bool { sshConfigURL != nil && configurationError == nil }

    init(persistSettings: Bool = true, controller: TunnelController? = nil,
         demoMode: Bool = false, settingsDirectory: URL? = nil,
         loginItem: LoginItemManager? = nil, sshConfigURL: URL? = nil) {
        self.persistSettings = persistSettings && !demoMode
        self.controller = demoMode ? nil : (controller ?? TunnelController())
        self.demoMode = demoMode
        self.loginItem = loginItem ?? LoginItemManager(offline: demoMode || !persistSettings || settingsDirectory != nil)
        let directory = settingsDirectory ?? AppIdentity.settingsDirectory()
        self.sshConfigURL = self.persistSettings ? sshConfigURL ?? (settingsDirectory == nil
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config") : nil) : nil
        settingsURL = directory.appendingPathComponent("profiles.json")
        preferencesURL = directory.appendingPathComponent("ui-preferences.json")
        var loaded = demoMode ? ServerProfile.examples : []
        var excluded: [String] = []
        var configurationLoadError: String?
        if self.persistSettings && FileManager.default.fileExists(atPath: settingsURL.path) {
            do {
                let configuration = try ServerConfiguration.decode(Data(contentsOf: settingsURL))
                loaded = configuration.profiles
                excluded = configuration.excludedSSHConfigAliases ?? []
            } catch {
                configurationLoadError = "无法读取服务器配置：\(error.localizedDescription)\n原文件已保留，新增、编辑和删除已禁用。请修复 \(settingsURL.path) 后重新启动 CATunnel。"
            }
        }
        profiles = loaded
        excludedSSHConfigAliases = Set(excluded.map { $0.lowercased() })
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
                hiddenPanelIDs = Set(preferences.hiddenPanelIDs).intersection(loaded.map(\.id))
                sshConfigSyncEnabled = preferences.sshConfigSyncEnabled
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

    func isVisibleInPanel(_ id: String) -> Bool { !hiddenPanelIDs.contains(id) }

    func selectPanelProfile(_ id: String) {
        guard panelProfiles.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    func setVisibleInPanel(_ visible: Bool, for id: String) {
        guard profiles.contains(where: { $0.id == id }), isVisibleInPanel(id) != visible else { return }
        if visible { hiddenPanelIDs.remove(id) }
        else { hiddenPanelIDs.insert(id) }
        savePreferences()
    }

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

    func isCurrentEditorProfile(_ original: ServerProfile) -> Bool {
        guard var current = profiles.first(where: { $0.id == original.id }) else { return false }
        current.autoConnectOnLaunch = original.autoConnectOnLaunch
        return current == original
    }

    private func sameSSHFields(_ left: ServerProfile, _ right: ServerProfile) -> Bool {
        left.host == right.host && left.user == right.user && left.sshPort == right.sshPort
            && left.identityFile == right.identityFile
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

    func save(_ profile: ServerProfile, original: ServerProfile? = nil,
              autoConnectOnLaunchEdited: Bool = false) throws {
        try ensureConfigurationAvailable()
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { throw StoreError.unknownServer }
        guard canModify(profile.id) else { throw StoreError.activeConnection }
        if let original, original.id != profile.id { throw StoreError.mismatchedOriginalProfile }
        let current = profiles[index]
        if let original, !isCurrentEditorProfile(original) { throw StoreError.staleEditor }
        if sshConfigSyncEnabled, current.sshConfigAlias != nil, !sameSSHFields(current, profile) {
            throw StoreError.sshConfigManaged
        }
        var edited = profile
        edited.sshConfigAlias = current.sshConfigAlias
        if let original, !autoConnectOnLaunchEdited,
           profile.autoConnectOnLaunch == original.autoConnectOnLaunch {
            // The settings panel can change this preference while the editor is open.
            edited.autoConnectOnLaunch = profiles[index].autoConnectOnLaunch
        }
        var updated = profiles
        updated[index] = edited
        try persistProfiles(updated)
        profiles = updated
        cancelDemoTask(profile.id)
        completedChecks.removeValue(forKey: profile.id)
        statuses[profile.id] = .stopped
        appendLog(profile.id, demoMode ? "演示：设置仅更新在内存中，没有写入配置文件。" : "连接设置已保存；下次开启隧道时生效。")
    }

    func setAutoConnectOnLaunch(_ enabled: Bool, for id: String) throws {
        try ensureConfigurationAvailable()
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw StoreError.unknownServer }
        guard profiles[index].autoConnectOnLaunch != enabled else { return }
        var updated = profiles
        updated[index].autoConnectOnLaunch = enabled
        try persistProfiles(updated)
        // Launch preference changes must not replace or stop an active controller session.
        profiles = updated
    }

    func remove(_ id: String) throws {
        try ensureConfigurationAvailable()
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw StoreError.unknownServer }
        guard canModify(id) else { throw StoreError.activeConnection }
        var updated = profiles
        let removed = updated.remove(at: index)
        var excluded = excludedSSHConfigAliases
        if let alias = removed.sshConfigAlias { excluded.insert(alias.lowercased()) }
        try persistProfiles(updated, excludedAliases: excluded)
        profiles = updated
        excludedSSHConfigAliases = excluded
        cancelDemoTask(id)
        statuses.removeValue(forKey: id)
        logs.removeValue(forKey: id)
        completedChecks.removeValue(forKey: id)
        let wasHidden = hiddenPanelIDs.remove(id) != nil
        if selectedID == id {
            selectedID = updated.isEmpty ? "" : updated[min(index, updated.count - 1)].id
        } else if wasHidden {
            savePreferences()
        }
    }

    private func ensureConfigurationAvailable() throws {
        guard configurationError == nil else { throw StoreError.configurationUnavailable }
    }

    private func persistProfiles(_ updated: [ServerProfile], excludedAliases: Set<String>? = nil) throws {
        try ensureConfigurationAvailable()
        let aliases = excludedAliases ?? excludedSSHConfigAliases
        let data = try ServerConfiguration(profiles: updated, excludedSSHConfigAliases: Array(aliases)).encoded()
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

    func setSSHConfigSyncEnabled(_ enabled: Bool) {
        guard canSyncSSHConfig, enabled != sshConfigSyncEnabled else { return }
        sshConfigSyncEnabled = enabled
        savePreferences()
        if enabled {
            startSSHConfigMonitoring(immediately: true)
        } else {
            sshConfigMonitor?.cancel()
            sshConfigMonitor = nil
            sshConfigMessage = nil
        }
    }

    func startSSHConfigMonitoring(immediately: Bool = false) {
        guard canSyncSSHConfig, sshConfigSyncEnabled, sshConfigMonitor == nil, !isShuttingDown else { return }
        sshConfigMonitor = Task { [weak self] in
            if immediately { await self?.refreshSSHConfig() }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { return }
                guard let self else { return }
                await self.refreshSSHConfig()
            }
        }
    }

    func refreshSSHConfig() async {
        await performSSHConfigRefresh(manual: false)
    }

    func syncSSHConfigNow() async {
        await performSSHConfigRefresh(manual: true)
    }

    private func performSSHConfigRefresh(manual: Bool) async {
        guard let sshConfigURL, canSyncSSHConfig, manual || sshConfigSyncEnabled,
              !isShuttingDown, !sshConfigRefreshing else { return }
        sshConfigRefreshing = true
        defer { sshConfigRefreshing = false }
        let result = await Task.detached(priority: .utility) { SSHConfigImport.load(from: sshConfigURL) }.value
        guard !Task.isCancelled, !isShuttingDown, manual || sshConfigSyncEnabled else { return }
        guard result.availability == .available else {
            sshConfigMessage = result.message ?? "未能读取 SSH 配置，已保留现有服务器。"
            return
        }
        do {
            try applySSHConfig(result)
        } catch {
            sshConfigMessage = "未能保存同步结果，已保留现有服务器。"
        }
    }

    func restoreExcludedSSHConfigAliases() async {
        guard canSyncSSHConfig, !excludedSSHConfigAliases.isEmpty else { return }
        do {
            try persistProfiles(profiles, excludedAliases: [])
            excludedSSHConfigAliases = []
            await refreshSSHConfig()
        } catch {
            sshConfigMessage = "无法恢复已跳过的别名。"
        }
    }

    private func applySSHConfig(_ result: SSHConfigImportResult) throws {
        var updated = profiles
        var resetByIndex: [Int: Bool] = [:]
        var newProfiles: [ServerProfile] = []
        var deferred = 0
        var conflicting = 0
        let knownAliases = Set(result.entries.map { $0.alias.lowercased() })
        let noSource = profiles.filter { profile in
            profile.sshConfigAlias.map { !knownAliases.contains($0.lowercased()) } ?? false
        }.count

        for entry in result.entries {
            let alias = entry.alias.lowercased()
            guard !excludedSSHConfigAliases.contains(alias) else { continue }
            let linked = profiles.firstIndex { $0.sshConfigAlias?.lowercased() == alias }
            let matching = profiles.indices.filter { index in
                let profile = profiles[index]
                return profile.sshConfigAlias == nil && profile.host.lowercased() == entry.host.lowercased()
                    && profile.user == entry.user && profile.sshPort == entry.sshPort
            }
            if linked == nil, matching.count > 1 {
                conflicting += 1
                continue
            }
            let index = linked ?? matching.first.flatMap { resetByIndex[$0] == nil ? $0 : nil }
            var candidate = index.map { profiles[$0] } ?? .draft()
            let old = candidate
            if index == nil { candidate.name = entry.alias }
            candidate.sshConfigAlias = entry.alias
            candidate.host = entry.host
            candidate.user = entry.user
            candidate.sshPort = entry.sshPort
            candidate.identityFile = entry.identityFile
            let newTarget = old.host.lowercased() != candidate.host.lowercased()
                || old.user != candidate.user || old.sshPort != candidate.sshPort
            let resetFixedEntry = index != nil && newTarget && (candidate.useFixedEntry
                || candidate.fixedEntryHelperPath != nil || candidate.fixedEntryRuntimePath != nil
                || candidate.fixedEntryPythonPath != nil)
            if resetFixedEntry {
                candidate.useFixedEntry = false
                candidate.fixedEntryHelperPath = nil
                candidate.fixedEntryRuntimePath = nil
                candidate.fixedEntryPythonPath = nil
            }
            guard candidate != old else { continue }
            if let index, !canModify(old.id), !sameSSHFields(old, candidate) {
                deferred += 1
                if old.sshConfigAlias == nil {
                    // Record the association without changing the running session's parameters.
                    updated[index].sshConfigAlias = entry.alias
                    resetByIndex[index] = false
                }
                continue
            }
            guard (try? candidate.validateForConnection()) != nil else {
                conflicting += 1
                continue
            }
            if let index {
                updated[index] = candidate
                resetByIndex[index] = resetFixedEntry
            } else {
                newProfiles.append(candidate)
            }
        }

        func endpoint(_ profile: ServerProfile) -> String {
            "\(profile.host.lowercased()):\(profile.sshPort):\(profile.remotePort)"
        }
        // Validate the final endpoints together so two profiles can swap destinations.
        // Restoring a rejected move can block another move into its former endpoint.
        while true {
            let groups = Dictionary(grouping: updated.indices) { endpoint(updated[$0]) }
            let rejected = groups.values.filter { $0.count > 1 }.flatMap { group in
                group.filter { endpoint(profiles[$0]) != endpoint(updated[$0]) }
            }
            guard !rejected.isEmpty else { break }
            conflicting += rejected.count
            for index in rejected {
                updated[index] = profiles[index]
                resetByIndex.removeValue(forKey: index)
            }
        }
        var endpoints = Set(updated.map(endpoint))
        var added: [String] = []
        for profile in newProfiles {
            if endpoints.insert(endpoint(profile)).inserted {
                updated.append(profile)
                added.append(profile.id)
            } else {
                conflicting += 1
            }
        }
        if updated != profiles {
            try persistProfiles(updated)
            let previousProfiles = profiles
            profiles = updated
            for id in added {
                statuses[id] = .stopped
                logs[id] = []
                appendLog(id, "已从 SSH 配置添加服务器。")
            }
            for (index, resetFixedEntry) in resetByIndex {
                let id = updated[index].id
                if !sameSSHFields(previousProfiles[index], updated[index]) {
                    completedChecks.removeValue(forKey: id)
                    statuses[id] = .stopped
                }
                appendLog(id, resetFixedEntry
                    ? "SSH 目标已更新。请在新目标上重新安装固定入口。"
                    : "已从 SSH 配置同步连接设置。")
            }
            if selectedID.isEmpty, let first = updated.first { selectedID = first.id }
        }
        let linkedCount = updated.filter { $0.sshConfigAlias != nil }.count
        var summary = ["已关联 \(linkedCount) 台服务器"]
        if deferred > 0 {
            summary.append(sshConfigSyncEnabled
                ? "\(deferred) 台停止后自动更新"
                : "\(deferred) 台活动中，请停止后再次扫描")
        }
        if noSource > 0 { summary.append("\(noSource) 台保留上次配置") }
        if conflicting > 0 { summary.append("\(conflicting) 个条目冲突") }
        if !result.skippedAliases.isEmpty { summary.append("\(result.skippedAliases.count) 个别名不受支持") }
        let message = summary.joined(separator: " · ")
        if sshConfigMessage != message { sshConfigMessage = message }
    }

    func shutdown() async {
        isShuttingDown = true
        sshConfigMonitor?.cancel()
        if demoMode {
            for id in profiles.map(\.id) { stop(id) }
            return
        }
        await controller?.shutdown()
    }

    private func receiveStatus(_ id: String, _ status: TunnelStatus) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        let terminalRiskStates: [IPRiskCheckState] = [.available, .failed, .skipped]
        let netCoffeeFinished = !profile.assessIPRisk || terminalRiskStates.contains(status.ipRisk.state)
        if [.passed, .partial, .failed].contains(status.proxyCheck),
           status.websiteResults.count == WebsiteTarget.allCases.count,
           status.websiteResults.allSatisfy({ [.passed, .restricted, .failed].contains($0.state) }),
           netCoffeeFinished {
            let dates = status.websiteResults.compactMap(\.checkedAt)
                + [status.ipRisk.checkedAt].compactMap { $0 }
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
            let data = try JSONEncoder().encode(Preferences(selectedID: selectedID, panelAppearance: panelAppearance,
                hiddenPanelIDs: hiddenPanelIDs, sshConfigSyncEnabled: sshConfigSyncEnabled))
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
