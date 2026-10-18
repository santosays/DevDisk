import Foundation
import Darwin

struct ScanItem: Codable {
    var id: String
    var path: String
    var displayPath: String
    var bytes: Int64
    var group: Group
    var kind: Kind
    var label: String
    var effect: String
    var command: String?
    var prevBytes: Int64?
    var grew = false
    var isNew = false
}

struct Skipped: Codable {
    var path: String
    var reason: String
}

struct ScanResult: Codable {
    var scannedAt: String
    var previousScanAt: String?
    var durationMs: Int
    var home: String
    var minBytes: Int64
    var hiddenSmall: Int
    var items: [ScanItem]
    var gone: [GoneItem]
    var skipped: [Skipped]
    var notes: [String]
    var csvPath: String
}

/// Read-only, metadata-only scanner. It lists directories and stats entries; it never opens a file.
final class Scanner {
    static let minBytes: Int64 = 10_000_000

    var scanProtected = false
    var recordHistory = true
    var onProgress: ((String, Int) -> Void)?

    private var skipped: [Skipped] = []
    private var notes: [String] = []
    private var lastProgress = Date.distantPast

    func run() -> ScanResult {
        let start = Date()
        let history = History.load()
        var candidates: [(path: String, label: String, kind: Kind, group: Group, effect: String, command: String?)] = []

        // 1. Fixed locations: caches, toolchains, models, sessions, VMs.
        for rule in Rules.globals {
            let full = home + "/" + rule.path
            guard isRealDirectory(full) else { continue }
            if let perChild = rule.perChild {
                for child in listDirs(full) {
                    let (label, cmd) = perChild(child)
                    candidates.append((full + "/" + child, label, rule.kind, rule.group, rule.effect, cmd))
                }
            } else if rule.path == ".ollama/models" {
                let models = ollamaModels(full)
                let cmd = models.isEmpty ? nil : models.map { "ollama rm \(shq($0))" }.joined(separator: "\n")
                let effect = models.isEmpty ? rule.effect : rule.effect + " Models: " + models.joined(separator: ", ") + "."
                candidates.append((full, rule.label, rule.kind, rule.group, effect, cmd))
            } else if rule.path == "Library/Developer/CoreSimulator/Devices" {
                // One item per simulator, named via simctl (the folders are UUIDs).
                let devices = simulators()
                for child in listDirs(full) {
                    if let d = devices[child] {
                        if d.available {
                            candidates.append((full + "/" + child, "Simulator · \(d.name) (\(d.runtime))", rule.kind, rule.group, rule.effect,
                                               "xcrun simctl shutdown \(child) 2>/dev/null; xcrun simctl erase \(child)"))
                        } else {
                            candidates.append((full + "/" + child, "Simulator · \(d.name) (\(d.runtime), not installed)", rule.kind, .safe,
                                               "Deletes this simulator. Its iOS version is no longer installed, so Xcode can't run it anyway.",
                                               "xcrun simctl delete \(child)"))
                        }
                    } else {
                        candidates.append((full + "/" + child, "Simulator · unknown \(child.prefix(8))", rule.kind, rule.group,
                                           "A simulator folder Xcode no longer lists. Safe to move to the Trash once Xcode is closed.", nil))
                    }
                }
            } else if rule.path == ".cache/huggingface/hub" {
                // One item per cached repo (models--org--name → model/org/name). Anything else at the
                // root belongs to no repo, so hf can't remove it.
                let types = ["models--": "model", "datasets--": "dataset", "spaces--": "space"]
                for child in listDirs(full) {
                    if let (prefix, type) = types.first(where: { child.hasPrefix($0.key) }) {
                        let repo = child.dropFirst(prefix.count).replacingOccurrences(of: "--", with: "/")
                        candidates.append((full + "/" + child, "\(rule.label) · \(repo)", rule.kind, rule.group,
                                           rule.effect, "hf cache rm -y \(shq("\(type)/\(repo)"))"))
                    } else {
                        candidates.append((full + "/" + child, "\(rule.label) · loose \(child)/", rule.kind, rule.group,
                                           "Files at the cache root that belong to no cached model, likely left by an older diffusers or huggingface_hub. `hf cache rm` can't target them, so DevDisk moves them to the Trash. Nothing that's still cached by `hf` breaks.", nil))
                    }
                }
            } else {
                candidates.append((full, rule.label, rule.kind, rule.group, rule.effect, rule.command))
            }
        }

        // 2. Walk the home folder for project build output and dependencies.
        for (path, rule) in walkProjects() {
            let parent = (path as NSString).deletingLastPathComponent
            let label = "\(rule.label) · \((parent as NSString).lastPathComponent)"
            candidates.append((path, label, rule.kind, rule.group, rule.effect, rule.command?(path, parent)))
        }

        // 3. Size everything in parallel.
        report("Measuring \(candidates.count) folders…", candidates.count, force: true)
        var sizes = [Int64](repeating: 0, count: candidates.count)
        sizes.withUnsafeMutableBufferPointer { buf in
            let base = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: candidates.count) { i in
                base[i] = allocatedSize(candidates[i].path)
            }
        }

