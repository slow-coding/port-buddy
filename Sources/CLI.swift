//  Command line surface: `--json` for scripting, `--kill <port>` and
//  `--kill-all` for the same signals the buttons send. Same rules as the
//  GUI: nothing that belongs to the system or to another user is touched.

import Darwin
import Foundation

enum CLI {
    /// Returns an exit code for a command-line run, or nil when the app
    /// should start normally.
    static func run(_ arguments: [String]) -> Int32? {
        let args = Array(arguments.dropFirst())
        guard !args.isEmpty else { return nil }

        if args.contains("--help") || args.contains("-h") { printHelp(); return 0 }
        if args.contains("--version") { print("\(AppInfo.name) \(AppInfo.version)"); return 0 }
        if args.contains("--json") { printJSON(); return 0 }

        if let index = args.firstIndex(of: "--kill"), index + 1 < args.count {
            return terminate(target: args[index + 1], force: args.contains("--force"))
        }
        if args.contains("--kill-all") {
            return terminateAll(dryRun: args.contains("--dry-run"))
        }

        let guiFlags = ["--show", "--appearance", "--selftest-click", "--selftest-filter",
                        "--debug-frame", "--arm", "--filter", "--settings", "--hotkey"]
        if args.contains(where: { guiFlags.contains($0) }) { return nil }

        FileHandle.standardError.write(Data("\(AppInfo.name): unknown argument \(args[0])\n".utf8))
        return 2
    }

    // MARK: - Commands

    private static func printJSON() {
        for entry in PortScanner.scan() {
            let fields = [
                "\"port\":\(entry.port)",
                "\"pid\":\(entry.pid)",
                "\"name\":\(quote(entry.displayName))",
                "\"command\":\(quote(entry.command))",
                "\"argv\":\(quote(entry.argv))",
                "\"cwd\":\(quote(entry.cwd))",
                "\"path\":\(quote(entry.path))",
                "\"uid\":\(entry.uid)",
                "\"system\":\(entry.isSystem)",
                "\"started\":\(entry.startedAt.map { Int($0.timeIntervalSince1970) } ?? 0)",
                "\"uptime\":\(entry.uptime.map { Int($0) } ?? 0)",
                "\"hosts\":[\(entry.hosts.sorted().map(quote).joined(separator: ","))]",
            ]
            print("{\(fields.joined(separator: ","))}")
        }
    }

    private static func terminate(target: String, force: Bool) -> Int32 {
        guard let value = Int(target) else {
            FileHandle.standardError.write(Data("\(AppInfo.name): --kill needs a port or pid\n".utf8))
            return 2
        }
        let all = PortScanner.scan()
        var hits = all.filter { $0.port == value }
        if hits.isEmpty { hits = all.filter { $0.pid == pid_t(value) } }
        guard !hits.isEmpty else {
            print("nothing is listening on port \(value)")
            return 1
        }

        var code: Int32 = 0
        for hit in hits {
            guard hit.canKill else {
                print("skipped \(hit.command) (pid \(hit.pid)) on :\(hit.port) — \(hit.isSystem ? "system process" : "owned by another user")")
                code = 1
                continue
            }
            if Darwin.kill(hit.pid, force ? SIGKILL : SIGTERM) == 0 {
                print("terminated \(hit.command) (pid \(hit.pid)) on :\(hit.port)")
            } else {
                print("failed to terminate \(hit.command) (pid \(hit.pid)): \(String(cString: strerror(errno)))")
                code = 1
            }
        }
        return code
    }

    private static func terminateAll(dryRun: Bool) -> Int32 {
        let targets = PortScanner.scan().filter { $0.canKill }
        guard !targets.isEmpty else {
            print("nothing to terminate")
            return 0
        }
        for target in targets {
            if dryRun {
                print("would terminate \(target.command) (pid \(target.pid)) on :\(target.port)")
            } else if Darwin.kill(target.pid, SIGTERM) == 0 {
                print("terminated \(target.command) (pid \(target.pid)) on :\(target.port)")
            }
        }
        return 0
    }

    private static func printHelp() {
        print("""
        \(AppInfo.name) \(AppInfo.version) — TCP listening ports in the menu bar

        Usage:
          PortBuddy                     start the menu bar app
          PortBuddy --json              one JSON object per listening socket
          PortBuddy --kill <port|pid>   terminate the process owning that socket
          PortBuddy --kill <port> --force   send SIGKILL instead of SIGTERM
          PortBuddy --kill-all          terminate every listening process of yours
          PortBuddy --kill-all --dry-run    list what would be terminated
          PortBuddy --version           print the version

        Options for the app itself:
          --show                open the panel on launch
          --appearance <light|dark>   force an appearance
        """)
    }

    private static func quote(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
