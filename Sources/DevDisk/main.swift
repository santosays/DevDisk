import AppKit
import WebKit

/// Remembered answer to "scan Desktop, Documents and Downloads?": "ask" | "allow" | "skip".
/// macOS remembers its own grant separately (System Settings › Privacy & Security › Files and Folders).
private let protectedPrefKey = "protectedFolders"

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler {
    private var window: NSWindow!
    private var web: WKWebView!
    private var scanning = false
    private var lastResult: ScanResult?
    private var cleaner: Cleaner?

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "bridge")
        web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1380, height: 920),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "DevDisk"
        window.minSize = NSSize(width: 900, height: 640)
        window.contentView = web
        window.center()
        window.setFrameAutosaveName("DevDiskMain")
        window.makeKeyAndOrderFront(nil)

        let webDir = Self.webDirectory()
        web.loadFileURL(webDir.appendingPathComponent("index.html"), allowingReadAccessTo: webDir)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ note: Notification) { cleaner?.stop() }

    /// Bundled app: Contents/Resources/web. `swift run`: the Web folder next to Sources.
    static func webDirectory() -> URL {
        if let url = Bundle.main.url(forResource: "web", withExtension: nil) { return url }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Web")
    }

    // MARK: - Bridge

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        switch cmd {
        case "ready":
            sendPrefs()
        case "setProtected":
            if let v = body["value"] as? String { UserDefaults.standard.set(v, forKey: protectedPrefKey) }
            sendPrefs()
        case "scan":
            startScan()
        case "clean":
            startCleanup(ids: body["ids"] as? [String] ?? [])
        case "stopClean":
            cleaner?.stop()
        case "reveal":
            if let p = body["path"] as? String, p.hasPrefix("/") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
            }
        default: break
        }
    }

    private func sendPrefs() {
        send(["type": "prefs",
              "protected": UserDefaults.standard.string(forKey: protectedPrefKey) ?? "ask",
              "protectedFolders": Rules.protectedFolders,
              "csvPath": tilde(History.csvURL.path)])
    }

    private func startScan() {
        guard !scanning else { return }
        scanning = true
        let scanner = Scanner()
        scanner.scanProtected = UserDefaults.standard.string(forKey: protectedPrefKey) == "allow"
        scanner.onProgress = { [weak self] path, count in
            DispatchQueue.main.async { self?.send(["type": "progress", "path": path, "found": count]) }
        }
        send(["type": "scanStarted"])
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = scanner.run()
            let data = (try? JSONEncoder().encode(result)) ?? Data("{}".utf8)
            DispatchQueue.main.async {
                self?.scanning = false
                self?.lastResult = result
                self?.sendRaw(type: "result", json: String(decoding: data, as: UTF8.self))
            }
        }
    }

    /// Runs only items from the app's own last scan; the page sends IDs, never commands.
    private func startCleanup(ids: [String]) {
        guard cleaner == nil, !scanning, let result = lastResult else { return }
        let byId = Dictionary(uniqueKeysWithValues: result.items.map { ($0.id, $0) })
        // macOS-managed items are informational; never clean them even if the page asks.
        let items = ids.compactMap { byId[$0] }.filter { !$0.managed }
        guard !items.isEmpty else { return }
        let cleaner = Cleaner { [weak self] event in
            DispatchQueue.main.async { self?.send(event) }
        }
        self.cleaner = cleaner
        send(["type": "cleanStarted", "ids": items.map(\.id)])
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            cleaner.run(items)
            DispatchQueue.main.async { self?.cleaner = nil }
        }
    }

    private func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        web.evaluateJavaScript("window.App && App.receive(\(String(decoding: data, as: UTF8.self)))")
    }

    private func sendRaw(type: String, json: String) {
        web.evaluateJavaScript("window.App && App.receive({type: \"\(type)\", payload: \(json)})")
    }

    // MARK: - Menu (needed for ⌘Q, ⌘C, ⌘A inside the web view)

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About DevDisk", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide DevDisk", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit DevDisk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let winItem = NSMenuItem()
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = win
        main.addItem(winItem)
        NSApp.mainMenu = main
    }
}

// Headless check: `DevDisk --json` prints a scan without touching sizes.csv.
if CommandLine.arguments.contains("--json") {
    let scanner = Scanner()
    scanner.recordHistory = false
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try enc.encode(scanner.run()), as: UTF8.self))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