        var items: [ScanItem] = []
        var hidden = 0
        for (i, c) in candidates.enumerated() {
            // A fresh simulator is ~20 MB on its own; only list ones holding real app data.
            let floor = c.path.contains("/CoreSimulator/Devices/") ? 100_000_000 : Self.minBytes
            guard sizes[i] >= floor else { hidden += 1; continue }
            var item = ScanItem(id: c.path, path: c.path, displayPath: tilde(c.path), bytes: sizes[i],
                                group: c.group, kind: c.kind, label: c.label, effect: c.effect, command: c.command)
            if let prev = history.latest[c.path] {
                item.prevBytes = prev
                let delta = sizes[i] - prev
                item.grew = delta >= 10_000_000 && Double(delta) >= Double(prev) * 0.02
            } else if history.previousScanAt != nil {
                item.isNew = true
            }
            items.append(item)
        }

        // 4. Docker Desktop keeps its disk in an app container that would trigger a prompt; ask its CLI instead.
        items += dockerItems(history: history)

        items.sort { $0.bytes > $1.bytes }
        let currentPaths = Set(items.map(\.path))
        let gone = history.lastScanItems.filter { !currentPaths.contains($0.path) }

        let scannedAt = ISO8601DateFormatter().string(from: Date())
        if recordHistory { History.append(items: items, scannedAt: scannedAt) }

