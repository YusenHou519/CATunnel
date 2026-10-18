import Combine
import Darwin
import Foundation
import ServiceManagement

enum LoginItemState: Equatable {
    case disabled, enabled, requiresApproval
}

@MainActor
protocol LoginItemBackend: AnyObject {
    func status() throws -> LoginItemState
    func legacyStatus(at url: URL) throws -> LoginItemState
    func register() throws
    func unregister() async throws
    func unloadLegacy() async throws
    func openSystemSettings()
}

struct LoginItemError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The legacy item only launches `open`; it must never target CATunnel or its SSH process directly.
struct LegacyLoginItem {
    static let label = "local.catunnel.autostart"
    static let arguments = ["/usr/bin/open", "-g", "-a", "/Applications/CATunnel.app"]
    let url: URL
    let backupDirectory: URL

    init(home: URL) {
        url = home.appendingPathComponent("Library/LaunchAgents/\(Self.label).plist")
        backupDirectory = home.appendingPathComponent("Library/Application Support/CATunnel/Backups/LoginItems")
    }

    func read() throws -> Data? {
        let manager = FileManager.default
        let attributes: [FileAttributeKey: Any]
        do { attributes = try manager.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            return nil
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw LoginItemError(message: "旧登录启动项不是普通文件，已保留，无法自动修改。")
        }
        let data = try Data(contentsOf: url)
        let expected: NSDictionary = ["Label": Self.label, "ProgramArguments": Self.arguments,
            "RunAtLoad": true, "LimitLoadToSessionType": "Aqua"]
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary,
              plist == expected else {
            throw LoginItemError(message: "旧登录启动项包含无法识别的设置，已保留。请先检查 \(url.path)。")
        }
        return data
    }

    func backup(_ expected: Data) throws -> URL {
        guard try read() == expected else { throw changedError }
        let directory = backupDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let backup = directory.appendingPathComponent(url.lastPathComponent)
        try expected.write(to: backup, options: .withoutOverwriting)
        guard try Data(contentsOf: backup) == expected else {
            throw LoginItemError(message: "旧登录启动项备份校验失败，原文件已保留。")
        }
        return backup
    }

    func remove(ifUnchanged expected: Data) throws {
        guard try read() == expected else { throw changedError }
        try FileManager.default.removeItem(at: url)
    }

    private var changedError: LoginItemError {
        LoginItemError(message: "旧登录启动项在操作期间发生变化，已停止修改，请重新检查。")
    }
}

