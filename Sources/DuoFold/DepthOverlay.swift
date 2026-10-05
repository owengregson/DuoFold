import AppKit
import Metal
import QuartzCore

/// A borderless window above everything, including the menu bar and full
/// screen spaces. It never takes focus and never takes clicks.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Where the picture lands on the glass.
///
/// The picture is a sheet hinged to the bottom edge of the screen, turned back
/// in world space by the angle the lid has travelled. The eye stays where it
/// is while the glass turns under it, so the projection takes both the current
/// lid angle and the eye position.
struct DepthGeometry {

    /// Past 90 degrees the picture turns its face away from the glass.
    var maxSeparationDegrees: Double = 88

    /// Bottom-left, bottom-right, top-right, top-left.
    func corners(
        startAngle: Double,
        currentAngle: Double,
        viewingDistanceRatio: Double,
        recession: Double,
        screenSize: CGSize
    ) -> [CGPoint] {
        let width = Double(screenSize.width)
        let height = Double(screenSize.height)
        let start = startAngle * .pi / 180
        let current = currentAngle * .pi / 180
        let travel = max(startAngle - currentAngle, 0)
        let separation = min(recession * travel, maxSeparationDegrees) * .pi / 180

        // The eye in world axes, hinge at the origin.
        let reach = height * viewingDistanceRatio + height / 2 * cos(start)
        let rise = height / 2 * sin(start)

        // The same eye, measured along the glass and away from it.
        let along = reach * cos(current) + rise * sin(current)
        let depth = max(reach * sin(current) - rise * cos(current), height / 10)

        let half = width / 2
        func project(_ x: Double, _ y: Double) -> CGPoint {
            let scale = depth / (depth + y * sin(separation))
            return CGPoint(
                x: half + (x - half) * scale,
                y: along + (y * cos(separation) - along) * scale
            )
        }
        return [project(0, 0), project(width, 0), project(width, height), project(0, height)]
    }
}

/// The settings that shape one frame.
struct DepthTuning: Equatable {
    var viewingDistance: Double = 2.7
    var recession: Double = 2
    var blurEvenness: Double = 0.4
    var dimReach: Double = 0.7
    var maxBlurRadius: Double = 55
    var maxDim: Double = 0.4
}

private final class MetalHostView: NSView {
    init(layer metalLayer: CALayer, scale: CGFloat) {
        super.init(frame: .zero)
        metalLayer.contentsScale = scale
        self.layer = metalLayer
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layout() {
        super.layout()
        layer?.frame = bounds
    }
}

/// Owns the overlay window for one run of the effect.
@MainActor
final class DepthOverlay {

    private var window: OverlayWindow?
    /// The window of the previous run while it fades out. AppKit keeps it
    /// alive past the fade, so a new run has to take it down itself.
    private var fadingWindow: OverlayWindow?
    private var presenceWindow: OverlayWindow?
    /// Built once and kept.
    private var renderer: DepthRenderer?
    private var hasTriedToBuildRenderer = false
    private var buildToken = 0
    private let buildQueue = DispatchQueue(label: "DuoFold.pictureUpload", qos: .userInteractive)
    /// The window server's glass, built ahead of time and kept hidden
    /// between runs, so a close shows it on the next frame instead of
    /// waiting for a new window.
    private var glassWindow: OverlayWindow?
    private var glassView: FrostedGlassView?
    /// True while the run on screen is the glass rather than the renderer.
    private var showsGlass = false
    /// The glass while it stands in for a picture still on its way: up at
    /// once under the picture's window, following the lid, and down once
    /// the picture has drawn over it. `LidPicturePolicy` decides when a run
    /// starts this way.
    private var bridge: OverlayWindow?
    private var glassShownAt: CFTimeInterval = 0
    private var handover = GlassHandover()
    /// Eases the picture from flat, as the glass had it, into the lid's lean.
    private var leanCatchUp = LidLeanCatchUp()

    private var screenSize: CGSize = .zero
    private var startAngle: Double = 90
    private var geometry = DepthGeometry()
    private var gradient = BlurGradient()
    private var tuning = DepthTuning()
    private var fadeIn: TimeInterval = 0.07
    private var hasRevealed = false

    var isVisible: Bool { window != nil }
    /// True once the picture has faded in over the screen, or the glass
    /// stands in for it. A live window waits transparent for its first
    /// frame, and that hides nothing.
    var isRevealed: Bool { (window != nil && hasRevealed) || bridge != nil }
    var isPictureReady: Bool { showsGlass || (renderer?.isReady ?? false) }
    /// True once a window for the captured picture is up, ready or not.
    var showsCapturedPicture: Bool { window != nil && !showsGlass }
    var hostWindow: NSWindow? { window }

    @discardableResult
    func warmUp() -> Bool {
        if !hasTriedToBuildRenderer {
            hasTriedToBuildRenderer = true
            renderer = DepthRenderer()
        }
        keepPresence()
        return renderer != nil
    }