        return ScanResult(scannedAt: scannedAt, previousScanAt: history.previousScanAt,
                          durationMs: Int(Date().timeIntervalSince(start) * 1000), home: home,
                          minBytes: Self.minBytes, hiddenSmall: hidden, items: items, gone: gone,
                          skipped: skipped, notes: notes, csvPath: tilde(History.csvURL.path))
    }

    // MARK: - Walk

    private func walkProjects() -> [(String, ProjectRule)] {
        var found: [(String, ProjectRule)] = []
        var roots: [String] = []
        for name in listDirs(home) {
            if Rules.skipTopLevel.contains(name) { continue }
            if Rules.cloudPrefixes.contains(where: { name.hasPrefix($0) }) {
                skipped.append(.init(path: "~/" + name, reason: "Cloud-synced folder"))
                continue
            }
            if Rules.protectedFolders.contains(name) && !scanProtected {
                skipped.append(.init(path: "~/" + name, reason: "Protected by macOS. Turn it on in Settings to scan it"))
                continue
            }
            roots.append(home + "/" + name)
        }
        skipped.append(.init(path: "~/Library/Mobile Documents, ~/Library/CloudStorage", reason: "iCloud and cloud storage"))
        skipped.append(.init(path: "~/Pictures (Photos library)", reason: "Photos library"))
        skipped.append(.init(path: "~/Library/Containers, Group Containers, Mail, Messages, Safari…", reason: "Would trigger a macOS permission prompt"))
        skipped.append(.init(path: "/Volumes/*", reason: "External drives (the scan never leaves the home volume)"))

        for root in roots {
            fts(root) { ent, fts in
                let info = Int32(ent.pointee.fts_info)
                let path = String(cString: ent.pointee.fts_path)
                let name = (path as NSString).lastPathComponent
                switch info {
                case FTS_D:
                    if ent.pointee.fts_level > 12 || name == ".git" || name == ".Trash"
                        || name.hasSuffix(".photoslibrary") || name.hasSuffix(".photolibrary") {
                        fts_set(fts, ent, FTS_SKIP); return
                    }
                    self.report(path, found.count)
                    if let rule = self.match(path: path, name: name) {
                        found.append((path, rule))
                        fts_set(fts, ent, FTS_SKIP)
                    }
                case FTS_DNR, FTS_ERR:
                    let err = ent.pointee.fts_errno
                    if (err == EPERM || err == EACCES) && self.skipped.count < 200 {
                        self.skipped.append(.init(path: tilde(path), reason: "macOS denied access"))
                    }
                default: break
                }
            }
        }
        return found
    }

    private func match(path: String, name: String) -> ProjectRule? {
        let fm = FileManager.default
        let parent = (path as NSString).deletingLastPathComponent
        for rule in Rules.projectRules where rule.names.contains(name) {
            if !rule.parentMarkers.isEmpty && !rule.parentMarkers.contains(where: { fm.fileExists(atPath: parent + "/" + $0) }) { continue }
            if !rule.innerMarkers.isEmpty && !rule.innerMarkers.contains(where: { fm.fileExists(atPath: path + "/" + $0) }) { continue }
            return rule
        }
        return nil
    }

    // MARK: - Sizes

    /// Allocated bytes on disk under `path`, from stat only. Stays on one volume, never follows symlinks.
    func allocatedSize(_ path: String) -> Int64 {
        var total: Int64 = 0
        var seenInodes = Set<UInt64>()
        fts(path) { ent, _ in
            let info = Int32(ent.pointee.fts_info)
            guard info == FTS_F || info == FTS_DP || info == FTS_SL || info == FTS_SLNONE || info == FTS_DEFAULT,
                  let st = ent.pointee.fts_statp?.pointee else { return }
            if st.st_nlink > 1 && info == FTS_F && !seenInodes.insert(st.st_ino).inserted { return }
            total += Int64(st.st_blocks) * 512
        }
        return total
    }

    private func fts(_ root: String, _ body: (UnsafeMutablePointer<FTSENT>, UnsafeMutablePointer<FTS>) -> Void) {
        guard let cRoot = strdup(root) else { return }
        defer { free(cRoot) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cRoot, nil]
        guard let handle = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return }
        defer { fts_close(handle) }
        while let ent = fts_read(handle) { body(ent, handle) }
    }

    // MARK: - Helpers

    private func isRealDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    private func listDirs(_ path: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return names.filter { !$0.hasPrefix(".") && isRealDirectory(path + "/" + $0) }.sorted()
    }

    /// Model names come from the manifest folder layout (host/namespace/model/tag), not from file contents.
    private func ollamaModels(_ modelsDir: String) -> [String] {
        let manifests = modelsDir + "/manifests"
        var names: [String] = []
        for host in listDirs(manifests) {
            for ns in listDirs(manifests + "/" + host) {
                for model in listDirs(manifests + "/" + host + "/" + ns) {
                    let tags = (try? FileManager.default.contentsOfDirectory(atPath: [manifests, host, ns, model].joined(separator: "/"))) ?? []
                    for tag in tags where !tag.hasPrefix(".") {
                        let base = ns == "library" ? model : "\(ns)/\(model)"
                        names.append(host == "registry.ollama.ai" ? "\(base):\(tag)" : "\(host)/\(base):\(tag)")
                    }
                }
            }
        }
        return names.sorted()
    }

    private func dockerItems(history: History.Snapshot) -> [ScanItem] {
        let candidates = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", home + "/.docker/bin/docker",
                          "/Applications/Docker.app/Contents/Resources/bin/docker"]
        let hasDesktop = FileManager.default.fileExists(atPath: "/Applications/Docker.app")
        guard let bin = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            if hasDesktop { notes.append("Docker Desktop is installed but its CLI wasn't found, so its disk image wasn't measured.") }
            return []
        }
        report("Asking Docker for its disk usage…", 0, force: true)
        guard let out = runTool(bin, ["system", "df", "--format", "{{json .}}"], timeout: 15) else {
            notes.append("Docker didn't answer (is it running?), so images, containers and volumes weren't measured.")
            return []
        }
        let map: [String: (String, String, String)] = [
            "Images": ("Docker images", "docker image prune -a -f", "Deletes every image no container uses. They're pulled or rebuilt when next needed."),
            "Containers": ("Docker stopped containers", "docker container prune -f", "Deletes stopped containers and anything written inside them."),
            "Local Volumes": ("Docker volumes", "docker volume prune -a -f", "Deletes volumes no container uses, including database data stored in them. Data loss is permanent."),
            "Build Cache": ("Docker build cache", "docker builder prune -a -f", "Deletes BuildKit cache. The next image builds start from scratch."),
        ]
        var items: [ScanItem] = []
        for line in out.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = obj["Type"] as? String, let (label, cmd, effect) = map[type],
                  let total = parseDockerSize(obj["Size"] as? String ?? "") else { continue }
            // prune only frees what nothing uses ("1.2GB (45%)"), so that's the size to show.
            let reclaimText = (obj["Reclaimable"] as? String ?? "").split(separator: " ").first.map(String.init) ?? ""
            let bytes = parseDockerSize(reclaimText) ?? total
            guard bytes >= Self.minBytes else { continue }
            let reclaim = bytes < total ? " The rest of the \(fmtBytes(total)) is in use and stays." : ""
            let id = "docker:" + type
            var item = ScanItem(id: id, path: id, displayPath: "Docker · \(type)", bytes: bytes, group: .review,
                                kind: .docker, label: label, effect: effect + reclaim, command: cmd)
            if let prev = history.latest[id] {
                item.prevBytes = prev
                item.grew = bytes - prev >= 10_000_000
            }
            items.append(item)
        }
        return items
    }

    private func parseDockerSize(_ s: String) -> Int64? {
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (u, m) in units where s.hasSuffix(u) {
            return Double(s.dropLast(u.count)).map { Int64($0 * m) }
        }
        return nil
    }

    /// UDID → name/runtime/availability, from `simctl list` (reads Xcode's own registry, not the folders).
    private func simulators() -> [String: (name: String, runtime: String, available: Bool)] {
        guard let out = runTool("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"], timeout: 20),
              let json = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let byRuntime = json["devices"] as? [String: [[String: Any]]] else { return [:] }
        var map: [String: (String, String, Bool)] = [:]
        for (rt, list) in byRuntime {
            // com.apple.CoreSimulator.SimRuntime.iOS-26-0 → iOS 26.0
            let parts = (rt.split(separator: ".").last ?? "").split(separator: "-")
            let runtime = parts.isEmpty ? rt : parts[0] + " " + parts.dropFirst().joined(separator: ".")
            for d in list {
                guard let udid = d["udid"] as? String, let name = d["name"] as? String else { continue }
                map[udid] = (name, runtime, d["isAvailable"] as? Bool ?? true)
            }
        }
        return map
    }

    private func runTool(_ bin: String, _ args: [String], timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(100_000) }
        if p.isRunning { p.terminate(); return nil }
        guard p.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    private func report(_ message: String, _ count: Int, force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastProgress) > 0.08 else { return }
        lastProgress = now
        onProgress?(tilde(message), count)
    }
}

func tilde(_ path: String) -> String {
    path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}
