import AppKit
import Combine
import SwiftUI

/// Hosts the Desktop Line in a transparent panel under the menu bar and
/// decides, from the pointer, when it comes down. On hover it waits above
/// the top edge and slides down when the pointer rests in the menu bar;
/// Always Show keeps it down; Only with Shortcut keeps it up until the
/// shortcut asks for it. It never hangs across a full screen app.
/// Adapted from iSnap's Capture Line (Tendedero, MIT, see DesktopLineView.swift).
@MainActor
final class DesktopLineWindowController {
    private let viewModel: DesktopLineViewModel
    private let panel: DesktopLinePanel
    private var mouseTimer: Timer?
    private var clickMonitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []

    /// Opened on purpose: it stays down until the pointer has visited it and
    /// left, or the shortcut is pressed again.
    private var isPinned = false
    private var hotZoneSince: Date?
    private var awaySince: Date?
    /// After a click in the menu bar the line stays up until the pointer
    /// leaves it, so it never comes down over an open menu.
    private var menuBarSuppressed = false
    /// Always Show: hidden on purpose with the shortcut or the menu.
    private var hiddenByUser = false
    private var isPresent = false

    private static let revealDelay: TimeInterval = 0.25
    private static let retractDelay: TimeInterval = 0.5

    init(viewModel: DesktopLineViewModel) {
        self.viewModel = viewModel
        let host = NSHostingView(rootView: DesktopLineView(viewModel: viewModel))
        host.sizingOptions = []
        panel = DesktopLinePanel(content: host)
    }

    private var visibility: LineVisibility { viewModel.visibility }

