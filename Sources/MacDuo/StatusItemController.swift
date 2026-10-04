import AppKit
import Combine
import SwiftUI

/// The menu bar item and the settings popover, and the panel that holds the
/// settings when the item is hidden.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {

    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let preferences: Preferences
    private let controller: LidController
    private var titleTimer: Timer?
    private var barWindowMoved: NSObjectProtocol?
    private var iconSubscription: AnyCancellable?
    /// Built on first use, then reused.
    private var panel: NSPanel?

    init(controller: LidController, preferences: Preferences) {
        self.controller = controller
        self.preferences = preferences
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "laptopcomputer",
                accessibilityDescription: "Mac Duo"
            )
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        let hostingController = makeSettingsController()
        // Without this the popover keeps its default height and clips the content.
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController

        watchBarWindow()
        // Delivers the stored value straight away, which also starts the title timer.
        iconSubscription = preferences.$showsMenuBarIcon
            .removeDuplicates()
            .sink { [weak self] shows in self?.setIconShown(shows) }
    }

    deinit {
        titleTimer?.invalidate()
        if let barWindowMoved {
            NotificationCenter.default.removeObserver(barWindowMoved)
        }
    }

    /// Opening the app again lands here. The popover needs the button on
    /// screen to hang from, so the panel holds the settings whenever it is not.
    func showSettings() {
        if statusItem.isVisible, statusItem.button?.window?.occlusionState.contains(.visible) == true {
            if !popover.isShown { showPopover() }
        } else {
            showPanel()
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        // One copy of the settings on screen at a time.
        panel?.close()
        NSApp.activate()
        anchor(to: button)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showPanel() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible {
            centreOnPointerScreen(panel)
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: true
        )
        panel.title = "Mac Duo"
        // The settings already start with the name.
        panel.titleVisibility = .hidden
        // A utility panel floats over every app and hides whenever this one
        // deactivates, and with no Dock icon there would be no clicking it back.
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = .moveToActiveSpace
        panel.isReleasedWhenClosed = false
        let settings = makeSettingsController()
        panel.contentViewController = settings
        // Otherwise the panel takes the size of the settings only once it is
        // on screen, too late to centre it.
        panel.setContentSize(settings.view.fittingSize)
        return panel
    }

    /// Each surface needs its own copy, as a view can only be in one window.
    private func makeSettingsController() -> NSHostingController<SettingsView> {
        NSHostingController(
            rootView: SettingsView(
                preferences: preferences,
                controller: controller,
                onQuit: { NSApp.terminate(nil) }
            )
        )
    }

    /// Centred on the screen with the pointer, which is usually where the app
    /// was just opened from.
    private func centreOnPointerScreen(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) })
            ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: (area.midX - size.width / 2).rounded(),
            y: (area.midY - size.height / 2).rounded()
        ))
    }

    /// `isVisible` rather than removing the item, which would give up its
    /// place in the menu bar.
    private func setIconShown(_ shown: Bool) {
        if shown {
            statusItem.isVisible = true
            startTitleTimer()
        } else {
            // The popover would be left hanging from nothing.
            popover.close()
            statusItem.isVisible = false
            titleTimer?.invalidate()
            titleTimer = nil
        }
    }

    /// The title is all it updates, so it only runs while the item shows.
    private func startTitleTimer() {
        guard titleTimer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTitle() }
        }
        RunLoop.main.add(timer, forMode: .common)
        titleTimer = timer
        refreshTitle()
    }

    /// Showing the angle changes the button width, and the status item window
    /// slides along the menu bar about a tenth of a second later. AppKit places
    /// the popover on the width change, before the slide, so it lands a whole
    /// button width away until the window has settled.
    private func watchBarWindow() {
        barWindowMoved = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, self.popover.isShown,
                      let button = self.statusItem.button,
                      let moved = notification.object as? NSWindow,
                      moved === button.window else { return }
                // Re-showing an animating popover makes it flicker shut.
                let animates = self.popover.animates
                self.popover.animates = false
                self.anchor(to: button)
                self.popover.animates = animates
            }
        }
    }

    /// An empty rectangle means the button's own bounds.
    private func anchor(to button: NSStatusBarButton) {
        popover.show(relativeTo: .zero, of: button, preferredEdge: .minY)
    }

    private func refreshTitle() {
        guard let button = statusItem.button else { return }
        if preferences.showsAngleInMenuBar {
            button.title = String(format: " %.0f°", controller.currentAngle)
        } else if !button.title.isEmpty {
            button.title = ""
        }
    }
}
