import Foundation
import Darwin

@MainActor
public final class TunnelController {
    public var onEvent: ((TunnelEvent) -> Void)?
    private let executionContext: SSHExecutionContext
    private var sessions: [String: Session] = [:]
    private var retired: [UUID: Session] = [:]
    private var isShuttingDown = false
    private var isSleeping = false

    private enum ProbeOutcome: Sendable {
        case website(WebsiteTarget, CommandResult)
        case exitIP(CommandResult)
        case ipRisk(IPRiskCheckResult)
    }

    private final class Session {
        let profile: ServerProfile
        let generation = UUID()
        var desired = true
        var waitingForWake = false
        var status = TunnelStatus()
        var directory: String?
        var socket: String { (directory ?? "") + "/c" }
        var master: ChildCommand?
        var probes: [UUID: ChildCommand] = [:]
        var connectTask: Task<Void, Never>?
        var reconnectTask: Task<Void, Never>?
        var proxyTask: Task<Void, Never>?
        var proxyRunID: UUID?
        var retryPolicy = SSHReconnectPolicy()
        var forcedFailure: SSHFailure?
        var fixedGateway: FixedEntryGateway?
        var gatewayStopTask: Task<Void, Never>?
        var fixedRenewTask: Task<Void, Never>?
        var fixedReleaseTask: Task<Void, Never>?
        var fixedLease: FixedEntryIdentity?
        var fixedFence: FixedEntryFence?
        init(_ profile: ServerProfile) { self.profile = profile }
    }

    public init() { executionContext = SSHExecutionContext() }

    init(executionContext: SSHExecutionContext) { self.executionContext = executionContext }

    public func start(_ profile: ServerProfile) {
        guard !isShuttingDown else { return }
        do { try profile.validateForConnection() }
        catch {
            onEvent?(.status(id: profile.id, status: .init(phase: .failed, message: error.localizedDescription)))
            return
        }
        if let current = sessions[profile.id], current.desired,
           current.master?.isRunning == true || current.connectTask != nil || current.reconnectTask != nil || current.waitingForWake {
            log(profile.id, "此服务器的隧道已经开启或正在重连。")
            return
        }
        var previous = Array(retired.values).filter { $0.profile.id == profile.id }
        if let current = sessions[profile.id] {
            if !previous.contains(where: { $0 === current }) { previous.append(current) }
            stop(id: profile.id)
        }
        let session = Session(profile)
        sessions[profile.id] = session
        if isSleeping {
            guard profile.autoReconnect else {
                session.desired = false
                session.status = .init(phase: .stopped, message: "系统正在休眠，且未开启自动重连；请唤醒后手动连接。")
                publish(session)
                return
            }
            session.waitingForWake = true
            session.status = .init(phase: .reconnecting, message: "系统正在休眠，等待唤醒后连接。")
            publish(session)
            return
        }
        launchAfterPreviousSessions(session, previous: previous)
    }

    private func launchAfterPreviousSessions(_ session: Session, previous: [Session]) {
        guard isCurrent(session) else { return }
        if previous.isEmpty {
            launch(session)
        } else {
            session.status = .init(phase: .checking, message: "等待此前的隧道完全关闭…")
            publish(session)
            session.connectTask = Task { [weak self, weak session] in
                // Serialize restart behind actual owned-child exits, not a fixed delay.
                for previousSession in previous {
                    await self?.waitForOwnedExit(previousSession)
                }
                guard !Task.isCancelled, let self, let session, self.isCurrent(session) else { return }
                self.launch(session)
            }
        }
    }

    public func stop(id: String) {
        guard let session = sessions[id] else {
            onEvent?(.status(id: id, status: .stopped)); return
        }
        retire(session)
        session.status = .stopped
        publish(session)
        log(id, "已关闭此管理器创建的隧道。")
    }

