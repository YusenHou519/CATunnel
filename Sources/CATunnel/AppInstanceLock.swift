import AppKit
import Darwin
import Foundation

final class AppInstanceLock {
    private let descriptor: Int32

    enum Failure: LocalizedError {
        case running, unavailable(Int32)
        var errorDescription: String? {
            switch self {
            case .running:
                return "CATunnel 已在运行。请先退出当前实例，再打开 CATunnel。现有连接未被修改。"
            case let .unavailable(code):
                return "无法确认应用是否已运行（系统错误 \(code)），本次未启动隧道。"
            }
        }
    }

    static func acquire() throws -> AppInstanceLock {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let other = NSWorkspace.shared.runningApplications.contains { app in
            guard app.processIdentifier != ownPID, !app.isTerminated else { return false }
            return AppIdentity.matchesRunningApplication(bundleIdentifier: app.bundleIdentifier,
                executableName: app.executableURL?.lastPathComponent, bundleName: app.bundleURL?.lastPathComponent)
        }
        guard !other else { throw Failure.running }
        return try AppInstanceLock(url: AppIdentity.lockURL())
    }

    init(url: URL) throws {
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Failure.unavailable(errno) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { throw Failure.running }
            throw Failure.unavailable(code)
        }
        descriptor = fd
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
        // Keep the inode: unlinking it could let another process lock a different file.
    }
}
