import Foundation

/// Only injected backends and temporary home directories are used by these checks.
@MainActor
enum LoginItemChecks {
    private final class Backend: LoginItemBackend {
        var state: LoginItemState = .disabled
        var legacy: LoginItemState = .enabled
        var calls: [String] = []
        var readFailure = false
        var registerFailure = false
        var unregisterFailure = false
        var unloadFailure = false
        var approvalRequired = false
        var afterUnload: (() throws -> Void)?

        func status() throws -> LoginItemState {
            calls.append("status")
            if readFailure { throw LoginItemError(message: "fixture read failure") }
            return state
        }
        func legacyStatus(at url: URL) throws -> LoginItemState {
            calls.append("legacy-status")
            if readFailure { throw LoginItemError(message: "fixture read failure") }
            return legacy
        }
        func register() throws {
            calls.append("register")
            if registerFailure { throw LoginItemError(message: "fixture registration failure") }
            state = approvalRequired ? .requiresApproval : .enabled
        }
        func unregister() async throws {
            calls.append("unregister")
            if unregisterFailure { throw LoginItemError(message: "fixture unregister failure") }
            state = .disabled
        }
        func unloadLegacy() async throws {
            calls.append("unload-legacy")
            if unloadFailure { throw LoginItemError(message: "fixture unload failure") }
            try afterUnload?()
        }
        func openSystemSettings() { calls.append("system-settings") }
        var mutations: [String] { calls.filter { !["status", "legacy-status"].contains($0) } }
    }

