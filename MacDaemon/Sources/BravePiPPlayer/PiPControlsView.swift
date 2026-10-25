// PiPControlsView.swift — Barre de contrôles overlay en bas de la fenêtre PiP.
// Contient : -10s, Play/Pause, +10s, et une seek bar cliquable/draggable.

import AppKit

protocol PiPControlsDelegate: AnyObject {
    func controlsTogglePlayPause()
    func controlsSeek(toFraction fraction: Double)
    func controlsSkip(by seconds: Double)
}

final class PiPControlsView: NSView {
    weak var delegate: PiPControlsDelegate?

    private let back10Button = NSButton()
    private let playPauseButton = NSButton()
    private let fwd10Button = NSButton()
    private let slider = SeekSlider()

    var isUserDragging: Bool { return slider.isDragging }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.45).cgColor

        configSymbolButton(back10Button, symbol: "gobackward.10", action: #selector(back10Clicked))
        configSymbolButton(playPauseButton, symbol: "play.fill", action: #selector(playPauseClicked))
        configSymbolButton(fwd10Button, symbol: "goforward.10", action: #selector(fwd10Clicked))

        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = 0
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [back10Button, playPauseButton, fwd10Button, slider])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            playPauseButton.widthAnchor.constraint(equalToConstant: 28),
            back10Button.widthAnchor.constraint(equalToConstant: 28),
            fwd10Button.widthAnchor.constraint(equalToConstant: 28),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func configSymbolButton(_ btn: NSButton, symbol: String, action: Selector) {
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
        btn.imagePosition = .imageOnly
        btn.bezelColor = .clear
        btn.isBordered = false
        btn.contentTintColor = .white
        btn.target = self
        btn.action = action
        btn.translatesAutoresizingMaskIntoConstraints = false
    }

    @objc private func back10Clicked() { delegate?.controlsSkip(by: -10) }
    @objc private func fwd10Clicked() { delegate?.controlsSkip(by: 10) }
    @objc private func playPauseClicked() { delegate?.controlsTogglePlayPause() }

    @objc private func sliderChanged() {
        delegate?.controlsSeek(toFraction: slider.doubleValue)
    }

    // ─── Mises à jour depuis le controller (polling) ──────────────────────────
    func updatePlayback(currentTime: Double, duration: Double, isPaused: Bool) {
        // Ne pas écraser la position du slider pendant que l'utilisateur le drag.
        if !slider.isDragging {
            if duration > 0 {
                slider.doubleValue = min(max(currentTime / duration, 0), 1)
            } else {
                slider.doubleValue = 0
            }
        }
        let symbol = isPaused ? "play.fill" : "pause.fill"
        playPauseButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
    }
}

// ─── SeekSlider : NSSlider qui piste l'état de drag ──────────────────────────
final class SeekSlider: NSSlider {
    private(set) var isDragging = false

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        // Déclenche une dernière fois l'action pour finaliser le seek.
        if let target = target, let action = action {
            _ = target.perform(action, with: self)
        }
        super.mouseUp(with: event)
    }
}
