import AppKit
import Darwin
import SwiftUI
import Combine
import UserNotifications
import ImageIO

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class DetailsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OrbitAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    let preferences = OrbitPreferences()
    let launchAtLogin = LaunchAtLogin()
    let edgeState = EdgeDockState()
    lazy var store = UsageStore(preferences: preferences, allowsNotifications: !isDiagnostic && !isSmokeTest)
    private let quotaHUD = QuotaHUDController()
    private let approvalBridge = ApprovalBridge()
    private let activity = HarnessActivityStore()
    private let dashboard = DashboardStore()
    private lazy var approvalPanels = ApprovalPanelController(bridge: approvalBridge, onExpand: { [weak self] in self?.hideHoverDetails() })
    private var orbPanel: FloatingPanel?
    private var edgePanel: FloatingPanel?
    private var edgeTimer: Timer?
    private var collapseTask: Task<Void, Never>?
    private var trackingMenu = false
    private var hoverDetailsPanel: FloatingPanel?
    private var hoverDismissedUntilExit = false
    private var updatingEdgeVisibility = false
    private var edgeTestPointer: NSPoint?
    private let edgeSlide = EdgeSlideAnimator()
    private var animateEdgeDuringTest = false
    private var reducedEdgeMotionForTest: Bool?
    private var detailsPanel: DetailsPanel?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var statusSignal: QuotaSignal?
    private let statusLightAnimator = StatusLightAnimator()
    private var displaySleeping = false
    private var subscriptions = Set<AnyCancellable>()
    private var monitors: [Any] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var localObservers: [NSObjectProtocol] = []
    private enum DragSource { case orb, capsule }
    private var dragStart: (mouse: NSPoint, origin: NSPoint, source: DragSource)?
    private var menu: NSMenu?
    private var isSmokeTest: Bool { ProcessInfo.processInfo.arguments.contains("--smoke-test") || ProcessInfo.processInfo.arguments.contains("--edge-self-test") || ProcessInfo.processInfo.arguments.contains("--edge-animation-self-test") || ProcessInfo.processInfo.arguments.contains("--hud-self-test") || ProcessInfo.processInfo.arguments.contains("--approval-self-test") || ProcessInfo.processInfo.arguments.contains("--activity-self-test") }
    private var isDiagnostic: Bool { ProcessInfo.processInfo.arguments.contains("--diagnose") }
    private var previousScale: Double = 1
    private var previousAppearance = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon; the menu bar is always available even when the orb is hidden.
        NSApp.setActivationPolicy(.accessory)
        makeApplicationMenu()
        UNUserNotificationCenter.current().delegate = self
        if isDiagnostic {
            Task { await diagnose() }
            return
        }
        makeMenuBar()
        makeOrb()
        makeEdgePanel()
        applyPreferences()
        startEdgeMonitoring()
        approvalBridge.onActivity = { [weak self] event in self?.activity.receive(event) }
        if !isSmokeTest { approvalBridge.start() }
        activity.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusItem() }
        }.store(in: &subscriptions)
        approvalBridge.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateApprovalPanels(); self?.updateQuotaHUD(); self?.updateActivity() }
        }.store(in: &subscriptions)
        store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusItem(); self?.resizeDetails(); self?.updateDashboardAccount(); self?.updateApprovalPanels(); self?.updateQuotaHUD(); self?.updateActivity() }
        }.store(in: &subscriptions)
        preferences.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyPreferences(); self?.updateStatusItem(); self?.updateApprovalPanels(); self?.updateQuotaHUD(); self?.updateActivity() }
        }.store(in: &subscriptions)
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.store.sleep(); self?.dashboard.stop(); self?.hideDetails(); self?.stopEdgeMotionForSleep(); self?.quotaHUD.dismiss(); self?.approvalBridge.releaseAll(); self?.updateApprovalPanels() }
        })
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.store.wake() }
        })
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.displaySleeping = true; self?.stopEdgeMotionForSleep(); self?.updateStatusItem(); self?.quotaHUD.dismiss(); self?.approvalBridge.releaseAll(); self?.updateApprovalPanels() }
        })
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.displaySleeping = false; self?.updateStatusItem() }
        })
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem(); self?.collapseOrb() }
        })
        localObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.keepOrbOnScreen(); self?.updateEdgeVisibility(); self?.updateQuotaHUD() }
        })
        localObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.launchAtLogin.refresh() }
        })
        for (name, isTracking) in [(NSMenu.didBeginTrackingNotification, true), (NSMenu.didEndTrackingNotification, false)] {
            localObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.trackingMenu = isTracking; self?.updateEdgeVisibility() }
            })
        }
        // A click outside the app dismisses the transient details, without consuming that click.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            Task { @MainActor in self?.hideDetails() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] event in
            if event.type == .keyDown, event.keyCode == 53 { self?.hideDetails() }
            else if event.type != .keyDown, event.window !== self?.detailsPanel, event.window !== self?.orbPanel, event.window !== self?.edgePanel, event.window !== self?.hoverDetailsPanel { self?.hideDetails() }
            return event
        }) { monitors.append(local) }
        if let report = argument(after: "--activity-self-test") {
            Task { await activitySelfTest(report: URL(fileURLWithPath: report)) }
        } else if let report = argument(after: "--approval-self-test") {
            Task { await approvalSelfTest(report: URL(fileURLWithPath: report)) }
        } else if let report = argument(after: "--hud-self-test") {
            Task { await hudSelfTest(report: URL(fileURLWithPath: report)) }
        } else if let report = argument(after: "--edge-animation-self-test") {
            Task { await edgeAnimationSelfTest(report: URL(fileURLWithPath: report)) }
        } else if let report = argument(after: "--edge-self-test") {
            Task { await edgeSelfTest(report: URL(fileURLWithPath: report)) }
        } else if isSmokeTest {
            Task { await smokeTest() }
        } else { store.start() }
        if ProcessInfo.processInfo.arguments.contains("--show-sidebar") {
            preferences.showOrb = true
            preferences.autoHideAtEdge = true
            preferences.snapToEdge = true
            if edgeGeometry() == nil { positionOnMainScreen() }
            updateEdgeVisibility()
        }
        if ProcessInfo.processInfo.arguments.contains("--enable-login-item") { launchAtLogin.setEnabled(true) }
        Task {
            if ProcessInfo.processInfo.arguments.contains("--install-activity-hooks") { activity.installHooks() }
            if ProcessInfo.processInfo.arguments.contains("--install-approval-hook") { approvalBridge.installHook() }
            if ProcessInfo.processInfo.arguments.contains("--enable-weekly-alert") { await store.setNotifications(true) }
            if ProcessInfo.processInfo.arguments.contains("--test-notification") { await store.sendTestNotification() }
            if let report = argument(after: "--installation-report") {
                await writeInstallationReport(to: URL(fileURLWithPath: report))
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !isDiagnostic, !isSmokeTest else { return false }
        showDetails(fromMenuBar: !preferences.showOrb)
        return true
    }

    private func makeApplicationMenu() {
        let main = NSMenu()
        let applicationItem = NSMenuItem()
        let application = NSMenu(title: "Codex Orbit")
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        application.addItem(settings)
        application.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 Codex Orbit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        application.addItem(quitItem)
        applicationItem.submenu = application
        main.addItem(applicationItem)
        NSApp.mainMenu = main
    }

    func applicationWillTerminate(_ notification: Notification) {
        edgeSlide.stop()
        approvalBridge.stop()
        dashboard.stop()
        savePosition()
        edgeTimer?.invalidate()
        statusLightAnimator.stop()
        cancelCollapse()
        store.stop()
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        localObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func makeMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(statusClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        item.button?.imagePosition = .imageLeading
        statusItem = item
        updateStatusItem()
    }

    private func updateStatusItem() {
        let short = store.window(.short)
        let signal = QuotaSignal(remaining: short?.remaining, stale: store.isStale || store.lastError != nil)
        statusSignal = signal
        statusLightAnimator.update(button: statusItem?.button, signal: signal,
                                   animate: !store.isSleeping && !displaySleeping && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        statusItem?.button?.title = "\(short?.shortTitle ?? "5h") \(short?.percentText ?? "—")"
        statusItem?.button?.toolTip = "Codex Orbit · \(short?.title ?? "5 小时额度")剩余 \(short?.percentText ?? "—")\n\(signal.description) · \(store.statusText)\n绿 ≥60% · 黄 30%–<60% · 红 <30%\n左键查看详情，右键打开菜单"
        statusItem?.button?.setAccessibilityLabel("Codex Orbit，\(short?.title ?? "5 小时额度")剩余 \(short?.percentText ?? "未知")，\(signal.description)，\(store.statusText)")
    }

    @objc private func statusClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
        } else if detailsPanel?.isVisible == true { hideDetails() }
        else { showDetails(fromMenuBar: true) }
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, key: String = "") {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self; menu.addItem(item)
        }
        add("查看额度", #selector(showFromMenu))
        add("立即刷新", #selector(refreshFromMenu), key: "r")
        menu.addItem(.separator())
        add(preferences.showOrb ? "隐藏悬浮球" : "显示悬浮球", #selector(toggleOrb))
        add("悬浮球移回主屏幕", #selector(resetOrbPosition))
        add("设置…", #selector(openSettings), key: ",")
        add("打开 Codex", #selector(openCodex))
        menu.addItem(.separator())
        add("退出 Codex Orbit", #selector(quit), key: "q")
        self.menu = menu
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func showFromMenu() { showDetails(fromMenuBar: true) }
    @objc private func refreshFromMenu() { Task { await store.refresh() } }
    @objc private func toggleOrb() { preferences.showOrb.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func configurePanel(_ panel: NSPanel) {
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
    }

    private func makeOrb() {
        let initialSize = NSSize(width: 164 * preferences.scale, height: 176 * preferences.scale)
        let panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: initialSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configurePanel(panel)
        panel.title = "Codex Orbit 悬浮球"
        panel.hasShadow = false
        let root = OrbView(store: store, preferences: preferences,
                           openDetails: { [weak self] in
                               guard let self, self.dragStart == nil else { return }
                               if self.detailsPanel?.isVisible == true { self.hideDetails() } else { self.showDetails() }
                           }, dragChanged: { [weak self] start, point in self?.dragOrb(from: .orb, start: start, to: point) },
                           dragEnded: { [weak self] in self?.finishDrag() },
                           contextMenu: { [weak self] in self?.openSettings() },
                           hoverChanged: { [weak self] _ in self?.updateEdgeVisibility() })
        let hosting = NSHostingView(rootView: root)
        // Window geometry belongs to the dock controller, not SwiftUI's intrinsic size.
        hosting.sizingOptions = []
        hosting.frame = panel.contentView?.bounds ?? .zero
        panel.contentView = hosting
        hosting.setBoundsSize(NSSize(width: 164, height: 176))
        orbPanel = panel
        previousScale = preferences.scale
        let defaults = UserDefaults.standard
        if !isSmokeTest, defaults.object(forKey: "orbX") != nil {
            panel.setFrameOrigin(NSPoint(x: defaults.double(forKey: "orbX"), y: defaults.double(forKey: "orbY")))
            keepOrbOnScreen()
        } else { positionOnMainScreen() }
    }

    private func applyPreferences() {
        guard let panel = orbPanel else { return }
        if preferences.scale != previousScale {
            let previousFrame = panel.frame
            let size = NSSize(width: 164 * preferences.scale, height: 176 * preferences.scale)
            var frame = NSRect(origin: previousFrame.origin, size: size)
            if let visible = bestScreen(for: previousFrame).map({ preferences.autoHideAtEdge ? dockArea(for: $0) : $0.visibleFrame }),
               let edge = EdgeDockGeometry.edge(of: previousFrame, in: visible) {
                frame = EdgeDockGeometry.expandedFrame(edge: edge, visible: visible, size: size, centerY: previousFrame.midY, compact: preferences.autoHideAtEdge)
            }
            panel.setFrame(frame, display: true)
            if let hosting = panel.contentView as? NSHostingView<OrbView> {
                // NSHostingView alone relayouts instead of scaling; use its layer transform.
                hosting.setBoundsSize(NSSize(width: 164, height: 176))
            }
            previousScale = preferences.scale
            keepOrbOnScreen()
        }
        panel.alphaValue = preferences.opacity
        if !preferences.showOrb {
            cancelCollapse(); hideHoverDetails(); panel.orderOut(nil); edgePanel?.orderOut(nil)
        } else if edgeState.isCollapsed && preferences.autoHideAtEdge {
            edgePanel?.alphaValue = preferences.opacity
        } else if !panel.isVisible { panel.orderFrontRegardless() }
        if preferences.appearance != previousAppearance {
            let appearance: NSAppearance?
            switch preferences.appearance {
            case "light": appearance = NSAppearance(named: .aqua)
            case "dark": appearance = NSAppearance(named: .darkAqua)
            default: appearance = nil
            }
            NSApp.appearance = appearance
            previousAppearance = preferences.appearance
        }
        updateEdgeVisibility()
    }

    private func makeEdgePanel() {
        let panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: EdgeDockGeometry.tabSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configurePanel(panel)
        panel.title = "Codex Orbit 侧边标签"
        panel.hasShadow = false
        let hosting = NSHostingView(rootView: EdgeTabView(store: store, activity: activity, state: edgeState,
            hoverChanged: { [weak self] _ in self?.updateEdgeVisibility() },
            openDetails: { [weak self] in self?.showHoverDetails(force: true) },
            openSettings: { [weak self] in self?.openSettings() },
            dragChanged: { [weak self] start, point in self?.dragOrb(from: .capsule, start: start, to: point) },
            dragEnded: { [weak self] in self?.finishDrag() }))
        hosting.sizingOptions = []
        panel.contentView = hosting
        edgePanel = panel
    }

    private func startEdgeMonitoring() {
        guard !isSmokeTest else { return }
        let timer = Timer(timeInterval: 0.20, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateEdgeVisibility() }
        }
        RunLoop.main.add(timer, forMode: .common)
        edgeTimer = timer
    }

    private var edgeProtection: EdgeDockProtection {
        EdgeDockProtection(dragging: dragStart != nil,
                           showingDetails: detailsPanel?.isVisible == true || approvalPanels.isExpanded,
                           showingSettings: settingsWindow?.isVisible == true,
                           trackingMenu: trackingMenu)
    }

    private func edgeGeometry() -> (edge: DockEdge, tab: NSRect)? {
        guard let panel = orbPanel, let visible = bestScreen(for: panel.frame).map({ dockArea(for: $0) }),
              let edge = EdgeDockGeometry.edge(of: panel.frame, in: visible) else { return nil }
        return (edge, EdgeDockGeometry.tabFrame(edge: edge, visible: visible, expanded: panel.frame, scale: preferences.scale))
    }

    private func cancelCollapse() { collapseTask?.cancel(); collapseTask = nil }

    private func dockOrbIfNeeded() {
        guard preferences.showOrb, preferences.autoHideAtEdge, preferences.snapToEdge, !edgeProtection.holdsExpanded,
              edgeGeometry() == nil, let panel = orbPanel,
              let visible = bestScreen(for: panel.frame).map({ dockArea(for: $0) }) else { return }
        let edge = EdgeDockGeometry.nearestEdge(of: panel.frame, in: visible)
        panel.setFrame(EdgeDockGeometry.expandedFrame(edge: edge, visible: visible, size: panel.frame.size, centerY: panel.frame.midY, compact: true), display: true)
        savePosition()
    }

    private func expandOrb() {
        edgeSlide.stop()
        hideHoverDetails()
        cancelCollapse()
        edgePanel?.orderOut(nil)
        guard preferences.showOrb else { return }
        keepOrbOnScreen(allowCompact: false)
        let wasCollapsed = edgeState.isCollapsed
        if wasCollapsed { edgeState.isCollapsed = false }
        if wasCollapsed || orbPanel?.isVisible != true { orbPanel?.orderFrontRegardless() }
    }

    private func stopEdgeMotionForSleep() {
        edgeSlide.stop()
        hideHoverDetails()
        edgeState.isTucked = true
        collapseOrb()
    }

    private func collapseOrb(pointer _: NSPoint? = nil) {
        dockOrbIfNeeded()
        guard preferences.showOrb, preferences.autoHideAtEdge, dragStart == nil,
              let geometry = edgeGeometry(), let panel = orbPanel, let edgePanel else { return }
        if edgeState.edge != geometry.edge { edgeState.edge = geometry.edge }
        let animated = (!isSmokeTest || animateEdgeDuringTest) && edgePanel.isVisible &&
            !store.isSleeping && !displaySleeping && !(reducedEdgeMotionForTest ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        if edgeProtection.holdsExpanded {
            edgeSlide.stop()
            layoutEdgePanel(progress: edgeState.revealProgress)
        } else {
            edgeSlide.move(from: edgeState.revealProgress, to: edgeState.isTucked ? 0 : 1, animated: animated) { [weak self] progress in
                self?.layoutEdgePanel(progress: progress)
            }
        }
        edgePanel.alphaValue = preferences.opacity
        edgeState.isCollapsed = true
        if !edgePanel.isVisible { edgePanel.orderFrontRegardless() }
        panel.orderOut(nil)
    }

    private func layoutEdgePanel(progress: Double) {
        guard preferences.showOrb, preferences.autoHideAtEdge, let geometry = edgeGeometry(), let edgePanel else { edgeSlide.stop(); return }
        let wasUpdating = updatingEdgeVisibility
        updatingEdgeVisibility = true
        defer { updatingEdgeVisibility = wasUpdating }
        let frame = EdgeDockGeometry.slideFrame(edge: geometry.edge, tab: geometry.tab, progress: progress)
        if edgeState.revealProgress != progress { edgeState.revealProgress = progress }
        if edgePanel.frame != frame { edgePanel.setFrame(frame, display: true) }
        if edgePanel.contentView?.bounds.size != frame.size { edgePanel.contentView?.setBoundsSize(frame.size) }
        if let popup = hoverDetailsPanel, popup.isVisible {
            popup.alphaValue = progress
            if progress == 0 && edgeState.isTucked { popup.orderOut(nil); popup.alphaValue = 1 }
        }
        if progress == 0 || progress == 1 { updateApprovalPanels(); updateQuotaHUD() }
    }

    private func showHoverDetails(force: Bool = false) {
        if force { hoverDismissedUntilExit = false }
        guard preferences.showOrb, preferences.autoHideAtEdge, dragStart == nil, edgeGeometry() != nil else { return }
        if edgeState.isTucked { edgeState.isTucked = false; collapseOrb() }
        guard !approvalPanels.isExpanded, !hoverDismissedUntilExit, preferences.showOrb, preferences.autoHideAtEdge,
              !edgeProtection.holdsExpanded, let geometry = edgeGeometry(),
              let visible = bestScreen(for: geometry.tab)?.visibleFrame else { return }
        cancelCollapse()
        collapseOrb()
        let wasVisible = hoverDetailsPanel?.isVisible == true
        if hoverDetailsPanel == nil {
            let panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: EdgeDockGeometry.detailsSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            configurePanel(panel)
            panel.title = "Codex Orbit 侧边额度详情"
            panel.hasShadow = true
            let hosting = NSHostingView(rootView: SideQuotaDetailsView(store: store, activity: activity, dashboard: dashboard,
                close: { [weak self] in self?.hideHoverDetails(manually: true) },
                openSettings: { [weak self] in self?.openSettings() },
                openCodex: { [weak self] in self?.openCodex() },
                refresh: { [weak self] in self?.refreshDashboard() },
                hoverChanged: { [weak self] _ in self?.updateEdgeVisibility() }))
            hosting.sizingOptions = []
            panel.contentView = hosting
            hoverDetailsPanel = panel
        }
        let frame = EdgeDockGeometry.detailsFrame(edge: geometry.edge, visible: visible, tab: geometry.tab)
        if hoverDetailsPanel?.frame != frame { hoverDetailsPanel?.setFrame(frame, display: true) }
        hoverDetailsPanel?.alphaValue = edgeState.revealProgress
        if hoverDetailsPanel?.isVisible != true { hoverDetailsPanel?.orderFrontRegardless() }
        if !isSmokeTest, !wasVisible { Task { await refreshDashboardData() } }
        if !isSmokeTest, !wasVisible, (store.snapshot == nil || store.isStale), Date() >= store.nextRefreshAt { Task { await store.refresh() } }
    }

    private func refreshDashboardData(force: Bool = false) async {
        await dashboard.refresh(account: store.snapshot?.account.identity, customPath: preferences.customCLI, force: force)
    }

    private func updateDashboardAccount() {
        dashboard.synchronize(account: store.snapshot?.account.identity)
        if !isSmokeTest, hoverDetailsPanel?.isVisible == true, dashboard.refreshDue {
            Task { await refreshDashboardData() }
        }
    }

    private func refreshDashboard() {
        Task {
            await store.refresh()
            await refreshDashboardData(force: true)
        }
    }

    private func hideHoverDetails(manually: Bool = false) {
        cancelCollapse()
        if manually { hoverDismissedUntilExit = true }
        hoverDetailsPanel?.orderOut(nil)
    }

    private func dismissHoverDetailsIfOutside(pointer: NSPoint? = nil) {
        guard !edgeProtection.holdsExpanded, let tab = edgePanel?.frame, edgeGeometry() != nil else { return }
        let details = hoverDetailsPanel?.isVisible == true ? hoverDetailsPanel?.frame : nil
        guard !EdgeDockGeometry.pointerIsInsideSidebar(pointer ?? edgeTestPointer ?? NSEvent.mouseLocation, tab: tab, details: details) else { cancelCollapse(); return }
        cancelCollapse()
        edgeState.isTucked = true
        collapseOrb()
        updateApprovalPanels(); updateQuotaHUD()
    }

    private func updateEdgeVisibility(pointer: NSPoint? = nil) {
        // Frame changes can synchronously emit tracking-area callbacks. Finish
        // one transition before handling the next hover notification.
        guard !updatingEdgeVisibility else { return }
        updatingEdgeVisibility = true
        defer { updatingEdgeVisibility = false }
        if argument(after: "--edge-self-test") != nil, let pointer { edgeTestPointer = pointer }
        guard !store.isSleeping else { hideHoverDetails(); return }
        guard preferences.showOrb else {
            edgeSlide.stop()
            hideHoverDetails(); hoverDismissedUntilExit = false
            edgeState.isTucked = true
            edgeState.revealProgress = 0
            edgePanel?.orderOut(nil); orbPanel?.orderOut(nil)
            return
        }
        // A moving capsule owns its frame until mouse-up. In particular, don't
        // reveal the old orb or let the 200 ms docking timer reset this frame.
        guard dragStart == nil else { cancelCollapse(); return }
        dockOrbIfNeeded()
        guard preferences.autoHideAtEdge, let geometry = edgeGeometry(), orbPanel != nil, dragStart == nil else {
            expandOrb(); return
        }
        collapseOrb()
        if hoverDetailsPanel?.isVisible == true, let visible = bestScreen(for: geometry.tab)?.visibleFrame {
            let frame = EdgeDockGeometry.detailsFrame(edge: geometry.edge, visible: visible, tab: geometry.tab)
            if hoverDetailsPanel?.frame != frame { hoverDetailsPanel?.setFrame(frame, display: true) }
        }
        if edgeProtection.holdsExpanded { cancelCollapse(); return }
        let point = pointer ?? edgeTestPointer ?? NSEvent.mouseLocation
        let details = hoverDetailsPanel?.isVisible == true ? hoverDetailsPanel?.frame : nil
        let activeTab = edgePanel?.frame ?? geometry.tab
        let inside = EdgeDockGeometry.pointerIsInsideSidebar(point, tab: activeTab, details: details)
        if !inside { hoverDismissedUntilExit = false }
        if activeTab.insetBy(dx: -2, dy: -3).contains(point) || (inside && edgeState.isTucked) {
            showHoverDetails()
        } else if !edgeState.isTucked {
            if inside { cancelCollapse() }
            else if collapseTask == nil {
                let pointerOverride = pointer
                collapseTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: 320_000_000) } catch { return }
                    self?.collapseTask = nil
                    self?.dismissHoverDetailsIfOutside(pointer: pointerOverride)
                }
            }
        }
    }

    private func dragOrb(from source: DragSource, start: NSPoint, to mouse: NSPoint) {
        guard let panel = source == .capsule ? edgePanel : orbPanel else { return }
        if dragStart == nil {
            guard panel.isVisible else { return }
            edgeSlide.stop()
            dragStart = (start, panel.frame.origin, source)
            hideDetails()
        }
        cancelCollapse()
        if let start = dragStart, start.source == source {
            panel.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y))
            if source == .capsule, let orb = orbPanel {
                orb.setFrameOrigin(NSPoint(x: panel.frame.midX - orb.frame.width / 2, y: panel.frame.midY - orb.frame.height / 2))
            }
        }
        updateApprovalPanels(); updateQuotaHUD()
    }

    private func finishDrag() {
        guard let start = dragStart else { return }
        dragStart = nil
        guard let panel = orbPanel else { return }
        let footprint = start.source == .capsule ? (edgePanel?.frame ?? panel.frame) : panel.frame
        let screen = bestScreen(for: footprint)
        if preferences.snapToEdge, let visible = screen.map({ dockArea(for: $0) }) {
            let edge = EdgeDockGeometry.nearestEdge(of: footprint, in: visible)
            panel.setFrame(EdgeDockGeometry.expandedFrame(edge: edge, visible: visible, size: panel.frame.size,
                                                         centerY: footprint.midY, compact: preferences.autoHideAtEdge), display: true)
        } else { keepOrbOnScreen() }
        savePosition()
        hoverDismissedUntilExit = true
        edgeState.isTucked = false
        updateEdgeVisibility()
        updateApprovalPanels(); updateQuotaHUD()
    }

    private func bestScreen(for rect: NSRect) -> NSScreen? {
        NSScreen.screens.max { a, b in
            let ia = a.visibleFrame.intersection(rect), ib = b.visibleFrame.intersection(rect)
            return max(0, ia.width) * max(0, ia.height) < max(0, ib.width) * max(0, ib.height)
        }
    }

    private func dockArea(for screen: NSScreen) -> NSRect {
        // Use the physical display edges even when the Dock occupies one side;
        // retain the work area's vertical safety margins for menu bar and Dock.
        NSRect(x: screen.frame.minX, y: screen.visibleFrame.minY,
               width: screen.frame.width, height: screen.visibleFrame.height)
    }

    private func positionOnMainScreen() {
        guard let panel = orbPanel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 8, y: visible.midY - panel.frame.height / 2))
    }

    @objc func resetOrbPosition() {
        positionOnMainScreen()
        preferences.showOrb = true
        savePosition()
    }

    private func keepOrbOnScreen(allowCompact: Bool = true) {
        guard let panel = orbPanel else { return }
        guard let screen = bestScreen(for: panel.frame) else { return }
        var frame = panel.frame
        let visible = allowCompact && preferences.autoHideAtEdge ? dockArea(for: screen) : screen.visibleFrame
        if frame.intersection(visible).isEmpty { positionOnMainScreen(); return }
        if allowCompact, preferences.autoHideAtEdge, let edge = EdgeDockGeometry.edge(of: frame, in: visible) {
            frame = EdgeDockGeometry.expandedFrame(edge: edge, visible: visible, size: frame.size, centerY: frame.midY, compact: true)
        } else {
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            savePosition()
        }
    }

    private func savePosition() {
        guard !isSmokeTest, let panel = orbPanel else { return }
        UserDefaults.standard.set(panel.frame.minX, forKey: "orbX")
        UserDefaults.standard.set(panel.frame.minY, forKey: "orbY")
    }

    func showDetails(fromMenuBar: Bool = false) {
        hideHoverDetails()
        if preferences.showOrb && preferences.autoHideAtEdge && edgeGeometry() != nil { collapseOrb() } else { expandOrb() }
        if detailsPanel == nil {
            let panel = DetailsPanel(contentRect: NSRect(x: 0, y: 0, width: 364, height: 430), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            configurePanel(panel)
            panel.title = "Codex Orbit 额度详情"
            panel.hasShadow = true
            panel.becomesKeyOnlyIfNeeded = true
            let hosting = NSHostingView(rootView: DetailsView(store: store, preferences: preferences,
                openSettings: { [weak self] in self?.openSettings() }, close: { [weak self] in self?.hideDetails() }))
            panel.contentView = hosting
            detailsPanel = panel
        }
        resizeDetails()
        guard let panel = detailsPanel else { return }
        let anchor: NSRect
        if fromMenuBar, let button = statusItem?.button, let window = button.window {
            anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        } else { anchor = orbPanel?.frame ?? NSRect(x: 100, y: 100, width: 164, height: 176) }
        let visible = bestScreen(for: anchor)?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var origin: NSPoint
        if fromMenuBar { origin = NSPoint(x: anchor.midX - panel.frame.width / 2, y: visible.maxY - panel.frame.height - 6) }
        else {
            let left = anchor.minX - panel.frame.width + 8
            origin = NSPoint(x: left >= visible.minX ? left : anchor.maxX - 8, y: anchor.midY - panel.frame.height / 2)
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - panel.frame.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - panel.frame.height)
        panel.setFrameOrigin(origin)
        panel.makeKeyAndOrderFront(nil)
        if !isSmokeTest, store.snapshot == nil || Date().timeIntervalSince(store.snapshot!.fetchedAt) >= 15 { Task { await store.refresh() } }
    }

    private func resizeDetails() {
        guard let panel = detailsPanel, let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let fitting = content.fittingSize
        let height = min(max(340, ceil(fitting.height)), (panel.screen?.visibleFrame.height ?? 900) - 20)
        if abs(panel.frame.height - height) > 1 {
            var frame = panel.frame
            frame.origin.y += frame.height - height
            frame.size = NSSize(width: 364, height: height)
            panel.setFrame(frame, display: true)
            if panel.isVisible, let visible = panel.screen?.visibleFrame, frame.minY < visible.minY { panel.setFrameOrigin(NSPoint(x: frame.minX, y: visible.minY)) }
        }
    }

    func hideDetails() {
        detailsPanel?.orderOut(nil)
        hideHoverDetails(manually: true)
        updateEdgeVisibility()
    }

    @objc func openSettings() {
        launchAtLogin.refresh()
        hideDetails()
        if preferences.showOrb && preferences.autoHideAtEdge && edgeGeometry() != nil { collapseOrb() } else { expandOrb() }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 650), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Codex Orbit 设置"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: OrbitSettingsView(store: store, preferences: preferences, launchAtLogin: launchAtLogin,
                resetPosition: { [weak self] in self?.resetOrbPosition() },
                chooseCLI: { [weak self] in self?.chooseCLI() }, openCodex: { [weak self] in self?.openCodex() },
                previewHUD: { [weak self] level in self?.previewQuotaHUD(level) },
                approvalBridge: approvalBridge, activity: activity, previewApproval: { [weak self] in
                    guard let self, let screen = self.hudScreen() else { return }
                    self.approvalPanels.preview(visible: screen.visibleFrame, anchor: self.hudAnchor)
                }))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        cancelCollapse()
    }

    private func updateActivity() {
        activity.update(waitingRequests: approvalBridge.requests,
                        awake: !store.isSleeping && !displaySleeping,
                        visible: preferences.animateWhenWorking && (edgePanel?.isVisible == true || orbPanel?.isVisible == true))
    }

    private func updateApprovalPanels() {
        guard let visible = hudScreen()?.visibleFrame else { return }
        approvalPanels.update(visible: visible, anchor: hudAnchor, suspended: store.isSleeping || displaySleeping)
    }

    private func updateQuotaHUD() {
        guard !isDiagnostic, !isSmokeTest, let visible = hudScreen()?.visibleFrame else { return }
        quotaHUD.update(snapshot: store.snapshot,
                        fresh: !store.isStale && store.lastError == nil && !store.isSleeping && !displaySleeping,
                        enabled: preferences.hudAlerts, visible: visible, anchor: hudAnchor,
                        obstacle: approvalPanels.obstacle ?? (hoverDetailsPanel?.isVisible == true ? hoverDetailsPanel?.frame : nil))
    }

    private var hudAnchor: CGRect? {
        if edgePanel?.isVisible == true { return edgePanel?.frame }
        if orbPanel?.isVisible == true { return orbPanel?.frame }
        return nil
    }

    private func hudScreen() -> NSScreen? {
        hudAnchor.flatMap { bestScreen(for: $0) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func previewQuotaHUD(_ level: QuotaHUDLevel) {
        guard let visible = hudScreen()?.visibleFrame else { return }
        quotaHUD.preview(level, visible: visible, anchor: hudAnchor,
                         obstacle: approvalPanels.obstacle ?? (hoverDetailsPanel?.isVisible == true ? hoverDetailsPanel?.frame : nil))
    }

    private func chooseCLI() {
        let panel = NSOpenPanel()
        panel.title = "选择 Codex 可执行文件"
        panel.message = "选择 codex 文件。Codex 应用内的 CLI 也可使用。"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.customCLI = url.path
        Task { await store.refresh(reconnect: true) }
    }

    @objc private func openCodex() {
        for path in ["/Applications/Codex.app", "/Applications/ChatGPT.app", FileManager.default.homeDirectoryForCurrentUser.path + "/Applications/Codex.app"] {
            if FileManager.default.fileExists(atPath: path) { NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init()); return }
        }
        if let url = URL(string: "https://developers.openai.com/codex/app/") { NSWorkspace.shared.open(url) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    private func diagnosticObject() -> [String: Any] {
        var result: [String: Any] = ["application": "Codex Orbit", "version": "0.8.2", "status": store.statusText, "cliDetected": store.cliPath != nil]
        if let error = store.lastError { result["error"] = error }
        if let snapshot = store.snapshot {
            result["accountType"] = snapshot.account.type
            result["plan"] = snapshot.account.planType ?? "unknown"
            result["fetchedAt"] = ISO8601DateFormatter().string(from: snapshot.fetchedAt)
            result["ordinaryUsageAllowed"] = snapshot.limits.ordinaryUsageAllowed ?? NSNull() as Any
            result["buckets"] = snapshot.limits.buckets.map { bucket -> [String: Any] in
                var value: [String: Any] = ["id": bucket.id]
                for period in QuotaPeriod.allCases {
                    if let window = bucket.window(period) {
                        value[period.rawValue] = ["title": window.title, "remainingPercent": window.remaining ?? NSNull() as Any, "windowMinutes": window.windowDurationMins ?? NSNull() as Any, "resetsAt": window.resetsAt ?? NSNull() as Any]
                    }
                }
                return value
            }
        }
        result["dashboardTokensAvailable"] = dashboard.tokens != nil
        result["dashboardDailyBucketCount"] = dashboard.tokens?.dailyUsageBuckets?.count ?? 0
        result["dashboardRecentSessionCount"] = dashboard.sessions.count
        result["dashboardMeasuredSessionCount"] = dashboard.sessions.compactMap(\.localTokens).count
        result["dashboardTokenError"] = dashboard.tokenError ?? NSNull() as Any
        return result
    }

    private func diagnose() async {
        await store.refresh()
        await refreshDashboardData(force: true)
        if let data = try? JSONSerialization.data(withJSONObject: diagnosticObject(), options: [.prettyPrinted, .sortedKeys]), let string = String(data: data, encoding: .utf8) { print(string) }
        let success = store.snapshot != nil && store.lastError == nil
        dashboard.stop()
        store.stop()
        exit(success ? 0 : 1)
    }

    private func argument(after key: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: key), args.count > index + 1 else { return nil }
        return args[index + 1]
    }

    private func writeInstallationReport(to url: URL) async {
        // Let the first real reading and its animation reach the menu bar before reporting.
        for _ in 0..<100 {
            if store.snapshot != nil || store.lastError != nil { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try? await Task.sleep(nanoseconds: 350_000_000)
        launchAtLogin.refresh()
        let notifications = await UNUserNotificationCenter.current().notificationSettings()
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        let geometry = edgeGeometry()
        let report: [String: Any] = ["bundlePath": Bundle.main.bundleURL.path, "version": "0.8.2",
                                   "loginItemStatus": launchAtLogin.statusCode,
                                   "loginItemEnabled": launchAtLogin.isEnabled,
                                   "autoHideAtEdge": preferences.autoHideAtEdge,
                                   "snapToEdge": preferences.snapToEdge,
                                   "showOrb": preferences.showOrb,
                                   "sidePanelVisible": edgePanel?.isVisible == true,
                                   "sidePanelCollapsed": edgeState.isCollapsed,
                                   "sidePanelTucked": edgeState.isTucked,
                                   "sidePanelFrame": edgePanel.map { NSStringFromRect($0.frame) } ?? "none",
                                   "dockEdge": geometry?.edge.rawValue ?? "none",
                                   "expandedFrame": orbPanel.map { NSStringFromRect($0.frame) } ?? "none",
                                   "interactionProtectsExpansion": edgeProtection.holdsExpanded,
                                   "pointerInsideSidebar": geometry.map { EdgeDockGeometry.pointerIsInsideSidebar(NSEvent.mouseLocation, tab: $0.tab, details: hoverDetailsPanel?.isVisible == true ? hoverDetailsPanel?.frame : nil) } ?? false,
                                   "hoverDetailsVisible": hoverDetailsPanel?.isVisible == true,
                                   "orbVisible": orbPanel?.isVisible == true,
                                   "hoverDashboardSize": [EdgeDockGeometry.detailsSize.width, EdgeDockGeometry.detailsSize.height],
                                   "sidePanelSize": [edgePanel?.frame.width ?? 0, edgePanel?.frame.height ?? 0],
                                   "sidePanelExpandedSize": [EdgeDockGeometry.tabSize.width, EdgeDockGeometry.tabSize.height],
                                   "sidePanelHiddenSize": [EdgeDockGeometry.handleSize.width, EdgeDockGeometry.handleSize.height],
                                   "sidePanelProvider": "codex",
                                   "sidePanelLayout": "compact-provider-row",
                                   "providerIconLoaded": ProviderArtwork.codex != nil,
                                   "harnessPhase": activity.phase.rawValue,
                                   "thinkingAnimationActive": activity.animationActive,
                                   "activityHookStatus": activity.hookStatus,
                                   "approvalBridgeListening": approvalBridge.isListening,
                                   "approvalBridgeEnabled": approvalBridge.enabled,
                                   "approvalBridgeStatus": approvalBridge.status,
                                   "hudSize": [QuotaHUDGeometry.size.width, QuotaHUDGeometry.size.height],
                                   "hudAlertsEnabled": preferences.hudAlerts,
                                   "hudVisible": quotaHUD.isVisible,
                                   "weeklyAlertsEnabled": preferences.notifications,
                                   "notificationAuthorization": notifications.authorizationStatus.rawValue,
                                   "notificationAlertStyle": notifications.alertStyle.rawValue,
                                   "notificationAlertsEnabled": notifications.alertSetting == .enabled,
                                   "notificationMessage": store.notificationMessage ?? NSNull() as Any,
                                   "testNotificationDelivered": delivered.contains { $0.request.identifier == "orbit-notification-test" },
                                   "statusItemTitle": statusItem?.button?.title ?? "",
                                   "statusSignal": statusSignal?.rawValue ?? "unknown",
                                   "statusLightAnimating": statusLightAnimator.isAnimating,
                                   "statusLightFramesRendered": statusLightAnimator.renderedFrameCount,
                                   "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                                   "error": launchAtLogin.errorMessage ?? NSNull() as Any]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]) { try? data.write(to: url) }
        exportView(statusItem?.button, to: url.deletingLastPathComponent().appendingPathComponent("installed-status-item.png"))
    }

    private func edgeSelfTest(report url: URL) async {
        // Test our window controller directly; never synthesize system pointer events.
        let oldShow = preferences.showOrb, oldHide = preferences.autoHideAtEdge, oldScale = preferences.scale, oldSnap = preferences.snapToEdge
        preferences.showOrb = true; preferences.autoHideAtEdge = true
        preferences.snapToEdge = true
        positionOnMainScreen()
        var results: [String: Bool] = [:]
        let outside = NSPoint(x: NSScreen.main?.visibleFrame.midX ?? 0, y: NSScreen.main?.visibleFrame.midY ?? 0)
        if let panel = orbPanel, let visible = bestScreen(for: panel.frame).map({ dockArea(for: $0) }) {
            let free = NSRect(x: visible.midX - panel.frame.width / 2, y: visible.midY - panel.frame.height / 2, width: panel.frame.width, height: panel.frame.height)
            expandOrb()
            preferences.snapToEdge = false
            panel.setFrame(free, display: true)
            let freeFrame = panel.frame
            updateEdgeVisibility(pointer: outside)
            results["disabledSnapKeepsFreePosition"] = edgeGeometry() == nil && panel.frame == freeFrame
            preferences.snapToEdge = true
            preferences.autoHideAtEdge = false
            updateEdgeVisibility(pointer: outside)
            results["disabledAutoHideKeepsFreePosition"] = edgeGeometry() == nil && panel.frame == freeFrame
            preferences.autoHideAtEdge = true
            updateEdgeVisibility(pointer: outside)
            results["offEdgePositionAutomaticallyDocks"] = edgeGeometry() != nil && visible.contains(panel.frame)
        }
        collapseOrb(pointer: outside)
        results["collapsedLeavesVisibleTab"] = edgeState.isCollapsed && edgePanel?.isVisible == true && orbPanel?.isVisible == false
        results["idleSidebarUsesNarrowHandle"] = edgeState.isTucked && edgePanel?.frame.size == EdgeDockGeometry.handleSize
        if let rect = edgeGeometry()?.tab, let handle = edgePanel?.frame {
            updateEdgeVisibility(pointer: NSPoint(x: rect.midX, y: rect.midY))
            results["emptyFormerCapsuleAreaDoesNotReveal"] = edgeState.isTucked && hoverDetailsPanel?.isVisible != true
            let capsulePoint = NSPoint(x: handle.midX, y: handle.midY)
            updateEdgeVisibility(pointer: capsulePoint)
            results["hoverShowsDetailsWithoutOrb"] = hoverDetailsPanel?.isVisible == true && edgePanel?.isVisible == true && orbPanel?.isVisible == false
            results["revealKeepsEdgeAndHeight"] = !edgeState.isTucked && edgePanel?.frame == rect
            if let popup = hoverDetailsPanel?.frame {
                updateEdgeVisibility(pointer: NSPoint(x: popup.midX, y: popup.midY))
                results["pointerInsideDetailsKeepsThemOpen"] = hoverDetailsPanel?.isVisible == true && collapseTask == nil
                updateEdgeVisibility(pointer: NSPoint(x: (popup.maxX + rect.minX) / 2, y: rect.midY))
                results["crossingGapKeepsDetailsOpen"] = hoverDetailsPanel?.isVisible == true && collapseTask == nil
            }
            updateEdgeVisibility(pointer: outside)
            results["leavingBothSchedulesDismissal"] = collapseTask != nil
            try? await Task.sleep(nanoseconds: 450_000_000)
            results["leavingBothClosesOnlyDetails"] = hoverDetailsPanel?.isVisible == false && edgePanel?.isVisible == true && orbPanel?.isVisible == false
            results["leavingBothTucksFullCapsule"] = edgeState.isTucked && edgePanel?.frame.size == EdgeDockGeometry.handleSize
            showHoverDetails(force: true)
            hideHoverDetails(manually: true)
            updateEdgeVisibility(pointer: capsulePoint)
            results["manualDismissWaitsForExit"] = hoverDetailsPanel?.isVisible == false
            updateEdgeVisibility(pointer: outside)
            updateEdgeVisibility(pointer: capsulePoint)
            results["reentryReopensDetails"] = hoverDetailsPanel?.isVisible == true
            hideHoverDetails(manually: true)
            updateEdgeVisibility(pointer: outside)
            try? await Task.sleep(nanoseconds: 450_000_000)
            results["manualDashboardCloseStillAllowsAutoHide"] = edgeState.isTucked && hoverDetailsPanel?.isVisible == false && edgePanel?.frame.size == EdgeDockGeometry.handleSize
        }
        preferences.showOrb = false
        applyPreferences()
        results["hideHidesAllWindows"] = orbPanel?.isVisible == false && edgePanel?.isVisible == false && hoverDetailsPanel?.isVisible == false
        preferences.showOrb = true
        applyPreferences()
        results["restoreRecoversSidebar"] = edgePanel?.isVisible == true && orbPanel?.isVisible == false
        preferences.autoHideAtEdge = false
        applyPreferences()
        results["disableAutoHideShowsFreeOrb"] = !edgeState.isCollapsed && orbPanel?.isVisible == true && edgePanel?.isVisible == false && hoverDetailsPanel?.isVisible == false
        preferences.autoHideAtEdge = true
        applyPreferences()
        showDetails()
        collapseOrb(pointer: outside)
        results["fullDetailsKeepCapsuleAndHideOrb"] = edgePanel?.isVisible == true && orbPanel?.isVisible == false && detailsPanel?.isVisible == true
        hideDetails()
        updateEdgeVisibility(pointer: outside)
        if let rect = edgePanel?.frame, let visible = bestScreen(for: orbPanel?.frame ?? .zero).map({ dockArea(for: $0) }) {
            results["tabStaysOnScreen"] = visible.contains(rect)
        }
        for scale in [0.8, 1.0, 1.35] {
            preferences.scale = scale
            applyPreferences()
            orbPanel?.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 150_000_000)
            if let frame = orbPanel?.frame {
                results["nativeScale\(Int(scale * 100))KeepsDockGeometry"] = abs(frame.width - 164 * scale) <= 1 && abs(frame.height - 176 * scale) <= 1 && edgeGeometry() != nil
            }
        }
        preferences.scale = oldScale
        applyPreferences()
        showHoverDetails(force: true)
        // Exercise the actual NSView mouse handlers directly, without posting
        // synthetic events into the OS or moving the user's pointer.
        func dragSurface(_ view: NSView?) -> PointerDragView? {
            guard let view else { return nil }
            if let surface = view as? PointerDragView { return surface }
            return view.subviews.lazy.compactMap { dragSurface($0) }.first
        }
        func mouseEvent(_ type: NSEvent.EventType, at screenPoint: NSPoint, in window: NSWindow) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: screenPoint), modifierFlags: [],
                              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                              context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        if let panel = edgePanel, let visible = bestScreen(for: panel.frame).map({ dockArea(for: $0) }) {
            panel.contentView?.layoutSubtreeIfNeeded()
            if let surface = dragSurface(panel.contentView) {
                let initial = panel.frame, press = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
                surface.mouseDown(with: mouseEvent(.leftMouseDown, at: press, in: panel))
                surface.mouseDragged(with: mouseEvent(.leftMouseDragged, at: NSPoint(x: press.x + 1, y: press.y + 1), in: panel))
                results["smallPointerJitterDoesNotDrag"] = dragStart == nil && panel.frame == initial
                surface.mouseUp(with: mouseEvent(.leftMouseUp, at: press, in: panel))
                results["nativeCapsuleClickStillOpensDashboard"] = hoverDetailsPanel?.isVisible == true

                let target = NSPoint(x: visible.minX + 180, y: visible.midY + 90)
                surface.mouseDown(with: mouseEvent(.leftMouseDown, at: press, in: panel))
                surface.mouseDragged(with: mouseEvent(.leftMouseDragged, at: target, in: panel))
                let moving = panel.frame
                results["nativeCapsuleDragFollowsFullPointerDelta"] = abs(moving.midX - target.x) < 1 && abs(moving.midY - target.y) < 1
                updateEdgeVisibility(pointer: outside)
                results["dockingTimerDoesNotInterruptDrag"] = panel.frame == moving && dragStart != nil
                results["dragKeepsCapsuleAndHidesDashboard"] = panel.isVisible && panel.frame.size == EdgeDockGeometry.tabSize && orbPanel?.isVisible == false && hoverDetailsPanel?.isVisible == false
                // The final movement may arrive only in mouse-up, after the
                // window has already changed origin since the previous event.
                let release = NSPoint(x: visible.minX + 140, y: visible.maxY - 32)
                surface.mouseUp(with: mouseEvent(.leftMouseUp, at: release, in: panel))
                results["nativeReleaseDocksAtNewSideAndHeight"] = dragStart == nil && edgeGeometry()?.edge == .left && abs(panel.frame.midY - release.y) < 1
                results["dragDoesNotTriggerClickDashboard"] = hoverDetailsPanel?.isVisible == false
                keepOrbOnScreen()
                updateEdgeVisibility(pointer: outside)
                results["compactPositionSurvivesRestoreClamping"] = abs(panel.frame.midY - release.y) < 1

                let nextPress = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
                let nextRelease = NSPoint(x: visible.maxX - 120, y: visible.minY + 32)
                surface.mouseDown(with: mouseEvent(.leftMouseDown, at: nextPress, in: panel))
                surface.mouseDragged(with: mouseEvent(.leftMouseDragged, at: nextRelease, in: panel))
                surface.mouseUp(with: mouseEvent(.leftMouseUp, at: nextRelease, in: panel))
                results["capsuleCanDragBackToOtherEdge"] = edgeGeometry()?.edge == .right && abs(panel.frame.midY - nextRelease.y) < 1
            }
            preferences.autoHideAtEdge = false; preferences.snapToEdge = false
            applyPreferences()
            orbPanel?.contentView?.layoutSubtreeIfNeeded()
            if let orb = orbPanel, let surface = dragSurface(orb.contentView) {
                let press = NSPoint(x: orb.frame.midX, y: orb.frame.midY)
                let target = NSPoint(x: visible.midX, y: visible.midY)
                surface.mouseDown(with: mouseEvent(.leftMouseDown, at: press, in: orb))
                surface.mouseDragged(with: mouseEvent(.leftMouseDragged, at: target, in: orb))
                updateEdgeVisibility(pointer: outside)
                surface.mouseUp(with: mouseEvent(.leftMouseUp, at: target, in: orb))
                results["nativeFreeOrbDragKeepsChosenPosition"] = orb.isVisible && abs(orb.frame.midX - target.x) < 1 && abs(orb.frame.midY - target.y) < 1 && dragStart == nil
            }
            preferences.autoHideAtEdge = true; preferences.snapToEdge = true
            applyPreferences()
        }
        positionOnMainScreen()
        edgeState.isTucked = true
        collapseOrb(pointer: outside)
        try? await Task.sleep(nanoseconds: 250_000_000)
        exportView(edgePanel?.contentView, to: url.deletingLastPathComponent().appendingPathComponent("edge-tab-test.png"))
        preferences.showOrb = oldShow; preferences.autoHideAtEdge = oldHide
        preferences.snapToEdge = oldSnap
        cancelCollapse()
        if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url) }
        print("Edge UI checks: \(results)")
        store.stop()
        exit(results.count == 34 && results.values.allSatisfy({ $0 }) ? 0 : 1)
    }

    private func edgeAnimationSelfTest(report url: URL) async {
        let previous = (preferences.showOrb, preferences.autoHideAtEdge, preferences.snapToEdge)
        preferences.showOrb = true; preferences.autoHideAtEdge = true; preferences.snapToEdge = true
        positionOnMainScreen()
        let outside = NSPoint(x: NSScreen.main?.visibleFrame.midX ?? 0, y: NSScreen.main?.visibleFrame.midY ?? 0)
        edgeTestPointer = outside
        applyPreferences()
        animateEdgeDuringTest = true; reducedEdgeMotionForTest = false
        edgeState.isTucked = true; collapseOrb()
        try? await Task.sleep(nanoseconds: 300_000_000)
        var checks: [String: Bool] = [:]
        if let frame = edgePanel?.frame { edgeTestPointer = NSPoint(x: frame.midX, y: frame.midY) }
        showHoverDetails(force: true)
        checks["expandStartsWithoutJump"] = edgeSlide.isRunning && edgePanel?.frame.width == 12
        try? await Task.sleep(nanoseconds: 75_000_000)
        let openWidth = edgePanel?.frame.width ?? 0
        checks["expandHasIntermediateFrames"] = openWidth > 12 && openWidth < 108
        exportView(edgePanel?.contentView, to: url.deletingLastPathComponent().appendingPathComponent("edge-slide-midpoint.png"))
        try? await Task.sleep(nanoseconds: 260_000_000)
        checks["expandCompletesAtExactFrame"] = !edgeSlide.isRunning && edgePanel?.frame.width == 108 && hoverDetailsPanel?.alphaValue == 1
        let full = edgePanel?.frame
        edgeTestPointer = outside
        dismissHoverDetailsIfOutside(pointer: outside)
        checks["collapseStartsWithoutJump"] = edgeSlide.isRunning && edgePanel?.frame == full
        try? await Task.sleep(nanoseconds: 75_000_000)
        let closing = edgePanel?.frame ?? .zero
        checks["collapseSlidesAndFadesDashboard"] = closing.width > 12 && closing.width < 108 && (hoverDetailsPanel?.alphaValue ?? 1) < 1 && (hoverDetailsPanel?.alphaValue ?? 0) > 0
        let entry = NSPoint(x: closing.midX, y: closing.midY)
        edgeTestPointer = entry
        updateEdgeVisibility(pointer: entry)
        checks["reentryReversesWithoutPositionJump"] = !edgeState.isTucked && edgePanel?.frame == closing
        try? await Task.sleep(nanoseconds: 300_000_000)
        checks["reentryFinishesExpanded"] = !edgeSlide.isRunning && edgePanel?.frame.width == 108 && hoverDetailsPanel?.isVisible == true
        edgeTestPointer = outside
        dismissHoverDetailsIfOutside(pointer: outside)
        try? await Task.sleep(nanoseconds: 50_000_000)
        trackingMenu = true; updateEdgeVisibility(pointer: outside)
        let heldFrame = edgePanel?.frame
        try? await Task.sleep(nanoseconds: 75_000_000)
        checks["contextMenuPausesSlide"] = !edgeSlide.isRunning && edgePanel?.frame == heldFrame
        trackingMenu = false
        reducedEdgeMotionForTest = true
        edgeState.isTucked = true; collapseOrb()
        checks["reduceMotionSkipsSlide"] = !edgeSlide.isRunning && edgePanel?.frame.width == 12 && hoverDetailsPanel?.isVisible == false
        reducedEdgeMotionForTest = false
        edgeTestPointer = outside
        showHoverDetails(force: true)
        try? await Task.sleep(nanoseconds: 70_000_000)
        if let frame = edgePanel?.frame {
            let press = NSPoint(x: frame.midX, y: frame.midY)
            dragOrb(from: .capsule, start: press, to: NSPoint(x: press.x - 10, y: press.y + 10))
            let width = edgePanel?.frame.width
            try? await Task.sleep(nanoseconds: 70_000_000)
            checks["dragStopsSlideAtCurrentSize"] = !edgeSlide.isRunning && dragStart != nil && edgePanel?.frame.width == width
            finishDrag()
        }
        preferences.showOrb = false; applyPreferences()
        try? await Task.sleep(nanoseconds: 100_000_000)
        checks["hiddenWindowCannotBeResurrectedByTimer"] = !edgeSlide.isRunning && edgePanel?.isVisible == false && edgeState.revealProgress == 0
        animateEdgeDuringTest = false; reducedEdgeMotionForTest = nil; edgeSlide.stop()
        var images: [CGImage] = []
        let motion = (0...11).map { EdgeDockGeometry.slideEase(Double($0) / 11) }
        let phases = [Double](repeating: 0, count: 10) + motion + [Double](repeating: 1, count: 18) + motion.map { 1 - $0 } + [Double](repeating: 0, count: 10)
        let sample = QuotaWindow(usedPercent: 35, windowDurationMins: 300, resetsAt: Date().addingTimeInterval(3600).timeIntervalSince1970)
        for phase in phases {
            let root = ZStack(alignment: .trailing) {
                Color(red: 0.08, green: 0.105, blue: 0.12)
                EdgeSlideReadout(window: sample, edge: .right, progress: phase)
            }.frame(width: 108, height: 56).clipped().preferredColorScheme(.dark)
            let view = NSHostingView(rootView: root)
            view.sizingOptions = []; view.frame = NSRect(x: 0, y: 0, width: 108, height: 56)
            view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let image = bitmap.cgImage { images.append(image) }
            }
        }
        if let gif = CGImageDestinationCreateWithURL(url.deletingLastPathComponent().appendingPathComponent("edge-slide-preview.gif") as CFURL, "com.compuserve.gif" as CFString, images.count, nil) {
            CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            for frame in images { CGImageDestinationAddImage(gif, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.02]] as CFDictionary) }
            checks["slidePreviewExported"] = images.count == phases.count && CGImageDestinationFinalize(gif)
        }
        preferences.showOrb = previous.0; preferences.autoHideAtEdge = previous.1; preferences.snapToEdge = previous.2
        if let data = try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url) }
        print("Edge animation checks: \(checks)")
        exit(checks.count == 12 && checks.values.allSatisfy({ $0 }) ? 0 : 1)
    }

    private func activitySelfTest(report url: URL) async {
        let state = HarnessActivityStore()
        let now = Date()
        func event(_ name: String, offset: Double = 0) -> HarnessActivityEvent {
            let data = try! JSONSerialization.data(withJSONObject: ["hook_event_name": name, "session_id": "activity-native-qa", "turn_id": "qa-turn"])
            return try! HarnessActivityEvent.fromHook(data, at: now.addingTimeInterval(offset))
        }
        var checks: [String: Bool] = [:]
        state.update(waitingRequests: [], awake: true, visible: true)
        state.receive(event("UserPromptSubmit"), at: now)
        checks["startEnablesThinking"] = state.phase == .working && state.animationActive
        state.update(waitingRequests: [], awake: false, visible: true)
        checks["screenSleepPausesAnimation"] = !state.animationActive
        state.update(waitingRequests: [], awake: true, visible: false)
        checks["hiddenCapsulePausesAnimation"] = !state.animationActive
        state.update(waitingRequests: [], awake: true, visible: true)
        checks["visibleWorkingResumesAnimation"] = state.animationActive
        let input = Data("{\"hook_event_name\":\"PermissionRequest\",\"session_id\":\"activity-native-qa\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"display-only\"}}".utf8)
        let pending = try! OrbitApprovalRequest.fromHook(input)
        state.update(waitingRequests: [pending], awake: true, visible: true)
        checks["approvalWaitStopsThinking"] = state.phase == .waiting && !state.animationActive
        state.update(waitingRequests: [], awake: true, visible: true)
        checks["approvalResolvedResumesWork"] = state.phase == .working && state.animationActive
        state.receive(event("Stop", offset: 1), at: now.addingTimeInterval(1))
        checks["completedWorkStopsThinking"] = state.phase == .idle && !state.animationActive
        state.receive(event("UserPromptSubmit", offset: 2), at: now.addingTimeInterval(2))
        state.tick(at: now.addingTimeInterval(603))
        // A duplicate completed turn cannot restart animation; reset establishes a new observation.
        state.reset()
        state.receive(event("UserPromptSubmit", offset: 3), at: now.addingTimeInterval(3))
        state.tick(at: now.addingTimeInterval(604))
        checks["lostEndSignalExpiresToUnknown"] = state.phase == .unknown && !state.animationActive

        let sample = QuotaWindow(usedPercent: 18, windowDurationMins: 300, resetsAt: now.addingTimeInterval(3600).timeIntervalSince1970)
        var images: [CGImage] = []
        var uniquePNGs = Set<Data>()
        for index in 0..<20 {
            let root = EdgeTabReadout(window: sample, activityPhase: .working, animateActivity: false, fixedThinkingPhase: Double(index) / 20)
            let hosting = NSHostingView(rootView: root)
            hosting.sizingOptions = []
            hosting.frame = NSRect(origin: .zero, size: EdgeDockGeometry.tabSize)
            hosting.layoutSubtreeIfNeeded()
            if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    uniquePNGs.insert(data)
                    if index == 0 { try? data.write(to: url.deletingLastPathComponent().appendingPathComponent("thinking-frame.png")) }
                }
                if let cg = bitmap.cgImage { images.append(cg) }
            }
        }
        checks["thinkingFramesVisiblyChange"] = uniquePNGs.count >= 4
        checks["capsuleStaysCompact"] = edgePanel.map { [EdgeDockGeometry.tabSize, EdgeDockGeometry.handleSize].contains($0.frame.size) } ?? false
        var reducedFrames = Set<Data>()
        for phase in [0.0, 0.5] {
            let root = EdgeTabReadout(window: sample, activityPhase: .working, animateActivity: true, fixedThinkingPhase: phase, reduceMotionOverride: true)
            let hosting = NSHostingView(rootView: root)
            hosting.sizingOptions = []; hosting.frame = NSRect(origin: .zero, size: EdgeDockGeometry.tabSize)
            hosting.layoutSubtreeIfNeeded()
            if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) { reducedFrames.insert(data) }
            }
        }
        checks["reduceMotionKeepsWorkIndicatorStatic"] = reducedFrames.count == 1
        let livePanel = FloatingPanel(contentRect: NSRect(x: 20, y: 20, width: 108, height: 56), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configurePanel(livePanel)
        let liveView = NSHostingView(rootView: EdgeTabReadout(window: sample, activityPhase: .working, animateActivity: true, reduceMotionOverride: false))
        liveView.sizingOptions = []; livePanel.contentView = liveView; livePanel.orderFrontRegardless()
        func bitmapData() -> Data? {
            liveView.layoutSubtreeIfNeeded()
            guard let bitmap = liveView.bitmapImageRepForCachingDisplay(in: liveView.bounds) else { return nil }
            liveView.cacheDisplay(in: liveView.bounds, to: bitmap)
            return bitmap.representation(using: .png, properties: [:])
        }
        try? await Task.sleep(nanoseconds: 120_000_000)
        let firstLiveFrame = bitmapData()
        try? await Task.sleep(nanoseconds: 350_000_000)
        checks["liveTimelineActuallyAnimates"] = firstLiveFrame != nil && firstLiveFrame != bitmapData()
        livePanel.orderOut(nil)
        if let destination = CGImageDestinationCreateWithURL(url.deletingLastPathComponent().appendingPathComponent("thinking-preview.gif") as CFURL, "com.compuserve.gif" as CFString, images.count, nil) {
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            for image in images { CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.12]] as CFDictionary) }
            checks["animatedPreviewExported"] = CGImageDestinationFinalize(destination)
        }
        if let data = try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url) }
        print("Activity native checks: \(checks)")
        exit(checks.count == 13 && checks.values.allSatisfy({ $0 }) ? 0 : 1)
    }

    private func approvalSelfTest(report url: URL) async {
        let suite = "local.codexorbit.approval-qa." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let bridge = ApprovalBridge(defaults: defaults)
        let panels = ApprovalPanelController(bridge: bridge)
        let socketDirectory = url.deletingLastPathComponent().appendingPathComponent("socket-test", isDirectory: true)
        try? FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = socketDirectory.appendingPathComponent("approval.sock").path
        bridge.start(path: path)
        let visible = NSScreen.main!.visibleFrame
        let hookData = Data("{\"hook_event_name\":\"PermissionRequest\",\"session_id\":\"isolated-native-test\",\"turn_id\":\"qa-turn\",\"cwd\":\"/示例项目\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"swift build\",\"description\":\"本地隔离验收；只返回授权决定，不执行此命令。\"}}".utf8)
        let request = try! OrbitApprovalRequest.fromHook(hookData)
        func connect(_ value: OrbitApprovalRequest) -> Task<Data?, Never> {
            Task.detached {
                guard let fd = try? ApprovalSocket.connect(path: path) else { return nil }
                defer { Darwin.close(fd) }
                try? ApprovalSocket.send(JSONEncoder().encode(value), to: fd)
                return try? ApprovalSocket.receive(from: fd, timeout: 5)
            }
        }
        func waitForRequest() async {
            for _ in 0..<50 {
                if !bridge.requests.isEmpty { return }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        func decision(_ data: Data?) -> String? {
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return json["decision"] as? String
        }
        var checks: [String: Bool] = ["privateSocketListening": bridge.isListening]
        var observedActivity = false
        bridge.onActivity = { _ in observedActivity = true }
        let lifecycle = try! HarnessActivityEvent.fromHook(Data("{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"socket-activity-qa\"}".utf8))
        let activityReply = await Task.detached { () -> Data? in
            guard let fd = try? ApprovalSocket.connect(path: path) else { return nil }
            defer { Darwin.close(fd) }
            try? ApprovalSocket.send(JSONEncoder().encode(lifecycle), to: fd)
            return try? ApprovalSocket.receive(from: fd, timeout: 2)
        }.value
        try? await Task.sleep(nanoseconds: 20_000_000)
        checks["activityEventDelivered"] = observedActivity
        checks["activityAckNeverGrantsPermission"] = activityReply.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?.isEmpty == true
        checks["activityDoesNotQueueApproval"] = bridge.requests.isEmpty
        let client = connect(request)
        await waitForRequest()
        checks["realSocketDeliversFullInput"] = bridge.requests.first?.inputJSON == request.inputJSON
        panels.update(visible: visible, anchor: hudAnchor)
        checks["pendingStartsAsCompactBadge"] = panels.badgeVisible && !panels.cardVisible
        try? await Task.sleep(nanoseconds: 100_000_000)
        exportView(panels.badgeContent, to: url.deletingLastPathComponent().appendingPathComponent("approval-badge.png"))
        panels.setExpanded(true)
        checks["clickExpandsReviewCard"] = panels.cardVisible
        try? await Task.sleep(nanoseconds: 100_000_000)
        exportView(panels.cardContent, to: url.deletingLastPathComponent().appendingPathComponent("approval-card.png"))
        panels.decide(UUID(), .allow)
        checks["wrongRequestCannotApprove"] = bridge.requests.count == 1
        panels.decide(request.id, .allow)
        checks["allowSentToExactWaitingRequest"] = decision(await client.value) == "allow"
        checks["decisionClearsCard"] = bridge.requests.isEmpty && !panels.cardVisible
        let denyRequest = try! OrbitApprovalRequest.fromHook(hookData)
        let denied = connect(denyRequest)
        await waitForRequest()
        bridge.decide(denyRequest, .deny)
        checks["denyReturnsToOriginatingHook"] = decision(await denied.value) == "deny"
        let originalRequest = try! OrbitApprovalRequest.fromHook(hookData)
        let original = connect(originalRequest)
        await waitForRequest()
        bridge.enabled = false
        checks["disablingReturnsToNativePrompt"] = decision(await original.value) == "original"
        bridge.enabled = true
        // A dead hook process must remove its stale card without granting anything.
        let disconnected = try! OrbitApprovalRequest.fromHook(hookData)
        let deadClient = Task.detached {
            if let fd = try? ApprovalSocket.connect(path: path) {
                try? ApprovalSocket.send(JSONEncoder().encode(disconnected), to: fd)
                try? await Task.sleep(nanoseconds: 100_000_000)
                Darwin.close(fd)
            }
        }
        await deadClient.value
        try? await Task.sleep(nanoseconds: 350_000_000)
        checks["disconnectedRequestRemoved"] = bridge.requests.isEmpty
        panels.preview(visible: visible, anchor: hudAnchor)
        checks["previewDoesNotCreateRealRequest"] = bridge.requests.isEmpty && panels.cardVisible
        panels.setExpanded(false)
        bridge.stop()
        checks["shutdownRemovesSocket"] = !FileManager.default.fileExists(atPath: path)
        defaults.removePersistentDomain(forName: suite)
        if let data = try? JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys, .prettyPrinted]) { try? data.write(to: url) }
        print("Approval native checks: \(checks)")
        exit(checks.count == 15 && checks.values.allSatisfy({ $0 }) ? 0 : 1)
    }

    private func hudSelfTest(report url: URL) async {
        let suite = "local.codexorbit.hud-qa." + UUID().uuidString
        let isolated = UserDefaults(suiteName: suite)!
        defer { isolated.removePersistentDomain(forName: suite) }
        let hud = QuotaHUDController(defaults: isolated, testDuration: 0.18)
        let visible = NSScreen.main!.visibleFrame
        let at = Date()
        func reading(_ used: Double, week: Double = 20, account: String = "qa") -> UsageSnapshot {
            let bucket = LimitBucket(limitId: "codex", limitName: nil,
                                     primary: QuotaWindow(usedPercent: used, windowDurationMins: 300, resetsAt: at.addingTimeInterval(3600).timeIntervalSince1970),
                                     secondary: QuotaWindow(usedPercent: week, windowDurationMins: 10080, resetsAt: at.addingTimeInterval(86400).timeIntervalSince1970),
                                     planType: "plus", credits: nil, rateLimitReachedType: nil, spendControlReached: nil)
            return UsageSnapshot(account: AccountInfo(type: "chatgpt", email: nil, planType: "plus", id: account),
                                 limits: LimitsResponse(rateLimits: bucket, rateLimitsByLimitId: nil, accountId: nil, ordinaryUsageAllowed: true), fetchedAt: at)
        }
        func update(_ snapshot: UsageSnapshot?, fresh: Bool = true, enabled: Bool = true) {
            hud.update(snapshot: snapshot, fresh: fresh, enabled: enabled, visible: visible, anchor: nil)
        }
        var checks: [String: Bool] = [:]
        update(reading(20))
        checks["normalQuotaShowsNothing"] = !hud.isVisible
        update(reading(92))
        checks["lowQuotaShowsNativePanel"] = hud.isVisible && hud.currentAlert?.level == .low
        checks["panelStaysOnScreen"] = hud.frame.map { visible.contains($0) } ?? false
        update(reading(95))
        checks["sameCycleUpdatesReadout"] = hud.currentAlert?.window.remaining == 5
        try? await Task.sleep(nanoseconds: 260_000_000)
        checks["timerAutomaticallyDismisses"] = !hud.isVisible
        update(reading(96))
        checks["lowDoesNotRepeat"] = !hud.isVisible
        update(reading(100))
        checks["exhaustionStillShowsAfterLow"] = hud.isVisible && hud.currentAlert?.level == .exhausted
        update(reading(20))
        checks["recoveryHidesOutdatedWarning"] = !hud.isVisible
        update(reading(95))
        checks["correctionDoesNotRepeatLow"] = !hud.isVisible
        update(reading(95, account: "second"))
        checks["newAccountHasIndependentReminder"] = hud.isVisible
        update(reading(95, account: "stale"), fresh: false)
        checks["staleOrSignedOutHidesHUD"] = !hud.isVisible
        update(reading(95, account: "stale"))
        checks["staleReadingDidNotConsumeReminder"] = hud.isVisible
        update(reading(95, account: "disabled"), enabled: false)
        checks["disabledDoesNotShowHUD"] = !hud.isVisible
        update(reading(95, account: "disabled"))
        checks["disabledReadingDidNotConsumeReminder"] = hud.isVisible
        hud.dismiss()
        hud.preview(.exhausted, visible: visible, anchor: nil)
        checks["previewIsExplicitlyLabeled"] = hud.isVisible && hud.currentAlert?.isPreview == true
        hud.dismiss()
        let relaunched = QuotaHUDController(defaults: isolated)
        relaunched.update(snapshot: reading(100), fresh: true, enabled: true, visible: visible, anchor: nil)
        checks["relaunchKeepsDeduplication"] = !relaunched.isVisible
        update(reading(95, week: 100, account: "priority"))
        checks["exhaustedWeeklyTakesPriority"] = hud.currentAlert?.period == .weekly && hud.currentAlert?.level == .exhausted
        hud.dismiss()
        update(reading(95, week: 100, account: "priority"))
        checks["otherLowWindowIsNotLost"] = hud.currentAlert?.period == .short && hud.currentAlert?.level == .low
        hud.dismiss()
        let keyWindow = NSApp.keyWindow
        hud.pauseAnimationForCapture(true)
        for level in [QuotaHUDLevel.low, .exhausted] {
            hud.preview(level, visible: visible, anchor: nil)
            try? await Task.sleep(nanoseconds: 80_000_000)
            exportView(hud.contentView, to: url.deletingLastPathComponent().appendingPathComponent("hud-\(level == .low ? "low" : "exhausted")-preview.png"))
        }
        checks["hudDoesNotStealKeyboardFocus"] = NSApp.keyWindow === keyWindow
        hud.dismiss()
        if let data = try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url) }
        print("HUD native checks: \(checks)")
        isolated.removePersistentDomain(forName: suite)
        exit(checks.count == 19 && checks.values.allSatisfy({ $0 }) ? 0 : 1)
    }

    private func smokeTest() async {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--smoke-test"), args.count > index + 1 else { NSApp.terminate(nil); return }
        let dir = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        await store.refresh()
        await refreshDashboardData(force: true)
        if let data = try? JSONSerialization.data(withJSONObject: diagnosticObject(), options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: dir.appendingPathComponent("live-diagnostic.json")) }
        showDetails()
        // Let SwiftUI complete its next layout/display pass before exporting our own views.
        try? await Task.sleep(nanoseconds: 800_000_000)
        exportView(orbPanel?.contentView, to: dir.appendingPathComponent("orb.png"))
        exportView(detailsPanel?.contentView, to: dir.appendingPathComponent("details.png"))
        if let geometry = edgeGeometry() {
            edgeState.edge = geometry.edge
            edgeState.isTucked = false
            layoutEdgePanel(progress: 1)
            edgePanel?.setFrame(geometry.tab, display: true)
            edgePanel?.contentView?.setBoundsSize(EdgeDockGeometry.tabSize)
            exportView(edgePanel?.contentView, to: dir.appendingPathComponent("edge-tab.png"))
        }
        detailsPanel?.orderOut(nil)
        showHoverDetails(force: true)
        try? await Task.sleep(nanoseconds: 300_000_000)
        exportView(hoverDetailsPanel?.contentView, to: dir.appendingPathComponent("hover-details.png"))
        hideHoverDetails()
        edgeState.isTucked = true; collapseOrb()
        try? await Task.sleep(nanoseconds: 150_000_000)
        exportView(edgePanel?.contentView, to: dir.appendingPathComponent("edge-hidden.png"))
        previewQuotaHUD(.low)
        quotaHUD.pauseAnimationForCapture(true)
        try? await Task.sleep(nanoseconds: 400_000_000)
        exportView(quotaHUD.contentView, to: dir.appendingPathComponent("hud-low-preview.png"))
        previewQuotaHUD(.exhausted)
        try? await Task.sleep(nanoseconds: 400_000_000)
        exportView(quotaHUD.contentView, to: dir.appendingPathComponent("hud-exhausted-preview.png"))
        quotaHUD.pauseAnimationForCapture(false)
        quotaHUD.dismiss()
        openSettings()
        try? await Task.sleep(nanoseconds: 500_000_000)
        exportView(settingsWindow?.contentView, to: dir.appendingPathComponent("settings.png"))
        if args.contains("--quit-after-smoke") { NSApp.terminate(nil) }
    }

    private func exportView(_ view: NSView?, to url: URL) {
        guard let view else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: url) }
    }
}

@main
@MainActor
enum OrbitMain {
    static func main() {
        if ProcessInfo.processInfo.arguments.contains("--activity-hook") {
            ApprovalSocket.runActivityHook(); return
        }
        if ProcessInfo.processInfo.arguments.contains("--permission-hook") {
            ApprovalSocket.runHook(); return
        }
        let app = NSApplication.shared
        let delegate = OrbitAppDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