    private func retire(_ session: Session) {
        session.desired = false
        session.waitingForWake = false
        session.connectTask?.cancel(); session.connectTask = nil
        session.reconnectTask?.cancel(); session.reconnectTask = nil
        session.proxyTask?.cancel(); session.proxyTask = nil
        session.proxyRunID = nil
        session.fixedRenewTask?.cancel(); session.fixedRenewTask = nil
        for command in session.probes.values { command.stop() }
        stopFixedGateway(session)
        if session.fixedReleaseTask == nil {
            if let lease = session.fixedLease, let master = session.master, master.isRunning {
                session.fixedLease = nil
                session.fixedReleaseTask = Task { [weak self, weak session] in
                    guard let self, let session else { return }
                    // A timed-out mux request can still await pipe EOF from its master.
                    // Bound the release grace period independently of that completion.
                    let stopMaster = Task {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        guard !Task.isCancelled else { return }
                        master.stop()
                    }
                    defer { stopMaster.cancel() }
                    _ = try? await self.runFixedControl(session, request: .release(lease), timeout: 1, retiring: true)
                    master.stop()
                    session.fixedReleaseTask = nil
                    if session.master?.isRunning != true { self.cleanup(session) }
                }
            } else {
                session.master?.stop()
            }
        }
        retired[session.generation] = session
        if session.master?.isRunning != true { cleanup(session) }
    }

    public func suspendForSleep() {
        guard !isShuttingDown, !isSleeping else { return }
        isSleeping = true
        var suspendedSessions: [Session] = []
        for session in Array(sessions.values) where session.desired {
            guard [.checking, .connecting, .connected, .reconnecting].contains(session.status.phase) else { continue }
            retire(session)
            guard session.profile.autoReconnect else {
                session.status = .init(phase: .stopped, message: "系统即将休眠，隧道已关闭；未开启自动重连。")
                suspendedSessions.append(session)
                continue
            }
            // A new generation prevents late callbacks from the old transport affecting wake recovery.
            let suspended = Session(session.profile)
            suspended.retryPolicy = session.retryPolicy
            suspended.fixedFence = session.fixedFence
            suspended.waitingForWake = true
            suspended.status = .init(phase: .reconnecting, message: "系统即将休眠，已暂停隧道，等待唤醒后恢复。")
            sessions[session.profile.id] = suspended
            suspendedSessions.append(suspended)
        }
        // Complete the batch before callbacks can synchronously request wake or stop.
        for session in suspendedSessions {
            guard sessions[session.profile.id] === session else { continue }
            if isSleeping { log(session.profile.id, session.status.message) }
            // Wake can update these statuses synchronously; manual-only sessions still need their stopped event.
            publish(session)
        }
    }

    public func resumeAfterWake() {
        guard !isShuttingDown, isSleeping else { return }
        isSleeping = false
        for session in Array(sessions.values) where session.desired && session.waitingForWake {
            session.waitingForWake = false
            log(session.profile.id, "系统已唤醒，正在恢复此前开启的隧道。")
            let previous = Array(retired.values).filter { $0.profile.id == session.profile.id }
            launchAfterPreviousSessions(session, previous: previous)
        }
    }

