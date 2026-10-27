// PiPWindowController.swift — Gère la création/fermeture de la fenêtre PiP
// contenant une WKWebView qui joue l'intégration YouTube. Au STOP, récupère le
// currentTime via JS et le renvoie via un callback pour synchronisation.

import AppKit
import WebKit

struct PiPPlaybackSnapshot {
    let timestamp: Double
    let paused: Bool
}

final class PiPWindowController {
    private var window: DraggableWindow?
    private var webView: WKWebView?
    private var dragHandle: DragHandleView?
    private var controlsView: PiPControlsView?
    private var currentVideoId: String?
    private(set) var isPiPActive: Bool = false
    private var pollTimer: Timer?
    private var chromeHideWork: DispatchWorkItem?
    private var chromeVisible = true
    private var chromeGeneration = 0
    private var lastPointer = NSPoint(x: -10_000, y: -10_000)
    private var lastKnownPaused = false
    private var lastKnownTime: Double = 0
    private var isDismissing = false
    private var ignoreStopUntil = Date.distantPast
    private var braveObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var ignoringBraveActivation = false
    private var raiseWork: [DispatchWorkItem] = []

    var onUserDismiss: ((PiPPlaybackSnapshot) -> Void)?
    var shouldIgnoreStop: Bool { Date() < ignoreStopUntil }

