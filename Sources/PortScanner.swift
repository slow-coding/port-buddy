//  TCP listening sockets, read from `lsof` and joined with the process that
//  owns each one: its command line, its working directory and the path of the
//  executable, which is what turns "python3.14" into "shop-web".
//
//  Runs as the logged-in user on purpose: whatever this user cannot see is not
//  listed, and whatever this user cannot signal is marked instead of offered.

import Darwin
import Foundation

struct PortEntry: Hashable {
    let pid: pid_t
    let command: String
    let argv: String
    let uid: uid_t
    let path: String
    let cwd: String
    let startedAt: Date?
    let port: Int
    let hosts: Set<String>

    var isOwn: Bool { uid == getuid() }

    /// Apple's daemons (ControlCenter, rapportd, mDNSResponder …) also listen
    /// as the logged-in user, so uid alone cannot tell "my dev server" from
    /// "the system". Their binaries live in the read-only system trees.
    var isSystem: Bool {
        guard isOwn else { return true }
        guard !path.isEmpty else { return false }
        let roots = ["/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/sbin/", "/bin/"]
        return roots.contains { path.hasPrefix($0) }
    }

    var canKill: Bool { isOwn && !isSystem && pid != getpid() }

    var hostSummary: String { hosts.sorted().joined(separator: ", ") }

    /// How long the process has been up; nil when the system would not say.
    var uptime: TimeInterval? {
        guard let startedAt else { return nil }
        return Date().timeIntervalSince(startedAt)
    }

    /// Name of the app bundle a process lives in, if any:
    /// "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" →
    /// "Google Chrome".
    var appName: String {
        guard let marker = path.range(of: ".app/") else { return "" }
        return String(path[path.startIndex..<marker.lowerBound].split(separator: "/").last ?? "")
    }

    /// Project folder a process was started from:
    /// "/Users/you/code/acme-webapp" → "acme-webapp".
    ///
    /// A dev server inherits the directory it was launched in, which is the
    /// only place "which project is this" is written down. Directories that
    /// say nothing (home, /, temp) are dropped so the caller falls back to the
    /// binary name instead of printing "tmp" for every scratch server.
    var projectName: String {
        guard !cwd.isEmpty, let folder = cwd.split(separator: "/").last else { return "" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let silent = ["/", "/private/tmp", "/tmp", "/var/tmp", "/private/var/tmp", home, home + "/code"]
        guard !silent.contains(cwd) else { return "" }
        return String(folder)
    }

    /// What a row shows: the app, else the project folder, else the binary.
    var displayName: String {
        if !appName.isEmpty { return appName }
        if !projectName.isEmpty { return projectName }
        return command
    }

    func adding(argv: String, cwd: String, startedAt: Date?) -> PortEntry {
        PortEntry(pid: pid, command: command, argv: argv, uid: uid, path: path,
                  cwd: cwd, startedAt: startedAt, port: port, hosts: hosts)
    }
}

enum PortScanner {

    static func scan() -> [PortEntry] {
        var entries = parse(lsofOutput())
        let pids = Set(entries.map { $0.pid })
        let argv = commandLines(for: pids)
        var cwds: [pid_t: String] = [:]
        var starts: [pid_t: Date?] = [:]
        entries = entries.map { entry in
            let cwd: String
            if let cached = cwds[entry.pid] {
                cwd = cached
            } else {
                cwd = workingDirectory(of: entry.pid)
                cwds[entry.pid] = cwd
            }
            let started: Date?
            if let cached = starts[entry.pid] {
                started = cached
            } else {
                started = startTime(of: entry.pid)
                starts[entry.pid] = started
            }
            return entry.adding(argv: argv[entry.pid] ?? "", cwd: cwd, startedAt: started)
        }
        return sort(entries)
    }

