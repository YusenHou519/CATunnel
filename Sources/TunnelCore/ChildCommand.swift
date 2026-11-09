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

/// Serializes nonblocking I/O and descriptor closure, including when another process holds a pipe open.
private final class ChildPipePump: @unchecked Sendable {
    enum Direction {
        case read(OutputBuffer)
        case write(Data)
    }

    private let handle: FileHandle
    private let direction: Direction
    private let queue: DispatchQueue
    private let source: DispatchSourceProtocol
    private var offset = 0

    init(handle: FileHandle, direction: Direction, queue: DispatchQueue, drained: DispatchGroup) {
        self.handle = handle
        self.direction = direction
        self.queue = queue
        switch direction {
        case .read:
            source = DispatchSource.makeReadSource(fileDescriptor: handle.fileDescriptor, queue: queue)
        case .write:
            source = DispatchSource.makeWriteSource(fileDescriptor: handle.fileDescriptor, queue: queue)
        }
        drained.enter()
        source.setEventHandler { [weak self] in self?.transferAvailable() }
        source.setCancelHandler {
            try? handle.close()
            drained.leave()
        }
        source.resume()
    }

    func cancel(after delay: TimeInterval = 0) {
        queue.asyncAfter(deadline: .now() + delay) { [self] in source.cancel() }
    }

    private func transferAvailable() {
        guard !source.isCancelled else { return }
        // Yield between bounded batches so cancellation cannot be starved by continuous output.
        for _ in 0..<16 {
            let count: Int
            switch direction {
            case let .read(buffer):
                var bytes = [UInt8](repeating: 0, count: 16_384)
                count = bytes.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
                if count > 0 { buffer.append(Data(bytes.prefix(count))) }
            case let .write(data):
                guard offset < data.count else { source.cancel(); return }
                count = data.withUnsafeBytes {
                    Darwin.write(handle.fileDescriptor, $0.baseAddress!.advanced(by: offset), $0.count - offset)
                }
                if count > 0 { offset += count }
            }
            if count > 0 { continue }
            if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                source.cancel()
            }
            if count == 0 || errno != EINTR { return }
        }
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
    private var pipes: [ChildPipePump] = []
    private var pipeCloseScheduled = false
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    var isRunning: Bool { process.isRunning }

    func start(executable: String = "/usr/bin/ssh", arguments: [String], timeout: TimeInterval? = nil,
               stdoutLimit: Int = 32_768, stdin: Data? = nil, stdinLimit: Int = 4096,
               onTimeout: (() -> Void)? = nil,
               completion: @escaping (CommandResult) -> Void) throws {
        guard (1...262_144).contains(stdinLimit), stdin.map({ $0.count <= stdinLimit }) ?? true else {
            throw NSError(domain: "CATunnel.ChildCommand", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "私有控制请求超过大小限制。"])
        }
        self.completion = completion
        let outputPipe = Pipe(), errorPipe = Pipe()
        let inputPipe = stdin.map { _ in Pipe() }
        let handles = [outputPipe.fileHandleForReading, errorPipe.fileHandleForReading]
            + (inputPipe.map { [$0.fileHandleForWriting] } ?? [])
        for handle in handles {
            let flags = fcntl(handle.fileDescriptor, F_GETFL)
            guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        if let inputPipe, fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) < 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let output = OutputBuffer(limit: stdoutLimit), error = OutputBuffer(), drained = DispatchGroup()
        let ioQueue = DispatchQueue(label: "CATunnel.ChildCommand.io", qos: .utility)
        pipes = [ChildPipePump(handle: outputPipe.fileHandleForReading, direction: .read(output), queue: ioQueue, drained: drained),
                 ChildPipePump(handle: errorPipe.fileHandleForReading, direction: .read(error), queue: ioQueue, drained: drained)]
        if let inputPipe, let stdin {
            pipes.append(ChildPipePump(handle: inputPipe.fileHandleForWriting, direction: .write(stdin), queue: ioQueue, drained: drained))
        }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = inputPipe?.fileHandleForReading ?? FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { [weak self] process in
            let code = process.terminationStatus
            drained.notify(queue: ioQueue) {
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
            for pipe in pipes { pipe.cancel() }
            pipes.removeAll()
            if let inputPipe {
                try? inputPipe.fileHandleForReading.close()
            }
            throw error
        }
        if let inputPipe {
            try? inputPipe.fileHandleForReading.close()
        }
        if let timeout {
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled, let self, !self.hasFinished else { return }
                self.didTimeout = true
                self.stop()
                onTimeout?()
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
        guard hasStarted, !hasFinished else { return }
        if !pipeCloseScheduled {
            pipeCloseScheduled = true
            // A mux master can retain the child's descriptors after it exits. Bound only stopped I/O;
            // normal commands still drain to EOF, and completion still waits for the owned PID's exit.
            for pipe in pipes { pipe.cancel(after: 0.25) }
        }
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
        pipes.removeAll()
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