    init() {
        braveObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.brave.Browser" else { return }
            self?.braveDidBecomeActive()
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.pipFollowedSpaceChange()
        }
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        if let braveObserver { center.removeObserver(braveObserver) }
        if let spaceObserver { center.removeObserver(spaceObserver) }
    }
    private var exitHideArmed = false
    private var pointerWasInside = false

    private let initialSize = NSSize(width: 400, height: 225)
    private let dragHandleHeight: CGFloat = 32
    private let controlsHeight: CGFloat = 40

    // ─── Ad-Skipper + UI-hider JavaScript ─────────────────────────────────────
    // Injecté via WKUserScript (atDocumentStart pour le CSS, atDocumentEnd pour
    // l'Ad-Skipper). La webview est sandboxée (pas d'extensions ni de Brave
    // Shields), on gère donc les pubs côté client et on masque le chrome YouTube.
    static let uiHiderCSS = """
    .ytp-chrome-top, .ytp-chrome-bottom,
    .ytp-gradient-top, .ytp-gradient-bottom,
    .ytp-title-channel, .ytp-title-text, .ytp-cued-thumbnail-overlay,
    .ytp-show-cards-title, .ytp-pause-overlay, .html5-watermark,
    .ytp-settings-menu, .ytp-popup-menu, .iv-branding,
    .ytp-button.ytp-jump-button, .ytp-expand,
    .ytp-impression-link, .ytp-pause-overlay,
    .branding-img-container, .ytp-button,
    .ytp-large-play-button, .ytp-cued-thumbnail-overlay-image {
        display: none !important;
        opacity: 0 !important;
        visibility: hidden !important;
    }
    .html5-video-container, .html5-main-video {
        background: #000 !important;
    }
    .ytp-autoheat-title, .ytp-autoheat-link, .ytp-heat-menu {
        display: none !important;
    }
    """

    static let adSkipperJavaScript = """
    (function () {
        setInterval(function () {
            try {
                // 1. Cacher les bannières superposées
                var adOverlays = document.querySelectorAll('.ytp-ad-overlay-container, .ytp-ad-message-container');
                adOverlays.forEach(function (el) { el.style.display = 'none'; });

                // 2. Passer la pub vidéo si elle est en cours
                var video = document.querySelector('video');
                var adShowing = document.querySelector('.ad-showing');
                if (adShowing && video) {
                    video.playbackRate = 16.0;
                    if (!isNaN(video.duration)) {
                        video.currentTime = video.duration - 0.1;
                    }
                    // 3. Cliquer sur le bouton "Passer l'annonce" s'il apparaît
                    var skipBtn = document.querySelector('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button');
                    if (skipBtn) { skipBtn.click(); }
                }
            } catch (e) { /* ignore */ }
        }, 500);
    })();
    """

    // ─── Affichage de la fenêtre PiP ─────────────────────────────────────────
    func showPiPWindow(videoId: String, timestamp: Double) {
        guard !videoId.isEmpty else {
            log("videoId vide — fenêtre PiP non ouverte.")
            return
        }
        currentVideoId = videoId

        DispatchQueue.main.async { [weak self] in
            self?.instantiateWindowIfNeeded()
            self?.window?.applyOverlayBehavior()
            self?.loadVideo(videoId: videoId, timestamp: timestamp)
            NSApp.setActivationPolicy(.accessory)
            self?.window?.orderFrontRegardless()
            self?.isPiPActive = true
            self?.lastKnownPaused = false
            self?.pointerWasInside = false
            self?.exitHideArmed = false
            self?.lastPointer = NSEvent.mouseLocation
            self?.startPolling()
            self?.revealChrome()
            self?.scheduleRaiseBurst()
            log("Fenêtre PiP affichée pour videoId=\(videoId) à t=\(timestamp)s.")
        }
    }

    // ─── STOP : récupère le currentTime, ferme la fenêtre ───────────────────
    // completion reçoit nil si aucune fenêtre PiP n'était ouverte (pour que le
    // daemon puisse envoyer NO_PIP au lieu de SYNC_TIME).
    func stopAndSync(completion: @escaping (PiPPlaybackSnapshot?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                completion(nil)
                return
            }
            guard self.isPiPActive, let webView = self.webView else {
                log("STOP reçu mais aucun PiP actif — pas de SYNC_TIME.")
                self.isPiPActive = false
                completion(nil)
                return
            }
            let js = "(function(){var v=document.querySelector('video');if(!v)return null;return JSON.stringify({t:v.currentTime||0,p:!!v.paused});})();"
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                let snapshot = self?.parseSnapshot(result) ?? PiPPlaybackSnapshot(
                    timestamp: 0,
                    paused: self?.lastKnownPaused ?? false
                )
                log("État PiP: t=\(snapshot.timestamp)s paused=\(snapshot.paused)")
                self?.isPiPActive = false
                self?.close()
                completion(snapshot)
            }
        }
    }

    private func parseSnapshot(_ result: Any?) -> PiPPlaybackSnapshot? {
        let raw: String?
        if let s = result as? String {
            raw = s
        } else if let s = result as? NSString {
            raw = s as String
        } else {
            raw = nil
        }
        guard let raw, let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let t = (obj["t"] as? Double) ?? (obj["t"] as? NSNumber)?.doubleValue ?? 0
        let p = (obj["p"] as? Bool) ?? ((obj["p"] as? NSNumber)?.boolValue ?? lastKnownPaused)
        return PiPPlaybackSnapshot(timestamp: t, paused: p)
    }

    // ─── Création de la fenêtre et de la WebView ────────────────────────────
    private func instantiateWindowIfNeeded() {
        if window != nil { return }

        let rect = NSRect(x: 100, y: 100, width: initialSize.width, height: initialSize.height)
        let win = DraggableWindow(
            contentRect: rect,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        win.minSize = NSSize(width: 240, height: 135)
        win.maxSize = NSSize(width: 1280, height: 720)
        win.acceptsMouseMovedEvents = true

        // Conteneur avec coins arrondis + clip.
        let container = PiPContainerView(frame: rect)
        container.autoresizingMask = [.width, .height]
        win.contentView = container

        // ─── Barre de drag en haut (au-dessus de la webView) ────────────────
        let handleRect = NSRect(x: 0, y: rect.height - dragHandleHeight,
                               width: rect.width, height: dragHandleHeight)
        let handle = DragHandleView(frame: handleRect)
        handle.autoresizingMask = [.width, .minYMargin]
        handle.windowRef = win
        handle.onClose = { [weak self] in
            self?.userDismiss(jumpToBrave: false, pausedOverride: true)
        }
        handle.onJumpToBrave = { [weak self] in
            self?.userDismiss(jumpToBrave: true, pausedOverride: false)
        }
        container.addSubview(handle)
        self.dragHandle = handle

        // ─── Barre de contrôles en bas (overlay) ─────────────────────────────
        let controlsRect = NSRect(x: 0, y: 0, width: rect.width, height: controlsHeight)
        let controls = PiPControlsView(frame: controlsRect)
        controls.autoresizingMask = [.width, .maxYMargin]
        controls.delegate = self
        container.addSubview(controls)
        self.controlsView = controls

        // ─── Configuration de la WKWebView ──────────────────────────────────
        let config = WKWebViewConfiguration()
        config.allowsAirPlayForMediaPlayback = false
        config.mediaTypesRequiringUserActionForPlayback = []
        if #available(macOS 11.0, *) {
            config.defaultWebpagePreferences.allowsContentJavaScript = true
        }

        let userContentController = WKUserContentController()
        config.userContentController = userContentController

        // CSS injecté au plus tôt (atDocumentStart) pour masquer le chrome YouTube.
        let cssScript = WKUserScript(
            source: "var style=document.createElement('style');style.textContent=\(Self.uiHiderCSS.replacingOccurrences(of: "\n", with: " "));document.head.appendChild(style);",
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        userContentController.addUserScript(cssScript)

        // Ad-Skipper injecté à la fin du document.
        let adSkipperScript = WKUserScript(
            source: Self.adSkipperJavaScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        userContentController.addUserScript(adSkipperScript)

        // La webView occupe toute la fenêtre (la barre de drag flotte au-dessus).
        let webView = WKWebView(frame: container.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.wantsLayer = true
        webView.layer?.cornerRadius = 12
        webView.layer?.masksToBounds = true
        container.addSubview(webView, positioned: .below, relativeTo: handle)
        self.webView = webView

        self.window = win
    }

    // ─── Chargement de la vidéo YouTube (domaine allégé) ────────────────────
    // On utilise youtube-nocookie.com (domaine officiel Google pour la
    // confidentialité) : moins agressif sur le tracking publicitaire.
    // controls=0 + modestbranding=1 pour réduire le chrome du player.
    private func loadVideo(videoId: String, timestamp: Double) {
        let start = Int(timestamp.rounded())
        let urlString = "https://www.youtube-nocookie.com/embed/\(videoId)?start=\(start)&autoplay=1&controls=0&modestbranding=1&playsinline=1&rel=0&showinfo=0&iv_load_policy=3&disablekb=1"
        guard let url = URL(string: urlString) else {
            log("URL invalide: \(urlString)")
            return
        }
        var request = URLRequest(url: url)
        request.setValue("https://www.youtube-nocookie.com", forHTTPHeaderField: "Referer")
        webView?.load(request)
        log("Chargement YouTube embed: \(urlString)")
    }

    // ─── Fermeture ──────────────────────────────────────────────────────────
    func close() {
        stopPolling()
        chromeHideWork?.cancel()
        chromeHideWork = nil
        raiseWork.forEach { $0.cancel() }
        raiseWork = []
        if let webView = self.webView {
            webView.stopLoading()
            webView.loadHTMLString("<html></html>", baseURL: nil)
        }
        self.window?.orderOut(nil)
        self.isPiPActive = false
        self.isDismissing = false
        log("Fenêtre PiP fermée.")
    }

    // Brave redevient actif. On libère l'écran le temps que ses fenêtres arrivent,
    // sans fermer le PiP : s'il s'agit d'un autre onglet, la fenêtre repasse devant.
    // Le retour sur l'onglet YouTube envoie STOP et ferme vraiment le PiP.
    private func braveDidBecomeActive() {
        if ignoringBraveActivation {
            ignoringBraveActivation = false
            return
        }
        guard isPiPActive, !isDismissing else { return }
        log("Brave au premier plan : le PiP se replace au-dessus.")
        window?.orderOut(nil)
        ignoringBraveActivation = true
        DispatchQueue.main.async { [weak self] in
            self?.activateBrave()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.scheduleRaiseBurst()
        }
    }

    /// Remet la fenêtre au-dessus de Brave. Ignoré si une fermeture est en cours.
    func raiseAboveBrave() {
        guard isPiPActive, !isDismissing, let window else { return }
        window.applyOverlayBehavior()
    }

    /// Brave réordonne sa fenêtre à chaque changement d'onglet. On répète
    /// le passage au premier plan pendant une seconde pour gagner cette course.
    func keepAboveBrave() {
        scheduleRaiseBurst()
    }

    private func scheduleRaiseBurst() {
        raiseWork.forEach { $0.cancel() }
        raiseWork = [0, 0.12, 0.3, 0.55, 1.0].map { delay in
            let work = DispatchWorkItem { [weak self] in
                self?.raiseAboveBrave()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    }

    /// macOS rattache parfois la fenêtre au bureau où elle a été créée.
    /// On réapplique l'overlay à chaque changement de bureau.
    private func pipFollowedSpaceChange() {
        guard isPiPActive, let window else { return }
        window.applyOverlayBehavior()
        window.orderFrontRegardless()
        log("Changement de bureau : PiP réaffiché par-dessus.")
    }

    // pausedOverride : true = pause forcée (croix), false = lecture forcée
    // (bouton retour), nil = conserver l'état réel du lecteur.
    private func userDismiss(jumpToBrave: Bool, pausedOverride: Bool?) {
        guard isPiPActive, !isDismissing else { return }
        isDismissing = true
        ignoreStopUntil = Date().addingTimeInterval(2)
        window?.orderOut(nil)
        let fallback = PiPPlaybackSnapshot(
            timestamp: lastKnownTime,
            paused: pausedOverride ?? lastKnownPaused
        )
        guard let webView = webView else {
            finishDismiss(fallback, jumpToBrave: jumpToBrave)
            return
        }
        let js = "(function(){var v=document.querySelector('video');if(!v)return null;return JSON.stringify({t:v.currentTime||0,p:!!v.paused});})();"
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            let parsed = self?.parseSnapshot(result) ?? fallback
            let outgoing = PiPPlaybackSnapshot(
                timestamp: parsed.timestamp,
                paused: pausedOverride ?? parsed.paused
            )
            self?.finishDismiss(outgoing, jumpToBrave: jumpToBrave)
        }
    }

    private func finishDismiss(_ snapshot: PiPPlaybackSnapshot, jumpToBrave: Bool) {
        onUserDismiss?(snapshot)
        close()
        guard jumpToBrave else { return }
        DispatchQueue.main.async { [weak self] in
            self?.activateBrave()
        }
    }

    private func activateBrave() {
        let bundleID = "com.brave.Browser"
        if let brave = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            brave.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            log("Brave ramené au premier plan.")
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            log("Brave introuvable.")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
        log("Brave lancé.")
    }

    // ─── Polling de l'état de la vidéo (currentTime / duration / paused) ──────
    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.pollPlaybackState()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollPlaybackState() {
        pollPointer()
        guard let webView = webView, isPiPActive else { return }
        let js = "(function(){var v=document.querySelector('video');if(!v)return null;return JSON.stringify({t:v.currentTime,d:v.duration||0,p:v.paused});})();"
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self = self, let s = result as? String,
                  let data = s.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            let t = (obj["t"] as? Double) ?? 0
            let d = (obj["d"] as? Double) ?? 0
            let p = (obj["p"] as? Bool) ?? false
            self.lastKnownPaused = p
            self.lastKnownTime = t
            self.controlsView?.updatePlayback(currentTime: t, duration: d, isPaused: p)
        }
    }

    // ─── Chrome auto-hide (barre de drag + contrôles) ────────────────────────
    // Le PiP flotte au-dessus d'une autre app : les mouseMoved ne sont pas
    // livrés tant que notre processus n'est pas actif. On suit donc le curseur
    // via NSEvent.mouseLocation, lisible sans permission d'accessibilité.
    private func pollPointer() {
        guard let window = window, window.isVisible else { return }
        if controlsView?.isUserDragging == true {
            revealChrome()
            return
        }
        let loc = NSEvent.mouseLocation
        let inside = window.frame.contains(loc)
        let moved = hypot(loc.x - lastPointer.x, loc.y - lastPointer.y) > 1.5
        lastPointer = loc
        if inside {
            pointerWasInside = true
            if moved || exitHideArmed {
                exitHideArmed = false
                revealChrome()
            }
        } else if pointerWasInside, chromeVisible, !exitHideArmed {
            pointerWasInside = false
            exitHideArmed = true
            scheduleChromeHide(after: 0.25)
        }
    }

    private func revealChrome() {
        chromeHideWork?.cancel()
        setChromeVisible(true)
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if self.controlsView?.isUserDragging == true {
                self.revealChrome()
                return
            }
            self.setChromeVisible(false)
        }
        chromeHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func scheduleChromeHide(after delay: TimeInterval) {
        chromeHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, let window = self.window else { return }
            if window.frame.contains(NSEvent.mouseLocation) {
                self.exitHideArmed = false
                self.revealChrome()
                return
            }
            self.exitHideArmed = false
            self.setChromeVisible(false)
        }
        chromeHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func setChromeVisible(_ visible: Bool) {
        guard visible != chromeVisible else { return }
        chromeVisible = visible
        chromeGeneration += 1
        let generation = chromeGeneration
        let views: [NSView] = [dragHandle as NSView?, controlsView as NSView?].compactMap { $0 }
        if visible {
            for view in views {
                view.isHidden = false
                view.alphaValue = 0
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                for view in views {
                    view.animator().alphaValue = 1
                }
            }
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                for view in views {
                    view.animator().alphaValue = 0
                }
            }, completionHandler: { [weak self] in
                guard let self = self, self.chromeGeneration == generation, !self.chromeVisible else { return }
                views.forEach { $0.isHidden = true }
            })
        }
    }
}

