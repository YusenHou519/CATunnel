import Foundation
import TunnelCore

/// The UI check invokes these fixtures without starting any real connection.
@MainActor
enum ProfileStoreChecks {
    static func profile(_ index: Int) -> ServerProfile {
        .init(id: "fixture-\(index)", name: "Server \(index)", host: "192.0.2.\(index)", user: "user",
              sshPort: 22, remotePort: 17892, localPort: 7890, autoReconnect: true)
    }

    private static func rejects(_ operation: () throws -> Void) -> Bool {
        do { try operation(); return false }
        catch { return true }
    }

    private static func failsWriting(_ operation: () throws -> Void) -> Bool {
        do { try operation(); return false }
        catch {
            let error = error as NSError
            return error.domain == NSCocoaErrorDomain || error.domain == NSPOSIXErrorDomain
        }
    }

    static func run(in temporaryDirectory: URL) async throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        var stores: [TunnelStore] = []
        func makeStore(_ directory: URL, persist: Bool = true, demo: Bool = false) -> TunnelStore {
            let store = TunnelStore(persistSettings: persist, demoMode: demo, settingsDirectory: directory)
            stores.append(store)
            return store
        }
        func writeProfiles(_ profiles: [ServerProfile], to directory: URL, legacy: Bool = false) throws -> Data {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data: Data
            if legacy { data = try JSONEncoder().encode(profiles) }
            else { data = try ServerConfiguration(profiles: profiles).encoded() }
            try data.write(to: directory.appendingPathComponent("profiles.json"))
            return data
        }

        let independentDirectory = AppIdentity.settingsDirectory(homeDirectory: temporaryDirectory)
        let unrelatedDirectory = independentDirectory.deletingLastPathComponent().appendingPathComponent("UnrelatedApp")
        let unrelatedData = try writeProfiles(ServerProfile.examples, to: unrelatedDirectory)
        let independent = makeStore(independentDirectory)
        checks["freshNormalStoreStartsEmptyWithoutWriting"] = independent.profiles.isEmpty && independent.selectedID.isEmpty
            && independent.selectedProfile == nil && independent.statuses.isEmpty && independent.configurationError == nil
            && !independent.demoMode && independent.controller != nil
            && !FileManager.default.fileExists(atPath: independentDirectory.path)
        checks["unknownProfileEditsAreRejected"] = rejects { try independent.save(profile(99)) }
            && rejects { try independent.remove("missing-server") }
            && independent.profiles.isEmpty && !FileManager.default.fileExists(atPath: independentDirectory.path)

        try independent.add(profile(1))
        checks["addInitializesStoppedProfileAndSelection"] = independent.profiles == [profile(1)]
            && independent.selectedID == profile(1).id && independent.status(for: profile(1).id).phase == .stopped
        for index in 2...9 { try independent.add(profile(index)) }
        checks["moreThanTwoServersKeepDistinctIdentities"] = independent.profiles.count == 9
            && Set(independent.profiles.map(\.id)).count == 9
            && independent.statuses.count == 9 && independent.statuses.values.allSatisfy { $0.phase == .stopped }
            && independent.selectedID == profile(9).id
        let savedProfiles = independent.profiles
        let savedSelection = independent.selectedID
        var duplicateID = profile(10)
        duplicateID.id = profile(1).id
        var duplicateEndpoint = profile(10)
        duplicateEndpoint.host = profile(1).host
        duplicateEndpoint.user = "anotheruser"
        checks["duplicateAddLeavesCollectionUnchanged"] = rejects { try independent.add(duplicateID) }
            && rejects { try independent.add(duplicateEndpoint) }
            && independent.profiles == savedProfiles && independent.selectedID == savedSelection
        var edited = profile(5)
        edited.name = "Renamed server"
        edited.localPort = 8899
        edited.identityFile = "~/.ssh/catunnel_fixture_key"
        edited.assessIPRisk = true
        try independent.save(edited)
        checks["editKeepsIdentityOrderAndUnrelatedProfiles"] = independent.profiles[4] == edited
            && independent.profiles.map(\.id) == savedProfiles.map(\.id)
            && independent.profiles.enumerated().allSatisfy { $0.offset == 4 || $0.element == savedProfiles[$0.offset] }
            && independent.selectedID == savedSelection
        let reloaded = makeStore(independentDirectory)
        let unrelatedReadBack = try Data(contentsOf: unrelatedDirectory.appendingPathComponent("profiles.json"))
        checks["configurationReloadsWithoutTouchingOtherApplications"] = reloaded.profiles == independent.profiles
            && reloaded.selectedID == independent.selectedID && unrelatedReadBack == unrelatedData
            && independentDirectory.lastPathComponent == "CATunnel"
        checks["SSHIdentityAndRiskConsentPersistPerProfile"] = reloaded.profiles[4].identityFile == edited.identityFile
            && reloaded.profiles[4].assessIPRisk && reloaded.profiles[0].identityFile == nil
            && !reloaded.profiles[0].assessIPRisk
        let savedObject = try JSONSerialization.jsonObject(with: Data(contentsOf: independentDirectory.appendingPathComponent("profiles.json"))) as? [String: Any]
        checks["savedConfigurationIsVersioned"] = savedObject?["version"] as? Int == 1
            && (savedObject?["profiles"] as? [Any])?.count == 9
        independent.selectedID = "unknown"
        independent.selectedID = ""
        checks["nonemptyListRejectsInvalidSelection"] = independent.selectedID == savedSelection
        try independent.remove(profile(1).id)
        checks["deleteNonselectedPreservesSelection"] = independent.selectedID == savedSelection
            && !independent.profiles.contains { $0.id == profile(1).id }
            && independent.statuses[profile(1).id] == nil && independent.logs[profile(1).id] == nil
        independent.controller?.onEvent?(.status(id: profile(1).id, status: .init(phase: .connected)))
        independent.controller?.onEvent?(.log(id: profile(1).id, message: "Late fixture event"))
        checks["deletedProfileIgnoresLateControllerEvents"] = independent.statuses[profile(1).id] == nil
            && independent.logs[profile(1).id] == nil
        try independent.remove(savedSelection)
        checks["deleteSelectedChoosesRemainingServer"] = independent.selectedID != savedSelection
            && independent.profiles.contains { $0.id == independent.selectedID }
        for id in independent.profiles.map(\.id) { try independent.remove(id) }
        let emptyReloaded = makeStore(independentDirectory)
        checks["deleteLastPersistsEmptyListAndSelection"] = independent.profiles.isEmpty && independent.selectedID.isEmpty
            && independent.selectedProfile == nil && independent.statuses.isEmpty && independent.logs.isEmpty
            && emptyReloaded.profiles.isEmpty && emptyReloaded.selectedID.isEmpty && emptyReloaded.configurationError == nil

