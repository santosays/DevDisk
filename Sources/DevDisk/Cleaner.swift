import Foundation

/// Runs the cleanup the user confirmed in the UI: each item's own clean command, or Move to Trash
/// when the tool has none. Commands only ever come from the scanner's rules, never from the page.
final class Cleaner {
    private let emit: ([String: Any]) -> Void
    private let lock = NSLock()
    private var cancelled = false
    private var current: Process?
    private var log = ""

    /// Used when a tool is only installed inside a project venv.
    private static let prelude = #"(( $+commands[hf] )) || hf() { uvx --from huggingface_hub hf "$@" }"#

    init(emit: @escaping ([String: Any]) -> Void) { self.emit = emit }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let p = current, p.isRunning {
            // zsh may have spawned children (subshells, &&); stop them too.
            _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/pkill"), arguments: ["-TERM", "-P", String(p.processIdentifier)])
            p.terminate()
        }
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func run(_ items: [ScanItem]) {
        let start = Date()
        let stamp = ISO8601DateFormatter().string(from: start)
        write("DevDisk cleanup started \(stamp)\n\(items.count) items\n")
        let path = Self.userPATH()
        var done = Set<String>()
        var freed: Int64 = 0, trashed: Int64 = 0
        var counts: [String: Int] = [:]

        for (idx, item) in items.enumerated() {
            if isCancelled {
                for j in idx..<items.count { step(j, "notRun", message: "Not run (stopped)") }
                counts["notRun", default: 0] += items.count - idx
                write("\nStopped by user. \(items.count - idx) items not run.\n")
                break
            }
            step(idx, "running")
            write("\n==> \(item.label) (\(fmtBytes(item.bytes)))\n    \(item.displayPath)\n")

            if let command = item.command {
                let measuredBefore = item.measure.map { Scanner().allocatedSize($0) }
                let cmds = command.split(separator: "\n").map(String.init).filter { !done.contains($0) }
                var status = "done", message = ""
                if cmds.isEmpty { message = "Already handled by an earlier step" }
                for c in cmds {
                    write("$ \(c)\n", idx)
                    let code = shell(c, path: path, idx: idx)
                    done.insert(c)
                    if isCancelled { status = "stopped"; message = "Stopped"; break }
                    if code == 127 { status = "missing"; message = "Command not found. Is the tool installed?"; break }
                    if code != 0 { status = "failed"; message = "Exited with code \(code)"; break }
                }
                var gained: Int64 = 0
                let measured = item.measure ?? (item.path.hasPrefix("/") ? item.path : nil)
                if let measured {
                    let after = FileManager.default.fileExists(atPath: measured) ? Scanner().allocatedSize(measured) : 0
                    gained = max(0, (measuredBefore ?? item.bytes) - after)
                    freed += gained
                    // The tool succeeded but left the folder as it was: say so instead of a bare "done".
                    if status == "done" && !cmds.isEmpty && gained < 1_000_000 {
                        status = "nothing"; message = "Ran fine, but there was nothing for it to remove"
                    }
                }
                write("    → \(status)\(message.isEmpty ? "" : ": \(message)")\(gained > 0 ? ", freed \(fmtBytes(gained))" : "")\n")
                step(idx, status, freed: gained, message: message)
                counts[status, default: 0] += 1
            } else {
                // No clean command: Move to Trash, so it can still be put back.
                let url = URL(fileURLWithPath: item.path)
                guard item.path.hasPrefix(home + "/"), FileManager.default.fileExists(atPath: item.path) else {
                    write("    → skipped: no longer exists\n")
                    step(idx, "skipped", message: "No longer exists")
                    counts["skipped", default: 0] += 1
                    continue
                }
                write("$ mv \(Self.tildeQuoted(item.path)) ~/.Trash/\n", idx)
                do {
                    var inTrash: NSURL?
                    try FileManager.default.trashItem(at: url, resultingItemURL: &inTrash)
                    // The Trash renames on a clash ("sdk 2"), so say exactly where to find it.
                    let whereTo = (inTrash as URL?).map { tilde($0.path) } ?? "~/.Trash"
                    write("Moved to \(whereTo). To undo, drag it out of the Trash.\n", idx)
                    trashed += item.bytes
                    write("    → moved to Trash (\(fmtBytes(item.bytes)) frees up when you empty the Trash)\n")
                    step(idx, "trashed", freed: item.bytes, message: "Moved to Trash")
                    counts["trashed", default: 0] += 1
                } catch {
                    write("    → failed: \(error.localizedDescription)\n")
                    step(idx, "failed", message: error.localizedDescription)
                    counts["failed", default: 0] += 1
                }
            }
        }

        let secs = Int(Date().timeIntervalSince(start))
        write("\nFinished in \(secs)s. Freed \(fmtBytes(freed)). Moved \(fmtBytes(trashed)) to Trash.\n")
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let logURL = History.dir.appendingPathComponent("cleanup-\(fmt.string(from: start)).log")
        try? FileManager.default.createDirectory(at: History.dir, withIntermediateDirectories: true)
        try? log.write(to: logURL, atomically: true, encoding: .utf8)
        emit(["type": "cleanDone", "freed": freed, "trashed": trashed, "counts": counts, "seconds": secs,
              "stopped": isCancelled, "logPath": logURL.path, "logDisplay": tilde(logURL.path)])
    }