// ─── PiPControlsDelegate ─────────────────────────────────────────────────────
extension PiPWindowController: PiPControlsDelegate {
    func controlsTogglePlayPause() {
        guard let webView = webView else { return }
        let js = "(function(){var v=document.querySelector('video');if(!v)return;if(v.paused){v.play();}else{v.pause();}})();"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func controlsSeek(toFraction fraction: Double) {
        guard let webView = webView else { return }
        let clamped = min(max(fraction, 0), 1)
        let js = "(function(){var v=document.querySelector('video');if(!v)return;var d=v.duration||0;if(d>0)v.currentTime=\(clamped)*d;})();"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func controlsSkip(by seconds: Double) {
        guard let webView = webView else { return }
        let js = "(function(){var v=document.querySelector('video');if(!v)return;var t=v.currentTime+\(seconds);if(t<0)t=0;if(v.duration&&t>v.duration)t=v.duration;v.currentTime=t;})();"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
}

// ─── Conteneur avec coins arrondis (background clair + clip) ────────────────
final class PiPContainerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
}

// ─── Barre de drag (en haut de la fenêtre) ──────────────────────────────────
// Une zone transparente qui capture mouseDown/mouseDragged pour déplacer la
// fenêtre, sans interférer avec les contrôles de la vidéo en dessous.
final class DragHandleView: NSView {
    weak var windowRef: NSWindow?
    var onClose: (() -> Void)?
    var onJumpToBrave: (() -> Void)?
    private var initialMouseLocation: NSPoint = .zero
    private var initialWindowOrigin: NSPoint = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.25).cgColor

        let closeButton = ChromeButton(symbol: "xmark", action: #selector(closeClicked))
        closeButton.target = self
        closeButton.toolTip = "Fermer le PiP et mettre la vidéo en pause"
        let jumpButton = ChromeButton(symbol: "macwindow", action: #selector(jumpClicked))
        jumpButton.target = self
        jumpButton.toolTip = "Revenir à Brave et laisser la vidéo tourner"

        let label = NSTextField(labelWithString: "⋮⋮")
        label.textColor = NSColor(white: 1, alpha: 0.6)
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(closeButton)
        addSubview(jumpButton)
        addSubview(label)
        NSLayoutConstraint.activate([
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            closeButton.heightAnchor.constraint(equalToConstant: 22),
            jumpButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2),
            jumpButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            jumpButton.widthAnchor.constraint(equalToConstant: 22),
            jumpButton.heightAnchor.constraint(equalToConstant: 22),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    @objc private func closeClicked() { onClose?() }
    @objc private func jumpClicked() { onJumpToBrave?() }

    override func mouseDown(with event: NSEvent) {
        initialMouseLocation = NSEvent.mouseLocation
        initialWindowOrigin = windowRef?.frame.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        let current = NSEvent.mouseLocation
        let dx = current.x - initialMouseLocation.x
        let dy = current.y - initialMouseLocation.y
        windowRef?.setFrameOrigin(NSPoint(x: initialWindowOrigin.x + dx,
                                          y: initialWindowOrigin.y + dy))
    }
}

/// Bouton du chrome PiP : le premier clic est pris en compte même si l'app
/// n'est pas au premier plan.
final class ChromeButton: NSButton {
    init(symbol: String, action: Selector) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
        imagePosition = .imageOnly
        isBordered = false
        bezelStyle = .inline
        contentTintColor = .white
        target = nil
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Le parent DragHandleView démarre un drag sur mouseDown. On consomme
        // le clic ici pour que la croix et le retour Brave ne déplacent pas la fenêtre.
        super.mouseDown(with: event)
    }
}
