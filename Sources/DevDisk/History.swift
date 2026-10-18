import Foundation

struct GoneItem: Codable {
    var path: String
    var displayPath: String
    var bytes: Int64
}

/// ~/disk-report/sizes.csv: one row per item per scan. Read before scanning, appended after.
enum History {
    static let dir = URL(fileURLWithPath: home).appendingPathComponent("disk-report")
    static let csvURL = dir.appendingPathComponent("sizes.csv")
    static let header = "scanned_at,path,group,kind,bytes\n"

    struct Snapshot {
        /// Most recent size seen for each path, from any earlier scan.
        var latest: [String: Int64] = [:]
        var previousScanAt: String?
        var lastScanItems: [GoneItem] = []
    }

    static func load() -> Snapshot {
        var snap = Snapshot()
        guard let text = try? String(contentsOf: csvURL, encoding: .utf8) else { return snap }
        var rowsByScan: [String: [(String, Int64)]] = [:]
        for line in text.split(separator: "\n").dropFirst() {
            let f = parseCSVLine(String(line))
            guard f.count >= 5, let bytes = Int64(f[4]) else { continue }
            snap.latest[f[1]] = bytes   // rows are chronological, so later rows win
            rowsByScan[f[0], default: []].append((f[1], bytes))
            if snap.previousScanAt.map({ f[0] > $0 }) ?? true { snap.previousScanAt = f[0] }
        }
        if let last = snap.previousScanAt {
            snap.lastScanItems = (rowsByScan[last] ?? []).map {
                GoneItem(path: $0.0, displayPath: $0.0.hasPrefix("/") ? tilde($0.0) : $0.0, bytes: $0.1)
            }
        }
        return snap
    }

    static func append(items: [ScanItem], scannedAt: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: csvURL.path) {
            try? header.write(to: csvURL, atomically: true, encoding: .utf8)
        }
        let rows = items.map { [scannedAt, $0.path, $0.group.rawValue, $0.kind.rawValue, String($0.bytes)].map(csvField).joined(separator: ",") }
        guard !rows.isEmpty, let handle = try? FileHandle(forWritingTo: csvURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((rows.joined(separator: "\n") + "\n").utf8))
    }

    private static func csvField(_ s: String) -> String {
        s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    private static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var cur = ""
        var quoted = false
        var it = line.makeIterator()
        while let c = it.next() {
            if quoted {
                if c == "\"" {
                    // Peek: doubled quote is a literal quote.
                    if let n = it.next() {
                        if n == "\"" { cur.append("\"") } else { quoted = false; if n == "," { fields.append(cur); cur = "" } else { cur.append(n) } }
                    } else { quoted = false }
                } else { cur.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == "," { fields.append(cur); cur = "" }
            else { cur.append(c) }
        }
        fields.append(cur)
        return fields
    }
}
