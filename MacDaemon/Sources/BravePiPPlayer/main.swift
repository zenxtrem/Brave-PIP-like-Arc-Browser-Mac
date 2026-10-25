// main.swift — Point d'entrée de l'application BravePiPPlayer
// Agent macOS : pas d'icône dans le Dock, un seul menu dans la barre des menus.

import Foundation
import AppKit
import Darwin

// ─── Une seule instance ──────────────────────────────────────────────────────
// Sans ce verrou, chaque relance laissait une copie de plus, et la suivante
// échouait parce que le port 8765 était déjà pris.
private var instanceLockFD: Int32 = -1

private func acquireSingleInstanceLock() {
    let path = "/tmp/bravepip-player.lock"
    instanceLockFD = open(path, O_CREAT | O_RDWR, 0o644)
    guard instanceLockFD >= 0, flock(instanceLockFD, LOCK_EX | LOCK_NB) == 0 else {
        fputs("Brave PiP est déjà lancé. Cette copie s'arrête.\n", stderr)
        exit(0)
    }
}

// ─── AppDelegate ────────────────────────────────────────────────────────────
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var webSocketServer: WebSocketServer!
    private var windowController: PiPWindowController!
    private var statusItem: NSStatusItem!
    private var activateItem: NSMenuItem!
    private var relaunchItem: NSMenuItem!
    private let relaunchLockPath = "/tmp/bravepip-relaunch.exclusive"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installStatusItem()

        windowController = PiPWindowController()
        webSocketServer = WebSocketServer(port: 8765, windowController: windowController)
        webSocketServer.start()

        log("BravePiPPlayer démarré. WebSocket en écoute sur ws://127.0.0.1:8765")
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        webSocketServer?.stop()
        windowController?.close()
    }

    // ─── Barre des menus ─────────────────────────────────────────────────────
    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "pip", accessibilityDescription: "Brave PiP") {
            image.isTemplate = true
            statusItem.button?.image = image
        } else {
            statusItem.button?.title = "PiP"
        }

        let menu = NSMenu()
        menu.delegate = self

        let title = NSMenuItem(title: "Brave PiP", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        activateItem = NSMenuItem(title: "Activer", action: #selector(activateDaemon), keyEquivalent: "")
        activateItem.target = self
        menu.addItem(activateItem)

        relaunchItem = NSMenuItem(title: "Relancer", action: #selector(relaunchDaemon), keyEquivalent: "")
        relaunchItem.target = self
        menu.addItem(relaunchItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quitter", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        let listening = webSocketServer?.isListening == true
        activateItem.title = listening ? "Actif" : "Activer"
        activateItem.state = listening ? .on : .off
        activateItem.isEnabled = !listening
        let relaunchBusy = FileManager.default.fileExists(atPath: relaunchLockPath)
        relaunchItem.isEnabled = !relaunchBusy
        relaunchItem.title = relaunchBusy ? "Relance en cours…" : "Relancer"
    }

    @objc private func activateDaemon() {
        webSocketServer?.ensureListening()
    }

    @objc private func relaunchDaemon() {
        guard !FileManager.default.fileExists(atPath: relaunchLockPath) else {
            log("Relance déjà en cours.")
            return
        }
        guard let root = packageRoot() else {
            log("Relance impossible : Package.swift introuvable depuis \(CommandLine.arguments[0]).")
            return
        }
        let escaped = root.path.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        #!/bin/bash
        LOCKDIR=/tmp/bravepip-relaunch.exclusive
        if ! mkdir "$LOCKDIR" 2>/dev/null; then
          exit 0
        fi
        if [ -z "$BRAVEPIP_RELAUNCH" ]; then
          export BRAVEPIP_RELAUNCH=1
          nohup /bin/bash "$0" >>/tmp/bravepip-relaunch.log 2>&1 &
          exit 0
        fi
        cleanup() { rmdir "$LOCKDIR" 2>/dev/null || true; }
        trap cleanup EXIT
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
          pgrep -x BravePiPPlayer >/dev/null || break
          pkill -x BravePiPPlayer || true
          sleep 0.25
        done
        pkill -9 -x BravePiPPlayer >/dev/null 2>&1 || true
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
          lsof -nP -iTCP:8765 -sTCP:LISTEN >/dev/null 2>&1 || break
          sleep 0.25
        done
        cd '\(escaped)' || exit 1
        nohup /usr/bin/swift run >>/tmp/bravepip.log 2>&1 &
        for _ in $(seq 1 90); do
          lsof -nP -iTCP:8765 -sTCP:LISTEN >/dev/null 2>&1 && exit 0
          sleep 0.5
        done
        exit 1
        """
        let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bravepip-relaunch.sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = [scriptURL.path]
            try task.run()
            log("Relance unique programmée depuis \(root.path).")
        } catch {
            log("Relance impossible : \(error)")
        }
    }

    private func packageRoot() -> URL? {
        let fm = FileManager.default
        var url = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<10 {
            if fm.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return nil
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

func log(_ message: @autoclosure () -> String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    print("[\(ts)] " + message())
    fflush(stdout)
}

acquireSingleInstanceLock()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
