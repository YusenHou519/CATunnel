import Foundation
import TunnelCore

@MainActor
enum SSHConfigStoreChecks {
    static func run(in root: URL) async throws -> [String: Bool] {
        let directory = root.appendingPathComponent("ssh-sync")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("ssh-config")
        let settings = directory.appendingPathComponent("settings")
        func writeSource(port: Int, includeNewServer: Bool = true) throws {
            var config = """
                Host saved
                    HostName 192.0.2.1
                    User user
                    Port \(port)
                """
            if includeNewServer {
                config += """

                    Host new-server
                        HostName 192.0.2.2
                        User user
                    """
            }
            try config.write(to: source, atomically: true, encoding: .utf8)
        }

        try writeSource(port: 22)
        let store = TunnelStore(settingsDirectory: settings, sshConfigURL: source)
        var profile = ProfileStoreChecks.profile(1)
        profile.name = "Custom server name"
        profile.remotePort = 18000
        profile.autoConnectOnLaunch = true
        profile.useFixedEntry = true
        profile.fixedEntryHelperPath = "/fixture/relay.py"
        profile.fixedEntryRuntimePath = "/fixture/runtime"
        profile.fixedEntryPythonPath = "/fixture/python3"
        try store.add(profile)
        let savedID = profile.id
        await store.refreshSSHConfig()
        var checks = ["sshSyncDefaultsOff": store.profiles == [profile]]
        store.setSSHConfigSyncEnabled(true)
        await store.refreshSSHConfig()

        let associated = store.profiles.first { $0.id == savedID }
        let imported = store.profiles.first { $0.sshConfigAlias == "new-server" }
        checks["sshSyncAssociatesExistingAndAddsStoppedProfile"] = store.profiles.count == 2
            && associated?.sshConfigAlias == "saved" && associated?.name == profile.name
            && associated?.remotePort == profile.remotePort && associated?.autoConnectOnLaunch == true
            && associated?.useFixedEntry == true && imported?.autoConnectOnLaunch == false
            && imported.map { store.status(for: $0.id).phase == .stopped } == true
        let reloaded = TunnelStore(settingsDirectory: settings, sshConfigURL: source)
        checks["sshSyncPreservesLinksAndOptInAcrossLaunch"] = reloaded.sshConfigSyncEnabled
            && reloaded.profiles == store.profiles

        let active = TunnelStatus(phase: .connected, message: "Fixture", connectedAt: Date())
        store.controller?.onEvent?(.status(id: savedID, status: active))
        try writeSource(port: 2201)
        await store.refreshSSHConfig()
        checks["sshSyncDoesNotChangeActiveTunnel"] = store.profiles.first { $0.id == savedID } == associated
            && store.status(for: savedID) == active
        store.controller?.onEvent?(.status(id: savedID, status: .stopped))
        for _ in 0..<60 {
            if store.profiles.first(where: { $0.id == savedID })?.sshPort == 2201 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let updated = store.profiles.first { $0.id == savedID }
        checks["sshSyncAppliesAfterStopAndResetsOldFixedEntry"] = updated?.sshPort == 2201
            && updated?.useFixedEntry == false && updated?.fixedEntryHelperPath == nil
            && updated?.fixedEntryRuntimePath == nil && updated?.fixedEntryPythonPath == nil
            && updated?.autoConnectOnLaunch == true && updated?.remotePort == profile.remotePort
            && associated.map { !store.isCurrentEditorProfile($0) } == true

        try writeSource(port: 2201, includeNewServer: false)
        await store.refreshSSHConfig()
        checks["sshSyncRetainsProfileWhenAliasDisappears"] = imported.map { store.profiles.contains($0) } == true
        if let imported {
            try store.remove(imported.id)
            try writeSource(port: 2201)
            await store.refreshSSHConfig()
            let afterDeletion = TunnelStore(settingsDirectory: settings, sshConfigURL: source)
            checks["sshSyncDeletionSkipsAliasOnFutureRefresh"] = !store.profiles.contains(imported)
                && afterDeletion.excludedSSHConfigAliases == ["new-server"]
            await store.restoreExcludedSSHConfigAliases()
            checks["sshSyncRestoringExcludedAliasImportsItAgain"] = store.excludedSSHConfigAliases.isEmpty
                && store.profiles.contains { $0.sshConfigAlias == "new-server" && $0.id != imported.id }
        } else {
            checks["sshSyncDeletionSkipsAliasOnFutureRefresh"] = false
            checks["sshSyncRestoringExcludedAliasImportsItAgain"] = false
        }

        let savedProfiles = store.profiles
        try FileManager.default.removeItem(at: source)
        await store.refreshSSHConfig()
        checks["sshSyncMissingFilePreservesLastSavedProfiles"] = store.profiles == savedProfiles
        store.setSSHConfigSyncEnabled(false)

        let swapStore = TunnelStore(settingsDirectory: directory.appendingPathComponent("swap"), sshConfigURL: source)
        try writeSource(port: 22)
        swapStore.setSSHConfigSyncEnabled(true)
        await swapStore.refreshSSHConfig()
        let beforeSwap = swapStore.profiles
        let swappedSource = """
            Host saved
                HostName 192.0.2.2
                User user
            Host new-server
                HostName 192.0.2.1
                User user
            """
        try swappedSource.write(to: source, atomically: true, encoding: .utf8)
        await swapStore.refreshSSHConfig()
        checks["sshSyncAllowsTwoStoppedAliasesToSwapEndpoints"] = beforeSwap.map(\.host) == ["192.0.2.1", "192.0.2.2"]
            && swapStore.profiles.map(\.host) == ["192.0.2.2", "192.0.2.1"]
            && swapStore.profiles.map(\.id) == beforeSwap.map(\.id)
        swapStore.setSSHConfigSyncEnabled(false)
        checks.merge(try await manualSyncChecks(in: directory.appendingPathComponent("manual"))) { _, value in value }
        return checks
    }

    private static func manualSyncChecks(in directory: URL) async throws -> [String: Bool] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("ssh-config")
        let settings = directory.appendingPathComponent("settings")
        func writeSource(port: Int) throws {
            try """
                Host manual-saved
                    HostName 192.0.2.31
                    User user
                    Port \(port)
                Host manual-new
                    HostName 192.0.2.32
                    User user
                """.write(to: source, atomically: true, encoding: .utf8)
        }
        try writeSource(port: 2231)
        let store = TunnelStore(settingsDirectory: settings, sshConfigURL: source)
        var saved = ProfileStoreChecks.profile(31)
        saved.sshConfigAlias = "manual-saved"
        saved.autoConnectOnLaunch = true
        saved.remotePort = 18031
        try store.add(saved)
        let profilesURL = settings.appendingPathComponent("profiles.json")
        let preferencesURL = settings.appendingPathComponent("ui-preferences.json")
        let initialProfiles = try Data(contentsOf: profilesURL)
        let initialPreferences = try Data(contentsOf: preferencesURL)
        await store.refreshSSHConfig()
        var checks = ["manualSSHSyncDefaultsOffAndAutomaticRefreshDoesNothing": !store.sshConfigSyncEnabled
            && store.profiles == [saved] && !store.sshConfigRefreshing
            && (try? Data(contentsOf: profilesURL)) == initialProfiles
            && (try? Data(contentsOf: preferencesURL)) == initialPreferences]

        await store.syncSSHConfigNow()
        let updated = store.profiles.first { $0.id == saved.id }
        let imported = store.profiles.first { $0.sshConfigAlias == "manual-new" }
        checks["manualSSHSyncUpdatesLinkedServerAndImportsWhileAutomaticSyncIsOff"] = !store.sshConfigSyncEnabled
            && !store.sshConfigRefreshing && store.profiles.count == 2
            && updated?.sshPort == 2231 && updated?.sshConfigAlias == saved.sshConfigAlias
            && updated?.name == saved.name && updated?.remotePort == saved.remotePort
            && updated?.autoConnectOnLaunch == true && imported?.autoConnectOnLaunch == false
            && store.statuses.values.allSatisfy { $0.phase == .stopped }
        let reloaded = TunnelStore(settingsDirectory: settings, sshConfigURL: source)
        checks["manualSSHSyncPersistsProfilesWithoutEnablingAutomaticSync"] = !reloaded.sshConfigSyncEnabled
            && reloaded.profiles == store.profiles
            && reloaded.profiles.first { $0.sshConfigAlias == "manual-new" }?.autoConnectOnLaunch == false

        try writeSource(port: 2232)
        let beforeAutomaticRefresh = reloaded.profiles
        let beforeAutomaticProfiles = try Data(contentsOf: profilesURL)
        await reloaded.refreshSSHConfig()
        checks["manualSSHSyncDoesNotEnableSubsequentAutomaticRefresh"] = !reloaded.sshConfigSyncEnabled
            && reloaded.profiles == beforeAutomaticRefresh
            && (try? Data(contentsOf: profilesURL)) == beforeAutomaticProfiles
        await reloaded.syncSSHConfigNow()
        let finalReloaded = TunnelStore(settingsDirectory: settings, sshConfigURL: source)
        checks["manualSSHSyncButtonCanUpdateAgainWithoutChangingIDsOrOptIn"] = !reloaded.sshConfigSyncEnabled
            && !finalReloaded.sshConfigSyncEnabled && !reloaded.sshConfigRefreshing
            && reloaded.profiles.count == 2 && finalReloaded.profiles == reloaded.profiles
            && reloaded.profiles.first { $0.id == saved.id }?.sshPort == 2232
            && reloaded.profiles.first { $0.sshConfigAlias == "manual-new" }?.id == imported?.id
            && reloaded.profiles.first { $0.sshConfigAlias == "manual-new" }?.autoConnectOnLaunch == false
            && reloaded.statuses.values.allSatisfy { $0.phase == .stopped }
        for fixture in [store, reloaded, finalReloaded] { await fixture.shutdown() }
        return checks
    }
}
