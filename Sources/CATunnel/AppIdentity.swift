import Darwin
import Foundation

enum AppIdentity {
    static let bundleIdentifier = "local.catunnel.CATunnel"
    static let executableName = "CATunnel"

    static func settingsDirectory(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent("Library/Application Support/CATunnel", isDirectory: true)
    }

    static func lockURL(temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                        userID: uid_t = getuid()) -> URL {
        temporaryDirectory.appendingPathComponent("\(bundleIdentifier).\(userID).lock")
    }

    static func matchesRunningApplication(bundleIdentifier: String?, executableName: String?, bundleName: String?) -> Bool {
        if bundleIdentifier == Self.bundleIdentifier { return true }
        return executableName == Self.executableName && bundleName == "CATunnel.app"
    }
}
