import Foundation
import Darwin

struct CommandResult: Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool = false
    var stdoutTruncated: Bool = false
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var didTruncate = false
    private let limit: Int

    init(limit: Int = 32_768) {
        self.limit = min(max(1, limit), 1_048_576)
    }

    func append(_ bytes: Data) {
        lock.lock(); defer { lock.unlock() }
        if bytes.count >= limit {
            didTruncate = didTruncate || !data.isEmpty || bytes.count > limit
            data = Data(bytes.suffix(limit))
            return
        }
        if data.count + bytes.count > limit {
            didTruncate = true
            data.removeFirst(data.count + bytes.count - limit)
        }
        data.append(bytes)
    }
    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
    var truncated: Bool {
        lock.lock(); defer { lock.unlock() }
        return didTruncate
    }
}

/// Owns exactly one child process and drains its pipes even when no UI is observing it.
@MainActor
final class ChildCommand {
    private let process = Process()
    private var timeoutTask: Task<Void, Never>?
    private var killTask: Task<Void, Never>?
    private var completion: ((CommandResult) -> Void)?
    private var didTimeout = false
    private var hasStarted = false
    private var hasFinished = false
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    var isRunning: Bool { process.isRunning }

    func start(executable: String = "/usr/bin/ssh", arguments: [String], timeout: TimeInterval? = nil,
               stdoutLimit: Int = 32_768, stdin: Data? = nil, stdinLimit: Int = 4096,
               completion: @escaping (CommandResult) -> Void) throws {
        guard (1...262_144).contains(stdinLimit), stdin.map({ $0.count <= stdinLimit }) ?? true else {
            throw NSError(domain: "CATunnel.ChildCommand", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "私有控制请求超过大小限制。"])
        }
        self.completion = completion
        let outputPipe = Pipe(), errorPipe = Pipe()
        let inputPipe = stdin.map { _ in Pipe() }
        if let inputPipe, fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) < 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let output = OutputBuffer(limit: stdoutLimit), error = OutputBuffer(), drained = DispatchGroup()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = inputPipe?.fileHandleForReading ?? FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        drained.enter(); drained.enter()
        if inputPipe != nil { drained.enter() }
        process.terminationHandler = { [weak self] process in
            let code = process.terminationStatus
            drained.notify(queue: .global(qos: .utility)) {
                let result = CommandResult(exitCode: code, stdout: output.string, stderr: error.string,
                                           stdoutTruncated: output.truncated)
                Task { @MainActor [weak self] in self?.finish(result) }
            }
        }
        do { try process.run(); hasStarted = true }
        catch {
            hasFinished = true
            self.completion = nil
            process.terminationHandler = nil
            drained.leave(); drained.leave()
            if let inputPipe {
                try? inputPipe.fileHandleForReading.close()
                try? inputPipe.fileHandleForWriting.close()
                drained.leave()
            }
            throw error
        }
        if let inputPipe, let stdin {
            try? inputPipe.fileHandleForReading.close()
            DispatchQueue.global(qos: .utility).async {
                try? Self.writePrivateInput(stdin, to: inputPipe.fileHandleForWriting)
                drained.leave()
            }
        }
        for (handle, buffer) in [(outputPipe.fileHandleForReading, output), (errorPipe.fileHandleForReading, error)] {
            DispatchQueue.global(qos: .utility).async {
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                }
                try? handle.close()
                drained.leave()
            }
        }
        if let timeout {
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled, let self, self.isRunning else { return }
                self.didTimeout = true
                self.stop()
            }
        }
    }

    nonisolated static func writePrivateInput(_ data: Data, to writer: FileHandle) throws {
        defer { try? writer.close() }
        // The peer may exit before this queue runs; suppress SIGPIPE for this descriptor only.
        guard fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        try writer.write(contentsOf: data)
    }

    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        if killTask == nil {
            killTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self, self.process.isRunning else { return }
                // This PID belongs to a still-running Process object created here.
                Darwin.kill(self.process.processIdentifier, SIGKILL)
            }
        }
    }

    func waitForExit() async {
        guard hasStarted, !hasFinished else { return }
        await withCheckedContinuation { exitWaiters.append($0) }
    }

    private func finish(_ result: CommandResult) {
        guard !hasFinished else { return }
        hasFinished = true
        timeoutTask?.cancel(); timeoutTask = nil
        killTask?.cancel(); killTask = nil
        let callback = completion
        completion = nil
        var completed = result
        completed.timedOut = didTimeout
        callback?(completed)
        let waiters = exitWaiters
        exitWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