    /// A window one point across that shows nothing.
    ///
    /// ScreenCaptureKit only lists an application that owns a window, and the
    /// stream has to name this application to leave the overlay out of its own
    /// picture.
    private func keepPresence() {
        guard presenceWindow == nil else { return }
        let window = OverlayWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.alphaValue = 0.004
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.orderFrontRegardless()
        presenceWindow = window
    }

    /// Puts up a window for a live stream. It stays transparent until the
    /// first frame is absorbed. A glass already showing stays up under it
    /// until then.
    @discardableResult
    func showLive(
        on screen: NSScreen,
        startAngle: Double,
        tuning: DepthTuning,
        fadeIn: TimeInterval
    ) -> Bool {
        carryGlassUnderPicture()
        guard warmUp(), let renderer else {
            restoreGlassFromBridge()
            return false
        }
        self.startAngle = startAngle
        self.tuning = tuning
        self.fadeIn = fadeIn
        screenSize = screen.frame.size

        let pixelScale = Double(screen.backingScaleFactor)
        guard renderer.beginLive(screenSize: screenSize, pixelScale: CGFloat(pixelScale)) else {
            restoreGlassFromBridge()
            return false
        }
        buildToken += 1
        makeWindow(on: screen, pixelScale: pixelScale)
        if window == nil { restoreGlassFromBridge() }
        return window != nil
    }

    /// Takes the run's windows down the way `dismiss` does, except a glass
    /// that is showing, which stays up as the bridge under the picture's
    /// window about to go up.
    private func carryGlassUnderPicture() {
        guard showsGlass, let glassWindow, window === glassWindow else {
            dismiss(animated: false)
            return
        }
        closeFadingWindow()
        leanCatchUp.reset()
        bridge = glassWindow
        window = nil
        showsGlass = false
        buildToken += 1
        renderer?.release()
    }

    /// A picture window that could not go up leaves the glass as the run.
    private func restoreGlassFromBridge() {
        guard let bridge else { return }
        self.bridge = nil
        window = bridge
        showsGlass = true
        hasRevealed = true
    }

    private func takeDownBridge() {
        guard let bridge else { return }
        self.bridge = nil
        takeDown(bridge)
    }

    /// Hands one live frame to the renderer and reveals the window once the
    /// first one has landed.
    func absorb(_ frame: CapturedFrame) {
        guard window != nil, let renderer else { return }
        renderer.absorb(frame)
        reveal()
    }

    /// Starts a live overlay from one held frame.
    func seed(image: CGImage) {
        guard window != nil, let renderer, renderer.seed(image: image) else { return }
        reveal()
    }

    func discardLive() {
        renderer?.discardLive()
    }

    /// Builds the glass for `screen`, hidden, unless one for that screen is
    /// already waiting. A few layers and no drawing until it is shown.
    func prepareGlass(on screen: NSScreen) {
        guard WindowServerBlur.isAvailable else { return }
        if let glassWindow, glassWindow.frame == screen.frame,
           glassView?.layer?.contentsScale == screen.backingScaleFactor { return }
        if let old = glassWindow {
            // One on screen finishes its run first; the next run rebuilds.
            guard window !== old, bridge !== old else { return }
            if fadingWindow === old { fadingWindow = nil }
            old.orderOut(nil)
            old.close()
        }
        let view = FrostedGlassView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            scale: screen.backingScaleFactor
        )
        view.autoresizingMask = [.width, .height]
        let window = makeOverlayWindow(on: screen, contentView: view)
        window.alphaValue = 0
        glassView = view
        glassWindow = window
    }