        let fixtureDirectory = temporaryDirectory.appendingPathComponent("preferences")
        let fixtureProfiles = [profile(1), profile(2), profile(3)]
        let originalProfileData = try writeProfiles(fixtureProfiles, to: fixtureDirectory)
        let preferenceStore = makeStore(fixtureDirectory)
        preferenceStore.selectedID = profile(3).id
        preferenceStore.updatePanelAppearance(width: 360, fontScale: 1.15)
        let preferencesURL = fixtureDirectory.appendingPathComponent("ui-preferences.json")
        let preferencesBeforeLoad = try Data(contentsOf: preferencesURL)
        let restored = makeStore(fixtureDirectory)
        let preferencesAfterLoad = try Data(contentsOf: preferencesURL)
        let profilesAfterPreferences = try Data(contentsOf: fixtureDirectory.appendingPathComponent("profiles.json"))
        checks["selectionAndAppearanceRestoreWithoutInitializationWrites"] = restored.selectedID == profile(3).id
            && restored.panelAppearance.width == 360 && restored.panelAppearance.fontScale == 1.15
            && restored.profiles == fixtureProfiles && preferencesAfterLoad == preferencesBeforeLoad
            && profilesAfterPreferences == originalProfileData
        restored.selectedID = profile(2).id
        let afterSelection = makeStore(fixtureDirectory)
        checks["selectionPreservesAppearance"] = afterSelection.selectedID == profile(2).id
            && afterSelection.panelAppearance == restored.panelAppearance
        restored.resetPanelAppearance()
        let afterReset = makeStore(fixtureDirectory)
        checks["appearanceResetPersistsAndKeepsSelection"] = afterReset.panelAppearance == .default
            && afterReset.selectedID == profile(2).id
        try JSONSerialization.data(withJSONObject: ["selectedID": "deleted-server"]).write(to: preferencesURL)
        let stalePreferenceBytes = try Data(contentsOf: preferencesURL)
        let stalePreferences = makeStore(fixtureDirectory)
        let unchangedStalePreferenceBytes = try Data(contentsOf: preferencesURL)
        checks["staleSelectionFallsBackWithoutWritingOnLoad"] = stalePreferences.selectedID == profile(1).id
            && unchangedStalePreferenceBytes == stalePreferenceBytes
        try JSONSerialization.data(withJSONObject: ["selectedID": profile(2).id]).write(to: preferencesURL)
        let legacyPreferences = makeStore(fixtureDirectory)
        checks["legacyPreferencesKeepSelectionAndDefaultAppearance"] = legacyPreferences.selectedID == profile(2).id
            && legacyPreferences.panelAppearance == .default
        try JSONSerialization.data(withJSONObject: ["selectedID": profile(2).id,
            "panelAppearance": ["width": 900, "fontScale": 0.1]]).write(to: preferencesURL)
        let boundedPreferences = makeStore(fixtureDirectory)
        checks["persistedAppearanceClampsToSafeRange"] = boundedPreferences.panelAppearance.width == 440
            && boundedPreferences.panelAppearance.fontScale == 0.9 && boundedPreferences.selectedID == profile(2).id
        try JSONSerialization.data(withJSONObject: ["selectedID": profile(2).id,
            "panelAppearance": ["width": "invalid", "fontScale": 1.1]]).write(to: preferencesURL)
        let malformedPreferences = makeStore(fixtureDirectory)
        checks["malformedAppearanceFieldPreservesOtherPreferences"] = malformedPreferences.selectedID == profile(2).id
            && malformedPreferences.panelAppearance == PanelAppearance(width: 320, fontScale: 1.1)
        let nonPersistent = makeStore(fixtureDirectory, persist: false)
        try nonPersistent.add(profile(4))
        checks["nonpersistentStoreDoesNotReadOrWriteSavedProfiles"] = nonPersistent.profiles == [profile(4)]
            && makeStore(fixtureDirectory).profiles == fixtureProfiles

