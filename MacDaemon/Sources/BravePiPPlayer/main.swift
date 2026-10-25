// main.swift — Point d'entrée de l'application BravePiPPlayer
// Application macOS d'arrière-plan (sans icône dans le Dock) qui héberge un
// serveur WebSocket local et une fenêtre PiP personnalisée (WKWebView) au-dessus
// des jeux plein écran.

import Foundation
import AppKit

// ─── AppDelegate ────────────────────────────────────────────────────────────
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var webSocketServer: WebSocketServer!
    private var windowController: PiPWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Mode agent : pas d'icône dans le Dock, pas de menu principal visible.
        NSApp.setActivationPolicy(.accessory)

        // Instancie le contrôleur de fenêtre PiP (créée à la demande).
        windowController = PiPWindowController()

        // Démarre le serveur WebSocket sur le port 8765.
        webSocketServer = WebSocketServer(port: 8765, windowController: windowController)
        webSocketServer.start()

        log("BravePiPPlayer démarré. WebSocket en écoute sur ws://127.0.0.1:8765")
    }

    func applicationWillTerminate(_ notification: Notification) {
        webSocketServer?.stop()
        windowController?.close()
    }
}

// ─── Logging global ──────────────────────────────────────────────────────────
func log(_ message: @autoclosure () -> String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    print("[\(ts)] " + message())
    fflush(stdout)
}

// ─── Lancement de l'application ──────────────────────────────────────────────
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
