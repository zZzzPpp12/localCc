import AppKit
import SwiftUI

@MainActor
final class QuotaHUDController {
    private let defaults: UserDefaults
    private var ledger: QuotaHUDLedger
    private let presentation = QuotaHUDPresentation()
    private var panel: FloatingPanel?
    private var dismissTask: Task<Void, Never>?
    private var candidates: [QuotaHUDAlert] = []
    private var enabled = false
    private var placement = CGRect.zero
    private let testDuration: TimeInterval?
    private(set) var currentAlert: QuotaHUDAlert?
    var isVisible: Bool { panel?.isVisible == true }
    var frame: CGRect? { panel?.frame }
    var contentView: NSView? { panel?.contentView }

    init(defaults: UserDefaults = .standard, testDuration: TimeInterval? = nil) {
        self.defaults = defaults
        self.testDuration = testDuration
        ledger = defaults.data(forKey: "quotaHUDLedger").flatMap { try? JSONDecoder().decode(QuotaHUDLedger.self, from: $0) } ?? QuotaHUDLedger()
    }

    func update(snapshot: UsageSnapshot?, fresh: Bool, enabled: Bool, visible: CGRect, anchor: CGRect?, obstacle: CGRect? = nil, at now: Date = Date()) {
        placement = QuotaHUDGeometry.frame(visible: visible, anchor: anchor, obstacle: obstacle)
        self.enabled = enabled && fresh
        candidates = self.enabled ? snapshot.map { QuotaHUDAlert.candidates(snapshot: $0, at: now) } ?? [] : []
        if let current = currentAlert {
            if current.isPreview {
                // Preview is explicitly requested, independent of quota / reminder settings.
                reposition(); return
            }
            if let latest = candidates.first(where: { $0.id == current.id }) {
                currentAlert = latest
                presentation.alert = latest; presentation.now = now
                reposition()
                // An exhausted window takes precedence over a still-visible low reminder.
                if latest.level == .low, candidates.contains(where: { $0.level == .exhausted && ledger.shouldPresent($0) }) {
                    dismiss(); presentNext(at: now)
                }
                return
            }
            dismiss()
        }
        presentNext(at: now)
    }

    private func presentNext(at now: Date) {
        guard enabled, let next = candidates.first(where: { ledger.shouldPresent($0) }) else { return }
        present(next, at: now)
        // Persist only after a real native panel has been shown. Preview never touches the ledger.
        ledger.markPresented(next, at: now)
        if let data = try? JSONEncoder().encode(ledger) { defaults.set(data, forKey: "quotaHUDLedger") }
    }

    func preview(_ level: QuotaHUDLevel, visible: CGRect, anchor: CGRect?, obstacle: CGRect? = nil) {
        placement = QuotaHUDGeometry.frame(visible: visible, anchor: anchor, obstacle: obstacle)
        present(.preview(level), at: Date())
    }

    private func present(_ alert: QuotaHUDAlert, at now: Date) {
        dismissTask?.cancel()
        currentAlert = alert
        presentation.isVisible = true
        presentation.alert = alert; presentation.now = now
        if panel == nil {
            let window = FloatingPanel(contentRect: placement, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.title = "Codex Orbit 额度 HUD"
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            window.hidesOnDeactivate = false; window.isOpaque = false; window.backgroundColor = .clear
            window.isReleasedWhenClosed = false; window.hasShadow = false; window.animationBehavior = .none
            let hosting = NSHostingView(rootView: QuotaHUDView(presentation: presentation, dismiss: { [weak self] in self?.dismiss() }))
            hosting.sizingOptions = []
            window.contentView = hosting
            panel = window
        }
        reposition()
        panel?.orderFrontRegardless()
        let duration = testDuration ?? alert.level.duration
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func reposition() {
        if panel?.frame != placement { panel?.setFrame(placement, display: true) }
    }

    func dismiss() {
        dismissTask?.cancel(); dismissTask = nil
        presentation.isVisible = false
        currentAlert = nil; panel?.orderOut(nil)
        // The next valid window is evaluated on the next store tick, never from a stale queue.
    }

    func pauseAnimationForCapture(_ paused: Bool) { presentation.isCapturing = paused }
}