        let legacyDirectory = temporaryDirectory.appendingPathComponent("legacy-profiles")
        let legacyData = try writeProfiles(fixtureProfiles, to: legacyDirectory, legacy: true)
        let legacy = makeStore(legacyDirectory)
        let legacyURL = legacyDirectory.appendingPathComponent("profiles.json")
        let legacyBeforeSave = try Data(contentsOf: legacyURL)
        checks["legacyArrayLoadsWithoutAutomaticMigration"] = legacy.profiles == fixtureProfiles
            && legacyBeforeSave == legacyData && legacy.configurationError == nil
        var legacyEdited = fixtureProfiles[0]
        legacyEdited.name = "Explicitly edited"
        try legacy.save(legacyEdited)
        let migratedData = try Data(contentsOf: legacyURL)
        let migrated = try ServerConfiguration.decode(migratedData)
        let migratedObject = try JSONSerialization.jsonObject(with: migratedData) as? [String: Any]
        checks["legacyArrayUpgradesOnlyAfterExplicitSave"] = migrated.profiles.first == legacyEdited
            && migratedObject?["version"] as? Int == 1

        var repeatedID = fixtureProfiles[1]
        repeatedID.id = fixtureProfiles[0].id
        var caseHost = fixtureProfiles[0]
        caseHost.host = "fixture.example.com"
        var repeatedEndpoint = fixtureProfiles[1]
        repeatedEndpoint.host = "FIXTURE.EXAMPLE.COM"
        let invalidConfigurations: [(String, Data)] = [
            ("malformed", Data("{".utf8)),
            ("unknownVersion", Data("{\"version\":2,\"profiles\":[]}".utf8)),
            ("duplicateID", try JSONEncoder().encode([fixtureProfiles[0], repeatedID])),
            ("duplicateEndpointCase", try JSONEncoder().encode([caseHost, repeatedEndpoint]))
        ]
        for (label, data) in invalidConfigurations {
            let directory = temporaryDirectory.appendingPathComponent("invalid-\(label)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("profiles.json")
            try data.write(to: url)
            let invalid = makeStore(directory)
            let refused = rejects { try invalid.add(profile(10)) }
                && rejects { try invalid.save(profile(10)) }
                && rejects { try invalid.remove(profile(10).id) }
            let after = try Data(contentsOf: url)
            checks["preservesInvalidConfiguration-\(label)"] = invalid.configurationError != nil
                && invalid.profiles.isEmpty && invalid.selectedID.isEmpty && refused && after == data
                && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("ui-preferences.json").path)
        }

        let failingDirectory = temporaryDirectory.appendingPathComponent("write-failure")
        let beforeFailureData = try writeProfiles(fixtureProfiles, to: failingDirectory)
        let failing = makeStore(failingDirectory)
        failing.selectedID = profile(2).id
        let beforeFailureProfiles = failing.profiles
        let beforeFailureStatuses = failing.statuses
        let beforeFailureLogIDs = failing.logs.mapValues { $0.map(\.id) }
        let displacedDirectory = temporaryDirectory.appendingPathComponent("write-failure-original")
        try FileManager.default.moveItem(at: failingDirectory, to: displacedDirectory)
        let blocker = Data("fixture blocking a configuration directory".utf8)
        try blocker.write(to: failingDirectory)
        var failedEdit = fixtureProfiles[0]
        failedEdit.name = "This change cannot be persisted"
        let failures = failsWriting { try failing.add(profile(10)) }
            && failsWriting { try failing.save(failedEdit) }
            && failsWriting { try failing.remove(profile(2).id) }
        let blockerAfter = try Data(contentsOf: failingDirectory)
        let originalAfter = try Data(contentsOf: displacedDirectory.appendingPathComponent("profiles.json"))
        checks["failedWritesPreserveAllInMemoryState"] = failures && failing.profiles == beforeFailureProfiles
            && failing.statuses == beforeFailureStatuses && failing.logs.mapValues { $0.map(\.id) } == beforeFailureLogIDs
            && failing.selectedID == profile(2).id && blockerAfter == blocker && originalAfter == beforeFailureData

