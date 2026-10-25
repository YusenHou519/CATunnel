import Foundation
import CryptoKit
import Darwin
@testable import TunnelCore

private struct GatewayCheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func gatewayRequire(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try condition() == false { throw GatewayCheckFailure(description: message) }
}

private final class GatewayCheckSocket: @unchecked Sendable {
    private(set) var descriptor: Int32
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init(_ descriptor: Int32) throws {
        guard descriptor >= 0 else { throw GatewayCheckFailure(description: "fixture socket creation failed") }
        self.descriptor = descriptor
        var enabled: Int32 = 1
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            close()
            throw GatewayCheckFailure(description: "fixture socket configuration failed")
        }
    }

    deinit { close() }
    func close() {
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
    }
    func halfClose() { Darwin.shutdown(descriptor, SHUT_WR) }
    func interrupt() { Darwin.shutdown(descriptor, SHUT_RDWR) }
    var port: Int {
        var address = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
        }
        return result == 0 ? Int(in_port_t(bigEndian: address.sin_port)) : 0
    }

    private static func address(_ port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = in_port_t(port).bigEndian
        return address
    }

    static func listener(listen: Bool = true) throws -> GatewayCheckSocket {
        let socket = try GatewayCheckSocket(Darwin.socket(AF_INET, SOCK_STREAM, 0))
        var address = address(0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket.descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try gatewayRequire(bound == 0 && socket.port > 0, "fixture bind failed")
        if listen { try gatewayRequire(Darwin.listen(socket.descriptor, 16) == 0, "fixture listen failed") }
        return socket
    }

    static func connect(_ port: Int) throws -> GatewayCheckSocket {
        let socket = try GatewayCheckSocket(Darwin.socket(AF_INET, SOCK_STREAM, 0))
        var address = address(port)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket.descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            try gatewayRequire(errno == EINPROGRESS, "fixture connect refused")
            try socket.wait(Int16(POLLOUT), until: now + 3)
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            try gatewayRequire(getsockopt(socket.descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0 && error == 0,
                               "fixture connect failed")
        }
        return socket
    }

    func accept() throws -> GatewayCheckSocket {
        try wait(Int16(POLLIN), until: Self.now + 3)
        return try GatewayCheckSocket(Darwin.accept(descriptor, nil, nil))
    }

    func readable(within seconds: Double) throws -> Bool {
        var polling = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let result = Darwin.poll(&polling, 1, Int32(seconds * 1000))
        try gatewayRequire(result >= 0, "fixture poll failed")
        return result > 0 && polling.revents & Int16(POLLIN | POLLHUP | POLLERR) != 0
    }

    private func wait(_ events: Int16, until deadline: TimeInterval) throws {
        while Self.now < deadline {
            var polling = pollfd(fd: descriptor, events: events, revents: 0)
            let remaining = Int32(max(1, min(250, (deadline - Self.now) * 1000)))
            let result = Darwin.poll(&polling, 1, remaining)
            if result < 0 && errno == EINTR { continue }
            try gatewayRequire(result >= 0, "fixture poll failed")
            if polling.revents & (events | Int16(POLLHUP | POLLERR)) != 0 { return }
        }
        throw GatewayCheckFailure(description: "fixture socket operation timed out")
    }

    func write(_ bytes: Data, timeout: Double = 5) throws {
        let deadline = Self.now + timeout
        var offset = 0
        while offset < bytes.count {
            try wait(Int16(POLLOUT), until: deadline)
            let count = bytes.withUnsafeBytes {
                Darwin.send(descriptor, $0.baseAddress!.advanced(by: offset), $0.count - offset, 0)
            }
            if count > 0 { offset += count }
            else if count < 0 && [EAGAIN, EWOULDBLOCK, EINTR].contains(errno) { continue }
            else { throw GatewayCheckFailure(description: "fixture send failed") }
        }
    }

    func readExactly(_ length: Int, timeout: Double = 3) throws -> Data {
        let deadline = Self.now + timeout
        var data = Data()
        while data.count < length {
            let next = try read(maximum: length - data.count, until: deadline)
            try gatewayRequire(!next.isEmpty, "unexpected EOF before exact fixture response")
            data.append(next)
        }
        return data
    }

    func readAll(timeout: Double = 5, allowReset: Bool = false) throws -> Data {
        let deadline = Self.now + timeout
        var data = Data()
        while true {
            let next = try read(maximum: 4096, until: deadline, allowReset: allowReset)
            if next.isEmpty { return data }
            data.append(next)
            try gatewayRequire(data.count <= 2_000_000, "fixture response exceeded bounded buffer")
        }
    }

    private func read(maximum: Int, until deadline: TimeInterval, allowReset: Bool = false) throws -> Data {
        while true {
            try wait(Int16(POLLIN), until: deadline)
            var buffer = [UInt8](repeating: 0, count: maximum)
            let count = buffer.withUnsafeMutableBytes { Darwin.recv(descriptor, $0.baseAddress, $0.count, 0) }
            if count >= 0 { return Data(buffer.prefix(count)) }
            if allowReset && errno == ECONNRESET { return Data() }
            if [EAGAIN, EWOULDBLOCK, EINTR].contains(errno) { continue }
            throw GatewayCheckFailure(description: "fixture receive failed")
        }
    }
}

