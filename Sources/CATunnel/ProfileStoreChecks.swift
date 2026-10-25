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
        let originalPythonPath = "/tmp/fixture tools/bin/python3 "
        checks["editorPreservesUneditedRemotePythonPathExactly"] = ProfileEditor.optionalPath(originalPythonPath,
            original: originalPythonPath) == originalPythonPath
            && ProfileEditor.optionalPath("", original: "") == ""
            && ProfileEditor.optionalPath("", original: nil) == nil
        checks["editorNormalizesOnlyEditedRemotePythonPath"] = ProfileEditor.optionalPath("  /tmp/new tools/bin/python3  ",
            original: originalPythonPath) == "/tmp/new tools/bin/python3"
            && ProfileEditor.optionalPath("  ", original: originalPythonPath) == nil
            && ProfileEditor.optionalPath("", original: originalPythonPath) == nil
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
            && rejects { try independent.save(profile(99), original: profile(99)) }
            && rejects { try independent.remove("missing-server") }
            && rejects { try independent.setAutoConnectOnLaunch(true, for: "missing-server") }
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
        let startupDirectory = temporaryDirectory.appendingPathComponent("startup-preferences")
        _ = try writeProfiles([profile(1), profile(2)], to: startupDirectory)
        let startup = makeStore(startupDirectory)
        let stoppedStates = startup.statuses
        try startup.setAutoConnectOnLaunch(true, for: profile(1).id)
        let startupReloaded = makeStore(startupDirectory)
        checks["startupChoicePersistsPerServerWithoutConnecting"] = startupReloaded.profiles[0].autoConnectOnLaunch
            && !startupReloaded.profiles[1].autoConnectOnLaunch
            && startup.statuses == stoppedStates && startupReloaded.statuses == stoppedStates
        let activeStatus = TunnelStatus(phase: .connected, message: "Fixture connection", connectedAt: Date())
        startup.controller?.onEvent?(.status(id: profile(1).id, status: activeStatus))
        let startupLogIDs = startup.logs.mapValues { $0.map(\.id) }
        try startup.setAutoConnectOnLaunch(false, for: profile(1).id)
        checks["startupChoiceCanChangeWhileConnectedWithoutStopping"] = !startup.profiles[0].autoConnectOnLaunch
            && startup.status(for: profile(1).id) == activeStatus
            && startup.logs.mapValues { $0.map(\.id) } == startupLogIDs
            && startup.profiles[0].autoReconnect

        let retryDirectory = temporaryDirectory.appendingPathComponent("forwarding-retry-preferences")
        _ = try writeProfiles([profile(1), profile(2)], to: retryDirectory)
        let retryStore = makeStore(retryDirectory)
        let retryStoppedStates = retryStore.statuses
        checks["continuousForwardingRetryDefaultsOff"] = !ServerProfile.draft().keepRetryingForwardingFailure
            && ServerProfile.examples.allSatisfy { !$0.keepRetryingForwardingFailure }
            && retryStore.profiles.allSatisfy { !$0.keepRetryingForwardingFailure }
        var retryProfile = retryStore.profiles[0]
        retryProfile.keepRetryingForwardingFailure = true
        try retryStore.save(retryProfile)
        let retryEnabledReloaded = makeStore(retryDirectory)
        checks["continuousForwardingRetryPersistsPerServerWithoutConnecting"] = retryEnabledReloaded.profiles[0] == retryProfile
            && !retryEnabledReloaded.profiles[1].keepRetryingForwardingFailure
            && retryStore.statuses == retryStoppedStates && retryEnabledReloaded.statuses == retryStoppedStates
        retryProfile.autoReconnect = false
        try retryStore.save(retryProfile)
        let retryDisabledReloaded = makeStore(retryDirectory)
        checks["disablingAutoReconnectPreservesInactiveContinuousRetryPreference"] = !retryDisabledReloaded.profiles[0].autoReconnect
            && retryDisabledReloaded.profiles[0].keepRetryingForwardingFailure
            && retryStore.statuses == retryStoppedStates
        let originalRetry = retryProfile
        retryProfile.name = "Renamed with recovery preference"
        try retryStore.save(retryProfile, original: originalRetry)
        let retryRenamedReloaded = makeStore(retryDirectory)
        checks["ordinaryEditorSavePreservesContinuousRetryPreference"] = retryRenamedReloaded.profiles[0] == retryProfile
        retryProfile.keepRetryingForwardingFailure = false
        try retryStore.save(retryProfile)
        let retryOptOutReloaded = makeStore(retryDirectory)
        checks["continuousForwardingRetryOptOutPersists"] = retryOptOutReloaded.profiles[0] == retryProfile
            && !retryOptOutReloaded.profiles[0].keepRetryingForwardingFailure

        let oldRetryDirectory = temporaryDirectory.appendingPathComponent("old-forwarding-retry-profile")
        try FileManager.default.createDirectory(at: oldRetryDirectory, withIntermediateDirectories: true)
        let oldRetryObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile(1)))
        guard var oldRetryProfile = oldRetryObject as? [String: Any] else {
            throw NSError(domain: "CATunnelOfflineCheck", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Profile fixture did not encode as an object"])
        }
        oldRetryProfile.removeValue(forKey: "keepRetryingForwardingFailure")
        let oldRetryData = try JSONSerialization.data(withJSONObject: ["version": 1, "profiles": [oldRetryProfile]])
        let oldRetryURL = oldRetryDirectory.appendingPathComponent("profiles.json")
        try oldRetryData.write(to: oldRetryURL)
        let oldRetryStore = makeStore(oldRetryDirectory)
        let oldRetryReadBack = try Data(contentsOf: oldRetryURL)
        checks["olderConfigurationDefaultsContinuousRetryOffWithoutRewriting"] = oldRetryStore.configurationError == nil
            && oldRetryStore.profiles.count == 1 && !oldRetryStore.profiles[0].keepRetryingForwardingFailure
            && oldRetryReadBack == oldRetryData

        let fixedDirectory = temporaryDirectory.appendingPathComponent("fixed-entry-preferences")
        _ = try writeProfiles([profile(1), profile(2)], to: fixedDirectory)
        let fixedStore = makeStore(fixedDirectory)
        fixedStore.controller?.onEvent?(.status(id: profile(2).id, status: activeStatus))
        let fixedStates = fixedStore.statuses
        var fixedProfile = fixedStore.profiles[0]
        fixedProfile.useFixedEntry = true
        fixedProfile.fixedEntryHelperPath = "/opt/fixture relay/relay.py"
        fixedProfile.fixedEntryRuntimePath = "/run/user/1000/fixture-entry"
        fixedProfile.fixedEntryPythonPath = "/tmp/fixture tools/bin/python3"
        try fixedStore.save(fixedProfile, original: profile(1))
        let fixedReloaded = makeStore(fixedDirectory)
        checks["fixedEntrySavePersistsWithoutConnectingOrChangingAnotherSession"] = fixedReloaded.profiles == fixedStore.profiles
            && fixedStore.profiles[0] == fixedProfile && fixedStore.profiles[1] == profile(2)
            && fixedStore.statuses == fixedStates && fixedReloaded.statuses.values.allSatisfy { $0.phase == .stopped }
        checks["fixedEntryPythonSelectionPersistsOnExplicitSave"] = fixedReloaded.profiles[0].fixedEntryPythonPath
            == "/tmp/fixture tools/bin/python3" && fixedStore.statuses == fixedStates
        fixedProfile.useFixedEntry = false
        try fixedStore.save(fixedProfile)
        let fixedDisabled = makeStore(fixedDirectory)
        checks["disablingFixedEntryKeepsPathsAndUnrelatedOptions"] = fixedDisabled.profiles[0] == fixedProfile
            && !fixedDisabled.profiles[0].useFixedEntry && fixedDisabled.profiles[0].fixedEntryHelperPath != nil
            && fixedDisabled.profiles[0].fixedEntryPythonPath == "/tmp/fixture tools/bin/python3"
            && fixedStore.statuses == fixedStates && fixedDisabled.profiles[1] == profile(2)
        let beforeInvalidFixed = try Data(contentsOf: fixedDirectory.appendingPathComponent("profiles.json"))
        var invalidFixed = fixedProfile
        invalidFixed.useFixedEntry = true
        invalidFixed.fixedEntryRuntimePath = nil
        let refusedInvalidFixed = rejects { try fixedStore.save(invalidFixed) }
        let afterInvalidFixed = try Data(contentsOf: fixedDirectory.appendingPathComponent("profiles.json"))
        checks["invalidFixedEntrySaveIsAtomic"] = refusedInvalidFixed && fixedStore.profiles[0] == fixedProfile
            && fixedStore.statuses == fixedStates && beforeInvalidFixed == afterInvalidFixed

        let oldFixedDirectory = temporaryDirectory.appendingPathComponent("old-fixed-entry-profile")
        try FileManager.default.createDirectory(at: oldFixedDirectory, withIntermediateDirectories: true)
        var oldFixedProfile = oldRetryProfile
        for key in ["useFixedEntry", "fixedEntryHelperPath", "fixedEntryRuntimePath", "fixedEntryPythonPath"] {
            oldFixedProfile.removeValue(forKey: key)
        }
        let oldFixedData = try JSONSerialization.data(withJSONObject: ["version": 1, "profiles": [oldFixedProfile]])
        let oldFixedURL = oldFixedDirectory.appendingPathComponent("profiles.json")
        try oldFixedData.write(to: oldFixedURL)
        let oldFixedStore = makeStore(oldFixedDirectory)
        let oldFixedReadBack = try Data(contentsOf: oldFixedURL)
        checks["olderConfigurationDefaultsFixedEntryOffWithoutRewriting"] = oldFixedStore.configurationError == nil
            && oldFixedStore.profiles == [profile(1)] && oldFixedReadBack == oldFixedData

        let oldPythonDirectory = temporaryDirectory.appendingPathComponent("old-fixed-entry-python-profile")
        try FileManager.default.createDirectory(at: oldPythonDirectory, withIntermediateDirectories: true)
        let oldPythonObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixedProfile))
        guard var oldPythonProfile = oldPythonObject as? [String: Any] else {
            throw NSError(domain: "CATunnelOfflineCheck", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Profile fixture did not encode as an object"])
        }
        oldPythonProfile["useFixedEntry"] = true
        oldPythonProfile.removeValue(forKey: "fixedEntryPythonPath")
        let oldPythonData = try JSONSerialization.data(withJSONObject: ["version": 1, "profiles": [oldPythonProfile]])
        let oldPythonURL = oldPythonDirectory.appendingPathComponent("profiles.json")
        try oldPythonData.write(to: oldPythonURL)
        let oldPythonStore = makeStore(oldPythonDirectory)
        var expectedOldPython = fixedProfile
        expectedOldPython.useFixedEntry = true
        expectedOldPython.fixedEntryPythonPath = nil
        checks["existingFixedEntryWithoutPythonSelectionLoadsWithoutRewriting"] = oldPythonStore.configurationError == nil
            && oldPythonStore.profiles == [expectedOldPython] && (try? Data(contentsOf: oldPythonURL)) == oldPythonData

        let editorDirectory = temporaryDirectory.appendingPathComponent("editor-startup-preferences")
        _ = try writeProfiles([profile(1), profile(2)], to: editorDirectory)
        let editorStore = makeStore(editorDirectory)
        let editorStoppedStates = editorStore.statuses
        for enabled in [true, false] {
            let original = editorStore.profiles[0]
            var renamed = original
            renamed.name = "Renamed while startup is \(enabled)"
            try editorStore.setAutoConnectOnLaunch(enabled, for: original.id)
            try editorStore.save(renamed, original: original)
            let loaded = makeStore(editorDirectory)
            checks["editorPreservesExternalStartupChange-\(enabled)"] = editorStore.profiles[0].autoConnectOnLaunch == enabled
                && editorStore.profiles[0].name == renamed.name && loaded.profiles == editorStore.profiles
                && editorStore.profiles[1] == profile(2) && editorStore.statuses == editorStoppedStates
        }
        for enabled in [true, false] {
            let original = editorStore.profiles[0]
            var changed = original
            changed.autoConnectOnLaunch = enabled
            try editorStore.save(changed, original: original)
            let loaded = makeStore(editorDirectory)
            checks["editorExplicitStartupChangePersists-\(enabled)"] = editorStore.profiles[0] == changed
                && loaded.profiles == editorStore.profiles && editorStore.statuses == editorStoppedStates
        }
        for originalValue in [false, true] {
            try editorStore.setAutoConnectOnLaunch(originalValue, for: profile(1).id)
            let original = editorStore.profiles[0]
            try editorStore.setAutoConnectOnLaunch(!originalValue, for: original.id)
            var roundTrip = original
            roundTrip.autoConnectOnLaunch.toggle()
            roundTrip.autoConnectOnLaunch.toggle()
            try editorStore.save(roundTrip, original: original, autoConnectOnLaunchEdited: true)
            let loaded = makeStore(editorDirectory)
            checks["editorExplicitRoundTripStartupChangePersists-\(originalValue)"] = editorStore.profiles[0] == roundTrip
                && loaded.profiles == editorStore.profiles && editorStore.statuses == editorStoppedStates
        }
        let originalEditorProfile = editorStore.profiles[0]
        var ordinaryEdit = originalEditorProfile
        ordinaryEdit.name = "Ordinary editor save"
        ordinaryEdit.localPort = 8899
        try editorStore.save(ordinaryEdit, original: originalEditorProfile)
        let ordinaryReloaded = makeStore(editorDirectory)
        checks["editorWithoutConcurrentChangesPersistsNormally"] = editorStore.profiles[0] == ordinaryEdit
            && ordinaryReloaded.profiles == editorStore.profiles
        let beforeMismatch = editorStore.profiles
        let beforeMismatchData = try Data(contentsOf: editorDirectory.appendingPathComponent("profiles.json"))
        var rejectedMismatch = false
        do { try editorStore.save(editorStore.profiles[0], original: editorStore.profiles[1]) }
        catch StoreError.mismatchedOriginalProfile { rejectedMismatch = true }
        let afterMismatchData = try Data(contentsOf: editorDirectory.appendingPathComponent("profiles.json"))
        checks["editorRejectsMismatchedOriginalWithoutWriting"] = rejectedMismatch
            && editorStore.profiles == beforeMismatch && beforeMismatchData == afterMismatchData
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
        failedEdit.keepRetryingForwardingFailure = true
        failedEdit.useFixedEntry = true
        failedEdit.fixedEntryHelperPath = "/opt/catunnel/relay.py"
        failedEdit.fixedEntryRuntimePath = "/run/user/1000/catunnel"
        var failedStartupEdit = failedEdit
        failedStartupEdit.autoConnectOnLaunch.toggle()
        let failures = failsWriting { try failing.add(profile(10)) }
            && failsWriting { try failing.save(failedEdit) }
            && failsWriting { try failing.save(failedEdit, original: fixtureProfiles[0]) }
            && failsWriting {
                try failing.save(failedStartupEdit, original: fixtureProfiles[0], autoConnectOnLaunchEdited: true)
            }
            && failsWriting { try failing.remove(profile(2).id) }
            && failsWriting { try failing.setAutoConnectOnLaunch(true, for: profile(1).id) }
        let blockerAfter = try Data(contentsOf: failingDirectory)
        let originalAfter = try Data(contentsOf: displacedDirectory.appendingPathComponent("profiles.json"))
        checks["failedWritesPreserveAllInMemoryState"] = failures && failing.profiles == beforeFailureProfiles
            && failing.statuses == beforeFailureStatuses && failing.logs.mapValues { $0.map(\.id) } == beforeFailureLogIDs
            && failing.selectedID == profile(2).id && blockerAfter == blocker && originalAfter == beforeFailureData

        let providerDirectory = temporaryDirectory.appendingPathComponent("legacy-ping0-preference")
        let providers = makeStore(providerDirectory)
        var providerProfile = profile(30)
        providerProfile.assessPing0 = true
        try providers.add(providerProfile)
        let savedLegacyData = try Data(contentsOf: providerDirectory.appendingPathComponent("profiles.json"))
        let legacyReloaded = makeStore(providerDirectory)
        let reloadedLegacyData = try Data(contentsOf: providerDirectory.appendingPathComponent("profiles.json"))
        checks["legacyPing0PreferenceLoadsWithoutRewritingConfiguration"] = legacyReloaded.profiles == [providerProfile]
            && reloadedLegacyData == savedLegacyData
        providerProfile.assessIPRisk = true
        try providers.save(providerProfile)
        checks["unrelatedSavePreservesLegacyPing0Preference"] = makeStore(providerDirectory).profiles == [providerProfile]

        let websiteDate = Date(timeIntervalSince1970: 1_800_000_000)
        let scoreDate = websiteDate.addingTimeInterval(4)
        var providerStatus = TunnelStatus(phase: .connected, proxyCheck: .passed,
            websiteResults: WebsiteTarget.allCases.map {
                .init(target: $0, state: .passed, message: "Offline fixture", checkedAt: websiteDate,
                      exitIP: $0 == .claudeNetwork ? "8.8.8.8" : nil)
            }, ipRisk: .init(state: .checking, message: "Offline score pending"))
        providers.controller?.onEvent?(.status(id: providerProfile.id, status: providerStatus))
        checks["completedHistoryStillWaitsForEnabledNetCoffee"] = providers.lastCompletedCheckAt(for: providerProfile.id) == nil
        providerStatus.ipRisk = .init(state: .failed, message: "Offline score failure", checkedAt: scoreDate)
        providers.controller?.onEvent?(.status(id: providerProfile.id, status: providerStatus))
        checks["legacyPing0PreferenceDoesNotBlockCompletedHistory"] = providers.lastCompletedCheckAt(for: providerProfile.id) == scoreDate
        providers.controller?.onEvent?(.status(id: providerProfile.id, status: .stopped))
        checks["browserLinkCanUsePreservedHistoricalExitIP"] = providers.isShowingHistoricalResults(for: providerProfile.id)
            && Ping0BrowserAction.exitIP(in: providers.presentationStatus(for: providerProfile.id)) == "8.8.8.8"
        var pendingStatus = providerStatus
        pendingStatus.proxyCheck = .checking
        pendingStatus.ipRisk = .init(state: .checking, message: "Offline new request")
        providers.controller?.onEvent?(.status(id: providerProfile.id, status: pendingStatus))
        providers.controller?.onEvent?(.status(id: providerProfile.id, status: .stopped))
        checks["interruptedCheckKeepsPreviousCompletedHistory"] = providers.lastCompletedCheckAt(for: providerProfile.id) == scoreDate
            && providers.presentationStatus(for: providerProfile.id).websiteResults == providerStatus.websiteResults

        let isolatedDirectory = temporaryDirectory.appendingPathComponent("demo-must-not-write")
        let demo = makeStore(isolatedDirectory, demo: true)
        let active = demo.profiles[0]
        let stopped = demo.profiles[1]
        let demoProfiles = demo.profiles
        checks["demoDefaultsSkipRiskAndRetainNetworkEvidence"] = demo.profiles.allSatisfy { !$0.assessIPRisk && !$0.assessPing0 }
            && demo.status(for: active.id).proxyCheck == .passed
            && demo.status(for: active.id).ipRisk.state == .skipped
            && demo.status(for: active.id).ipRisk.assessment == nil
            && demo.status(for: active.id).ipRisk.ip == "198.51.100.10"
            && demo.lastCompletedCheckAt(for: active.id) != nil
        checks["connectedProfileCannotBeEditedOrDeleted"] = !demo.canModify(active.id)
            && rejects { try demo.save(active) } && rejects { try demo.remove(active.id) }
            && rejects { try demo.save(active, original: active) }
            && demo.profiles == demoProfiles && demo.status(for: active.id).phase == .connected
        var activeFixedEdit = active
        activeFixedEdit.useFixedEntry = true
        activeFixedEdit.fixedEntryHelperPath = "/opt/catunnel/relay.py"
        activeFixedEdit.fixedEntryRuntimePath = "/run/user/1000/catunnel"
        checks["connectedProfileCannotChangeFixedEntryMode"] = rejects { try demo.save(activeFixedEdit, original: active) }
            && demo.profiles == demoProfiles && demo.status(for: active.id).phase == .connected
        var activePythonEdit = active
        activePythonEdit.fixedEntryPythonPath = "/tmp/fixture tools/bin/python3"
        checks["connectedProfileCannotChangeRemotePython"] = rejects { try demo.save(activePythonEdit, original: active) }
            && demo.profiles == demoProfiles && demo.status(for: active.id).phase == .connected
        let activeBeforeStartupChange = demo.status(for: active.id)
        let historyBeforeStartupChange = demo.lastCompletedCheckAt(for: active.id)
        try demo.setAutoConnectOnLaunch(true, for: active.id)
        checks["demoStartupChoicePreservesConnectionAndHistoryWithoutWriting"] = demo.profiles[0].autoConnectOnLaunch
            && demo.status(for: active.id) == activeBeforeStartupChange
            && demo.lastCompletedCheckAt(for: active.id) == historyBeforeStartupChange
            && demo.controller == nil && !FileManager.default.fileExists(atPath: isolatedDirectory.path)
        demo.start(stopped.id)
        checks["connectingProfileCannotBeEditedOrDeleted"] = demo.status(for: stopped.id).phase == .connecting
            && !demo.canModify(stopped.id) && rejects { try demo.save(stopped) } && rejects { try demo.remove(stopped.id) }
            && rejects { try demo.save(stopped, original: stopped) }
        demo.stop(stopped.id)
        demo.stop(active.id)
        checks["skippedRiskCompletedCheckSurvivesDisconnectAsHistory"] = demo.isShowingHistoricalResults(for: active.id)
            && demo.presentationStatus(for: active.id).ipRisk.state == .skipped
            && demo.presentationStatus(for: active.id).proxyCheck == .passed
        var changedDemo = active
        changedDemo.name = "Edited demo"
        changedDemo.assessIPRisk = true
        changedDemo.assessPing0 = true
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
        checks["legacyPing0PreferenceDoesNotChangeDemoNetworkChecks"] = demo.status(for: active.id).websiteResults.count == 4
            && demo.status(for: active.id).ipRisk.assessment?.trustScore == 89
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
        checks["legacyPing0OnlyPreferenceDoesNotEnableNetCoffee"] = demo.status(for: active.id).ipRisk.state == .skipped
            && demo.status(for: active.id).proxyCheck == .passed && demo.controller == nil
        let completedWebsites = demo.status(for: active.id).websiteResults
        let completedDate = demo.lastCompletedCheckAt(for: active.id)
        demo.testProxy(active.id)
        let wasChecking = demo.status(for: active.id).proxyCheck == .checking
        demo.stop(active.id)
        try? await Task.sleep(nanoseconds: 1_300_000_000)
        checks["cancelledDemoCannotReplaceCompletedNetworkHistory"] = wasChecking
            && demo.status(for: active.id).phase == .stopped
            && demo.lastCompletedCheckAt(for: active.id) == completedDate
            && demo.presentationStatus(for: active.id).websiteResults == completedWebsites
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

        checks.merge(try await installationChecks(in: temporaryDirectory.appendingPathComponent("installation"))) { _, value in value }
        for store in stores { await store.shutdown() }
        return checks
    }

    private static func installationChecks(in directory: URL) async throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        let store = TunnelStore(persistSettings: true, settingsDirectory: directory)
        var original = profile(61)
        original.fixedEntryHelperPath = "/previous/manual/relay.py"
        original.fixedEntryRuntimePath = "/previous/manual/runtime"
        original.fixedEntryPythonPath = "/tmp/fixture tools/bin/python3"
        original.keepRetryingForwardingFailure = true
        original.assessPing0 = true
        try store.add(original)
        try store.add(profile(62))
        store.controller?.onEvent?(.status(id: profile(62).id,
            status: TunnelStatus(phase: .connected, message: "Unrelated fixture connection", connectedAt: Date())))
        let beforeProfiles = store.profiles
        let beforeStatuses = store.statuses
        let configURL = directory.appendingPathComponent("profiles.json")
        let beforeBytes = try Data(contentsOf: configURL)
        var draft = original
        let result = FixedEntryInstallation(helperPath: "/tmp/catunnel-fixture-home/.catunnel/fixed-entry/17892/relay.py",
            runtimePath: "/tmp/catunnel-fixture-home/.catunnel/fixed-entry/17892/r", port: original.remotePort, reused: false)
        let executor = InstallFixtureExecutor()
        let model = FixedEntryInstallModel(makeExecutor: { executor })
        model.start(profile: draft, demoMode: false) { installed in
            draft.useFixedEntry = true
            draft.fixedEntryHelperPath = installed.helperPath
            draft.fixedEntryRuntimePath = installed.runtimePath
        }
        await executor.waitForRequest()
        checks["installationStartsWithoutChangingDraftOrPersistedProfiles"] = model.isInstalling
            && executor.profiles == [original] && draft == original && store.profiles == beforeProfiles
            && store.statuses == beforeStatuses && (try? Data(contentsOf: configURL)) == beforeBytes
        checks["installationUsesSelectedPythonWithFixedEntryStillOff"] = !original.useFixedEntry
            && executor.profiles.first?.fixedEntryPythonPath == original.fixedEntryPythonPath
        var repeatedCallbacks = 0
        model.start(profile: draft, demoMode: false) { _ in repeatedCallbacks += 1 }
        checks["installationRejectsDuplicateClicksWhileBusy"] = executor.profiles.count == 1 && repeatedCallbacks == 0
        executor.finish(.success(result))
        await settle { !model.isInstalling }
        checks["installationSuccessOnlyFillsDraftUntilExplicitSave"] = model.state == .succeeded(result, demo: false)
            && draft.useFixedEntry && draft.fixedEntryHelperPath == result.helperPath
            && draft.fixedEntryRuntimePath == result.runtimePath && draft.keepRetryingForwardingFailure
            && draft.fixedEntryPythonPath == original.fixedEntryPythonPath
            && draft.assessPing0 && store.profiles == beforeProfiles && store.statuses == beforeStatuses
            && (try? Data(contentsOf: configURL)) == beforeBytes
        try store.save(draft, original: original)
        let saved = try ServerConfiguration.decode(Data(contentsOf: configURL))
        checks["installationExplicitSaveKeepsOtherConnectionsAndChoices"] = saved.profiles == [draft, profile(62)]
            && store.statuses == beforeStatuses && draft.autoReconnect == original.autoReconnect
            && draft.autoConnectOnLaunch == original.autoConnectOnLaunch && draft.localPort == original.localPort
            && saved.profiles[0].fixedEntryPythonPath == original.fixedEntryPythonPath
        let afterSave = draft
        let savedBytes = try Data(contentsOf: configURL)
        let failed = InstallFixtureExecutor()
        let failedModel = FixedEntryInstallModel(makeExecutor: { failed })
        failedModel.start(profile: draft, demoMode: false) { _ in draft.name = "Unexpected callback" }
        await failed.waitForRequest()
        failed.finish(.failure(InstallFixtureError()))
        await settle { !failedModel.isInstalling }
        checks["installationFailurePreservesManualSettingsAndConfiguration"] = failedModel.state == .failed(InstallFixtureError().localizedDescription)
            && draft == afterSave && store.profiles == saved.profiles && store.statuses == beforeStatuses
            && (try? Data(contentsOf: configURL)) == savedBytes
        checks["installationFailurePreservesSelectedPython"] = failed.profiles.first?.fixedEntryPythonPath
            == original.fixedEntryPythonPath && draft.fixedEntryPythonPath == original.fixedEntryPythonPath

        let cancelled = InstallFixtureExecutor()
        let cancelModel = FixedEntryInstallModel(makeExecutor: { cancelled })
        var cancelCallbacks = 0
        cancelModel.start(profile: original, demoMode: false) { _ in cancelCallbacks += 1 }
        await cancelled.waitForRequest()
        cancelModel.cancel()
        cancelled.finish(.success(result))
        await settle { cancelled.finished }
        checks["cancelledInstallationIgnoresLateSuccess"] = cancelled.cancellations == 1
            && cancelModel.state == .cancelled && cancelCallbacks == 0 && draft == afterSave
        checks["cancelledInstallationPreservesSelectedPython"] = cancelled.profiles.first?.fixedEntryPythonPath
            == original.fixedEntryPythonPath && draft.fixedEntryPythonPath == original.fixedEntryPythonPath

        let oldExecutor = InstallFixtureExecutor(), newExecutor = InstallFixtureExecutor()
        var executorIndex = 0
        let generationModel = FixedEntryInstallModel(makeExecutor: {
            executorIndex += 1
            return executorIndex == 1 ? oldExecutor : newExecutor
        })
        var completions: [FixedEntryInstallation] = []
        generationModel.start(profile: original, demoMode: false) { completions.append($0) }
        await oldExecutor.waitForRequest()
        generationModel.cancel(clearState: true)
        var changed = original
        changed.remotePort += 1
        changed.fixedEntryPythonPath = "/tmp/other fixture/bin/python3"
        let newer = FixedEntryInstallation(helperPath: result.helperPath,
            runtimePath: result.runtimePath + "-new", port: changed.remotePort, reused: true)
        generationModel.start(profile: changed, demoMode: false) { completions.append($0) }
        await newExecutor.waitForRequest()
        oldExecutor.finish(.failure(InstallFixtureError()))
        await settle { oldExecutor.finished }
        let oldIgnored = generationModel.isInstalling && completions.isEmpty
        newExecutor.finish(.success(newer))
        await settle { !generationModel.isInstalling }
        checks["changedInputsPreventOldInstallationFromOverwritingNewAttempt"] = oldIgnored
            && generationModel.state == .succeeded(newer, demo: false) && completions == [newer]
        checks["changingPythonUsesNewSelectionWithoutOldAttemptOverwrite"] = oldIgnored
            && newExecutor.profiles.first?.fixedEntryPythonPath == changed.fixedEntryPythonPath
            && oldExecutor.profiles.first?.fixedEntryPythonPath == original.fixedEntryPythonPath
            && completions == [newer] && store.profiles == saved.profiles

        var creationCount = 0
        let invalidModel = FixedEntryInstallModel(makeExecutor: {
            creationCount += 1
            throw InstallFixtureError()
        })
        var invalid = original
        invalid.remotePort = 0
        invalidModel.start(profile: invalid, demoMode: false) { _ in creationCount += 100 }
        checks["invalidInstallationInputNeverCreatesExecutor"] = creationCount == 0 && !invalidModel.isInstalling
            && invalidModel.state == .failed(ProfileValidationError.invalidPort.localizedDescription)
        invalidModel.start(profile: original, demoMode: false) { _ in creationCount += 100 }
        checks["missingInstallationResourcesLeaveDraftUntouched"] = creationCount == 1
            && invalidModel.state == .failed(InstallFixtureError().localizedDescription) && draft == afterSave

        let noPaths = InstallFixtureExecutor()
        let pathsModel = FixedEntryInstallModel(makeExecutor: { noPaths })
        var manual = original
        manual.useFixedEntry = true
        manual.fixedEntryHelperPath = nil
        manual.fixedEntryRuntimePath = nil
        pathsModel.start(profile: manual, demoMode: false) { _ in }
        await noPaths.waitForRequest()
        checks["installationDoesNotRequirePreviouslyInstalledManualPaths"] = noPaths.profiles.count == 1
            && noPaths.profiles.first?.useFixedEntry == false && pathsModel.isInstalling
        pathsModel.cancel()
        noPaths.finish(.failure(InstallFixtureError()))
        await settle { noPaths.finished }

        var offlineCreations = 0
        let offline = FixedEntryInstallModel(makeExecutor: {
            offlineCreations += 1
            throw InstallFixtureError()
        })
        var offlineResult: FixedEntryInstallation?
        offline.start(profile: original, demoMode: true) { offlineResult = $0 }
        await settle { !offline.isInstalling }
        checks["offlineInstallationNeverConstructsRealExecutorOrWritesSettings"] = offlineCreations == 0
            && offlineResult?.port == original.remotePort && store.profiles == saved.profiles
            && store.statuses == beforeStatuses && (try? Data(contentsOf: configURL)) == savedBytes
        var offlineCallbacks = 0
        offline.start(profile: original, demoMode: true) { _ in offlineCallbacks += 1 }
        offline.cancel()
        try? await Task.sleep(nanoseconds: 300_000_000)
        checks["closingEditorCancelsOfflineInstallationWithoutLateAutofill"] = offline.state == .cancelled
            && offlineCallbacks == 0 && offlineCreations == 0
        let unavailablePhases: [TunnelPhase] = [.connected, .connecting, .checking, .reconnecting, .failed]
        checks["installationRequiresStoppedProfileAndNoDiagnostics"] = unavailablePhases
            .allSatisfy { FixedEntryInstallModel.blockedReason(editorReason: nil, phase: $0, checking: false) != nil }
            && FixedEntryInstallModel.blockedReason(editorReason: nil, phase: .stopped, checking: false) == nil
            && FixedEntryInstallModel.blockedReason(editorReason: nil, phase: nil, checking: false) == nil
            && FixedEntryInstallModel.blockedReason(editorReason: nil, phase: .stopped, checking: true) != nil
            && FixedEntryInstallModel.blockedReason(editorReason: "Protected configuration", phase: .stopped, checking: false) == "Protected configuration"

        var guardedCreations = 0
        let guardedModel = FixedEntryInstallModel(makeExecutor: {
            guardedCreations += 1
            throw InstallFixtureError()
        })
        func guardedStart(_ candidate: ServerProfile, isNew: Bool,
                          existing: [ServerProfile]) -> Bool {
            do {
                let validated = try FixedEntryInstallModel.validateCandidate(candidate,
                    isNew: isNew, existingProfiles: existing)
                guardedModel.start(profile: validated, demoMode: false) { _ in guardedCreations += 100 }
                return true
            } catch { return false }
        }
        var duplicateNew = profile(63)
        duplicateNew.host = original.host
        duplicateNew.user = "anotheruser"
        checks["installationRejectsNewDraftUsingExistingServerPort"] = !guardedStart(duplicateNew,
            isNew: true, existing: store.profiles) && guardedCreations == 0 && guardedModel.state == .idle
        var duplicateEdit = original
        duplicateEdit.host = profile(62).host
        checks["installationRejectsEditedDraftUsingAnotherServerPort"] = !guardedStart(duplicateEdit,
            isNew: false, existing: store.profiles) && guardedCreations == 0 && guardedModel.state == .idle
        var validEdit = original
        validEdit.name = "Valid installation draft"
        validEdit.remotePort += 2
        let validatedEdit = try FixedEntryInstallModel.validateCandidate(validEdit,
            isNew: false, existingProfiles: store.profiles)
        checks["installationAllowsValidReplacementOfSameProfileID"] = validatedEdit == validEdit
            && store.profiles == saved.profiles && store.statuses == beforeStatuses
        let unknown = profile(64)
        checks["installationRejectsDeletedProfileBeforeCreatingExecutor"] = !guardedStart(unknown,
            isNew: false, existing: store.profiles) && guardedCreations == 0
        checks["installationValidatesEntireCandidateConfiguration"] = !guardedStart(unknown,
            isNew: true, existing: store.profiles + [original]) && guardedCreations == 0
        checks["installationPreflightFailuresPreserveConfigurationAndSessions"] = guardedModel.state == .idle
            && store.profiles == saved.profiles && store.statuses == beforeStatuses
            && (try? Data(contentsOf: configURL)) == savedBytes
        await store.shutdown()
        return checks
    }

    private static func settle(until condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        await Task.yield()
    }
}

@MainActor
private final class InstallFixtureExecutor: FixedEntryInstallExecuting {
    private(set) var profiles: [ServerProfile] = []
    private(set) var cancellations = 0
    private(set) var finished = false
    private var continuation: CheckedContinuation<FixedEntryInstallation, Error>?

    func install(_ profile: ServerProfile) async throws -> FixedEntryInstallation {
        profiles.append(profile)
        defer { finished = true }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func cancel() { cancellations += 1 }

    func finish(_ result: Result<FixedEntryInstallation, Error>) {
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }

    func waitForRequest() async {
        for _ in 0..<100 {
            if continuation != nil { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private struct InstallFixtureError: LocalizedError {
    var errorDescription: String? { "离线安装失败示例：入口端口被其他程序占用。" }
}
