import Foundation
import Darwin

enum SocketDirectory {
    static func create() throws -> String {
        var template = Array("/tmp/tm.XXXXXXXX".utf8CString)
        let directory = try template.withUnsafeMutableBufferPointer { buffer -> String in
            guard let address = buffer.baseAddress, let created = Darwin.mkdtemp(address) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            // mkdtemp returns the supplied buffer. Copy while that buffer is pinned.
            return String(cString: created)
        }
        var metadata = stat()
        guard !directory.isEmpty, directory.hasPrefix("/tmp/tm."), directory.utf8.count < 80,
              Darwin.lstat(directory, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_mode & 0o777 == 0o700,
              metadata.st_uid == geteuid() else {
            if directory.hasPrefix("/tmp/tm.") { Darwin.rmdir(directory) }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES),
                          userInfo: [NSLocalizedDescriptionKey: "私有 SSH 控制目录验证失败。"])
        }
        return directory
    }
}
