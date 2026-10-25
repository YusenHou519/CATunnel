import Foundation

public struct RemotePythonCandidate: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let version: String
    public let isSupported: Bool

    public init(path: String, version: String, isSupported: Bool) {
        self.path = path
        self.version = version
        self.isSupported = isSupported
    }
}

public struct RemotePythonDiscoveryResult: Equatable, Sendable {
    public let candidates: [RemotePythonCandidate]
    public let message: String
    public let isPartial: Bool

    public init(candidates: [RemotePythonCandidate], message: String, isPartial: Bool) {
        self.candidates = candidates
        self.message = message
        self.isPartial = isPartial
    }
}

/// Explicit discovery executes bounded version probes, without installing or activating environments.
@MainActor
public final class RemotePythonDiscovery {
    typealias Executor = RemoteInspection.Executor
    private let inspection: RemoteInspection
    static let marker = "CATUNNEL_PYTHON_DISCOVERY_V1"
    static let outputLimit = 131_072
    static let candidateLimit = 24

    public convenience init() { self.init(executionContext: SSHExecutionContext()) }

    init(executionContext: SSHExecutionContext, executor: Executor? = nil) {
        inspection = RemoteInspection(context: executionContext, executor: executor)
    }

    public func cancel() { inspection.cancel() }

    public func run(_ profile: ServerProfile) async throws -> RemotePythonDiscoveryResult {
        try await inspection.run {
            var base = profile
            base.useFixedEntry = false
            // Discovery must remain usable when the hand-entered interpreter is invalid.
            let selected = base.fixedEntryPythonPath
            base.fixedEntryPythonPath = nil
            try base.validateForConnection()
            let identity = SetupDiagnostics.identityReadiness(base)
            guard identity.state != .failed else { throw RemoteInspectionError(message: identity.message) }
            base.fixedEntryPythonPath = selected.flatMap { RemoteInspection.validPath($0) ? $0 : nil }
            let result = try await self.inspection.remote(base, command: Self.command(base), timeout: 22,
                                                         limit: Self.outputLimit)
            if result.timedOut || result.exitCode == 255 {
                throw RemoteInspectionError(message: SSHFailure.classify(result.stderr, timedOut: result.timedOut).message)
            }
            return try Self.parse(result)
        }
    }

    private struct Response: Decodable {
        struct Candidate: Decodable { let path: String; let version: [Int] }
        let version: Int
        let candidates: [Candidate]
        let partial: Bool
        let checked: Int
    }

    static func parse(_ result: CommandResult) throws -> RemotePythonDiscoveryResult {
        guard result.exitCode == 0, !result.timedOut, !result.stdoutTruncated,
              result.stdout.utf8.count <= outputLimit, result.stdout.hasSuffix("\n") else {
            throw RemoteInspectionError(message: "无法完成 Python 查找；请检查 SSH 环境，或手动填写已有解释器路径。")
        }
        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.filter({ $0 == Substring(marker) }).count == 1,
              let index = lines.firstIndex(of: Substring(marker)), index + 2 == lines.count - 1,
              let value = try? JSONDecoder().decode(Response.self, from: Data(lines[index + 1].utf8)),
              value.version == 1, (0...candidateLimit).contains(value.checked),
              value.candidates.count <= value.checked,
              Set(value.candidates.map(\.path)).count == value.candidates.count,
              value.candidates.allSatisfy({ RemoteInspection.validPath($0.path) && $0.version.count == 3 &&
                  $0.version.allSatisfy({ (0...999).contains($0) }) }) else {
            throw RemoteInspectionError(message: "远端 Python 查找结果无效或不完整；未更改解释器选择。")
        }
        let candidates = value.candidates.map {
            RemotePythonCandidate(path: $0.path, version: $0.version.map(String.init).joined(separator: "."),
                                  isSupported: $0.version[0] == 3 && $0.version[1] >= 9)
        }
        let message: String
        if candidates.isEmpty {
            message = "在已检查的位置未找到可确认的 Python；仍可手动填写已有解释器的绝对路径。"
        } else if !candidates.contains(where: \.isSupported) {
            message = "已找到 Python，但已确认的版本均不满足 3.9+；可手动填写其他已有环境。"
        } else {
            message = "已找到 \(candidates.filter(\.isSupported).count) 个可用解释器；选择后仅填入当前表单，不自动安装或保存。"
        }
        return .init(candidates: candidates, message: message + (value.partial
            ? " 部分候选未完成检查或已达到查找上限，列表可能不完整。" : ""), isPartial: value.partial)
    }

    static func command(_ profile: ServerProfile) throws -> String {
        let selected = profile.fixedEntryPythonPath.flatMap { RemoteInspection.validPath($0) ? $0 : nil } ?? ""
        return ["sh", "-c", discoveryShell, "catunnel-python-discovery", selected, discoveryScript]
            .map(RemoteInspection.quote).joined(separator: " ")
    }

