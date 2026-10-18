import AppKit
import Combine
import Foundation
import SwiftUI
import TunnelCore

private final class PanelHostingView<Content: View>: NSHostingView<Content> {
    override var allowsVibrancy: Bool { false }
}

struct LaunchOptions {
    var previewPath: String?
    var uiCheckReportPath: String?
    var demo = false
    var appearanceName: String?
    var argumentError: String?
    var connectOnce: [String] = []

    init(arguments: [String]) {
        var index = 1
        while index < arguments.count {
            let valueOptions = ["--preview", "--ui-check", "--appearance", "--connect-once"]
            if valueOptions.contains(arguments[index]),
               index + 1 >= arguments.count || arguments[index + 1].hasPrefix("--") {
                argumentError = "参数缺少值：\(arguments[index])"
                break
            }
            switch arguments[index] {
            case "--preview" where index + 1 < arguments.count:
                index += 1; previewPath = arguments[index]
            case "--ui-check" where index + 1 < arguments.count:
                index += 1; uiCheckReportPath = arguments[index]
            case "--demo": demo = true
            case "--appearance" where index + 1 < arguments.count:
                index += 1; appearanceName = arguments[index]
            case "--connect-once" where index + 1 < arguments.count:
                index += 1; connectOnce.append(arguments[index])
            default: argumentError = "未知参数或参数缺少值：\(arguments[index])"
            }
            index += 1
        }
    }
    var isOffline: Bool { demo || previewPath != nil || uiCheckReportPath != nil }
    var validationError: String? {
        if let argumentError { return argumentError }
        if isOffline && !connectOnce.isEmpty {
            return "离线预览不能与 --connect-once 一起使用。"
        }
        if previewPath != nil && uiCheckReportPath != nil { return "请分别运行 --preview 和 --ui-check。" }
        if let appearanceName, !["light", "dark"].contains(appearanceName) {
            return "--appearance 只接受 light 或 dark。"
        }
        return nil
    }

    func connectionValidationError(profiles: [ServerProfile], configurationError: String? = nil) -> String? {
        if let validationError { return validationError }
        guard !connectOnce.isEmpty else { return nil }
        if let configurationError { return configurationError }
        for id in Set(connectOnce) {
            guard let profile = profiles.first(where: { $0.id == id }) else {
                return "--connect-once 指定的服务器不存在：\(id)"
            }
            do { try profile.validateForConnection() }
            catch { return "无法连接 \(profile.name)：\(error.localizedDescription)" }
        }
        return nil
    }

    func startupConnectionIDs(profiles: [ServerProfile]) -> [String] {
        guard !isOffline else { return [] }
        var seen = Set<String>()
        return (profiles.filter(\.autoConnectOnLaunch).map(\.id) + connectOnce)
            .filter { seen.insert($0).inserted }
    }
}

@main
struct CATunnelMain {
    @MainActor
    static func main() {
        let options = LaunchOptions(arguments: CommandLine.arguments)
        if let error = options.validationError { fputs("\(error)\n", stderr); exit(2) }
        let application = NSApplication.shared
        var instanceLock: AppInstanceLock?
        if !options.isOffline {
            do { instanceLock = try AppInstanceLock.acquire() }
            catch {
                fputs("\(error.localizedDescription)\n", stderr)
                let alert = NSAlert()
                alert.messageText = "CATunnel 未启动"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "关闭")
                alert.runModal()
                exit(1)
            }
        }
        let delegate = AppDelegate(options: options)
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
        withExtendedLifetime(instanceLock) {}
        exit(delegate.exitCode)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let options: LaunchOptions
    private let store: TunnelStore
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var observation: AnyCancellable?
    private var panelSizeObservation: AnyCancellable?
    private var appearanceObservation: NSKeyValueObservation?
    private var terminating = false
    private var readyToTerminate = false
    var exitCode: Int32 = 0

    init(options: LaunchOptions) {
        self.options = options
        store = TunnelStore(persistSettings: !options.isOffline, demoMode: options.isOffline)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Validate the entire request before starting any connection.
        if let error = options.connectionValidationError(profiles: store.profiles,
                                                         configurationError: store.configurationError) {
            fputs("\(error)\n", stderr)
            exitCode = 2
            NSApp.terminate(nil)
            return
        }
        if let appearance = options.appearanceName {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        makeApplicationMenu()
        makeStatusItem()
        makePopover()
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.syncPopoverAppearance() }
        }

