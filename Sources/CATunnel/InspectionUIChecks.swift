import Foundation
import TunnelCore

@MainActor
enum InspectionUIChecks {
    static func run() async throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        var profile = ServerProfile(id: "inspection-fixture", name: "Fixture", host: "192.0.2.17", user: "user",
                                    sshPort: 22, remotePort: 17892, localPort: 7890, autoReconnect: true)
        profile.fixedEntryPythonPath = "/tmp/existing python/bin/python3"
        let original = try JSONEncoder().encode(profile)
        let inspected = [SetupCheckItem(id: "helper", title: "远端转接程序", state: .passed, message: "Fixture ready")]
        let partial = [SetupCheckItem(id: "backend", title: "当前转发通道", state: .warning, message: "Fixture idle")]
        var diagnosticCreations = 0
        let diagnosticExecutor = DiagnosticsFixtureExecutor()
        let diagnostics = FixedEntryDiagnosticsModel {
            diagnosticCreations += 1
            return diagnosticExecutor
        }
        checks["fixedEntryInspectionIsIdleUntilExplicitStart"] = diagnosticCreations == 0
            && !diagnostics.isChecking && diagnostics.items.isEmpty && diagnostics.checkedAt == nil
        diagnostics.start(profile: profile, demoMode: false)
        diagnostics.start(profile: profile, demoMode: false)
        await settle { diagnosticExecutor.hasRequest }
        checks["fixedEntryInspectionDoesNotStartDuplicateChecks"] = diagnosticCreations == 1
            && diagnosticExecutor.profiles == [profile] && diagnostics.isChecking
        diagnosticExecutor.finish(inspected)
        await settle { !diagnostics.isChecking }
        checks["fixedEntryInspectionPublishesTimestampAndResultsWithoutChangingProfile"] = diagnostics.items == inspected
            && diagnostics.checkedAt != nil && (try? JSONEncoder().encode(profile)) == original
        diagnostics.cancel(clearResults: true)
        checks["fixedEntryInspectionProfileChangeClearsHistoricalResult"] = diagnostics.items.isEmpty
            && diagnostics.checkedAt == nil && diagnostics.notice == nil

        let lateDiagnostics = DiagnosticsFixtureExecutor()
        let cancelledDiagnostics = FixedEntryDiagnosticsModel { lateDiagnostics }
        cancelledDiagnostics.start(profile: profile, demoMode: false)
        await settle { lateDiagnostics.hasRequest }
        cancelledDiagnostics.cancel()
        lateDiagnostics.finish(inspected)
        await settle { lateDiagnostics.finished }
        checks["fixedEntryInspectionCancellationRejectsLateResults"] = !cancelledDiagnostics.isChecking
            && cancelledDiagnostics.items.isEmpty && cancelledDiagnostics.checkedAt == nil
            && cancelledDiagnostics.notice != nil && lateDiagnostics.cancellations == 1

        let oldDiagnostics = DiagnosticsFixtureExecutor(), newDiagnostics = DiagnosticsFixtureExecutor()
        var diagnosticsQueue = [oldDiagnostics, newDiagnostics]
        let restartedDiagnostics = FixedEntryDiagnosticsModel { diagnosticsQueue.removeFirst() }
        restartedDiagnostics.start(profile: profile, demoMode: false)
        await settle { oldDiagnostics.hasRequest }
        restartedDiagnostics.cancel(clearResults: true)
        restartedDiagnostics.start(profile: profile, demoMode: false)
        await settle { newDiagnostics.hasRequest }
        oldDiagnostics.finish(inspected)
        await settle { oldDiagnostics.finished }
        checks["fixedEntryInspectionOlderProfileCannotOverwriteNewRun"] = restartedDiagnostics.isChecking
            && restartedDiagnostics.items.isEmpty
        newDiagnostics.finish(partial)
        await settle { !restartedDiagnostics.isChecking }
        checks["fixedEntryInspectionPreservesWarningInsteadOfReportingConnected"] = restartedDiagnostics.items == partial

        var demoDiagnosticCreations = 0
        let demoDiagnostics = FixedEntryDiagnosticsModel {
            demoDiagnosticCreations += 1
            return DiagnosticsFixtureExecutor()
        }
        demoDiagnostics.start(profile: profile, demoMode: true)
        await settle { !demoDiagnostics.isChecking }
        checks["fixedEntryInspectionDemoNeverConstructsSSHExecutor"] = demoDiagnosticCreations == 0
            && demoDiagnostics.items.count == 6 && demoDiagnostics.items.allSatisfy { $0.message.hasPrefix("演示：") }

