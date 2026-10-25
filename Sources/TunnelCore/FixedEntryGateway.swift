import Foundation
import CryptoKit
import Darwin

enum FixedEntryGatewayError: Error {
    case invalidConfiguration, listenerUnavailable, destinationUnavailable, closed, timedOut
}

/// Owns loopback sockets only. Blocking socket work never runs on the main actor.
final class FixedEntryGateway: @unchecked Sendable {
    let port: Int
    private let localPort: Int
    private let healthKey: Data
    private let idleTimeout: TimeInterval
    private let connectionLimit: Int
    private let lock = NSLock()
    private var source: DispatchSourceRead?
    private var stopped = false
    private var listenerClosed = false
    private var connections: [UUID: Connection] = [:]
    private var dataConnections: Set<UUID> = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private final class Connection: @unchecked Sendable {
        let id = UUID()
        let incoming: Int32
        private let lock = NSLock()
        private var descriptors: Set<Int32>
        private var stopped = false

        init(_ descriptor: Int32) {
            incoming = descriptor
            descriptors = [descriptor]
        }

        var isStopped: Bool {
            lock.lock(); defer { lock.unlock() }
            return stopped
        }

        func add(_ descriptor: Int32) {
            lock.lock(); defer { lock.unlock() }
            descriptors.insert(descriptor)
            if stopped { Darwin.shutdown(descriptor, SHUT_RDWR) }
        }

        func stop() {
            lock.lock(); defer { lock.unlock() }
            stopped = true
            // The worker alone closes descriptors, preventing reuse while it is polling them.
            for descriptor in descriptors { Darwin.shutdown(descriptor, SHUT_RDWR) }
        }

        func finish() {
            lock.lock(); defer { lock.unlock() }
            stopped = true
            for descriptor in descriptors { Darwin.close(descriptor) }
            descriptors.removeAll()
        }
    }

    init(localPort: Int, healthKey: Data, idleTimeout: TimeInterval = 60,
         connectionLimit: Int = 64) throws {
        guard (1...65535).contains(localPort), healthKey.count == 32,
              idleTimeout.isFinite, idleTimeout > 0, (1...64).contains(connectionLimit) else {
            throw FixedEntryGatewayError.invalidConfiguration
        }
        self.localPort = localPort
        self.healthKey = healthKey
        self.idleTimeout = idleTimeout
        self.connectionLimit = connectionLimit
        let listener = try Self.makeListener(excluding: localPort)
        port = listener.port
        let source = DispatchSource.makeReadSource(fileDescriptor: listener.descriptor,
            queue: DispatchQueue(label: "CATunnel.FixedEntryGateway.accept"))
        self.source = source
        source.setEventHandler { [weak self] in self?.accept(listener.descriptor) }
        source.setCancelHandler { [weak self] in
            Darwin.close(listener.descriptor)
            self?.didCloseListener()
        }
        source.resume()
    }

    deinit { stop() }

    func stop() {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        let listener = source
        source = nil
        let active = Array(connections.values)
        lock.unlock()
        listener?.cancel()
        for connection in active { connection.stop() }
    }