    /// Runs one command non-interactively (stdin is /dev/null, so nothing can hang on a prompt)
    /// and streams its output to the log as it arrives.
    private func shell(_ command: String, path: String, idx: Int) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-f", "-c", Self.prelude + "\n" + command]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"
        p.environment = env
        p.currentDirectoryURL = URL(fileURLWithPath: home)
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if !data.isEmpty { self?.write(String(decoding: data, as: UTF8.self), idx) }
        }
        do {
            lock.lock(); current = p; lock.unlock()
            try p.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            write("Couldn't start: \(error.localizedDescription)\n", idx)
            return 127
        }
        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        let rest = pipe.fileHandleForReading.readDataToEndOfFile()
        if !rest.isEmpty { write(String(decoding: rest, as: UTF8.self), idx) }
        lock.lock(); current = nil; lock.unlock()
        return p.terminationStatus
    }

    /// ~/path, single-quoted only when needed (matches the page's trashCmd()).
    static func tildeQuoted(_ path: String) -> String {
        let display = tilde(path)
        let safe = display.allSatisfy { $0.isLetter || $0.isNumber || "_@%+=:,./-~".contains($0) }
        if safe { return display }
        return display.hasPrefix("~/") ? "~/" + shq(String(display.dropFirst(2))) : shq(display)
    }

    private func write(_ text: String, _ idx: Int? = nil) {
        lock.lock(); log += text; lock.unlock()
        var e: [String: Any] = ["type": "cleanLog", "text": text]
        if let idx { e["idx"] = idx }
        emit(e)
    }

    private func step(_ idx: Int, _ status: String, freed: Int64 = 0, message: String = "") {
        emit(["type": "cleanStep", "idx": idx, "status": status, "freed": freed, "message": message])
    }

    /// Apps opened from Finder get a bare PATH; borrow the one the user's terminal has (brew, nvm, uv…).
    static func userPATH() -> String {
        let fallback = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                        home + "/.local/bin", home + "/.cargo/bin", home + "/go/bin"].joined(separator: ":")
        // Ask the user's own login shell (zsh, bash or fish); printenv works the same in all of them.
        var shell = "/bin/zsh"
        if let pw = getpwuid(getuid()), let s = pw.pointee.pw_shell, FileManager.default.isExecutableFile(atPath: String(cString: s)) {
            shell = String(cString: s)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-i", "-c", "/bin/echo; /bin/echo __DEVDISK_PATH; /usr/bin/printenv PATH"]
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return fallback }
        let deadline = Date().addingTimeInterval(10)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return fallback }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let lines = out.components(separatedBy: "\n")
        guard let i = lines.lastIndex(of: "__DEVDISK_PATH"), i + 1 < lines.count, lines[i + 1].contains("/") else { return fallback }
        return lines[i + 1] + ":" + fallback
    }
}

func fmtBytes(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}
