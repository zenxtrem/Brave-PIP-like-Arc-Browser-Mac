// DraggableWindow.swift — NSWindow personnalisée : sans bordure, coins arrondis,
// déplaçable à la souris, niveau .screenSaver pour passer au-dessus des jeux
// plein écran.

import AppKit

final class DraggableWindow: NSWindow {
    private var initialMouseLocation: NSPoint = .zero
    private var initialWindowOrigin: NSPoint = .zero

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovableByWindowBackground = true
        self.level = .screenSaver
        self.collectionBehavior = DraggableWindow.overlayBehavior
        self.isReleasedWhenClosed = false
        self.standardWindowButton(.closeButton)?.isHidden = true
        self.standardWindowButton(.miniaturizeButton)?.isHidden = true
        self.standardWindowButton(.zoomButton)?.isHidden = true
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.isExcludedFromWindowsMenu = true
        self.hidesOnDeactivate = false
    }

    // Permet le drag depuis n'importe quel point de la fenêtre.
    override func mouseDown(with event: NSEvent) {
        initialMouseLocation = NSEvent.mouseLocation
        initialWindowOrigin = self.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        let currentLocation = NSEvent.mouseLocation
        let dx = currentLocation.x - initialMouseLocation.x
        let dy = currentLocation.y - initialMouseLocation.y
        self.setFrameOrigin(NSPoint(x: initialWindowOrigin.x + dx, y: initialWindowOrigin.y + dy))
    }

    // Garde la fenêtre au niveau .screenSaver même si le système tente de la rétrograder.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Au-dessus des apps plein écran, visible sur tous les bureaux.
    static let overlayBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle
    ]

    func applyOverlayBehavior() {
        level = .screenSaver
        collectionBehavior = Self.overlayBehavior
    }
}