        let supported = RemotePythonCandidate(path: "/tmp/fixture tools/python '3", version: "3.12.0", isSupported: true)
        let old = RemotePythonCandidate(path: "/usr/bin/python3", version: "3.8.10", isSupported: false)
        let discoveryResult = RemotePythonDiscoveryResult(candidates: [old, supported], message: "Fixture candidates", isPartial: false)
        var discoveryCreations = 0
        let discoveryExecutor = PythonDiscoveryFixtureExecutor()
        let discovery = RemotePythonDiscoveryModel {
            discoveryCreations += 1
            return discoveryExecutor
        }
        checks["pythonDiscoveryIsIdleUntilExplicitStart"] = discoveryCreations == 0
            && discovery.result == nil && !discovery.isSearching
        let discoveryCandidate = try ProfileEditor.validatedPythonDiscoveryProfile(profile)
        discovery.start(profile: discoveryCandidate, demoMode: false)
        discovery.start(profile: profile, demoMode: false)
        await settle { discoveryExecutor.hasRequest }
        checks["pythonDiscoveryDoesNotStartDuplicateSearches"] = discoveryCreations == 1
            && discoveryExecutor.profiles == [profile] && discovery.isSearching
        checks["pythonDiscoveryEditorPreservesSelectedInterpreterForService"] = discoveryCandidate == profile
            && discoveryExecutor.profiles.first?.fixedEntryPythonPath == profile.fixedEntryPythonPath
        var invalidPythonDraft = profile
        invalidPythonDraft.fixedEntryPythonPath = "relative/python\ncommand"
        let invalidPythonCandidate = try ProfileEditor.validatedPythonDiscoveryProfile(invalidPythonDraft)
        checks["pythonDiscoveryEditorAllowsInvalidInterpreterForSafeServiceFiltering"] = invalidPythonCandidate == invalidPythonDraft
            && (try? JSONEncoder().encode(profile)) == original
        var invalidBaseDraft = profile
        invalidBaseDraft.sshPort = 0
        checks["pythonDiscoveryEditorStillRejectsInvalidConnectionFields"] =
            (try? ProfileEditor.validatedPythonDiscoveryProfile(invalidBaseDraft)) == nil
        discoveryExecutor.finish(.success(discoveryResult))
        await settle { !discovery.isSearching }
        var draftPythonPath = profile.fixedEntryPythonPath
        checks["pythonDiscoveryDoesNotAutomaticallyChangeDraftOrConfiguration"] = discovery.result == discoveryResult
            && draftPythonPath == profile.fixedEntryPythonPath && (try? JSONEncoder().encode(profile)) == original
        if let path = discovery.selectedPath(for: supported) { draftPythonPath = path }
        checks["pythonDiscoveryExplicitSelectionFillsOnlyDraft"] = draftPythonPath == supported.path
            && profile.fixedEntryPythonPath == "/tmp/existing python/bin/python3"
            && (try? JSONEncoder().encode(profile)) == original
        let unknown = RemotePythonCandidate(path: "/tmp/unlisted/python3", version: "3.12.0", isSupported: true)
        checks["pythonDiscoveryRejectsOldAndUnlistedCandidates"] = discovery.selectedPath(for: old) == nil
            && discovery.selectedPath(for: unknown) == nil
        discovery.cancel(clearResults: true)
        checks["pythonDiscoveryInputChangeClearsCandidatesAndRejectsStaleSelection"] = discovery.result == nil
            && discovery.checkedAt == nil && discovery.selectedPath(for: supported) == nil

        let lateDiscovery = PythonDiscoveryFixtureExecutor()
        let cancelledDiscovery = RemotePythonDiscoveryModel { lateDiscovery }
        cancelledDiscovery.start(profile: profile, demoMode: false)
        await settle { lateDiscovery.hasRequest }
        cancelledDiscovery.cancel()
        lateDiscovery.finish(.success(discoveryResult))
        await settle { lateDiscovery.finished }
        checks["pythonDiscoveryCancellationRejectsLateResults"] = !cancelledDiscovery.isSearching
            && cancelledDiscovery.result == nil && cancelledDiscovery.checkedAt == nil
            && cancelledDiscovery.message != nil && lateDiscovery.cancellations == 1