    static let discoveryShell = #"""
printf 'CATUNNEL_PYTHON_DISCOVERY_V1\n'
catunnel_bootstrap=$(command -v python3 2>/dev/null)
case "$catunnel_bootstrap" in /*) [ -x "$catunnel_bootstrap" ] || catunnel_bootstrap='' ;; *) catunnel_bootstrap='' ;; esac
if [ -z "$catunnel_bootstrap" ]; then
    for catunnel_candidate in "$1" /usr/bin/python3 /usr/local/bin/python3 "$HOME/miniconda3/bin/python3" "$HOME/anaconda3/bin/python3" "$HOME/miniforge3/bin/python3" "$HOME/mambaforge/bin/python3" "$HOME/micromamba/bin/python3" "$HOME/.local/bin/python3"; do
        case "$catunnel_candidate" in /*) if [ -f "$catunnel_candidate" ] && [ -x "$catunnel_candidate" ]; then catunnel_bootstrap=$catunnel_candidate; break; fi ;; esac
    done
fi
if [ -z "$catunnel_bootstrap" ] && [ -r "$HOME/.conda/environments.txt" ]; then
    catunnel_bootstrap=$(head -c 65536 "$HOME/.conda/environments.txt" | {
        catunnel_lines=0
        while IFS= read -r catunnel_prefix && [ "$catunnel_lines" -lt 64 ]; do
            catunnel_lines=$((catunnel_lines + 1))
            if [ "${catunnel_prefix#/}" != "$catunnel_prefix" ] && [ -f "$catunnel_prefix/bin/python3" ] && [ -x "$catunnel_prefix/bin/python3" ]; then
                printf '%s' "$catunnel_prefix/bin/python3"
                break
            fi
        done
    }
    )
fi
if [ -z "$catunnel_bootstrap" ]; then
    printf '{"version":1,"candidates":[],"partial":false,"checked":0}\n'
    exit 0
fi
exec "$catunnel_bootstrap" -I -S -B -c "$2" "$1" "$catunnel_bootstrap"
"""#

    static let discoveryScript = #"""
import json, os, select, shutil, subprocess, sys, time
limit = 24
deadline = time.monotonic() + 12.0
paths, identities, candidates = [], set(), []
partial = False
def add(path):
    global partial
    if not path or not path.startswith('/') or len(path.encode('utf-8')) > 4096 or any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in path):
        return
    try:
        info = os.stat(path)
        identity = (info.st_dev, info.st_ino)
        if not os.path.isfile(path) or not os.access(path, os.X_OK) or identity in identities:
            return
        identities.add(identity)
        if len(paths) < limit:
            paths.append(path)
        else:
            partial = True
    except OSError:
        pass
add(sys.argv[1])
add(shutil.which('python3'))
add(sys.argv[2])
for path in ['/usr/bin/python3', '/usr/local/bin/python3', '/opt/homebrew/bin/python3']:
    add(path)
home = os.path.expanduser('~')
for prefix in ['miniconda3', 'anaconda3', 'miniforge3', 'mambaforge', 'micromamba', '.local']:
    add(os.path.join(home, prefix, 'bin', 'python3'))
try:
    with open(os.path.join(home, '.conda', 'environments.txt'), 'rb') as source:
        data = source.read(65537)
    if len(data) > 65536:
        partial = True
    lines = data[:65536].decode('utf-8', 'replace').splitlines()
    if len(lines) > 64:
        partial = True
    for prefix in lines[:64]:
        if prefix.startswith('/'):
            add(os.path.join(prefix, 'bin', 'python3'))
except OSError:
    pass
def probe(path, budget):
    process = None
    try:
        process = subprocess.Popen([path, '-I', '-S', '-B', '-c', 'import json,sys;print(json.dumps(list(sys.version_info[:3])))'],
                                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        end = time.monotonic() + budget
        output = b''
        while True:
            remaining = end - time.monotonic()
            if remaining <= 0 or not select.select([process.stdout], [], [], remaining)[0]:
                return None
            chunk = os.read(process.stdout.fileno(), 1025 - len(output))
            if not chunk:
                break
            output += chunk
            if len(output) > 1024:
                return None
        if process.wait(timeout=max(0.01, end - time.monotonic())) != 0:
            return None
        version = json.loads(output.decode('utf-8'))
        if type(version) is list and len(version) == 3 and all(type(x) is int and 0 <= x <= 999 for x in version):
            return version
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None
    finally:
        if process is not None:
            if process.poll() is None:
                process.kill()
            process.wait()
            process.stdout.close()
    return None
checked = 0
for path in paths:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        partial = True
        break
    checked += 1
    version = probe(path, min(1.5, remaining))
    if version is None:
        partial = True
    else:
        candidates.append({'path': path, 'version': version})
print(json.dumps({'version': 1, 'candidates': candidates, 'partial': partial, 'checked': checked}))
"""#
}