@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    @Published private(set) var needsApproval = false
    @Published private(set) var canChange = true

    private let offline: Bool
    private let backend: LoginItemBackend
    private let validApplication: Bool
    private let legacy: LegacyLoginItem

    convenience init(offline: Bool = false) {
        let bundle = Bundle.main
        let valid = bundle.bundleURL.pathExtension == "app"
            && bundle.bundleIdentifier == AppIdentity.bundleIdentifier
            && bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL"
            && bundle.executableURL.map { FileManager.default.isExecutableFile(atPath: $0.path) } == true
        self.init(offline: offline, backend: SystemLoginItemBackend(),
                  home: FileManager.default.homeDirectoryForCurrentUser, validApplication: valid)
    }

    init(offline: Bool = false, backend: LoginItemBackend, home: URL, validApplication: Bool) {
        self.offline = offline
        self.backend = backend
        self.validApplication = validApplication
        legacy = LegacyLoginItem(home: home)
        refresh()
    }

    func refresh() {
        guard !offline else {
            message = "离线演示：此开关仅在本次演示中生效。"
            return
        }
        do {
            let snapshot = try readSnapshot()
            apply(snapshot)
        } catch {
            // Retain the last known value instead of displaying a read failure as “disabled”.
            canChange = false
            message = "无法读取登录启动状态：\(error.localizedDescription)"
        }
    }

    func setEnabled(_ enabled: Bool) async {
        guard !isBusy else { return }
        if offline {
            isEnabled = enabled
            needsApproval = false
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let snapshot = try readSnapshot()
            guard !enabled || validApplication else {
                throw LoginItemError(message: "请从完整的 CATunnel.app 中启用登录启动。")
            }
            // An already-enabled legacy entry remains supported until the user explicitly disables it.
            if enabled, snapshot.legacyData != nil, snapshot.legacyState == .enabled,
               snapshot.native == .disabled {
                apply(snapshot)
                return
            }
            var backup: URL?
            if let data = snapshot.legacyData {
                backup = try legacy.backup(data)
                guard try legacy.read() == data else {
                    throw LoginItemError(message: "旧登录启动项已变化，原文件已保留。")
                }
                try await backend.unloadLegacy()
                try legacy.remove(ifUnchanged: data)
            }
            if enabled {
                if snapshot.native == .disabled { try backend.register() }
            } else if snapshot.native != .disabled {
                try await backend.unregister()
            }
            let updated = try readSnapshot()
            apply(updated)
            if enabled, updated.native == .disabled {
                throw LoginItemError(message: "系统尚未登记登录启动，请重试或检查系统设置。")
            }
            if !enabled, isEnabled || needsApproval {
                throw LoginItemError(message: "系统尚未关闭登录启动，请重试或检查系统设置。")
            }
            if let backup {
                let note = "旧登录启动项已备份到 \(backup.path)。"
                message = [message, note].compactMap { $0 }.joined(separator: "\n")
            }
        } catch {
            let failure = error.localizedDescription
            refresh()
            if enabled, needsApproval {
                message = "等待系统批准，请在系统设置的“登录项”中允许 CATunnel。\n\(failure)"
            } else {
                message = "未能\(enabled ? "开启" : "关闭")登录启动：\(failure)"
            }
        }
    }

    func openSystemSettings() {
        guard !offline else { return }
        backend.openSystemSettings()
    }

    private struct Snapshot {
        let native: LoginItemState
        let legacyData: Data?
        let legacyState: LoginItemState
    }

    private func readSnapshot() throws -> Snapshot {
        let data = try legacy.read()
        return try Snapshot(native: validApplication ? backend.status() : .disabled,
                            legacyData: data, legacyState: data == nil ? .disabled : backend.legacyStatus(at: legacy.url))
    }

    private func apply(_ snapshot: Snapshot) {
        needsApproval = snapshot.native == .requiresApproval || snapshot.legacyState == .requiresApproval
        isEnabled = snapshot.native != .disabled || snapshot.legacyState != .disabled
        canChange = validApplication || isEnabled
        if needsApproval {
            message = "等待系统批准，请在系统设置的“登录项”中允许 CATunnel。"
        } else if snapshot.legacyState == .enabled {
            message = "已使用现有登录启动项；关闭时会先备份，再移除该启动项。"
        } else if !validApplication {
            message = "请从完整的 CATunnel.app 中启用登录启动。"
        } else {
            message = nil
        }
    }
}

@MainActor
final class SystemLoginItemBackend: LoginItemBackend {
    func status() throws -> LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .disabled
        case .notFound: throw LoginItemError(message: "系统找不到此应用的登录启动服务。")
        @unknown default: throw LoginItemError(message: "系统返回了未知的登录启动状态。")
        }
    }

    func legacyStatus(at url: URL) throws -> LoginItemState {
        let disabled = try Self.launchctl(["print-disabled", "gui/\(getuid())"])
        guard disabled.status == 0 else {
            throw LoginItemError(message: "无法检查旧登录启动项的系统状态。")
        }
        let key = "\"\(LegacyLoginItem.label)\" => true"
        if disabled.output.components(separatedBy: .newlines).contains(where: { $0.trimmingCharacters(in: .whitespaces) == key }) {
            return .disabled
        }
        if SMAppService.statusForLegacyPlist(at: url) == .requiresApproval { return .requiresApproval }
        // An exact RunAtLoad plist is also a login item when it predates ServiceManagement registration.
        return .enabled
    }

    func register() throws { try SMAppService.mainApp.register() }

    func unregister() async throws { try await SMAppService.mainApp.unregister() }

    func unloadLegacy() async throws {
        try await Task.detached {
            let target = "gui/\(getuid())/\(LegacyLoginItem.label)"
            let existing = try Self.launchctl(["print", target])
            if existing.status == 113 { return } // The exact service is not currently loaded.
            guard existing.status == 0 else {
                throw LoginItemError(message: "无法检查已加载的旧登录启动项，已保留原文件。")
            }
            let lines = existing.output.components(separatedBy: .newlines).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard lines.contains("program = /usr/bin/open"),
                  let start = lines.firstIndex(of: "arguments = {"),
                  let end = lines[(start + 1)...].firstIndex(of: "}"),
                  Array(lines[(start + 1)..<end]) == LegacyLoginItem.arguments else {
                throw LoginItemError(message: "已加载的旧启动项与 CATunnel 的已知启动命令不一致，已保留。")
            }
            let result = try Self.launchctl(["bootout", target])
            guard result.status == 0 || result.status == 113 else {
                throw LoginItemError(message: "未能卸载旧登录启动项，原文件已保留。")
            }
        }.value
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    private nonisolated static func launchctl(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