    static func run(in temporaryDirectory: URL) async throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        let root = temporaryDirectory.appendingPathComponent("login-items-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func make(_ name: String, backend: Backend? = nil, offline: Bool = false,
                  valid: Bool = true) -> (LoginItemManager, Backend, URL) {
            let home = root.appendingPathComponent(name)
            let injected = backend ?? Backend()
            return (LoginItemManager(offline: offline, backend: injected, home: home, validApplication: valid), injected, home)
        }
        func legacyData(arguments: [String] = LegacyLoginItem.arguments) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: ["Label": LegacyLoginItem.label,
                "ProgramArguments": arguments, "RunAtLoad": true, "LimitLoadToSessionType": "Aqua"],
                format: .xml, options: 0)
        }
        func writeLegacy(_ data: Data, home: URL) throws -> LegacyLoginItem {
            let item = LegacyLoginItem(home: home)
            try FileManager.default.createDirectory(at: item.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: item.url)
            return item
        }

        let (fresh, freshBackend, freshHome) = make("fresh")
        fresh.refresh()
        checks["loginItemRefreshHasNoWritesOrRegistrations"] = !fresh.isEnabled && fresh.canChange
            && fresh.message == nil && freshBackend.mutations.isEmpty
            && !FileManager.default.fileExists(atPath: freshHome.path)
        await fresh.setEnabled(true)
        checks["loginItemExplicitEnableUsesNativeRegistration"] = fresh.isEnabled && !fresh.needsApproval
            && freshBackend.mutations == ["register"]
        await fresh.setEnabled(false)
        checks["loginItemExplicitDisableUnregistersOnlyNativeLogin"] = !fresh.isEnabled && !fresh.needsApproval
            && freshBackend.mutations == ["register", "unregister"]

        let (offline, offlineBackend, offlineHome) = make("offline", offline: true)
        await offline.setEnabled(true)
        offline.refresh()
        offline.openSystemSettings()
        checks["offlineLoginItemToggleOnlyChangesMemory"] = offline.isEnabled && offline.canChange
            && offlineBackend.calls.isEmpty && !FileManager.default.fileExists(atPath: offlineHome.path)

        let (unbundled, unbundledBackend, _) = make("unbundled", valid: false)
        await unbundled.setEnabled(true)
        checks["loginItemRequiresApplicationBundleToEnable"] = !unbundled.isEnabled && !unbundled.canChange
            && unbundled.message != nil && unbundledBackend.calls.isEmpty

        let approvalBackend = Backend()
        approvalBackend.approvalRequired = true
        let (pending, _, _) = make("approval", backend: approvalBackend)
        await pending.setEnabled(true)
        pending.openSystemSettings()
        checks["loginItemPendingApprovalRemainsExplicit"] = pending.isEnabled && pending.needsApproval
            && pending.message?.contains("等待系统批准") == true
            && approvalBackend.mutations == ["register", "system-settings"]
        approvalBackend.state = .enabled
        pending.refresh()
        checks["loginItemRefreshReflectsSystemApproval"] = pending.isEnabled && !pending.needsApproval && pending.message == nil

        let readBackend = Backend()
        readBackend.state = .enabled
        let (readFailure, _, _) = make("read-failure", backend: readBackend)
        readBackend.readFailure = true
        readFailure.refresh()
        await readFailure.setEnabled(false)
        checks["loginItemReadFailureDoesNotFalselyReportDisabled"] = readFailure.isEnabled && !readFailure.canChange
            && readFailure.message != nil && readBackend.mutations.isEmpty

        let registerBackend = Backend()
        registerBackend.registerFailure = true
        let (registerFailure, _, _) = make("register-failure", backend: registerBackend)
        await registerFailure.setEnabled(true)
        checks["loginItemRegistrationFailureDoesNotReportEnabled"] = !registerFailure.isEnabled && !registerFailure.isBusy
            && registerFailure.message?.contains("fixture registration failure") == true
        let unregisterBackend = Backend()
        unregisterBackend.state = .enabled
        unregisterBackend.unregisterFailure = true
        let (unregisterFailure, _, _) = make("unregister-failure", backend: unregisterBackend)
        await unregisterFailure.setEnabled(false)
        checks["loginItemUnregisterFailureRetainsActualState"] = unregisterFailure.isEnabled
            && unregisterFailure.message?.contains("fixture unregister failure") == true

        let saved = try legacyData()
        let legacyHome = root.appendingPathComponent("legacy")
        let item = try writeLegacy(saved, home: legacyHome)
        let legacyBackend = Backend()
        let legacy = LoginItemManager(backend: legacyBackend, home: legacyHome, validApplication: true)
        let unchanged = try Data(contentsOf: item.url)
        checks["existingLegacyLoginItemIsReadOnlyOnInitialization"] = legacy.isEnabled && legacy.canChange
            && unchanged == saved && legacyBackend.mutations.isEmpty
            && !FileManager.default.fileExists(atPath: item.backupDirectory.path)
        await legacy.setEnabled(true)
        checks["existingLegacyLoginItemDoesNotGetDuplicateRegistration"] = legacy.isEnabled
            && legacyBackend.mutations.isEmpty
        await legacy.setEnabled(false)
        let backupDirectories = try FileManager.default.contentsOfDirectory(at: item.backupDirectory, includingPropertiesForKeys: nil)
        let backup = try Data(contentsOf: backupDirectories[0].appendingPathComponent(item.url.lastPathComponent))
        checks["legacyLoginItemExplicitDisableBacksUpThenRemovesExactFile"] = !legacy.isEnabled
            && !FileManager.default.fileExists(atPath: item.url.path)
            && backupDirectories.count == 1 && backup == saved && legacyBackend.mutations == ["unload-legacy"]
        await legacy.setEnabled(true)
        checks["reenablingLegacyLoginItemUsesOnlyNativeRegistration"] = legacy.isEnabled
            && legacyBackend.mutations == ["unload-legacy", "register"]
            && !FileManager.default.fileExists(atPath: item.url.path)

        let modifiedHome = root.appendingPathComponent("modified")
        let modifiedData = try legacyData(arguments: ["/usr/bin/open", "-a", "/Applications/Unrelated.app"])
        let modifiedItem = try writeLegacy(modifiedData, home: modifiedHome)
        let modifiedBackend = Backend()
        let modified = LoginItemManager(backend: modifiedBackend, home: modifiedHome, validApplication: true)
        await modified.setEnabled(false)
        let modifiedAfter = try Data(contentsOf: modifiedItem.url)
        checks["unrecognizedLegacyLoginItemIsNeverRemoved"] = !modified.canChange && modified.message != nil
            && modifiedAfter == modifiedData && modifiedBackend.mutations.isEmpty

        let unloadHome = root.appendingPathComponent("unload-failure")
        let unloadItem = try writeLegacy(saved, home: unloadHome)
        let unloadBackend = Backend()
        unloadBackend.unloadFailure = true
        let unload = LoginItemManager(backend: unloadBackend, home: unloadHome, validApplication: true)
        await unload.setEnabled(false)
        let unloadAfter = try Data(contentsOf: unloadItem.url)
        checks["failedLegacyUnloadPreservesLoginItem"] = unload.isEnabled && unloadAfter == saved
            && unload.message?.contains("fixture unload failure") == true

        let changedHome = root.appendingPathComponent("concurrent-change")
        let changedItem = try writeLegacy(saved, home: changedHome)
        let changedBackend = Backend()
        changedBackend.afterUnload = { try modifiedData.write(to: changedItem.url) }
        let changed = LoginItemManager(backend: changedBackend, home: changedHome, validApplication: true)
        await changed.setEnabled(false)
        let changedAfter = try Data(contentsOf: changedItem.url)
        checks["concurrentlyChangedLegacyLoginItemIsNotDeleted"] = changedAfter == modifiedData
            && !changed.canChange && changed.message != nil

        let symlinkHome = root.appendingPathComponent("symlink")
        let symlinkItem = LegacyLoginItem(home: symlinkHome)
        try FileManager.default.createDirectory(at: symlinkItem.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let otherFile = root.appendingPathComponent("unrelated.plist")
        try saved.write(to: otherFile)
        try FileManager.default.createSymbolicLink(at: symlinkItem.url, withDestinationURL: otherFile)
        let symlinkBackend = Backend()
        let symlink = LoginItemManager(backend: symlinkBackend, home: symlinkHome, validApplication: true)
        await symlink.setEnabled(false)
        let otherAfter = try Data(contentsOf: otherFile)
        checks["legacySymlinkIsNotFollowedForModification"] = !symlink.canChange && symlink.message != nil
            && symlinkBackend.mutations.isEmpty && otherAfter == saved
        return checks
    }
}