        if let path = options.previewPath {
            Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                showPopover()
                try? await Task.sleep(nanoseconds: 800_000_000)
                do { try capturePanel(to: URL(fileURLWithPath: path)) }
                catch { fputs("Preview failed: \(error.localizedDescription)\n", stderr); exitCode = 1 }
                NSApp.terminate(nil)
            }
        } else if let path = options.uiCheckReportPath {
            Task { await runUICheck(reportURL: URL(fileURLWithPath: path)) }
        } else if options.demo {
            Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                showPopover()
            }
        } else {
            for id in options.startupConnectionIDs(profiles: store.profiles) { store.start(id) }
        }
    }

    private func makeDetailsWindow() {
        guard window == nil else { return }
        let view = DashboardView(store: store)
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "CATunnel"
        window.subtitle = store.demoMode ? "演示模式 · 无真实连接" : "连接设置与日志"
        window.contentView = hosting
        window.minSize = NSSize(width: 940, height: 720)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if readyToTerminate { return .terminateNow }
        if !terminating {
            terminating = true
            Task {
                await store.shutdown()
                readyToTerminate = true
                if options.isOffline { exit(exitCode) }
                // Returning to the run loop avoids nesting AppKit's quit loop inside a Swift task.
                RunLoop.main.perform(inModes: [.common]) { NSApp.terminate(nil) }
            }
        }
        return .terminateCancel
    }

    private func makeApplicationMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settings = appMenu.addItem(withTitle: "设置…", action: #selector(showAppearanceSettings(_:)), keyEquivalent: ",")
        settings.target = self
        let details = appMenu.addItem(withTitle: "连接设置与日志…", action: #selector(showWindow(_:)), keyEquivalent: "")
        details.target = self
        appMenu.addItem(withTitle: "隐藏 CATunnel", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出并停止隧道", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "arrow.left.arrow.right.circle", accessibilityDescription: "CATunnel")
        item.button?.image?.isTemplate = true
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        statusItem = item
        observation = Publishers.CombineLatest(store.$statuses, store.$profiles).sink { [weak self] statuses, profiles in
            self?.updateStatusItem(statuses: statuses)
        }
        updateStatusItem()
    }

    private func updateStatusItem(statuses: [String: TunnelStatus]? = nil) {
        let statuses = statuses ?? store.statuses
        let count = statuses.values.filter { $0.phase == .connected }.count
        let warning = statuses.values.contains { $0.phase == .failed || $0.phase == .reconnecting }
        statusItem?.button?.image = NSImage(systemSymbolName: warning ? "exclamationmark.arrow.triangle.2.circlepath" : "arrow.left.arrow.right.circle", accessibilityDescription: "CATunnel")
        statusItem?.button?.image?.isTemplate = true
        statusItem?.button?.toolTip = "CATunnel\(store.demoMode ? " · 演示" : "") · \(count) 条隧道已连接"
    }

    private func makePopover() {
        let panel = NSPopover()
        panel.behavior = .transient
        panel.animates = false
        panel.appearance = NSApp.effectiveAppearance
        let content = PanelHostingView(rootView: MenuBarPanelView(store: store,
            showDetails: { [weak self] in self?.showWindow(nil) },
            showAbout: { [weak self] in self?.showAbout() },
            quit: { NSApp.terminate(nil) }))
        content.setFrameSize(NSSize(width: store.panelAppearance.width, height: 640))
        let hosting = NSViewController()
        hosting.view = content
        panel.contentViewController = hosting
        panel.contentSize = NSSize(width: store.panelAppearance.width, height: 640)
        popover = panel
        panelSizeObservation = store.$panelAppearance
            .map(\.width).removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] width in
                let size = NSSize(width: width, height: 640)
                self?.popover?.contentViewController?.view.setFrameSize(size)
                self?.popover?.contentSize = size
            }
    }

    @objc private func showAppearanceSettings(_ sender: Any?) {
        store.showingAppearanceSettings = true
        showPopover()
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover?.isShown == true { popover?.performClose(nil) }
        else { showPopover() }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        syncPopoverAppearance()
        NSApp.activate(ignoringOtherApps: true)
        popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover?.contentViewController?.view.window?.makeKey()
    }

    private func syncPopoverAppearance() {
        // NSPopover otherwise defaults to VibrantLight even when the application is dark.
        popover?.appearance = NSApp.effectiveAppearance
    }

    @objc private func showWindow(_ sender: Any?) {
        popover?.performClose(nil)
        makeDetailsWindow()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showAbout() {
        popover?.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "CATunnel",
            .credits: NSAttributedString(string: "Coding Agent Tunnel\n通过 Mac 的本地代理连接远程开发环境。")
        ])
    }

    private func captureContent(to url: URL) throws {
        guard let view = window?.contentView else { throw CocoaError(.fileWriteUnknown) }
        try capture(view, to: url)
    }

    private func capturePanel(to url: URL) throws {
        guard let view = popover?.contentViewController?.view else { throw CocoaError(.fileWriteUnknown) }
        try capture(view, to: url)
    }

    private func capture(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url, options: .atomic)
    }

    private func captureFixture<Content: View>(_ root: Content, size: NSSize? = nil, to url: URL,
                                               identifiers: [String] = []) async throws -> [String: NSRect] {
        var measuredFrames: [String: CGRect] = [:]
        let measuredRoot = root
            .environment(\.capturesLayoutEvidence, true)
            .coordinateSpace(name: "catunnel-offline-fixture")
            .onPreferenceChange(LayoutEvidenceKey.self) { measuredFrames = $0 }
        let hosting = PanelHostingView(rootView: measuredRoot)
        let contentSize = size ?? hosting.fittingSize
        let fixtureWindow = NSWindow(contentRect: NSRect(origin: .zero, size: contentSize),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        fixtureWindow.title = "CATunnel · Offline fixture"
        fixtureWindow.appearance = NSAppearance(named: .aqua)
        fixtureWindow.isReleasedWhenClosed = false
        fixtureWindow.contentView = hosting
        fixtureWindow.center()
        fixtureWindow.makeKeyAndOrderFront(nil)
        defer {
            fixtureWindow.orderOut(nil)
            fixtureWindow.contentView = nil
            fixtureWindow.close()
        }
        try? await Task.sleep(nanoseconds: 700_000_000)
        try capture(hosting, to: url)
        let evidence = measuredFrames.mapValues { NSStringFromRect($0) }
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: url.deletingPathExtension().appendingPathExtension("layout.json"), options: .atomic)
        var frames = ["fixture-content": hosting.bounds]
        for identifier in identifiers { frames[identifier] = measuredFrames[identifier] }
        return frames
    }

    private func captureProfileFixtures(in folder: URL) async throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        let empty = TunnelStore(persistSettings: false)
        let panel: (TunnelStore) -> MenuBarPanelView = { fixture in
            MenuBarPanelView(store: fixture, showDetails: {}, showAbout: {}, quit: {})
        }
        let emptyFrames = try await captureFixture(panel(empty), size: NSSize(width: 320, height: 640),
            to: folder.appendingPathComponent("panel-empty.png"), identifiers: ["panel-empty-add-server"])
        checks["emptyPanelPresentsAddServerAction"] = empty.profiles.isEmpty && empty.selectedProfile == nil
            && emptyFrames["panel-empty-add-server"] != nil
        let detailsFrames = try await captureFixture(DashboardView(store: empty), size: NSSize(width: 1060, height: 780),
            to: folder.appendingPathComponent("details-empty.png"), identifiers: ["dashboard-empty-add-server"])
        checks["emptyDetailsPresentsAddServerAction"] = detailsFrames["dashboard-empty-add-server"] != nil
        let editorFrames = try await captureFixture(ProfileEditor(profile: .draft(), isNew: true, store: empty),
            to: folder.appendingPathComponent("add-server.png"), identifiers: ["profile-name", "profile-host", "profile-user", "save-profile"])
        checks["newServerEditorShowsBlankConnectionFields"] = ["profile-name", "profile-host", "profile-user", "save-profile"]
            .allSatisfy { editorFrames[$0] != nil }
        if let content = editorFrames["fixture-content"], let save = editorFrames["save-profile"] {
            checks["newServerEditorKeepsSaveButtonVisible"] = content.insetBy(dx: -1, dy: -1).contains(save)
        } else { checks["newServerEditorKeepsSaveButtonVisible"] = false }

        let invalidDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("catunnel-invalid-editor-\(UUID().uuidString)")
            .appendingPathComponent(String(repeating: "long-fixture-path-", count: 8))
        try FileManager.default.createDirectory(at: invalidDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: invalidDirectory.deletingLastPathComponent()) }
        try Data("{".utf8).write(to: invalidDirectory.appendingPathComponent("profiles.json"))
        let blocked = TunnelStore(settingsDirectory: invalidDirectory)
        let errorFrames = try await captureFixture(ProfileEditor(profile: .draft(), isNew: true, store: blocked),
            to: folder.appendingPathComponent("add-server-configuration-error.png"),
            identifiers: ["profile-editor-error", "save-profile"])
        if let content = errorFrames["fixture-content"], let save = errorFrames["save-profile"] {
            checks["configurationErrorDoesNotHideEditorActions"] = blocked.configurationError != nil
                && errorFrames["profile-editor-error"] != nil && content.insetBy(dx: -1, dy: -1).contains(save)
        } else { checks["configurationErrorDoesNotHideEditorActions"] = false }
        await blocked.shutdown()

        let startupSettings = TunnelStore(persistSettings: false, demoMode: true)
        let startupStates = startupSettings.statuses
        try startupSettings.setAutoConnectOnLaunch(true, for: startupSettings.profiles[0].id)
        await startupSettings.loginItem.setEnabled(true)
        startupSettings.showingAppearanceSettings = true
        for (label, width, scale) in [("narrow-large", 300.0, 1.2), ("wide-small", 440.0, 0.9)] {
            startupSettings.updatePanelAppearance(width: width, fontScale: scale)
            let toggleIDs = ["settings-login-toggle"] + startupSettings.profiles.map { "settings-auto-connect-\($0.id)" }
            let frames = try await captureFixture(panel(startupSettings), size: NSSize(width: width, height: 640),
                to: folder.appendingPathComponent("startup-settings-\(label).png"),
                identifiers: toggleIDs + ["settings-scroll"])
            if let content = frames["fixture-content"], let scroll = frames["settings-scroll"] {
                checks["startupSwitchesFitSettingsPage-\(label)"] = toggleIDs.allSatisfy { id in
                    guard let frame = frames[id] else { return false }
                    return frame.width > 0 && frame.height > 0 && content.insetBy(dx: -1, dy: -1).contains(frame)
                        && scroll.insetBy(dx: -1, dy: -1).contains(frame)
                }
            } else { checks["startupSwitchesFitSettingsPage-\(label)"] = false }
        }
        checks["offlineStartupSwitchesDoNotAlterConnections"] = startupSettings.statuses == startupStates
            && startupSettings.loginItem.isEnabled && startupSettings.profiles[0].autoConnectOnLaunch
            && !startupSettings.profiles[1].autoConnectOnLaunch && startupSettings.controller == nil
        await startupSettings.shutdown()

        let multiple = TunnelStore(persistSettings: false, demoMode: true)
        for id in multiple.profiles.map(\.id) {
            multiple.stop(id)
            try multiple.remove(id)
        }
        for index in 1...9 { try multiple.add(ProfileStoreChecks.profile(index)) }
        for (label, width, scale) in [("narrow-large", 300.0, 1.2), ("wide-small", 440.0, 0.9)] {
            multiple.updatePanelAppearance(width: width, fontScale: scale)
            let selectedTab = "server-tab-\(multiple.selectedID)"
            let frames = try await captureFixture(panel(multiple), size: NSSize(width: width, height: 640),
                to: folder.appendingPathComponent("servers-\(label).png"), identifiers: [selectedTab, "server-tabs", "panel-add-server"])
            checks["multipleServerSelection-\(label)"] = multiple.profiles.count == 9
                && multiple.selectedID == ProfileStoreChecks.profile(9).id && multiple.controller == nil
            if let content = frames["fixture-content"], let selected = frames[selectedTab],
               let viewport = frames["server-tabs"], let add = frames["panel-add-server"] {
                checks["lastSelectedTabAndAddButtonVisible-\(label)"] = selected.width > 0 && selected.height > 0
                    && content.insetBy(dx: -1, dy: -1).contains(selected)
                    && viewport.insetBy(dx: -1, dy: -1).contains(selected)
                    && content.insetBy(dx: -1, dy: -1).contains(add) && selected.maxX <= add.minX
            } else { checks["lastSelectedTabAndAddButtonVisible-\(label)"] = false }
        }
        await empty.shutdown()
        await multiple.shutdown()
        return checks
    }

    private func captureSetupFixtures(in folder: URL) async throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        let guideFrames = try await captureFixture(GettingStartedView(),
            to: folder.appendingPathComponent("getting-started.png"),
            identifiers: ["getting-started-scroll", "getting-started-add",
                          "getting-started-step-1", "getting-started-step-2", "getting-started-step-3"])
        checks["guideShowsAllThreeSetupSteps"] = (1...3).allSatisfy { guideFrames["getting-started-step-\($0)"] != nil }
        if let content = guideFrames["fixture-content"], let add = guideFrames["getting-started-add"],
           let scroll = guideFrames["getting-started-scroll"] {
            checks["guideKeepsAddActionOutsideScrollingContent"] = content.insetBy(dx: -1, dy: -1).contains(add)
                && scroll.maxY <= add.minY
        } else { checks["guideKeepsAddActionOutsideScrollingContent"] = false }

        let demo = TunnelStore(persistSettings: false, demoMode: true)
        var profile = ProfileStoreChecks.profile(20)
        profile.identityFile = "/tmp/catunnel-fixture-identity-not-a-real-key"
        let model = SetupCheckModel()
        model.start(profile: profile, demoMode: true)
        let completed = await waitUntil(seconds: 2) { !model.isChecking }
        checks["demoSetupCompletesWithoutReadingSelectedKey"] = completed && model.items.count == 5
            && model.items.allSatisfy { $0.state == .passed && $0.message.hasPrefix("演示：") }
        let frames = try await captureFixture(ProfileEditor(profile: profile, isNew: true, store: demo, setupModel: model),
            to: folder.appendingPathComponent("setup-editor.png"),
            identifiers: ["profile-editor-scroll", "profile-select-identity", "profile-assess-ip-risk",
                          "profile-check-setup", "save-profile", "setup-results"])
        checks["editorOffersIdentityConsentAndExplicitSetupCheck"] = ["profile-select-identity", "profile-assess-ip-risk",
            "profile-check-setup", "setup-results"].allSatisfy { frames[$0] != nil }
        if let content = frames["fixture-content"], let save = frames["save-profile"], let scroll = frames["profile-editor-scroll"] {
            checks["setupResultsKeepSaveOutsideScrollingContent"] = content.insetBy(dx: -1, dy: -1).contains(save)
                && scroll.maxY <= save.minY
        } else { checks["setupResultsKeepSaveOutsideScrollingContent"] = false }
        if let content = frames["fixture-content"], let check = frames["profile-check-setup"],
           let scroll = frames["profile-editor-scroll"], let results = frames["setup-results"] {
            checks["setupActionStaysVisibleOutsideScrollingContent"] = content.insetBy(dx: -1, dy: -1).contains(check)
                && scroll.maxY <= check.minY
            checks["completedSetupResultsAutomaticallyScrollIntoView"] = scroll.insetBy(dx: -1, dy: -1).contains(results)
        } else {
            checks["setupActionStaysVisibleOutsideScrollingContent"] = false
            checks["completedSetupResultsAutomaticallyScrollIntoView"] = false
        }

        model.start(profile: profile, demoMode: true)
        model.cancel()
        try? await Task.sleep(nanoseconds: 400_000_000)
        checks["cancelledSetupCannotRestoreStaleResults"] = !model.isChecking && model.items.isEmpty
        model.start(profile: profile, demoMode: true)
        model.cancel()
        model.start(profile: ProfileStoreChecks.profile(21), demoMode: true)
        checks["newSetupRunSurvivesPriorCancellation"] = await waitUntil(seconds: 2) { !model.isChecking && model.items.count == 5 }
        model.cancel()

        let failures: [SetupCheckItem] = [
            .init(id: "localProxy", title: "本地代理端口", state: .failed, message: "示例：本机端口未能建立 TCP 连接，请核对代理端口。"),
            .init(id: "identity", title: "SSH 私钥", state: .warning, message: "示例：默认密钥是否可用，将由 SSH 认证确认。"),
            .init(id: "ssh", title: "SSH 连接", state: .failed, message: "示例：主机指纹未确认，请先在终端独立核实服务器身份。"),
            .init(id: "remoteSS", title: "远端 ss", state: .skipped, message: "示例：SSH 未通过，尚未检查服务器命令。"),
            .init(id: "remoteCurl", title: "远端 curl", state: .skipped, message: "示例：SSH 未通过，尚未检查服务器命令。")
        ]
        _ = try await captureFixture(SetupCheckResultsView(items: failures).padding(24).frame(width: 510)
            .background(Color(nsColor: .windowBackgroundColor)), to: folder.appendingPathComponent("setup-diagnostics.png"))

        let first = demo.profiles[0].id
        demo.stop(first)
        var optedIn = demo.profiles[0]
        optedIn.assessIPRisk = true
        try demo.save(optedIn)
        demo.start(first)
        _ = await waitUntil(seconds: 3) { demo.status(for: first).phase == .connected }
        demo.testProxy(first)
        checks["explicitDemoConsentStillShowsRiskScore"] = await waitUntil(seconds: 4) {
            demo.status(for: first).ipRisk.state == .available && demo.status(for: first).ipRisk.assessment != nil
        }
        _ = try await captureFixture(MenuBarPanelView(store: demo, showDetails: {}, showAbout: {}, quit: {}),
            size: NSSize(width: 320, height: 640), to: folder.appendingPathComponent("panel-risk-enabled.png"))
        await demo.shutdown()
        return checks
    }

    private func waitUntil(seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return condition()
    }

    /// Exercises the views and isolated stores without starting SSH or making proxy requests.
    private func runUICheck(reportURL: URL) async {
        var checks: [String: Bool] = [:]
        var failure: String?
        let folder = reportURL.deletingLastPathComponent()
        let ids = store.profiles.map(\.id)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            checks["offlineStoreHasNoController"] = store.demoMode && store.controller == nil
            checks["startsInMenuBarWithoutWindow"] = NSApp.activationPolicy() == .accessory && window == nil
                && statusItem != nil && popover?.behavior == .transient
            checks["rejectsMixedLiveAndOfflineArguments"] = [
                ["app", "--demo", "--connect-once", "example-a"],
                ["app", "--preview", "/tmp/p.png", "--connect-once", "example-a"],
                ["app", "--ui-check", "/tmp/u.json", "--connect-once", "example-b"]
            ].allSatisfy { LaunchOptions(arguments: $0).validationError != nil }
            checks["rejectsRemovedLiveVerificationOptions"] = [
                ["app", "--smoke-test", "/tmp/s.json"], ["app", "--test-port", "17893"]
            ].allSatisfy { LaunchOptions(arguments: $0).validationError != nil }
            let connectProfile = ProfileStoreChecks.profile(1)
            var automatic = ProfileStoreChecks.profile(2)
            automatic.autoConnectOnLaunch = true
            checks["normalStartupSelectsOnlyOptedInServers"] = LaunchOptions(arguments: ["app"])
                .startupConnectionIDs(profiles: [connectProfile, automatic]) == [automatic.id]
                && LaunchOptions(arguments: ["app"]).startupConnectionIDs(profiles: [connectProfile]).isEmpty
            checks["explicitStartupAndSavedChoiceAreDeduplicated"] = LaunchOptions(arguments: ["app", "--connect-once",
                automatic.id, "--connect-once", connectProfile.id, "--connect-once", automatic.id])
                .startupConnectionIDs(profiles: [connectProfile, automatic]) == [automatic.id, connectProfile.id]
            checks["allOfflineModesIgnoreAutomaticConnections"] = [
                ["app", "--demo"], ["app", "--preview", "/tmp/p.png"], ["app", "--ui-check", "/tmp/u.json"]
            ].allSatisfy { LaunchOptions(arguments: $0).startupConnectionIDs(profiles: [automatic]).isEmpty }
            checks["connectOnceUsesSavedIDs"] = LaunchOptions(arguments: ["app", "--connect-once", connectProfile.id])
                .connectionValidationError(profiles: [connectProfile]) == nil
                && LaunchOptions(arguments: ["app", "--connect-once", "missing-server"])
                    .connectionValidationError(profiles: [connectProfile]) != nil
            checks["connectOnceRejectsEntireInvalidRequest"] = LaunchOptions(arguments: ["app", "--connect-once",
                connectProfile.id, "--connect-once", "missing-server"]).connectionValidationError(profiles: [connectProfile]) != nil
                && LaunchOptions(arguments: ["app", "--connect-once", connectProfile.id])
                    .connectionValidationError(profiles: []) != nil
            checks["connectOnceRejectsExamplesAndConfigurationErrors"] = LaunchOptions(arguments: ["app", "--connect-once", "example-a"])
                .connectionValidationError(profiles: ServerProfile.examples) != nil
                && LaunchOptions(arguments: ["app", "--connect-once", connectProfile.id])
                    .connectionValidationError(profiles: [connectProfile], configurationError: "fixture error") != nil
            checks["packagedApplicationUsesIndependentIdentity"] = Bundle.main.bundleIdentifier == AppIdentity.bundleIdentifier
                && Bundle.main.executableURL?.lastPathComponent == AppIdentity.executableName
            checks["instanceMatchingExcludesUnrelatedApplications"] = !AppIdentity.matchesRunningApplication(
                bundleIdentifier: "org.example.UnrelatedApp", executableName: "UnrelatedApp", bundleName: "CATunnel.app")
                && AppIdentity.matchesRunningApplication(bundleIdentifier: AppIdentity.bundleIdentifier,
                    executableName: AppIdentity.executableName, bundleName: "CATunnel.app")
            guard ids.count == 2 else { throw CocoaError(.validationMissingMandatoryProperty) }
            let first = ids[0], second = ids[1]
            let initial = store.statuses
            store.selectedID = second
            checks["selectionDoesNotChangeConnections"] = store.statuses == initial && store.selectedProfile?.id == second
            store.selectedID = "unknown"
            checks["invalidSelectionRejected"] = store.selectedID == second
            store.start(second)
            checks["demoSecondConnects"] = await waitUntil(seconds: 3) { store.status(for: second).phase == .connected }
            store.testProxy(first)
            store.testProxy(second)
            store.selectedID = first
            checks["switchWhileBothTesting"] = store.status(for: first).proxyCheck == .checking
                && store.status(for: second).proxyCheck == .checking
            checks["independentTestsFinish"] = await waitUntil(seconds: 4) {
                ids.allSatisfy { store.status(for: $0).proxyCheck == .passed }
            }
            checks["serverResultsAreIsolated"] = store.status(for: first).ipRisk.ip != store.status(for: second).ipRisk.ip
            store.stop(first)
            checks["stopOnePreservesOther"] = store.status(for: first).phase == .stopped
                && store.status(for: second).phase == .connected
            checks["historicalResultsKeepStoppedState"] = store.isShowingHistoricalResults(for: first)
                && store.presentationStatus(for: first).phase == .stopped
                && store.presentationStatus(for: first).websiteResults.allSatisfy { $0.state == .passed }
            store.start(first)
            _ = await waitUntil(seconds: 3) { store.status(for: first).phase == .connected }
            checks["reconnectDoesNotReuseResultsAsCurrent"] = store.isShowingHistoricalResults(for: first)
            store.testProxy(first)
            store.stop(first)
            try? await Task.sleep(nanoseconds: 500_000_000)
            checks["cancelledCheckCannotOverwriteStoppedState"] = store.status(for: first).phase == .stopped
                && store.status(for: first).proxyCheck == .unchecked

            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("catunnel-ui-check-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            checks.merge(try await ProfileStoreChecks.run(in: temp)) { _, result in result }
            checks.merge(try await LoginItemChecks.run(in: temp.appendingPathComponent("login-items"))) { _, result in result }

            let lockURL = AppIdentity.lockURL(temporaryDirectory: temp)
            let unrelatedLock = try AppInstanceLock(url: temp.appendingPathComponent("unrelated-app.lock"))
            var firstLock: AppInstanceLock? = try AppInstanceLock(url: lockURL)
            withExtendedLifetime(unrelatedLock) { checks["independentLockCoexistsWithOtherApplications"] = firstLock != nil }
            do {
                let unexpected = try AppInstanceLock(url: lockURL)
                withExtendedLifetime(unexpected) {}
                checks["duplicateInstanceLockRejected"] = false
            } catch AppInstanceLock.Failure.running { checks["duplicateInstanceLockRejected"] = true }
            withExtendedLifetime(firstLock) {}
            firstLock = nil
            let nextLock = try AppInstanceLock(url: lockURL)
            withExtendedLifetime(nextLock) { checks["releasedInstanceLockReusable"] = true }

            store.start(first)
            _ = await waitUntil(seconds: 3) { store.status(for: first).phase == .connected }
            store.testProxy(first)
            _ = await waitUntil(seconds: 4) { store.status(for: first).proxyCheck == .passed }
            store.stop(second)
            store.selectedID = first
            showPopover()
            try? await Task.sleep(nanoseconds: 500_000_000)
            checks["popoverOpens"] = popover?.isShown == true
            for (label, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                NSApp.appearance = NSAppearance(named: appearance)
                checks["panelAppearance-\(label)"] = await waitUntil(seconds: 3) {
                    popover?.contentViewController?.view.effectiveAppearance
                        .bestMatch(from: [.aqua, .darkAqua]) == appearance
                }
                try? await Task.sleep(nanoseconds: 800_000_000)
                try capturePanel(to: folder.appendingPathComponent("panel-\(label).png"))
            }
            let stateBeforeAppearance = store.statuses
            checks["defaultPanelWidthIs320"] = popover?.contentSize.width == 320
            store.showingAppearanceSettings = true
            for (label, width, scale) in [("narrow-large", 300.0, 1.2), ("wide-small", 440.0, 0.9)] {
                store.updatePanelAppearance(width: width, fontScale: scale)
                checks["livePanelWidth-\(label)"] = await waitUntil(seconds: 3) {
                    popover?.contentSize.width == CGFloat(width)
                        && popover?.contentViewController?.view.frame.width == CGFloat(width)
                }
                try? await Task.sleep(nanoseconds: 600_000_000)
                try capturePanel(to: folder.appendingPathComponent("settings-\(label).png"))
                store.showingAppearanceSettings = false
                try? await Task.sleep(nanoseconds: 300_000_000)
                try capturePanel(to: folder.appendingPathComponent("panel-\(label).png"))
                store.showingAppearanceSettings = true
            }
            checks["appearanceChangesPreserveConnectionsAndResults"] = store.statuses == stateBeforeAppearance
            store.resetPanelAppearance()
            checks["resetResizesLivePanel"] = await waitUntil(seconds: 3) { popover?.contentSize.width == 320 }
            NSApp.appearance = NSAppearance(named: .aqua)
            try? await Task.sleep(nanoseconds: 600_000_000)
            try capturePanel(to: folder.appendingPathComponent("settings-default.png"))
            store.showingAppearanceSettings = false
            store.selectedID = second
            try? await Task.sleep(nanoseconds: 200_000_000)
            try capturePanel(to: folder.appendingPathComponent("panel-example-b.png"))
            let beforeClose = store.statuses
            popover?.performClose(nil)
            checks["closingPopoverKeepsState"] = store.statuses == beforeClose
            showWindow(nil)
            try? await Task.sleep(nanoseconds: 300_000_000)
            try captureContent(to: folder.appendingPathComponent("details-dark.png"))
            window?.performClose(nil)
            checks["closingDetailsKeepsState"] = store.statuses == beforeClose
            showPopover()
            checks["reopeningKeepsSelection"] = store.selectedID == second
            popover?.performClose(nil)
            checks.merge(try await captureProfileFixtures(in: folder)) { _, result in result }
            checks.merge(try await captureSetupFixtures(in: folder)) { _, result in result }
        } catch { failure = error.localizedDescription }
        await store.shutdown()
        checks["shutdownStopsOnlyDemoState"] = store.controller == nil && ids.allSatisfy { store.status(for: $0).phase == .stopped }
        let success = failure == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        var report: [String: Any] = ["mode": "offline-ui-check", "success": success,
            "checks": checks, "completedAt": ISO8601DateFormatter().string(from: Date()),
            "realSSHConnections": 0, "realProxyRequests": 0]
        if let failure { report["error"] = failure }
        do {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: reportURL, options: .atomic)
            print("UI_CHECK_SUCCESS \(success) · \(checks.values.filter { $0 }.count)/\(checks.count)")
            print("UI_CHECK_REPORT \(reportURL.path)")
        } catch { fputs("UI report failed: \(error.localizedDescription)\n", stderr) }
        exitCode = success ? 0 : 1
        NSApp.terminate(nil)
    }

}