        let oldDiscovery = PythonDiscoveryFixtureExecutor(), newDiscovery = PythonDiscoveryFixtureExecutor()
        var discoveryQueue = [oldDiscovery, newDiscovery]
        let restartedDiscovery = RemotePythonDiscoveryModel { discoveryQueue.removeFirst() }
        restartedDiscovery.start(profile: profile, demoMode: false)
        await settle { oldDiscovery.hasRequest }
        restartedDiscovery.cancel(clearResults: true)
        restartedDiscovery.start(profile: profile, demoMode: false)
        await settle { newDiscovery.hasRequest }
        oldDiscovery.finish(.success(discoveryResult))
        await settle { oldDiscovery.finished }
        checks["pythonDiscoveryOlderProfileCannotOverwriteNewSearch"] = restartedDiscovery.isSearching
            && restartedDiscovery.result == nil
        newDiscovery.finish(.failure(InspectionFixtureError()))
        await settle { !restartedDiscovery.isSearching }
        checks["pythonDiscoveryFailureRetainsNoSelectableCandidates"] = restartedDiscovery.result == nil
            && restartedDiscovery.checkedAt != nil && restartedDiscovery.message == "Fixture discovery failed"
            && restartedDiscovery.selectedPath(for: supported) == nil

        let partialExecutor = PythonDiscoveryFixtureExecutor()
        let partialDiscovery = RemotePythonDiscoveryModel { partialExecutor }
        partialDiscovery.start(profile: profile, demoMode: false)
        await settle { partialExecutor.hasRequest }
        let malformed = RemotePythonCandidate(path: "/tmp/python\ncommand", version: "3.12.0", isSupported: true)
        partialExecutor.finish(.success(.init(candidates: [supported, malformed], message: "Fixture partial", isPartial: true)))
        await settle { !partialDiscovery.isSearching }
        checks["pythonDiscoveryKeepsPartialStatusAndRejectsMalformedChoice"] = partialDiscovery.result?.isPartial == true
            && partialDiscovery.selectedPath(for: supported) == supported.path && partialDiscovery.selectedPath(for: malformed) == nil

        var demoDiscoveryCreations = 0
        let demoDiscovery = RemotePythonDiscoveryModel {
            demoDiscoveryCreations += 1
            return PythonDiscoveryFixtureExecutor()
        }
        demoDiscovery.start(profile: profile, demoMode: true)
        await settle { !demoDiscovery.isSearching }
        checks["pythonDiscoveryDemoNeverConstructsSSHExecutor"] = demoDiscoveryCreations == 0
            && demoDiscovery.result == RemotePythonDiscoveryModel.demoResult && demoDiscovery.checkedAt != nil
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
private final class DiagnosticsFixtureExecutor: FixedEntryDiagnosticsExecuting {
    private(set) var profiles: [ServerProfile] = []
    private(set) var cancellations = 0
    private(set) var finished = false
    private var continuation: CheckedContinuation<[SetupCheckItem], Never>?
    var hasRequest: Bool { continuation != nil }
    func run(_ profile: ServerProfile) async -> [SetupCheckItem] {
        profiles.append(profile)
        defer { finished = true }
        return await withCheckedContinuation { continuation = $0 }
    }
    func cancel() { cancellations += 1 }
    func finish(_ result: [SetupCheckItem]) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: result)
    }
}

@MainActor
private final class PythonDiscoveryFixtureExecutor: RemotePythonDiscoveryExecuting {
    private(set) var profiles: [ServerProfile] = []
    private(set) var cancellations = 0
    private(set) var finished = false
    private var continuation: CheckedContinuation<RemotePythonDiscoveryResult, Error>?
    var hasRequest: Bool { continuation != nil }
    func run(_ profile: ServerProfile) async throws -> RemotePythonDiscoveryResult {
        profiles.append(profile)
        defer { finished = true }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func cancel() { cancellations += 1 }
    func finish(_ result: Result<RemotePythonDiscoveryResult, Error>) {
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}

private struct InspectionFixtureError: LocalizedError {
    var errorDescription: String? { "Fixture discovery failed" }
}