private final class GatewayStopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    func mark() { lock.lock(); finished = true; lock.unlock() }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
}

private func gatewayStopped(_ gateway: FixedEntryGateway) async throws {
    gateway.stop()
    let flag = GatewayStopFlag()
    Task.detached { await gateway.waitForStop(); flag.mark() }
    let deadline = ProcessInfo.processInfo.systemUptime + 4
    while !flag.isFinished && ProcessInfo.processInfo.systemUptime < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    try gatewayRequire(flag.isFinished, "owned gateway workers/listener failed to finish within four seconds")
}

private func gatewaySocketDescriptors() -> Set<Int32> {
    var result = Set<Int32>()
    for descriptor in 0..<min(getdtablesize(), 8192) {
        guard fcntl(descriptor, F_GETFD) >= 0 else { continue }
        var type: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        if getsockopt(descriptor, SOL_SOCKET, SO_TYPE, &type, &size) == 0 && type == SOCK_STREAM {
            result.insert(descriptor)
        }
    }
    return result
}

enum FixedEntryGatewayChecks {
    static let checks: [(String, () async throws -> Void)] = [
        ("native gateway authenticates a fresh challenge through a listening local proxy", health),
        ("native gateway rejects unavailable proxy and malformed health requests", rejectedHealth),
        ("native gateway preserves fragmented CONNECT and SOCKS bytes and half-close", transparentTraffic),
        ("native gateway drains a large response under backpressure after request EOF", largeResponse),
        ("native gateway shares idle activity across both transfer directions", sharedIdle),
        ("native gateway closes an actually idle transfer", idleExpiry),
        ("native gateway stop releases partial-prefix connections and every owned socket", stopCleanup),
        ("native gateway connection limit rejects excess streams without damaging the first", connectionLimit),
        ("native gateway reserves health capacity while all 64 data streams remain usable", fullCapacityHealth)
    ]
    private static let key = Data(repeating: 0x42, count: 32)

    static func health() async throws {
        try await Task.detached {
            let proxy = try GatewayCheckSocket.listener()
            defer { proxy.close() }
            let gateway = try FixedEntryGateway(localPort: proxy.port, healthKey: key)
            defer { gateway.stop() }
            try gatewayRequire(gateway.port != proxy.port, "gateway accepted its own destination port")
            for character in ["a", "b"] {
                let client = try GatewayCheckSocket.connect(gateway.port)
                defer { client.close() }
                let challenge = String(repeating: character, count: 64)
                try client.write(Data(("CATUNNEL-HEALTH-1 " + challenge + "\n").utf8))
                let proof = try client.readAll()
                let digest = HMAC<SHA256>.authenticationCode(for: Data(challenge.utf8), using: SymmetricKey(data: key))
                    .map { String(format: "%02x", $0) }.joined()
                try gatewayRequire(proof == Data(("CATUNNEL-HEALTH-1 " + digest + "\n").utf8), "health HMAC did not bind the challenge")
                let touchedProxy = try proxy.accept()
                defer { touchedProxy.close() }
                try gatewayRequire(try touchedProxy.readAll().isEmpty, "health check sent proxy payload")
            }
            try await gatewayStopped(gateway)
        }.value
    }

