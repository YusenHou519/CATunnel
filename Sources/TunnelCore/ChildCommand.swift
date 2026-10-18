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
    func append(_ bytes: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(bytes)
        if data.count > 32_768 {
            didTruncate = true
            data.removeFirst(data.count - 32_768)
        }
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
               completion: @escaping (CommandResult) -> Void) throws {
        self.completion = completion
        let outputPipe = Pipe(), errorPipe = Pipe()
        let output = OutputBuffer(), error = OutputBuffer(), drained = DispatchGroup()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        drained.enter(); drained.enter()
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
            throw error
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
