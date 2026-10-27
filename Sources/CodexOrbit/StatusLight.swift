import AppKit

enum StatusLight {
    static let frameCount = 56
    static func breathingDuration(for signal: QuotaSignal) -> TimeInterval {
        signal == .red ? 2.4 : 2.8
    }

    // Full-color artwork keeps the traffic-light colors in both menu-bar appearances.
    static func image(for signal: QuotaSignal, phase: Double? = nil) -> NSImage {
        let color: NSColor
        switch signal {
        case .green: color = NSColor(srgbRed: 0.12, green: 0.77, blue: 0.48, alpha: 1)
        case .yellow: color = NSColor(srgbRed: 0.96, green: 0.70, blue: 0.12, alpha: 1)
        case .red: color = NSColor(srgbRed: 0.96, green: 0.30, blue: 0.35, alpha: 1)
        case .unknown: color = .systemGray
        }
        let pulse = phase.map { (1 - cos($0 * 2 * .pi)) / 2 }
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            if signal != .unknown, let pulse {
                // Red gets a slightly fuller halo, while its core stays continuously lit.
                let isRed = signal == .red
                let center = NSPoint(x: 7.5, y: 8)
                let radius = 4.8 + 2.7 * pulse
                let glow = NSGradient(colorsAndLocations:
                    (color.withAlphaComponent(0.22 + (isRed ? 0.54 : 0.48) * pulse), 0),
                    (color.withAlphaComponent(0.10 + (isRed ? 0.38 : 0.34) * pulse), 0.65),
                    (color.withAlphaComponent(0), 1))!
                glow.draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
                let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius + 0.4, y: center.y - radius + 0.4,
                                                      width: (radius - 0.4) * 2, height: (radius - 0.4) * 2))
                color.withAlphaComponent(0.18 + (isRed ? 0.46 : 0.40) * pulse).setStroke()
                ring.lineWidth = isRed ? 1.1 : 1.0
                ring.stroke()
                let coreRadius = 3.4 + (isRed ? 1.1 : 1.0) * pulse
                let core = NSBezierPath(ovalIn: NSRect(x: center.x - coreRadius, y: center.y - coreRadius,
                                                      width: coreRadius * 2, height: coreRadius * 2))
                (color.blended(withFraction: (isRed ? 0.10 : 0.18) * pulse, of: .white) ?? color).setFill()
                core.fill()
                // A bright inner bloom reads as emitted light; the saturated rim preserves the signal color.
                let innerGlow = NSGradient(colorsAndLocations:
                    (NSColor.white.withAlphaComponent(0.10 + (isRed ? 0.56 : 0.64) * pulse), 0),
                    ((color.blended(withFraction: 0.60, of: .white) ?? color).withAlphaComponent(0.06 + 0.44 * pulse), 0.5),
                    (color.withAlphaComponent(0), 1))!
                innerGlow.draw(fromCenter: center, radius: 0, toCenter: center, radius: coreRadius, options: [])
                NSColor.black.withAlphaComponent(0.10).setStroke()
                core.lineWidth = 0.5
                core.stroke()
                NSColor.white.withAlphaComponent(0.40 + 0.35 * pulse).setFill()
                NSBezierPath(ovalIn: NSRect(x: 5.5, y: 9, width: 3, height: 1.5)).fill()
                return true
            }
            color.withAlphaComponent(0.14).setFill()
            NSBezierPath(ovalIn: NSRect(x: 1, y: 2, width: 12, height: 12)).fill()
            let dot = NSBezierPath(ovalIn: NSRect(x: 3, y: 4, width: 8, height: 8))
            color.setFill()
            dot.fill()
            NSColor.black.withAlphaComponent(0.12).setStroke()
            dot.lineWidth = 0.5
            dot.stroke()
            NSColor.white.withAlphaComponent(0.4).setFill()
            NSBezierPath(ovalIn: NSRect(x: 5, y: 9, width: 3, height: 1.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

@MainActor
final class StatusLightAnimator {
    private weak var button: NSStatusBarButton?
    private var signal: QuotaSignal?
    private var timer: Timer?
    private var startedAt: TimeInterval = 0
    private var frameIndex = -1
    // Reuse a small set of frames; don't allocate or redraw artwork on every tick.
    private var frameCache: [QuotaSignal: [NSImage]] = [:]
    private var frames: [NSImage] = []
    var isAnimating: Bool { timer != nil }
    private(set) var renderedFrameCount = 0

    func update(button: NSStatusBarButton?, signal: QuotaSignal, animate: Bool) {
        let changed = self.signal != signal || self.button !== button
        self.button = button
        self.signal = signal
        guard let button else { stop(); return }
        if signal != .unknown && animate {
            guard timer == nil || changed else { return }
            stop()
            if frameCache[signal] == nil {
                frameCache[signal] = (0..<StatusLight.frameCount).map {
                    StatusLight.image(for: signal, phase: Double($0) / Double(StatusLight.frameCount))
                }
            }
            frames = frameCache[signal]!
            startedAt = ProcessInfo.processInfo.systemUptime
            frameIndex = -1
            renderFrame()
            let timer = Timer(timeInterval: StatusLight.breathingDuration(for: signal) / Double(StatusLight.frameCount), repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.renderFrame() }
            }
            timer.tolerance = 0.008
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if changed || timer != nil {
            stop()
            button.image = StatusLight.image(for: signal)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func renderFrame() {
        guard let button, let signal, signal != .unknown else { stop(); return }
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        let index = Int(elapsed / StatusLight.breathingDuration(for: signal) * Double(StatusLight.frameCount)) % StatusLight.frameCount
        guard index != frameIndex else { return }
        frameIndex = index
        button.image = frames[index]
        renderedFrameCount += 1
    }
}