    /// Shows the glass, through which the window server blurs and dims
    /// whatever is behind it. Nothing is captured. At the start angle it
    /// blurs and dims nothing, so it shows at once with no fade.
    @discardableResult
    func showGlass(on screen: NSScreen, startAngle: Double, tuning: DepthTuning) -> Bool {
        dismiss(animated: false)
        prepareGlass(on: screen)
        guard let glassWindow, glassView != nil else { return false }
        self.startAngle = startAngle
        self.tuning = tuning
        screenSize = screen.frame.size
        buildToken += 1
        showsGlass = true
        window = glassWindow
        hasRevealed = true
        glassShownAt = CACurrentMediaTime()
        update(progress: 0, currentAngle: startAngle, tuning: tuning)
        // Takes over from a fade out that may still be running.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            glassWindow.animator().alphaValue = 1
        }
        glassWindow.alphaValue = 1
        glassWindow.orderFrontRegardless()
        return true
    }


    func show(
        image: CGImage,
        on screen: NSScreen,
        startAngle: Double,
        tuning: DepthTuning,
        fadeIn: TimeInterval
    ) {
        carryGlassUnderPicture()
        // The screenshot's screen can be stale once the lid shuts into
        // clamshell mode, so no window goes up at its old frame.
        guard let displayID = screen.displayID, displayID == NSScreen.builtIn?.displayID,
              warmUp(), let renderer else {
            restoreGlassFromBridge()
            return
        }
        self.startAngle = startAngle
        self.tuning = tuning
        self.fadeIn = fadeIn
        screenSize = screen.frame.size

        let pixelScale = screen.frame.width > 0
            ? Double(image.width) / Double(screen.frame.width)
            : Double(screen.backingScaleFactor)

        makeWindow(on: screen, pixelScale: pixelScale)
        guard let window else {
            restoreGlassFromBridge()
            return
        }

        buildToken += 1
        let token = buildToken
        let size = screenSize
        buildQueue.async { [weak self, weak renderer] in
            guard let renderer else { return }
            let picture = renderer.makePicture(image: image, screenSize: size, pixelScale: CGFloat(pixelScale))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.buildToken == token, self.window === window,
                          let picture else { return }
                    renderer.adopt(picture)
                    self.update(progress: 0, currentAngle: self.startAngle, tuning: self.tuning)
                    self.reveal()
                }
            }
        }
    }

    private func makeWindow(on screen: NSScreen, pixelScale: Double) {
        guard let renderer else { return }
        let view = MetalHostView(layer: renderer.makeLayer(), scale: CGFloat(pixelScale))
        view.frame = NSRect(origin: .zero, size: screenSize)
        view.autoresizingMask = [.width, .height]

        let window = makeOverlayWindow(on: screen, contentView: view)
        window.alphaValue = 0
        window.orderFrontRegardless()
        hasRevealed = false
        self.window = window
    }

    private func makeOverlayWindow(on screen: NSScreen, contentView view: NSView) -> OverlayWindow {
        let window = OverlayWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        // On every space, full screen ones too, and floating above them while
        // they slide. `.stationary` keeps a window still like the desktop,
        // which slides away with its space on a swipe between spaces.
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle]
        window.setFrame(screen.frame, display: false)
        return window
    }

    /// Fades the window in once, and only once the picture has something to
    /// draw. Over glass that cannot lean, the picture starts flat as the
    /// glass is and eases into the lid's lean from here.
    private func reveal() {
        guard let window, !hasRevealed, renderer?.isReady == true else { return }
        hasRevealed = true
        let now = CACurrentMediaTime()
        if !GlassMesh.isAvailable { leanCatchUp.begin(at: now) }
        if bridge != nil {
            handover = GlassHandover()
            Diagnostics.geometry.notice(
                "picture took over from the glass \((now - self.glassShownAt) * 1000, format: .fixed(precision: 0)) ms after it went up"
            )
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeIn
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    /// How many times the glass has been laid out afresh, for the log.
    var glassChanges: Int { glassView?.changes ?? 0 }

    func update(progress: Double, currentAngle: Double, tuning: DepthTuning) {
        self.tuning = tuning
        let corners = geometry.corners(
            startAngle: startAngle,
            currentAngle: leanCatchUp.pictureAngle(currentAngle, startAngle: startAngle, at: CACurrentMediaTime()),
            viewingDistanceRatio: tuning.viewingDistance,
            recession: tuning.recession,
            screenSize: screenSize
        )
        if showsGlass || bridge != nil, let glassView {
            // The glass leans, blurs and dims as the captured picture does at
            // this point of the travel. As the bridge it keeps following the
            // lid until the picture is over it.
            let scale = glassView.layer?.contentsScale ?? 2
            glassView.apply(
                progress: progress,
                tuning: tuning,
                gradient: gradient,
                lean: GlassLean(
                    corners: corners,
                    screenSize: screenSize,
                    padded: DepthRenderer.paddedFrame(screenSize: screenSize, pixelScale: scale)
                )
            )
        }
        guard !showsGlass, let renderer, renderer.isReady else { return }
        renderer.render(
            corners: corners,
            blurStrength: gradient.blurStrength(progress: progress),
            dimStrength: gradient.dimStrength(progress: progress),
            hingeFloor: tuning.blurEvenness,
            dimHingeFloor: gradient.dimHingeFloor,
            dimReach: tuning.dimReach,
            maxBlurRadius: tuning.maxBlurRadius,
            maxDim: tuning.maxDim
        )
        if hasRevealed, bridge != nil {
            handover.drewFrame()
            if handover.isComplete { takeDownBridge() }
        }
    }

    func dismiss(animated: Bool, duration: TimeInterval = 0.22) {
        closeFadingWindow()
        leanCatchUp.reset()
        if let bridge {
            self.bridge = nil
            if let picture = window, !hasRevealed {
                // The picture never showed. Its window goes at once, and the
                // glass, which is what the screen shows, is the one to fade.
                takeDown(picture)
                window = bridge
            } else {
                takeDown(bridge)
            }
        }
        guard let window else { return }
        self.window = nil
        buildToken += 1
        renderer?.release()
        showsGlass = false

        guard animated else {
            takeDown(window)
            return
        }

        fadingWindow = window
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else {
                    window.orderOut(nil)
                    window.close()
                    return
                }
                // A new run may have taken the glass back over meanwhile.
                guard self.fadingWindow === window else { return }
                self.fadingWindow = nil
                self.takeDown(window)
            }
        }
    }

    /// Takes down a window that is still fading.
    private func closeFadingWindow() {
        guard let fadingWindow else { return }
        self.fadingWindow = nil
        takeDown(fadingWindow)
    }

    /// The glass is hidden and kept for the next run; any other window goes.
    private func takeDown(_ window: OverlayWindow) {
        window.orderOut(nil)
        if window !== glassWindow { window.close() }
    }
}