    static func rejectedHealth() async throws {
        try await Task.detached {
            // A bound, non-listening socket reserves the destination without contacting another service.
            let unavailable = try GatewayCheckSocket.listener(listen: false)
            defer { unavailable.close() }
            let gateway = try FixedEntryGateway(localPort: unavailable.port, healthKey: key)
            defer { gateway.stop() }
            let client = try GatewayCheckSocket.connect(gateway.port)
            defer { client.close() }
            try client.write(Data(("CATUNNEL-HEALTH-1 " + String(repeating: "a", count: 64) + "\n").utf8))
            try gatewayRequire(try client.readAll(allowReset: true).isEmpty, "unavailable local proxy received a health proof")
            try await gatewayStopped(gateway)

            let proxy = try GatewayCheckSocket.listener()
            defer { proxy.close() }
            let malformedGateway = try FixedEntryGateway(localPort: proxy.port, healthKey: key)
            defer { malformedGateway.stop() }
            for request in ["CATUNNEL-HEALTH-2 invalid\n", "CATUNNEL-HEALTH-1 short\n",
                            "CATUNNEL-HEALTH-1 " + String(repeating: "A", count: 64) + "\n"] {
                let rejected = try GatewayCheckSocket.connect(malformedGateway.port)
                defer { rejected.close() }
                try rejected.write(Data(request.utf8))
                try gatewayRequire(try rejected.readAll(allowReset: true).isEmpty, "malformed health request was accepted")
            }
            try gatewayRequire(try !proxy.readable(within: 0.05), "malformed health traffic reached the proxy")
            try await gatewayStopped(malformedGateway)
        }.value
    }

    static func transparentTraffic() async throws {
        try await Task.detached {
            let proxy = try GatewayCheckSocket.listener()
            defer { proxy.close() }
            let gateway = try FixedEntryGateway(localPort: proxy.port, healthKey: key)
            defer { gateway.stop() }
            let requests = [Data("CONNECT fixture.example:443 HTTP/1.1\r\nHost: fixture.example\r\n\r\n".utf8),
                            Data([5, 2, 0, 2, 5, 1, 0, 3, 3, 97, 98, 99, 1, 187])]
            for request in requests {
                let client = try GatewayCheckSocket.connect(gateway.port)
                defer { client.close() }
                for byte in request { try client.write(Data([byte])); usleep(1_000) }
                client.halfClose()
                let upstream = try proxy.accept()
                defer { upstream.close() }
                let received = try upstream.readAll()
                try gatewayRequire(received == request, "gateway consumed or rewrote fragmented proxy bytes")
                let response = Data("response-after-eof:".utf8) + request
                try upstream.write(response)
                upstream.halfClose()
                try gatewayRequire(try client.readAll() == response, "request half-close discarded the response")
            }
            try await gatewayStopped(gateway)
        }.value
    }

