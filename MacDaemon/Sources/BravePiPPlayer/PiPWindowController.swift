// PiPWindowController.swift — Gère la création/fermeture de la fenêtre PiP
// contenant une WKWebView qui joue l'intégration YouTube. Au STOP, récupère le
// currentTime via JS et le renvoie via un callback pour synchronisation.

import AppKit
import WebKit

final class PiPWindowController {
    private var window: DraggableWindow?
    private var webView: WKWebView?
    private var dragHandle: DragHandleView?
    private var currentVideoId: String?
    private(set) var isPiPActive: Bool = false

    private let initialSize = NSSize(width: 400, height: 225)
    private let dragHandleHeight: CGFloat = 22

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
            self?.loadVideo(videoId: videoId, timestamp: timestamp)
            self?.window?.makeKeyAndOrderFront(nil)
            self?.isPiPActive = true
            log("Fenêtre PiP affichée pour videoId=\(videoId) à t=\(timestamp)s.")
        }
    }

    // ─── STOP : récupère le currentTime, ferme la fenêtre ───────────────────
    // completion reçoit nil si aucune fenêtre PiP n'était ouverte (pour que le
    // daemon puisse envoyer NO_PIP au lieu de SYNC_TIME).
    func stopAndSync(completion: @escaping (Double?) -> Void) {
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
            let js = "(function(){var v=document.querySelector('video');return v?v.currentTime:0;})();"
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                let t: Double
                if let n = result as? Double {
                    t = n
                } else if let n = result as? NSNumber {
                    t = n.doubleValue
                } else if let s = result as? String, let parsed = Double(s) {
                    t = parsed
                } else {
                    t = 0
                }
                log("currentTime récupéré depuis le PiP: \(t)s")
                self?.isPiPActive = false
                self?.close()
                completion(t)
            }
        }
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

        // Conteneur avec coins arrondis + clip.
        let container = PiPContainerView(frame: rect)
        container.autoresizingMask = [.width, .height]
        win.contentView = container

        // ─── Barre de drag en haut (au-dessus de la webView) ────────────────
        let handleRect = NSRect(x: 0, y: rect.height - dragHandleHeight,
                               width: rect.width, height: dragHandleHeight)
        let handle = DragHandleView(frame: handleRect)
        handle.autoresizingMask = [.width, .height]
        handle.windowRef = win
        container.addSubview(handle)
        self.dragHandle = handle

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
        if let webView = self.webView {
            webView.stopLoading()
            webView.loadHTMLString("<html></html>", baseURL: nil)
        }
        self.window?.orderOut(nil)
        self.isPiPActive = false
        log("Fenêtre PiP fermée.")
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
    private var initialMouseLocation: NSPoint = .zero
    private var initialWindowOrigin: NSPoint = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.25).cgColor
        // Indicateur visuel discret (deux petits points centrés).
        let label = NSTextField(labelWithString: "⋮⋮")
        label.textColor = NSColor(white: 1, alpha: 0.6)
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

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