    func start() {
        panel.place(on: SpaceService.screenUnderPointer)
        viewModel.$visibility
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] visibility in self?.visibilityChanged(to: visibility) }
            .store(in: &cancellables)
        viewModel.toggleRequests
            .sink { [weak self] in self?.toggle() }
            .store(in: &cancellables)
        viewModel.spaceChanges
            .sink { [weak self] in self?.refreshPresence() }
            .store(in: &cancellables)
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.place(on: self?.panel.screen) }
        })
        watchClicks()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
        refreshPresence()
    }

    private func visibilityChanged(to visibility: LineVisibility) {
        hiddenByUser = false
        isPinned = false
        if visibility != .always { setRevealed(false) }
    }

    /// The shortcut or the menu: down if up, up if down.
    private func toggle() {
        if viewModel.isRevealed {
            hiddenByUser = true
            setRevealed(false)
        } else {
            hiddenByUser = false
            reveal(on: SpaceService.screenUnderPointer, pinned: true)
        }
    }

    // MARK: Showing and hiding

    /// Orders the panel out over full screen apps, and back in after.
    private func refreshPresence() {
        let blocked = panel.screen.map(viewModel.isFullScreen) ?? false
        if blocked {
            guard isPresent else { return }
            isPresent = false
            setRevealed(false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !self.isPresent else { return }
                self.panel.orderOut(nil)
            }
        } else if !isPresent {
            isPresent = true
            panel.orderFrontRegardless()
        }
    }

    private func reveal(on screen: NSScreen?, pinned: Bool) {
        guard let screen else { return }
        if panel.screen != screen { panel.place(on: screen) }
        refreshPresence()
        guard isPresent else { return }
        viewModel.prepare(for: screen)
        if pinned { isPinned = true }
        awaySince = nil
        setRevealed(true)
    }

    private func setRevealed(_ revealed: Bool) {
        viewModel.setRevealed(revealed)
        if !revealed {
            isPinned = false
            panel.ignoresMouseEvents = true
        }
    }

    // MARK: Pointer

    /// The menu bar strip at the top of a screen. With an auto-hiding menu
    /// bar the visible frame reaches the top, so the system thickness is used.
    private static func menuBarBand(of screen: NSScreen) -> NSRect {
        var height = screen.frame.maxY - screen.visibleFrame.maxY
        if height < 1 { height = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top) }
        return NSRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height)
    }

    /// A click anywhere but on a card puts the line away.
    private func watchClicks() {
        let handler: () -> Void = { [weak self] in
            guard let self else { return }
            let point = NSEvent.mouseLocation
            let inMenuBar = NSScreen.screens.contains { NSMouseInRect(point, Self.menuBarBand(of: $0), false) }
            guard self.visibility != .always else { return }
            if inMenuBar {
                self.menuBarSuppressed = true
                self.hotZoneSince = nil
            }
            guard self.viewModel.isRevealed, !CardClickView.isShowingMenu, inMenuBar || !self.isOverCard(point) else { return }
            self.setRevealed(false)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { _ in
            MainActor.assumeIsolated { handler() }
        }) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { event in
            MainActor.assumeIsolated { handler() }
            return event
        }) {
            clickMonitors.append(local)
        }
    }

    private func tick() {
        let mouse = NSEvent.mouseLocation
        let now = Date()
        let screenUnderPointer = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        let inMenuBar = screenUnderPointer.map { NSMouseInRect(mouse, Self.menuBarBand(of: $0), false) } ?? false
        if !inMenuBar { menuBarSuppressed = false }

        if visibility == .always {
            if !viewModel.isRevealed {
                if !hiddenByUser, !(panel.screen.map(viewModel.isFullScreen) ?? false) { reveal(on: panel.screen, pinned: false) }
                return
            }
            updateMousePassThrough(mouse)
            return
        }

        guard viewModel.isRevealed else {
            // Resting in the menu bar brings the line down on that screen.
            if visibility == .onHover, let screen = screenUnderPointer, inMenuBar, !menuBarSuppressed,
               !viewModel.isFullScreen(screen) {
                let since = hotZoneSince ?? now
                hotZoneSince = since
                if now.timeIntervalSince(since) >= Self.revealDelay {
                    hotZoneSince = nil
                    reveal(on: screen, pinned: false)
                }
            } else {
                hotZoneSince = nil
            }
            return
        }

        updateMousePassThrough(mouse)

        // The line's zone runs from its lowest point up to the top of the
        // screen, menu bar included, so moving up never hides it.
        var zone = panel.frame
        if let screen = panel.screen { zone.size.height = screen.frame.maxY - zone.minY }
        let inside = NSMouseInRect(mouse, zone, false)
        if inside && isPinned { isPinned = false }

        let busy = isPinned || CardClickView.isShowingMenu || viewModel.pressedID != nil
        if inside || busy {
            awaySince = nil
        } else {
            let since = awaySince ?? now
            awaySince = since
            if now.timeIntervalSince(since) >= Self.retractDelay {
                awaySince = nil
                setRevealed(false)
            }
        }
    }

    private func isOverCard(_ mouse: NSPoint) -> Bool {
        guard isPresent else { return false }
        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        return viewModel.hitRects.values.contains { $0.insetBy(dx: -4, dy: -4).contains(flipped) }
    }

    /// The panel spans the whole screen width, so it only takes the mouse
    /// while the pointer is over a card. Everywhere else clicks go through.
    private func updateMousePassThrough(_ mouse: NSPoint) {
        let overCard = isOverCard(mouse)
        if panel.ignoresMouseEvents == overCard { panel.ignoresMouseEvents = !overCard }
    }
}

/// A transparent strip along the top of the screen that floats over every
/// app and every Space, never takes focus, and lets clicks through
/// everywhere except over the cards.
private final class DesktopLinePanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        canHide = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func place(on screen: NSScreen?) {
        guard let visible = (screen ?? SpaceService.screenUnderPointer)?.visibleFrame else { return }
        let target = NSRect(
            x: visible.minX,
            y: visible.maxY - LineLayout.panelHeight,
            width: visible.width,
            height: LineLayout.panelHeight
        )
        if frame != target { setFrame(target, display: true) }
    }
}