    public func testProxy(id: String) {
        guard let session = sessions[id], isCurrent(session), session.status.phase == .connected,
              session.master?.isRunning == true else {
            log(id, "请先开启隧道，等待服务器入口确认后再测试代理。")
            return
        }
        guard session.proxyTask == nil else { return }
        let runID = UUID()
        session.proxyRunID = runID
        session.status.proxyCheck = .checking
        session.status.proxyMessage = "正在检测 \(WebsiteTarget.allCases.count) 项连通性"
            + (session.profile.assessIPRisk ? "和出口 IP 信息…" : "…")
        session.status.websiteResults = WebsiteTarget.allCases.map {
            .init(target: $0, state: .checking, message: "检测中…")
        }
        session.status.ipRisk = session.profile.assessIPRisk
            ? .init(state: .checking, message: "正在获取 Claude 出口 IP…", stage: .exitIP)
            : .skipped()
        publish(session)
        session.proxyTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            await withTaskGroup(of: ProbeOutcome.self) { group in
                for target in WebsiteTarget.independentRequestTargets {
                    group.addTask { .website(target, await self.runWebsiteProbe(session, target: target)) }
                }
                group.addTask {
                    .exitIP(await self.runProbe(session, arguments: SSHCommands.remote(session.profile,
                        socket: session.socket, command: SSHCommands.ipRiskTraceCommand(port: session.profile.remotePort)), timeout: 24))
                }
                for await outcome in group {
                    guard !Task.isCancelled, self.isCurrentProbe(session, runID: runID) else {
                        group.cancelAll()
                        continue
                    }
                    switch outcome {
                    case let .website(target, rawResult):
                        let result = WebsiteProbe.evaluate(rawResult, target: target)
                        if let index = session.status.websiteResults.firstIndex(where: { $0.target == target }) {
                            session.status.websiteResults[index] = result
                        }
                        self.log(id, "\(target.title)：\(result.message)；检测证据：\(WebsiteProbe.publicEvidenceLog(rawResult, target: target))")
                    case let .exitIP(rawResult):
                        let networkResult = WebsiteProbe.evaluateNetwork(rawResult)
                        if let index = session.status.websiteResults.firstIndex(where: { $0.target == .claudeNetwork }) {
                            session.status.websiteResults[index] = networkResult
                        }
                        self.log(id, "Claude 网络连通：\(networkResult.message)")
                        // Assess the observed Claude exit even with domain-based proxy routing.
                        group.addTask { .ipRisk(await self.runIPRiskProbe(session, runID: runID, networkResult: networkResult)) }
                    case let .ipRisk(result):
                        session.status.ipRisk = result
                        // Do not log the raw trace or third-party response body.
                        self.log(id, "Net.Coffee IP 风险：\(result.message)")
                    }
                    let completed = session.status.websiteResults.filter { $0.state != .checking }.count
                    let riskProgress = session.status.ipRisk.state == .checking
                        ? " · IP 信息检测中" : ""
                    session.status.proxyMessage = "检测进度 · \(completed)/\(WebsiteTarget.allCases.count)\(riskProgress)"
                    self.publish(session)
                }
            }
            guard !Task.isCancelled, self.isCurrentProbe(session, runID: runID) else { return }
            let masterCheck = await self.runProbe(session,
                arguments: SSHCommands.check(session.profile, socket: session.socket), timeout: 4)
            guard !Task.isCancelled, self.isCurrentProbe(session, runID: runID) else { return }
            session.proxyTask = nil
            session.proxyRunID = nil
            if masterCheck.exitCode == 0 {
                let results = session.status.websiteResults
                session.status.proxyCheck = WebsiteProbe.aggregate(results)
                let passed = results.filter { $0.state == .passed }.count
                let restricted = results.filter { $0.state == .restricted }.count
                let failed = results.filter { $0.state == .failed }.count
                if session.status.proxyCheck == .passed {
                    session.status.proxyMessage = "代理可用 · \(passed)/\(results.count) 项检测通过"
                } else if session.status.proxyCheck == .partial {
                    var parts = ["\(passed) 通过"]
                    if restricted > 0 { parts.append("\(restricted) 受限") }
                    if failed > 0 { parts.append("\(failed) 未通过") }
                    session.status.proxyMessage = "部分可达 · " + parts.joined(separator: "，")
                } else {
                    session.status.proxyMessage = "网站检测均未通过，请查看各站点结果。"
                }
            } else {
                session.status.proxyCheck = .failed
                session.status.proxyMessage = "检测结束时无法确认原 SSH 控制连接，请重新开启隧道。"
                session.status.websiteResults = session.status.websiteResults.map {
                    var result = $0
                    result.state = .failed
                    result.message = "原 SSH 控制连接已失效，请重新检测"
                    return result
                }
                session.status.ipRisk = session.profile.assessIPRisk
                    ? .init(state: .failed, message: "原 SSH 控制连接已失效，请重新检测",
                        stage: session.status.ipRisk.stage, ip: session.status.ipRisk.ip,
                        countryCode: session.status.ipRisk.countryCode, checkedAt: Date())
                    : .skipped(checkedAt: Date())
                self.log(id, "网站检测后控制连接复核失败：\(SafeLog.clean(masterCheck.stderr))")
            }
            self.publish(session)
        }
    }

    private func runWebsiteProbe(_ session: Session, target: WebsiteTarget) async -> CommandResult {
        await runProbe(session, arguments: SSHCommands.remote(session.profile, socket: session.socket,
            command: SSHCommands.proxyCommand(port: session.profile.remotePort, target: target)), timeout: 24)
    }

    private func runIPRiskProbe(_ session: Session, runID: UUID,
                                networkResult: WebsiteCheckResult) async -> IPRiskCheckResult {
        guard !Task.isCancelled, isCurrentProbe(session, runID: runID) else { return .init() }
        do {
            let plan = try IPRiskAssessmentPlan.make(enabled: session.profile.assessIPRisk,
                networkResult: networkResult, remotePort: session.profile.remotePort, checkedAt: Date())
            let command: String
            let exitIP: (ip: String, countryCode: String?)
            switch plan {
            case let .completed(result): return result
            case let .request(request, ip, countryCode):
                command = request
                exitIP = (ip, countryCode)
            }
            session.status.ipRisk = .init(state: .checking, message: "已获取出口 IP，正在查询 Net.Coffee…",
                stage: .riskAssessment, ip: exitIP.ip, countryCode: exitIP.countryCode)
            publish(session)
            guard !Task.isCancelled, isCurrentProbe(session, runID: runID) else { return .init() }
            let response = await runProbe(session, arguments: SSHCommands.remote(session.profile, socket: session.socket,
                command: command), timeout: 24)
            guard !Task.isCancelled, isCurrentProbe(session, runID: runID) else { return .init() }
            let assessment = try IPRiskProbe.assessment(from: response, expectedIP: exitIP.ip)
            let usesNetworkCache = assessment.ip != exitIP.ip
            let message: String
            if usesNetworkCache {
                message = assessment.trustScore == nil ? "已获取 Net.Coffee 网段缓存风险信息，服务未提供评分" : "已获取 Net.Coffee 网段缓存评分"
            } else {
                message = assessment.trustScore == nil ? "已获取风险信息，服务未提供评分" : "已获取 Net.Coffee 原始评分与风险信息"
            }
            return .init(state: .available,
                message: message,
                stage: .riskAssessment, assessment: assessment, ip: exitIP.ip,
                countryCode: exitIP.countryCode, checkedAt: Date())
        } catch {
            return .init(state: .failed, message: "已获取出口 IP，评分查询失败：\(error.localizedDescription)",
                stage: .riskAssessment, ip: networkResult.exitIP, countryCode: networkResult.countryCode, checkedAt: Date())
        }
    }

    private func isCurrentProbe(_ session: Session, runID: UUID) -> Bool {
        isCurrent(session) && session.proxyRunID == runID && session.master?.isRunning == true
    }

    public func shutdown() async {
        isShuttingDown = true
        for id in Array(sessions.keys) { stop(id: id) }
        for session in Array(sessions.values) + Array(retired.values) {
            await waitForOwnedExit(session)
            if session.master?.isRunning != true { cleanup(session) }
        }
    }

    private func waitForOwnedExit(_ session: Session) async {
        await session.fixedReleaseTask?.value
        if let master = session.master { await master.waitForExit() }
        for probe in Array(session.probes.values) { await probe.waitForExit() }
        await session.gatewayStopTask?.value
    }

    private func stopFixedGateway(_ session: Session) {
        guard let gateway = session.fixedGateway, session.gatewayStopTask == nil else { return }
        gateway.stop()
        session.gatewayStopTask = Task { [weak self, weak session] in
            await gateway.waitForStop()
            guard let self, let session else { return }
            if session.fixedGateway === gateway { session.fixedGateway = nil }
            session.gatewayStopTask = nil
            if session.master?.isRunning != true { self.cleanup(session) }
        }
    }

    private func launch(_ session: Session) {
        guard isCurrent(session) else { return }
        session.forcedFailure = nil
        let identity = SetupDiagnostics.identityReadiness(session.profile)
        guard identity.state != .failed else {
            fail(session, failure: .init(message: identity.message, retryable: false))
            return
        }
        session.status = .init(phase: .checking, message: "准备独立 SSH 连接…")
        publish(session)
        guard isCurrent(session) else { return }
        do { session.directory = try executionContext.makeSocketDirectory() }
        catch { fail(session, failure: .init(message: "无法创建私有 SSH 控制目录。", retryable: false)); return }
        let master = ChildCommand()
        session.master = master
        session.status.phase = .connecting
        session.status.message = "正在连接 \(session.profile.host)…"
        publish(session)
        log(session.profile.id, session.profile.useFixedEntry
            ? "开启固定入口 127.0.0.1:\(session.profile.remotePort)，将通过独立 SSH 通道验证并申请租约。"
            : "开启 127.0.0.1:\(session.profile.remotePort) → Mac 127.0.0.1:\(session.profile.localPort)，使用独立 SSH 连接。")
        guard isCurrent(session) else { return }
        do {
            try master.start(arguments: executionContext.arguments(SSHCommands.master(session.profile, socket: session.socket))) { [weak self, weak session, weak master] result in
                guard let self, let session, let master, session.master === master else { return }
                session.connectTask?.cancel(); session.connectTask = nil
                session.proxyTask?.cancel(); session.proxyTask = nil
                session.proxyRunID = nil
                session.fixedRenewTask?.cancel(); session.fixedRenewTask = nil
                session.fixedLease = nil
                for command in session.probes.values { command.stop() }
                self.stopFixedGateway(session)
                self.cleanup(session)
                guard self.isCurrent(session) else { return }
                let details = SafeLog.clean(result.stderr)
                if !details.isEmpty { self.log(session.profile.id, details) }
                let failure = session.forcedFailure ?? SSHFailure.classify(result.stderr, timedOut: result.timedOut)
                self.fail(session, failure: failure)
            }
        } catch {
            cleanup(session)
            fail(session, failure: .init(message: "无法启动系统 SSH：\(error.localizedDescription)", retryable: false))
            return
        }
        session.connectTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            // A running ssh process is not evidence of an established forwarding socket.
            for _ in 0..<48 {
                guard !Task.isCancelled, self.isCurrent(session), session.master?.isRunning == true else { return }
                if FileManager.default.fileExists(atPath: session.socket) {
                    let check = await self.runProbe(session,
                        arguments: SSHCommands.check(session.profile, socket: session.socket), timeout: 3)
                    guard !Task.isCancelled, self.isCurrent(session), session.master?.isRunning == true else { return }
                    if check.exitCode == 0 {
                        if session.profile.useFixedEntry {
                            await self.establishFixedEntry(session)
                            return
                        }
                        let listener = await self.runProbe(session, arguments: SSHCommands.remote(session.profile,
                            socket: session.socket, command: self.executionContext.listenerCommand(session.profile.remotePort)), timeout: 5)
                        guard !Task.isCancelled, self.isCurrent(session), session.master?.isRunning == true else { return }
                        if !listener.timedOut && listener.exitCode == 0 && SSHCommands.hasLoopbackListener(listener.stdout, port: session.profile.remotePort) {
                            session.status = .init(phase: .connected,
                                message: "SSH 已连接 · 服务器 127.0.0.1:\(session.profile.remotePort) 已监听", connectedAt: Date())
                            session.retryPolicy.didConnect()
                            session.connectTask = nil
                            self.publish(session)
                            self.log(session.profile.id, "独立控制连接和服务器入口均已确认；代理出口尚未测试。")
                        } else {
                            session.forcedFailure = listener.timedOut
                                ? .init(message: "SSH 已建立，但服务器入口检查超时；请检查网络和服务器响应。", retryable: true)
                                : .init(message: "SSH 已建立，但无法确认服务器本地入口；请检查 ss 命令及转发限制。", retryable: false)
                            self.log(session.profile.id, "入口检查失败：\(SafeLog.clean(listener.stdout + "\n" + listener.stderr))")
                            session.master?.stop()
                        }
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard !Task.isCancelled, self.isCurrent(session) else { return }
            session.forcedFailure = .init(message: "SSH 建立超时，请检查网络和服务器可达性。", retryable: true)
            session.master?.stop()
        }
    }

    private func fail(_ session: Session, failure: SSHFailure) {
        guard isCurrent(session) else { return }
        guard session.profile.autoReconnect, let delay = session.retryPolicy.retryDelay(after: failure,
            keepRetryingForwardingFailure: !session.profile.useFixedEntry && session.profile.keepRetryingForwardingFailure) else {
            let exhausted = session.profile.autoReconnect && failure.isForwardingFailure && session.retryPolicy.hasConnected
            let message = exhausted
                ? "转发重试已达 \(SSHReconnectPolicy.forwardingRetryDelays.count) 次，自动重连已停止。请检查入口端口及 SSH 转发权限后手动重试。"
                : failure.message
            session.status = .init(phase: .failed, message: message)
            publish(session)
            log(session.profile.id, message)
            return
        }
        let message: String
        if session.retryPolicy.isWaitingForForwardingRelease {
            message = "服务器转发仍未恢复，可能是端口占用或转发受限。已开启持续重试，\(delay) 秒后再试；关闭连接可停止等待。"
        } else if failure.isForwardingFailure {
            message = "服务器转发暂未恢复，可能仍有旧连接占用端口。\(delay) 秒后重试（\(session.retryPolicy.forwardingRetryCount)/\(SSHReconnectPolicy.forwardingRetryDelays.count)）。"
        } else {
            message = "\(failure.message) \(delay) 秒后重试。"
        }
        session.status = .init(phase: .reconnecting, message: message)
        let sleepBeforeRetry = executionContext.sleepBeforeRetry
        session.reconnectTask = Task { [weak self, weak session] in
            do { try await sleepBeforeRetry(TimeInterval(delay)) }
            catch { return }
            guard !Task.isCancelled, let self, let session, self.isCurrent(session) else { return }
            await self.waitForOwnedExit(session)
            guard !Task.isCancelled, self.isCurrent(session) else { return }
            session.reconnectTask = nil
            self.launch(session)
        }
        publish(session)
        log(session.profile.id, message)
    }

    private func requireFixedSession(_ session: Session) throws {
        guard !Task.isCancelled, isCurrent(session), session.master?.isRunning == true else {
            throw CancellationError()
        }
    }

    private func runFixedControl(_ session: Session, request: FixedEntryRequest,
                                 timeout: TimeInterval = 6, retiring: Bool = false) async throws -> CommandResult {
        let arguments = try SSHCommands.fixedEntryControl(session.profile, socket: session.socket)
        let input = try FixedEntryProtocol.input(request)
        return await runProbe(session, arguments: arguments, timeout: timeout,
                              stdoutLimit: FixedEntryProtocol.bodyLimit, stdin: input, retiring: retiring)
    }

    private func establishFixedEntry(_ session: Session) async {
        do {
            let statusResult = try await runFixedControl(session, request: .status)
            try requireFixedSession(session)
            let status = try FixedEntryProtocol.status(statusResult, expectedPort: session.profile.remotePort)
            try session.fixedFence?.check(status)
            var healthKey = Data(count: 32)
            healthKey.withUnsafeMutableBytes { bytes in
                if let address = bytes.baseAddress { arc4random_buf(address, bytes.count) }
            }
            let gateway: FixedEntryGateway
            do { gateway = try FixedEntryGateway(localPort: session.profile.localPort, healthKey: healthKey) }
            catch { throw FixedEntryError("无法启动本机固定入口网关，请检查本机监听资源。") }
            session.fixedGateway = gateway
            let forwarded = await runProbe(session, arguments: SSHCommands.fixedEntryForward(session.profile,
                socket: session.socket, gatewayPort: gateway.port), timeout: 8)
            try requireFixedSession(session)
            let backendPort = try FixedEntryProtocol.allocatedPort(forwarded)
            let baseline = FixedEntryFence(epoch: status.epoch, generation: status.generation)
            // Preserve the pre-begin baseline: a lost reply does not prove which client acquired the next generation.
            session.fixedFence = baseline
            let begun = try await runFixedControl(session, request: .begin(baseline))
            try requireFixedSession(session)
            let identity = try FixedEntryProtocol.candidate(begun, after: baseline)
            session.fixedFence = .init(epoch: identity.epoch, generation: identity.generation)
            session.fixedLease = identity
            let activated = try await runFixedControl(session,
                request: .activate(identity, backendPort: backendPort, healthKey: healthKey))
            try requireFixedSession(session)
            let seconds = try FixedEntryProtocol.activated(activated, identity: identity, backendPort: backendPort)
            session.status = .init(phase: .connected,
                message: "固定入口 127.0.0.1:\(session.profile.remotePort) 已连接 · 通道及本机代理端口已验证", connectedAt: Date())
            session.retryPolicy.didConnect()
            session.connectTask = nil
            publish(session)
            guard isCurrent(session) else { return }
            log(session.profile.id, "固定入口租约已激活；健康证明只验证此通道与本机代理端口，尚未检测外网。")
            guard isCurrent(session) else { return }
            renewFixedEntry(session, leaseSeconds: seconds)
        } catch is CancellationError {
            return
        } catch {
            failFixedEntry(session, error: error)
        }
    }

    private func renewFixedEntry(_ session: Session, leaseSeconds: TimeInterval) {
        session.fixedRenewTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            var seconds = leaseSeconds
            do {
                while true {
                    try await Task.sleep(nanoseconds: UInt64(seconds / 3 * 1_000_000_000))
                    try self.requireFixedSession(session)
                    guard let identity = session.fixedLease else { return }
                    let result = try await self.runFixedControl(session, request: .renew(identity))
                    try self.requireFixedSession(session)
                    seconds = try FixedEntryProtocol.renewed(result)
                }
            } catch is CancellationError {
                return
            } catch {
                self.failFixedEntry(session, error: error)
            }
        }
    }

    private func failFixedEntry(_ session: Session, error: Error) {
        guard isCurrent(session), session.master?.isRunning == true else { return }
        let failure = (error as? FixedEntryError)?.failure
            ?? .init(message: "固定入口控制请求失败，请检查 helper 配置。", retryable: false)
        session.forcedFailure = failure
        log(session.profile.id, failure.message)
        stopFixedGateway(session)
        session.master?.stop()
    }

    private func runProbe(_ session: Session, arguments: [String], timeout: TimeInterval,
                          stdoutLimit: Int = 32_768, stdin: Data? = nil,
                          retiring: Bool = false) async -> CommandResult {
        guard (retiring ? !session.desired : isCurrent(session)), !Task.isCancelled, session.master?.isRunning == true else {
            return .init(exitCode: 255, stdout: "", stderr: "隧道已经关闭。")
        }
        let token = UUID(), command = ChildCommand()
        session.probes[token] = command
        return await withCheckedContinuation { continuation in
            do {
                try command.start(arguments: executionContext.arguments(arguments), timeout: timeout,
                                  stdoutLimit: stdoutLimit, stdin: stdin) { result in
                    session.probes.removeValue(forKey: token)
                    if !session.desired && session.probes.isEmpty && session.master?.isRunning != true {
                        self.cleanup(session)
                    }
                    continuation.resume(returning: result)
                }
            } catch {
                session.probes.removeValue(forKey: token)
                continuation.resume(returning: .init(exitCode: 255, stdout: "", stderr: error.localizedDescription))
            }
        }
    }

    private func isCurrent(_ session: Session) -> Bool {
        !isShuttingDown && !isSleeping && !session.waitingForWake && session.desired
            && sessions[session.profile.id]?.generation == session.generation
    }

    private func publish(_ session: Session) {
        guard sessions[session.profile.id]?.generation == session.generation else { return }
        onEvent?(.status(id: session.profile.id, status: session.status))
    }

    private func log(_ id: String, _ message: String) {
        let clean = SafeLog.clean(message)
        if !clean.isEmpty { onEvent?(.log(id: id, message: clean)) }
    }

    private func cleanup(_ session: Session) {
        if let directory = session.directory {
            // Only directories made with mkdtemp by this session are ever removed.
            try? FileManager.default.removeItem(atPath: directory)
            session.directory = nil
        }
        if session.probes.isEmpty && session.master?.isRunning != true
            && session.fixedGateway == nil && session.fixedReleaseTask == nil {
            retired.removeValue(forKey: session.generation)
        }
    }
}