        let isolatedDirectory = temporaryDirectory.appendingPathComponent("demo-must-not-write")
        let demo = makeStore(isolatedDirectory, demo: true)
        let active = demo.profiles[0]
        let stopped = demo.profiles[1]
        let demoProfiles = demo.profiles
        checks["demoDefaultsSkipRiskAndRetainNetworkEvidence"] = demo.profiles.allSatisfy { !$0.assessIPRisk }
            && demo.status(for: active.id).proxyCheck == .passed
            && demo.status(for: active.id).ipRisk.state == .skipped
            && demo.status(for: active.id).ipRisk.assessment == nil
            && demo.status(for: active.id).ipRisk.ip == "198.51.100.10"
            && demo.lastCompletedCheckAt(for: active.id) != nil
        checks["connectedProfileCannotBeEditedOrDeleted"] = !demo.canModify(active.id)
            && rejects { try demo.save(active) } && rejects { try demo.remove(active.id) }
            && demo.profiles == demoProfiles && demo.status(for: active.id).phase == .connected
        demo.start(stopped.id)
        checks["connectingProfileCannotBeEditedOrDeleted"] = demo.status(for: stopped.id).phase == .connecting
            && !demo.canModify(stopped.id) && rejects { try demo.save(stopped) } && rejects { try demo.remove(stopped.id) }
        demo.stop(stopped.id)
        demo.stop(active.id)
        checks["skippedRiskCompletedCheckSurvivesDisconnectAsHistory"] = demo.isShowingHistoricalResults(for: active.id)
            && demo.presentationStatus(for: active.id).ipRisk.state == .skipped
            && demo.presentationStatus(for: active.id).proxyCheck == .passed
        var changedDemo = active
        changedDemo.name = "Edited demo"
        changedDemo.assessIPRisk = true
        try demo.save(changedDemo)
        checks["editingStoppedProfileClearsHistoricalResults"] = demo.canModify(active.id)
            && demo.lastCompletedCheckAt(for: active.id) == nil && !demo.isShowingHistoricalResults(for: active.id)
        demo.start(active.id)
        try? await Task.sleep(nanoseconds: 500_000_000)
        demo.testProxy(active.id)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        checks["demoExplicitConsentProducesOnlySimulatedRiskScore"] = demo.status(for: active.id).ipRisk.state == .available
            && demo.status(for: active.id).ipRisk.assessment?.trustScore == 89
            && demo.status(for: active.id).proxyCheck == .passed && demo.controller == nil
        demo.stop(active.id)
        changedDemo.assessIPRisk = false
        try demo.save(changedDemo)
        checks["disablingRiskClearsPreviousScoreAndHistory"] = demo.presentationStatus(for: active.id).ipRisk.assessment == nil
            && demo.lastCompletedCheckAt(for: active.id) == nil && !demo.isShowingHistoricalResults(for: active.id)
        demo.start(active.id)
        try? await Task.sleep(nanoseconds: 500_000_000)
        demo.testProxy(active.id)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        checks["demoOptOutPreservesNetworkChecksWithoutScore"] = demo.status(for: active.id).ipRisk.state == .skipped
            && demo.status(for: active.id).ipRisk.assessment == nil
            && demo.status(for: active.id).websiteResults.allSatisfy { $0.state == .passed }
            && demo.status(for: active.id).proxyCheck == .passed && demo.lastCompletedCheckAt(for: active.id) != nil
        demo.stop(active.id)
        try demo.remove(active.id)
        try demo.add(profile(10))
        demo.start(profile(10).id)
        demo.stop(profile(10).id)
        try demo.remove(profile(10).id)
        try? await Task.sleep(nanoseconds: 500_000_000)
        checks["deletedProfileCannotReappearFromCancelledDemoTask"] = !demo.profiles.contains { $0.id == profile(10).id }
            && demo.statuses[profile(10).id] == nil && demo.logs[profile(10).id] == nil
        demo.updatePanelAppearance(width: 300, fontScale: 1.2)
        checks["demoCRUDNeverWritesOrCreatesController"] = demo.controller == nil
            && !FileManager.default.fileExists(atPath: isolatedDirectory.path)

        for store in stores { await store.shutdown() }
        return checks
    }
}