    func waitForStop() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if stopped && listenerClosed && connections.isEmpty {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func didCloseListener() {
        lock.lock()
        listenerClosed = true
        let ready = takeWaitersIfStopped()
        lock.unlock()
        for waiter in ready { waiter.resume() }
    }

    private func didFinish(_ connection: Connection) {
        lock.lock()
        connections.removeValue(forKey: connection.id)
        dataConnections.remove(connection.id)
        let ready = takeWaitersIfStopped()
        lock.unlock()
        for waiter in ready { waiter.resume() }
    }

    private func takeWaitersIfStopped() -> [CheckedContinuation<Void, Never>] {
        guard stopped && listenerClosed && connections.isEmpty else { return [] }
        let result = waiters
        waiters.removeAll()
        return result
    }

    private func accept(_ listener: Int32) {
        while true {
            lock.lock()
            let mayAccept = !stopped
            lock.unlock()
            guard mayAccept else { return }
            let descriptor = Darwin.accept(listener, nil, nil)
            if descriptor < 0 {
                if errno == EINTR { continue }
                return
            }
            guard Self.configure(descriptor) else { Darwin.close(descriptor); continue }
            let connection = Connection(descriptor)
            lock.lock()
            // Leave one bounded slot for the helper's health proof even at full data capacity.
            let accepted = !stopped && connections.count < connectionLimit + 1
            if accepted { connections[connection.id] = connection }
            lock.unlock()
            guard accepted else { connection.finish(); continue }
            // Blocking poll loops must not exhaust the shared GCD pool and starve the health slot.
            let worker = Thread { [self] in
                defer {
                    connection.finish()
                    didFinish(connection)
                }
                try? serve(connection)
            }
            worker.name = "CATunnel.FixedEntryGateway.connection"
            worker.qualityOfService = .utility
            worker.start()
        }
    }

    private func serve(_ connection: Connection) throws {
        let deadline = Self.now + 3
        var prefix = Data()
        var isHealth = true
        for expected in Array("CATUNNEL-".utf8) {
            let byte = try Self.read(connection.incoming, maximum: 1, until: deadline)
            if byte.isEmpty { return }
            prefix.append(byte)
            if byte.first != expected { isHealth = false; break }
        }
        if isHealth {
            while prefix.count <= 128 && prefix.last != 10 {
                let byte = try Self.read(connection.incoming, maximum: 1, until: deadline)
                if byte.isEmpty { return }
                prefix.append(byte)
            }
            let marker = Data("CATUNNEL-HEALTH-1 ".utf8)
            guard prefix.count == marker.count + 65, prefix.starts(with: marker), prefix.last == 10 else { return }
            let challenge = Data(prefix.dropFirst(marker.count).dropLast())
            guard challenge.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return }
            // A proof is valid only when the configured local proxy accepts TCP.
            _ = try connectProxy(connection)
            guard !connection.isStopped else { return }
            let digest = HMAC<SHA256>.authenticationCode(for: challenge, using: SymmetricKey(data: healthKey))
                .map { String(format: "%02x", $0) }.joined()
            try Self.write(connection.incoming, data: marker + Data((digest + "\n").utf8), until: Self.now + 3)
        } else {
            guard admitData(connection) else { return }
            let upstream = try connectProxy(connection)
            try Self.write(upstream, data: prefix, until: Self.now + 3)
            try transfer(connection, upstream: upstream)
        }
    }