    static func largeResponse() async throws {
        try await Task.detached {
            let proxy = try GatewayCheckSocket.listener()
            defer { proxy.close() }
            let gateway = try FixedEntryGateway(localPort: proxy.port, healthKey: key)
            defer { gateway.stop() }
            let client = try GatewayCheckSocket.connect(gateway.port)
            defer { client.close() }
            var bufferSize: Int32 = 4096
            _ = setsockopt(client.descriptor, SOL_SOCKET, SO_RCVBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
            try client.write(Data("GET /fixture HTTP/1.0\r\n\r\n".utf8))
            client.halfClose()
            let upstream = try proxy.accept()
            defer { upstream.close() }
            _ = try upstream.readAll()
            _ = setsockopt(upstream.descriptor, SOL_SOCKET, SO_SNDBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
            let response = Data((0..<1_048_576).map { UInt8($0 % 251) })
            let sending = Task.detached {
                try upstream.write(response, timeout: 8)
                upstream.halfClose()
            }
            do {
                usleep(150_000)
                let received = try client.readAll(timeout: 8)
                try await sending.value
                try gatewayRequire(received == response, "large response was truncated or changed under backpressure")
            } catch {
                upstream.interrupt()
                _ = await sending.result
                throw error
            }
            try await gatewayStopped(gateway)
        }.value
    }

    static func sharedIdle() async throws {
        try await Task.detached {
            let proxy = try GatewayCheckSocket.listener()
            defer { proxy.close() }
            let gateway = try FixedEntryGateway(localPort: proxy.port, healthKey: key, idleTimeout: 0.3)
            defer { gateway.stop() }
            let client = try GatewayCheckSocket.connect(gateway.port)
            defer { client.close() }
            try client.write(Data([71]))
            let upstream = try proxy.accept()
            defer { upstream.close() }
            _ = try upstream.readExactly(1)
            for index in 0..<6 {
                try upstream.write(Data([UInt8(index)]))
                try gatewayRequire(try client.readExactly(1) == Data([UInt8(index)]), "one-way response activity timed out")
                usleep(80_000)
            }
            for index in 0..<6 {
                try client.write(Data([UInt8(index + 10)]))
                try gatewayRequire(try upstream.readExactly(1) == Data([UInt8(index + 10)]), "one-way request activity timed out")
                usleep(80_000)
            }
            client.halfClose()
            upstream.halfClose()
            try gatewayRequire(try client.readAll().isEmpty, "shared-idle fixture had unexpected response bytes")
            try await gatewayStopped(gateway)
        }.value
    }

    static func idleExpiry() async throws {
        try await Task.detached {
            let proxy = try GatewayCheckSocket.listener()
            defer { proxy.close() }
            let gateway = try FixedEntryGateway(localPort: proxy.port, healthKey: key, idleTimeout: 0.3)
            defer { gateway.stop() }
            let client = try GatewayCheckSocket.connect(gateway.port)
            defer { client.close() }
            try client.write(Data([71]))
            let upstream = try proxy.accept()
            defer { upstream.close() }
            _ = try upstream.readExactly(1)
            let start = ProcessInfo.processInfo.systemUptime
            try gatewayRequire(try client.readAll(timeout: 2).isEmpty, "idle connection returned unexpected data")
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            try gatewayRequire(elapsed >= 0.15 && elapsed < 1.5, "idle deadline was not applied to the transfer")
            try gatewayRequire(try upstream.readAll(timeout: 2).isEmpty, "idle gateway did not close its upstream")
            try await gatewayStopped(gateway)
        }.value
    }

    static func stopCleanup() async throws {
        try await Task.detached {
            let baseline = gatewaySocketDescriptors()
            let proxy = try GatewayCheckSocket.listener()
            defer { proxy.close() }
            let gateway = try FixedEntryGateway(localPort: proxy.port, healthKey: key)
            defer { gateway.stop() }
            let partial = try GatewayCheckSocket.connect(gateway.port)
            defer { partial.close() }
            try partial.write(Data("CAT".utf8))
            let client = try GatewayCheckSocket.connect(gateway.port)
            defer { client.close() }
            try client.write(Data([71]))
            let upstream = try proxy.accept()
            defer { upstream.close() }
            _ = try upstream.readExactly(1)
            try await gatewayStopped(gateway)
            gateway.stop()
            try gatewayRequire(try partial.readAll(timeout: 1, allowReset: true).isEmpty, "partial-prefix worker survived stop")
            try gatewayRequire(try client.readAll(timeout: 1, allowReset: true).isEmpty, "incoming stream survived stop")
            try gatewayRequire(try upstream.readAll(timeout: 1, allowReset: true).isEmpty, "upstream stream survived stop")
            var refused = false
            do { let unexpected = try GatewayCheckSocket.connect(gateway.port); unexpected.close() }
            catch { refused = true }
            try gatewayRequire(refused, "gateway listener survived stop")
            partial.close(); client.close(); upstream.close(); proxy.close()
            try gatewayRequire(gatewaySocketDescriptors() == baseline, "owned TCP descriptors leaked after stop completion")
        }.value
    }

    static func connectionLimit() async throws {
        try await Task.detached {
            let proxy = try GatewayCheckSocket.listener()
            defer { proxy.close() }
            let gateway = try FixedEntryGateway(localPort: proxy.port, healthKey: key, connectionLimit: 1)
            defer { gateway.stop() }
            let first = try GatewayCheckSocket.connect(gateway.port)
            defer { first.close() }
            try first.write(Data([71]))
            let upstream = try proxy.accept()
            defer { upstream.close() }
            _ = try upstream.readExactly(1)
            let excess = try GatewayCheckSocket.connect(gateway.port)
            defer { excess.close() }
            try excess.write(Data([71]))
            try gatewayRequire(try excess.readAll(timeout: 1, allowReset: true).isEmpty, "excess gateway stream was not rejected")
            try gatewayRequire(try !proxy.readable(within: 0.05), "excess connection reached local proxy")
            try upstream.write(Data("still-active".utf8))
            try gatewayRequire(try first.readExactly(12) == Data("still-active".utf8), "connection limit damaged admitted stream")
            try await gatewayStopped(gateway)
        }.value
    }

    static func fullCapacityHealth() async throws {
        try await Task.detached {
            var stage = "setup"
            do {
                let baseline = gatewaySocketDescriptors()
                let proxy = try GatewayCheckSocket.listener()
                defer { proxy.close() }
                let gateway = try FixedEntryGateway(localPort: proxy.port, healthKey: key)
                defer { gateway.stop() }
                var streams: [(client: GatewayCheckSocket, upstream: GatewayCheckSocket)] = []
                defer { for stream in streams { stream.client.close(); stream.upstream.close() } }
                for index in 0..<64 {
                    stage = "data stream \(index + 1) of 64: connect"
                    let client = try GatewayCheckSocket.connect(gateway.port)
                    do {
                        let initial = Data([71, UInt8(index)])
                        stage = "data stream \(index + 1) of 64: send prefix"
                        try client.write(initial)
                        stage = "data stream \(index + 1) of 64: accept local proxy"
                        let upstream = try proxy.accept()
                        streams.append((client, upstream))
                        stage = "data stream \(index + 1) of 64: receive prefix"
                        try gatewayRequire(try upstream.readExactly(initial.count) == initial, "full-capacity data admission changed bytes")
                    } catch {
                        client.close()
                        throw error
                    }
                }
                // The reserve must not become a 65th data connection.
                stage = "reject excess data stream"
                let excess = try GatewayCheckSocket.connect(gateway.port)
                defer { excess.close() }
                try excess.write(Data([71]))
                try gatewayRequire(try excess.readAll(timeout: 1, allowReset: true).isEmpty, "health reserve admitted excess data")
                try gatewayRequire(try !proxy.readable(within: 0.05), "excess data reached local proxy through the reserve")
                excess.close()

                stage = "health proof at full data capacity"
                let healthClient = try GatewayCheckSocket.connect(gateway.port)
                defer { healthClient.close() }
                let challenge = String(repeating: "c", count: 64)
                try healthClient.write(Data(("CATUNNEL-HEALTH-1 " + challenge + "\n").utf8))
                let digest = HMAC<SHA256>.authenticationCode(for: Data(challenge.utf8), using: SymmetricKey(data: key))
                    .map { String(format: "%02x", $0) }.joined()
                try gatewayRequire(try healthClient.readAll() == Data(("CATUNNEL-HEALTH-1 " + digest + "\n").utf8),
                                   "full data capacity starved the health proof")
                stage = "health local proxy connection"
                let healthProxy = try proxy.accept()
                defer { healthProxy.close() }
                try gatewayRequire(try healthProxy.readAll().isEmpty, "health proof sent unexpected proxy traffic")
                healthClient.close(); healthProxy.close()

                for (index, stream) in streams.enumerated() {
                    stage = "data stream \(index + 1) of 64: bidirectional recheck"
                    let request = Data([UInt8(index), 1, 2])
                    let response = Data([UInt8(index), 3, 4])
                    try stream.client.write(request)
                    try gatewayRequire(try stream.upstream.readExactly(request.count) == request, "capacity probe damaged an existing request stream")
                    try stream.upstream.write(response)
                    try gatewayRequire(try stream.client.readExactly(response.count) == response, "capacity probe damaged an existing response stream")
                }
                stage = "stop and socket cleanup"
                try await gatewayStopped(gateway)
                for stream in streams { stream.client.close(); stream.upstream.close() }
                proxy.close()
                try gatewayRequire(gatewaySocketDescriptors() == baseline, "full-capacity shutdown leaked owned sockets")
            } catch {
                throw GatewayCheckFailure(description: "full-capacity \(stage): \(error)")
            }
        }.value
    }
}
