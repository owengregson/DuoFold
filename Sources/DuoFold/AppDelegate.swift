import AppKit
import CoreGraphics

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var controller: LidController?
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diagnostics.geometry.notice("launched, screen recording granted: \(CGPreflightScreenCaptureAccess())")
        let preferences = Preferences.shared
        let controller = LidController(preferences: preferences)
        self.controller = controller
        statusItemController = StatusItemController(controller: controller, preferences: preferences)
        // Before the controller sets the sensor's report interval.
        TerminationSignals.routeToTerminate()
        controller.start()
    }

    /// Opening the app while it runs, from Finder, Spotlight or `open`. With
    /// the menu bar icon hidden, this is the only way back to the settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItemController?.showSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }
}