    private func admitData(_ connection: Connection) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, dataConnections.count < connectionLimit else { return false }
        dataConnections.insert(connection.id)
        return true
    }

    private func connectProxy(_ connection: Connection) throws -> Int32 {
        guard !connection.isStopped else { throw FixedEntryGatewayError.closed }
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw FixedEntryGatewayError.destinationUnavailable }
        connection.add(descriptor)
        guard Self.configure(descriptor), !connection.isStopped else { throw FixedEntryGatewayError.closed }
        var address = Self.address(port: localPort)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw FixedEntryGatewayError.destinationUnavailable }
            try Self.wait(descriptor, events: Int16(POLLOUT), until: Self.now + 3)
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                throw FixedEntryGatewayError.destinationUnavailable
            }
        }
        guard !connection.isStopped else { throw FixedEntryGatewayError.closed }
        return descriptor
    }

    private func transfer(_ connection: Connection, upstream: Int32) throws {
        let descriptors = [connection.incoming, upstream]
        var buffers = [Data(), Data()]
        var readEOF = [false, false]
        var writeEOF = [false, false]
        var activity = Self.now
        let limit = 65_536
        while !connection.isStopped {
            for index in 0..<2 where readEOF[index] && buffers[index].isEmpty && !writeEOF[1 - index] {
                Darwin.shutdown(descriptors[1 - index], SHUT_WR)
                writeEOF[1 - index] = true
            }
            if readEOF.allSatisfy({ $0 }) && buffers.allSatisfy({ $0.isEmpty }) { return }
            guard Self.now - activity < idleTimeout else { throw FixedEntryGatewayError.timedOut }
            var polling = (0..<2).map { index -> pollfd in
                var events: Int16 = 0
                if !readEOF[index] && buffers[index].count < limit { events |= Int16(POLLIN) }
                if !buffers[1 - index].isEmpty { events |= Int16(POLLOUT) }
                // poll reports HUP even for events=0; ignore a finished direction until it has work.
                return pollfd(fd: events == 0 ? -1 : descriptors[index], events: events, revents: 0)
            }
            let remaining = max(1, min(250, Int((idleTimeout - (Self.now - activity)) * 1000)))
            let result = Darwin.poll(&polling, 2, Int32(remaining))
            if result < 0 {
                if errno == EINTR { continue }
                throw FixedEntryGatewayError.closed
            }
            for index in 0..<2 {
                let events = polling[index].revents
                if events & Int16(POLLERR | POLLNVAL) != 0 { throw FixedEntryGatewayError.closed }
                if events & Int16(POLLOUT | POLLHUP) != 0 && !buffers[1 - index].isEmpty {
                    let count = buffers[1 - index].withUnsafeBytes {
                        Darwin.send(descriptors[index], $0.baseAddress, $0.count, 0)
                    }
                    if count > 0 {
                        buffers[1 - index].removeFirst(count)
                        activity = Self.now
                    } else if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                        throw FixedEntryGatewayError.closed
                    }
                }
                if events & Int16(POLLIN | POLLHUP) != 0 && !readEOF[index] && buffers[index].count < limit {
                    var bytes = [UInt8](repeating: 0, count: min(16_384, limit - buffers[index].count))
                    let count = bytes.withUnsafeMutableBytes { Darwin.recv(descriptors[index], $0.baseAddress, $0.count, 0) }
                    if count > 0 {
                        buffers[index].append(contentsOf: bytes.prefix(count))
                        activity = Self.now
                    } else if count == 0 {
                        readEOF[index] = true
                    } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                        throw FixedEntryGatewayError.closed
                    }
                }
            }
        }
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private static func configure(_ descriptor: Int32) -> Bool {
        var enabled: Int32 = 1
        return fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0
            && fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0
            && setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    private static func address(port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = in_port_t(port).bigEndian
        return address
    }

    private static func makeListener(excluding localPort: Int) throws -> (descriptor: Int32, port: Int) {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw FixedEntryGatewayError.listenerUnavailable }
        var success = false
        defer { if !success { Darwin.close(descriptor) } }
        guard configure(descriptor) else { throw FixedEntryGatewayError.listenerUnavailable }
        var address = address(port: 0)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let inspected = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        let port = Int(in_port_t(bigEndian: address.sin_port))
        guard result == 0, inspected == 0, port > 0, port != localPort,
              Darwin.listen(descriptor, 64) == 0 else { throw FixedEntryGatewayError.listenerUnavailable }
        success = true
        return (descriptor, port)
    }

    private static func wait(_ descriptor: Int32, events: Int16, until deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - now
            guard remaining > 0 else { throw FixedEntryGatewayError.timedOut }
            var polling = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&polling, 1, Int32(max(1, min(1000, remaining * 1000))))
            if result < 0 {
                if errno == EINTR { continue }
                throw FixedEntryGatewayError.closed
            }
            if polling.revents & Int16(POLLERR | POLLNVAL) != 0 { throw FixedEntryGatewayError.closed }
            if polling.revents & (events | Int16(POLLHUP)) != 0 { return }
        }
    }

    private static func read(_ descriptor: Int32, maximum: Int, until deadline: TimeInterval) throws -> Data {
        while true {
            try wait(descriptor, events: Int16(POLLIN), until: deadline)
            var bytes = [UInt8](repeating: 0, count: maximum)
            let count = bytes.withUnsafeMutableBytes { Darwin.recv(descriptor, $0.baseAddress, $0.count, 0) }
            if count >= 0 { return Data(bytes.prefix(count)) }
            if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { throw FixedEntryGatewayError.closed }
        }
    }

    private static func write(_ descriptor: Int32, data: Data, until deadline: TimeInterval) throws {
        var offset = 0
        while offset < data.count {
            try wait(descriptor, events: Int16(POLLOUT), until: deadline)
            let count = data.withUnsafeBytes {
                Darwin.send(descriptor, $0.baseAddress!.advanced(by: offset), $0.count - offset, 0)
            }
            if count > 0 { offset += count }
            else if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                throw FixedEntryGatewayError.closed
            }
        }
    }
}