    /// Longest running first, then by port. The server started three days ago
    /// is the one you forgot about; the one from a minute ago is usually the
    /// one you are still working with, so both ends of the list mean
    /// something.
    static func sort(_ items: [PortEntry]) -> [PortEntry] {
        items.sorted { a, b in
            if a.isSystem != b.isSystem { return !a.isSystem }
            switch (a.startedAt, b.startedAt) {
            case let (first?, second?) where first != second:
                return first < second          // earlier start = longer uptime
            case (nil, .some), (.some, nil):
                return a.startedAt != nil      // unknown start goes last
            default:
                break
            }
            if a.port != b.port { return a.port < b.port }
            return a.command.localizedStandardCompare(b.command) == .orderedAscending
        }
    }

    // MARK: - lsof

    private static func lsofOutput() -> String {
        run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcun"])
    }

    /// lsof `-F` output is one field per line: p = pid, c = command,
    /// u = uid, n = socket name. A socket name carries the port after the
    /// last colon; the same port shows up twice when it is bound on IPv4
    /// and IPv6, and both rows collapse into one entry.
    static func parse(_ text: String) -> [PortEntry] {
        struct ProcessInfo { var command = ""; var uid: uid_t = 0 }
        struct Socket { let pid: pid_t; let port: Int; var hosts: Set<String> }

        var processes: [pid_t: ProcessInfo] = [:]
        var sockets: [String: Socket] = [:]
        var current: pid_t?

        for line in text.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                guard let pid = pid_t(value) else { break }
                current = pid
                if processes[pid] == nil { processes[pid] = ProcessInfo() }
            case "c":
                if let pid = current { processes[pid]?.command = value }
            case "u":
                if let pid = current, let uid = uid_t(value) { processes[pid]?.uid = uid }
            case "n":
                guard let pid = current, let socket = split(value) else { break }
                let key = "\(pid):\(socket.port)"
                if sockets[key] != nil {
                    sockets[key]?.hosts.insert(socket.host)
                } else {
                    sockets[key] = Socket(pid: pid, port: socket.port, hosts: [socket.host])
                }
            default:
                break
            }
        }

        var paths: [pid_t: String] = [:]
        return sockets.values.map { socket in
            let info = processes[socket.pid] ?? ProcessInfo()
            let path: String
            if let cached = paths[socket.pid] {
                path = cached
            } else {
                path = executablePath(of: socket.pid)
                paths[socket.pid] = path
            }
            return PortEntry(pid: socket.pid, command: info.command, argv: "", uid: info.uid,
                             path: path, cwd: "", startedAt: nil, port: socket.port, hosts: socket.hosts)
        }
    }

    /// "127.0.0.1:8042" / "*:49152" / "[::1]:631" → (host, port)
    private static func split(_ name: String) -> (host: String, port: Int)? {
        guard let colon = name.lastIndex(of: ":") else { return nil }
        let host = String(name[name.startIndex..<colon])
        guard let port = Int(name[name.index(after: colon)...]) else { return nil }
        return (host.isEmpty ? "*" : host, port)
    }

    // MARK: - Per-process detail

    private static func commandLines(for pids: Set<pid_t>) -> [pid_t: String] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).sorted().joined(separator: ",")
        let output = run("/bin/ps", ["-o", "pid=,command=", "-p", list])
        var commands: [pid_t: String] = [:]
        for line in output.split(separator: "\n") {
            let trimmed = line.drop { $0 == " " }
            guard let space = trimmed.firstIndex(of: " "), let pid = pid_t(trimmed[..<space]) else { continue }
            commands[pid] = String(trimmed[trimmed.index(after: space)...])
        }
        return commands
    }

    /// Absolute path of the running executable. Empty for processes this user
    /// may not inspect; those are classified as system anyway.
    private static func executablePath(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)  // PROC_PIDPATHINFO_MAXSIZE
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return String(cString: buffer)
    }

    /// When the process was started, straight from libproc.
    private static func startTime(of pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_start_tvsec > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
    }

    /// Working directory of the process, straight from libproc.
    private static func workingDirectory(of pid: pid_t) -> String {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return "" }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { buffer in
            guard let base = buffer.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }
        // Drain first, wait after: reading only after waitUntilExit deadlocks
        // as soon as the tool fills the pipe buffer on a busy machine.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
