import AppKit
import QuartzCore
import Testing
@testable import DuoFold

/// Offscreen experiments behind the rendering audit: what Core Animation's
/// renderer does with meshed groups, layer hosts and the glass's per-frame
/// refresh. Run with `RENDER_AUDIT=1`; they only print.
@MainActor
struct RenderAuditExperiments {

    nonisolated static let enabled = ProcessInfo.processInfo.environment["RENDER_AUDIT"] != nil
    nonisolated static let directory = ProcessInfo.processInfo.environment["FIDELITY_DIR"]

    static func pixel(_ frame: GlassFidelityRig.Frame, x: Int, y: Int) -> (Int, Int, Int) {
        let i = (y * frame.width + x) * 4
        return (Int(frame.pixels[i + 2]), Int(frame.pixels[i + 1]), Int(frame.pixels[i]))
    }

    /// A mesh that slides a layer's unit square right by `shift` of its width.
    static func slide(_ layer: CALayer, by shift: Double) {
        let vertices = [
            GlassMesh.Vertex(from: CGPoint(x: 0, y: 0), to: (shift, 0, 0)),
            GlassMesh.Vertex(from: CGPoint(x: 1, y: 0), to: (1 + shift, 0, 0)),
            GlassMesh.Vertex(from: CGPoint(x: 1, y: 1), to: (1 + shift, 1, 0)),
            GlassMesh.Vertex(from: CGPoint(x: 0, y: 1), to: (shift, 1, 0)),
        ]
        GlassMesh.apply((vertices, [GlassMesh.Face(indices: (0, 1, 2, 3), weights: (0, 0, 0, 0))]), to: layer)
    }

    @Test(.enabled(if: enabled))
    func privateClassesAndSelectors() {
        let probes: [(String, [String])] = [
            ("CABackdropLayer", ["setInverseMeshed:", "isInverseMeshed", "setBackdropRect:", "setCaptureOnly:", "setWindowServerAware:", "setGroupName:", "setScale:", "setMarginWidth:", "setAllowsInPlaceFiltering:", "setDisablesOccludedBackdropBlurs:", "setIgnoresOffscreenGroups:", "setUsesGlobalGroupNamespace:"]),
            ("CALayer", ["setInverseMeshed:", "setMeshTransform:", "setAllowsBackdropGroups:", "setRasterizationPrefersWindowServerAwareBackdrops:"]),
            ("CALayerHost", ["setContextId:", "contextId", "setPreservesFlip:", "setInheritsSecurity:", "setHidesSublayers:"]),
            ("CAPortalLayer", ["setSourceLayer:", "setMatchesTransform:", "setMatchesPosition:", "setMatchesOpacity:", "setHidesSourceLayer:", "setSourceContextId:", "setSourceLayerRenderId:"]),
        ]
        for (name, selectors) in probes {
            guard let cls = NSClassFromString(name) as? NSObject.Type else { print("audit: no class \(name)"); continue }
            let instance = cls.init()
            let yes = selectors.filter { instance.responds(to: NSSelectorFromString($0)) }
            let no = selectors.filter { !instance.responds(to: NSSelectorFromString($0)) }
            print("audit: \(name) responds to \(yes); not \(no)")
        }
        if let context = NSClassFromString("CAContext") as? NSObject.Type {
            let classSelectors = ["remoteContextWithOptions:", "contextWithCGSConnection:options:", "localContext", "currentContext", "allContexts", "objectForSlot:", "setContextId:"]
            print("audit: CAContext class responds to \(classSelectors.filter { context.responds(to: NSSelectorFromString($0)) })")
        }
    }

    /// Does a mesh on a layer carry its sublayers with it, as a group?
    @Test(.enabled(if: enabled))
    func meshOnAParentCarriesItsSublayers() throws {
        let rig = try #require(GlassFidelityRig(screen: CGSize(width: 200, height: 100), scale: 1))
        let root = CALayer()
        root.anchorPoint = .zero
        root.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        root.backgroundColor = CGColor(gray: 0, alpha: 1)
        let parent = CALayer()
        parent.anchorPoint = .zero
        parent.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let child = CALayer()
        child.anchorPoint = .zero
        child.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        child.backgroundColor = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        parent.addSublayer(child)
        root.addSublayer(parent)
        Self.slide(parent, by: 1)
        let frame = try #require(rig.render(root))
        let left = Self.pixel(frame, x: 50, y: 50), right = Self.pixel(frame, x: 150, y: 50)
        print("audit: mesh on parent: left \(left) right \(right) -> \(right.0 > 128 ? "sublayers are carried (group)" : "sublayers are not carried")")
    }

    /// A backdrop meshed itself, under a meshed parent, and inverse meshed:
    /// which of them shows the stripe behind where it is laid out (left),
    /// and which the stripe behind where it shows (right)?
    @Test(.enabled(if: enabled), arguments: ["own mesh", "parent mesh", "own mesh, inverseMeshed", "parent mesh, inverseMeshed"])
    func backdropUnderAMesh(way: String) throws {
        let rig = try #require(GlassFidelityRig(screen: CGSize(width: 200, height: 100), scale: 1))
        let root = CALayer()
        root.anchorPoint = .zero
        root.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        root.backgroundColor = CGColor(gray: 0, alpha: 1)
        // A white stripe behind the flat layout, and a red one behind where
        // the mesh puts the layer.
        for (x, colour) in [(40, CGColor(gray: 1, alpha: 1)), (140, CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))] {
            let stripe = CALayer()
            stripe.anchorPoint = .zero
            stripe.frame = CGRect(x: x, y: 0, width: 4, height: 100)
            stripe.backgroundColor = colour
            root.addSublayer(stripe)
        }
        let parent = CALayer()
        parent.anchorPoint = .zero
        parent.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let band = try #require(WindowServerBlur.makeBand(groupName: "audit", samplesOtherWindows: false))
        band.anchorPoint = .zero
        band.frame = parent.bounds
        WindowServerBlur.setRadius(6, of: band)
        if way.contains("inverseMeshed") { band.setValue(true, forKey: "inverseMeshed") }
        parent.addSublayer(band)
        root.addSublayer(parent)
        Self.slide(way.hasPrefix("own") ? band : parent, by: 1)
        let frame = try #require(rig.render(root))
        let reds = (0..<200).map { Self.pixel(frame, x: $0, y: 50).0 }
        let greens = (0..<200).map { Self.pixel(frame, x: $0, y: 50).1 }
        // White shows in green too; red alone does not.
        let whiteLeft = greens[20..<70].max()!, whiteRight = greens[120..<170].max()!
        let redOnlyRight = reds[120..<170].max()! - greens[120..<170].max()!
        let spreadRight = greens[120..<170].filter { $0 > 8 }.count
        print("audit: backdrop \(way): white (laid-out side) shows left \(whiteLeft) right \(whiteRight), spread right \(spreadRight) px; red (shown side) alone right \(redOnlyRight)")
        if let directory = Self.directory {
            GlassFidelityRig.write([frame], to: URL(fileURLWithPath: directory).appendingPathComponent("audit-backdrop-\(way.replacingOccurrences(of: ", ", with: "-").replacingOccurrences(of: " ", with: "_")).png"))
        }
    }

    /// A `CALayerHost` of a context from this process, under `CARenderer`.
    @Test(.enabled(if: enabled))
    func layerHostOfARemoteContextUnderCARenderer() throws {
        let rig = try #require(GlassFidelityRig(screen: CGSize(width: 200, height: 100), scale: 1))
        guard let contextClass = NSClassFromString("CAContext") as? NSObject.Type,
              let hostClass = NSClassFromString("CALayerHost") as? CALayer.Type else {
            print("audit: no CAContext / CALayerHost")
            return
        }
        for way in ["remoteContextWithOptions:", "contextWithCGSConnection:options:"] {
            let hosted = CALayer()
            hosted.anchorPoint = .zero
            hosted.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
            hosted.backgroundColor = CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
            let options: NSDictionary = ["kCAContextCIFilterBehavior": "ignore"]
            let context: NSObject?
            if way == "remoteContextWithOptions:" {
                context = contextClass.perform(NSSelectorFromString(way), with: options)?.takeUnretainedValue() as? NSObject
            } else {
                typealias Make = @convention(c) (AnyClass, Selector, Int32, NSDictionary) -> Unmanaged<AnyObject>?
                guard let send = dlsym(dlopen(nil, RTLD_NOW), "objc_msgSend").map({ unsafeBitCast($0, to: Make.self) }),
                      let mainConnection = dlsym(dlopen(nil, RTLD_NOW), "CGSMainConnectionID").map({ unsafeBitCast($0, to: (@convention(c) () -> Int32).self) })
                else { continue }
                context = send(contextClass, NSSelectorFromString(way), mainConnection(), options)?.takeUnretainedValue() as? NSObject
            }
            guard let context else { print("audit: \(way) gave no context"); continue }
            context.setValue(hosted, forKey: "layer")
            let id = context.value(forKey: "contextId")
            print("audit: \(way) -> context \(context) id \(String(describing: id))")
            let root = CALayer()
            root.anchorPoint = .zero
            root.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
            root.backgroundColor = CGColor(gray: 0, alpha: 1)
            let host = hostClass.init()
            host.anchorPoint = .zero
            host.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
            host.setValue(id, forKey: "contextId")
            root.addSublayer(host)
            Self.slide(host, by: 1)
            CATransaction.flush()
            let frame = try #require(rig.render(root))
            let left = Self.pixel(frame, x: 50, y: 50), right = Self.pixel(frame, x: 150, y: 50)
            print("audit: layer host (\(way)) under CARenderer: left \(left) right \(right)")
            context.setValue(nil, forKey: "layer")
            if context.responds(to: NSSelectorFromString("invalidate")) { context.perform(NSSelectorFromString("invalidate")) }
        }
    }

    /// A backdrop whose mesh squeezes it into the lower half of its frame,
    /// as the base does when the picture leans: does it show the rows it is
    /// laid out over, squeezed, or the rows under where it shows, stretched?
    @Test(.enabled(if: enabled), arguments: [1, 2, -1, -2])
    func backdropSqueezedByItsMesh(variant: Int) throws {
        // Negative: the same with `backdropRect` set to the flat frame (-1)
        // or to a rect taller than the frame (-2).
        let meshRows = abs(variant)
        let rig = try #require(GlassFidelityRig(screen: CGSize(width: 100, height: 200), scale: 1))
        let root = CALayer()
        root.anchorPoint = .zero
        root.frame = CGRect(x: 0, y: 0, width: 100, height: 200)
        root.backgroundColor = CGColor(gray: 0, alpha: 1)
        // Stripes behind at y = 20 (red), 60 (green), 100 (blue), 140 (white).
        for (y, colour) in [(20, CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)), (60, CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)),
                            (100, CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)), (140, CGColor(gray: 1, alpha: 1))] {
            let stripe = CALayer()
            stripe.anchorPoint = .zero
            stripe.frame = CGRect(x: 0, y: y, width: 100, height: 4)
            stripe.backgroundColor = colour
            root.addSublayer(stripe)
        }
        let band = try #require(WindowServerBlur.makeBand(groupName: "audit", samplesOtherWindows: false))
        band.anchorPoint = .zero
        band.frame = CGRect(x: 0, y: 0, width: 100, height: 160)
        WindowServerBlur.setRadius(1, of: band)
        if variant == -1 { band.setValue(CGRect(x: 0, y: 0, width: 100, height: 160), forKey: "backdropRect") }
        if variant == -2 { band.setValue(CGRect(x: 0, y: 0, width: 100, height: 200), forKey: "backdropRect") }
        root.addSublayer(band)
        // Rows 0...160 of the layer shown over rows 0...80.
        var vertices: [GlassMesh.Vertex] = []
        var faces: [GlassMesh.Face] = []
        let rows = max(meshRows, 1)
        for row in 0...rows {
            let v = Double(row) / Double(rows)
            vertices.append(GlassMesh.Vertex(from: CGPoint(x: 0, y: v), to: (0, v / 2, 0)))
            vertices.append(GlassMesh.Vertex(from: CGPoint(x: 1, y: v), to: (1, v / 2, 0)))
        }
        for row in 0..<rows {
            let a = UInt32(row * 2)
            faces.append(GlassMesh.Face(indices: (a, a + 1, a + 3, a + 2), weights: (0, 0, 0, 0)))
        }
        GlassMesh.apply((vertices, faces), to: band)
        let frame = try #require(rig.render(root))
        // Rows from the bottom, as the layer has them.
        var found: [String] = []
        for y in 0..<200 {
            let p = Self.pixel(frame, x: 50, y: 199 - y)
            let name: String? = p.0 > 128 && p.1 > 128 && p.2 > 128 ? "white" : p.0 > 128 ? "red" : p.1 > 128 ? "green" : p.2 > 128 ? "blue" : nil
            if let name, found.last?.hasPrefix(name) != true { found.append("\(name)@\(y)") }
        }
        print("audit: backdrop squeezed by its mesh (variant \(variant)): stripes seen at \(found) — squeezed in place would be red@10 green@30 blue@50 white@70; captured under the output and stretched would be red@40 green@120")
        if let directory = Self.directory {
            GlassFidelityRig.write([frame], to: URL(fileURLWithPath: directory).appendingPathComponent("audit-backdrop-squeezed-\(variant).png"))
        }
    }

    /// The margin faces of the base's mesh have no area in the layer (two
    /// vertices at the same point of the unit square): what do they draw,
    /// and does giving them a pixel of area change it?
    @Test(.enabled(if: enabled), arguments: ["current", "inner vertex inset a pixel", "outer vertex a pixel outside"])
    func marginFacesOfTheBase(way: String) throws {
        let screen = CGSize(width: 400, height: 300)
        let rig = try #require(GlassFidelityRig(screen: screen, scale: 1))
        let root = CALayer()
        root.anchorPoint = .zero
        root.frame = CGRect(origin: .zero, size: screen)
        let desktop = CALayer()
        desktop.anchorPoint = .zero
        desktop.frame = root.bounds
        desktop.contents = rig.picture
        root.addSublayer(desktop)
        let base = try #require(WindowServerBlur.makeBand(groupName: "audit", samplesOtherWindows: false))
        base.anchorPoint = .zero
        base.frame = root.bounds
        root.addSublayer(base)
        // The picture's top on screen, at 220 of 300, its sides well in.
        let lean = GlassLean(
            corners: [CGPoint(x: 0, y: 0), CGPoint(x: 400, y: 0), CGPoint(x: 340, y: 220), CGPoint(x: 60, y: 220)],
            screenSize: screen, padded: DepthRenderer.paddedFrame(screenSize: screen, pixelScale: 1)
        )
        var grid = lean.pictureGrid(bottom: 0, top: 300, rows: 16)
        let dx = 1.0 / 400, dy = 1.0 / 300
        if way.hasPrefix("inner") {
            for r in grid.rows.indices {
                grid.rows[r][1].from.x = dx
                grid.rows[r][2].from.x = 1 - dx
            }
            let last = grid.rows.count - 2
            for c in grid.rows[last].indices { grid.rows[last][c].from.y = 1 - dy }
        } else if way.hasPrefix("outer") {
            for r in grid.rows.indices {
                grid.rows[r][0].from.x = -dx
                grid.rows[r][3].from.x = 1 + dx
            }
            let margin = grid.rows.count - 1
            for c in grid.rows[margin].indices { grid.rows[margin][c].from.y = 1 + dy }
        }
        GlassMesh.apply(lean.meshParts(for: grid, layerFrame: base.frame), to: base)
        let frame = try #require(rig.render(root))
        // Above the picture's top, rows 225...255 from the bottom, x 150...250:
        // a stretched edge is the same down each column; the flat desktop is
        // not, and matches the desktop pixel for pixel.
        var columnSpread = 0.0, sameAsDesktop = 0, count = 0, menuBarGrey = 0
        for x in 150..<250 {
            var values: [Int] = []
            for y in 225..<255 {
                let p = Self.pixel(frame, x: x, y: 299 - y)
                values.append(p.0 + p.1 + p.2)
                let i = (((299 - y) * 400) + x) * 4
                let d = rig.picture.dataProvider!.data! as Data
                let q = (Int(d[i + 2]), Int(d[i + 1]), Int(d[i]))
                if abs(q.0 - p.0) + abs(q.1 - p.1) + abs(q.2 - p.2) < 12 { sameAsDesktop += 1 }
                // The picture's top row is the menu bar, light grey.
                if p.0 > 200 && p.1 > 200 && p.2 > 200 { menuBarGrey += 1 }
                count += 1
            }
            columnSpread += Double(values.max()! - values.min()!)
        }
        print("audit: base margin faces (\(way)): above the top, \(menuBarGrey * 100 / count)% of pixels are the menu bar's grey, as a stretched top row would be")
        // In the left wedge, x 5...30 at rows 150...200: the same across each row.
        var rowSpread = 0.0
        for y in 150..<200 {
            let values = (5..<30).map { x -> Int in let p = Self.pixel(frame, x: x, y: 299 - y); return p.0 + p.1 + p.2 }
            rowSpread += Double(values.max()! - values.min()!)
        }
        print("audit: base margin faces (\(way)): above the top, spread down columns \(columnSpread / 100) and \(sameAsDesktop * 100 / count)% of pixels equal the flat desktop; in the left wedge, spread along rows \(rowSpread / 50)")
        if let directory = Self.directory {
            GlassFidelityRig.write([frame], to: URL(fileURLWithPath: directory).appendingPathComponent("audit-margin-\(way.replacingOccurrences(of: " ", with: "_")).png"))
        }
    }

    /// What a mesh face with no area in the layer draws: a layer of four
    /// coloured quadrants, its unit square carried to the lower (or left)
    /// half of the output and a face of no height (or width) to the other.
    @Test(.enabled(if: enabled), arguments: ["height", "width"])
    func faceWithNoAreaInTheLayer(axis: String) throws {
        let rig = try #require(GlassFidelityRig(screen: CGSize(width: 200, height: 200), scale: 1))
        let root = CALayer()
        root.anchorPoint = .zero
        root.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        root.backgroundColor = CGColor(gray: 0, alpha: 1)
        let layer = CALayer()
        layer.anchorPoint = .zero
        layer.frame = root.bounds
        for (index, colour) in [CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1),
                                CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), CGColor(gray: 1, alpha: 1)].enumerated() {
            let quadrant = CALayer()
            quadrant.anchorPoint = .zero
            quadrant.frame = CGRect(x: index % 2 == 0 ? 0 : 100, y: index < 2 ? 0 : 100, width: 100, height: 100)
            quadrant.backgroundColor = colour
            layer.addSublayer(quadrant)
        }
        root.addSublayer(layer)
        // Bottom left red, bottom right green, top left blue, top right white.
        typealias V = GlassMesh.Vertex
        let vertices: [V] = axis == "height"
            ? [V(from: CGPoint(x: 0, y: 0), to: (0, 0, 0)), V(from: CGPoint(x: 1, y: 0), to: (1, 0, 0)),
               V(from: CGPoint(x: 0, y: 1), to: (0, 0.5, 0)), V(from: CGPoint(x: 1, y: 1), to: (1, 0.5, 0)),
               V(from: CGPoint(x: 0, y: 1), to: (0, 1, 0)), V(from: CGPoint(x: 1, y: 1), to: (1, 1, 0))]
            : [V(from: CGPoint(x: 0, y: 0), to: (0, 0, 0)), V(from: CGPoint(x: 0, y: 1), to: (0, 1, 0)),
               V(from: CGPoint(x: 1, y: 0), to: (0.5, 0, 0)), V(from: CGPoint(x: 1, y: 1), to: (0.5, 1, 0)),
               V(from: CGPoint(x: 1, y: 0), to: (1, 0, 0)), V(from: CGPoint(x: 1, y: 1), to: (1, 1, 0))]
        let faces = [GlassMesh.Face(indices: (0, 1, 3, 2), weights: (0, 0, 0, 0)), GlassMesh.Face(indices: (2, 3, 5, 4), weights: (0, 0, 0, 0))]
        GlassMesh.apply((vertices, faces), to: layer)
        let frame = try #require(rig.render(root))
        func name(_ x: Int, _ y: Int) -> String {
            let p = Self.pixel(frame, x: x, y: 199 - y)
            return p.0 > 128 && p.1 > 128 && p.2 > 128 ? "white" : p.0 > 128 ? "red" : p.1 > 128 ? "green" : p.2 > 128 ? "blue" : "black"
        }
        let samples = axis == "height"
            ? [(50, 25), (150, 25), (50, 75), (150, 75), (50, 125), (150, 125), (50, 175), (150, 175)]
            : [(25, 50), (25, 150), (75, 50), (75, 150), (125, 50), (125, 150), (175, 50), (175, 150)]
        print("audit: face with no \(axis): " + samples.map { "(\($0.0),\($0.1))=\(name($0.0, $0.1))" }.joined(separator: " ")
              + " — a stretched edge would show only the two edge colours in the second half; the whole layer would show all four")
        if let directory = Self.directory {
            GlassFidelityRig.write([frame], to: URL(fileURLWithPath: directory).appendingPathComponent("audit-no-area-\(axis).png"))
        }
    }

    /// The whole glass, no blur and no dimming, at a lean whose top stays on
    /// screen: what shows above the picture's top.
    @Test(.enabled(if: enabled))
    func glassAboveThePictureTop() throws {
        let screen = CGSize(width: 400, height: 300)
        let rig = try #require(GlassFidelityRig(screen: screen, scale: 1))
        let lean = GlassLean(
            corners: [CGPoint(x: 0, y: 0), CGPoint(x: 400, y: 0), CGPoint(x: 340, y: 220), CGPoint(x: 60, y: 220)],
            screenSize: screen, padded: DepthRenderer.paddedFrame(screenSize: screen, pixelScale: 1)
        )
        for (name, tuning) in [
            ("no blur, no dim", DepthTuning(viewingDistance: 2.7, recession: 2, blurEvenness: 0.4, dimReach: 0.7, maxBlurRadius: 0, maxDim: 0)),
            ("blur 20, no dim", DepthTuning(viewingDistance: 2.7, recession: 2, blurEvenness: 0.4, dimReach: 0.7, maxBlurRadius: 20, maxDim: 0)),
        ] {
            let glass = try #require(rig.glass { $0.apply(progress: 1, tuning: tuning, gradient: BlurGradient(), lean: lean) })
            let d = rig.picture.dataProvider!.data! as Data
            var sameAsDesktop = 0, count = 0, dark = 0
            for x in 150..<250 { for y in 225..<295 {
                let p = Self.pixel(glass, x: x, y: 299 - y)
                let i = (((299 - y) * 400) + x) * 4
                let q = (Int(d[i + 2]), Int(d[i + 1]), Int(d[i]))
                if abs(q.0 - p.0) + abs(q.1 - p.1) + abs(q.2 - p.2) < 12 { sameAsDesktop += 1 }
                if p.0 + p.1 + p.2 < 30 { dark += 1 }
                count += 1
            } }
            print("audit: glass above the picture top (\(name)): \(sameAsDesktop * 100 / count)% of pixels equal the flat desktop, \(dark * 100 / count)% near black")
            if let directory = Self.directory {
                GlassFidelityRig.write([glass], to: URL(fileURLWithPath: directory).appendingPathComponent("audit-glass-top-\(name.replacingOccurrences(of: ", ", with: "-").replacingOccurrences(of: " ", with: "_")).png"))
            }
        }
    }


    /// Where the band count changes as progress rises, and how much the
    /// picture jumps there against a step of the same size elsewhere.
    @Test(.enabled(if: enabled))
    func bandCountStepsAndTheJumpTheyMake() throws {
        let screen = CGSize(width: 504, height: 328)
        let rig = try #require(GlassFidelityRig(screen: screen, scale: 2))
        let tuning = DepthTuning(viewingDistance: 4, recession: 0.8, blurEvenness: 0.1, dimReach: 0.6, maxBlurRadius: 40, maxDim: 0.8)
        let layout = FrostBandLayout()
        var counts: [(Double, Int)] = []
        var last = -1
        for step in 0...400 {
            let progress = Double(step) / 400
            let profile = FrostedGlassView.blurProfile(progress: progress, tuning: tuning, gradient: BlurGradient(), height: Double(screen.height))
            let count = layout.bands(for: profile, maximumRadius: Double(screen.height) / 2).count
            if count != last { counts.append((progress, count)); last = count }
        }
        print("audit: band counts by progress: \(counts.map { "\($0.1)@\($0.0)" }.joined(separator: " "))")
        guard counts.count > 2 else { return }
        let change = counts[2].0
        let epsilon = 0.0025
        func frame(_ progress: Double) throws -> GlassFidelityRig.Frame {
            let corners = GlassFidelityTests.corners(progress: progress, start: 85, span: 60, maxLean: 60)
            let lean = GlassLean(corners: corners, screenSize: screen, padded: DepthRenderer.paddedFrame(screenSize: screen, pixelScale: 2))
            return try #require(rig.glass { $0.apply(progress: progress, tuning: tuning, gradient: BlurGradient(), lean: lean) })
        }
        let across = GlassFidelityRig.difference(try frame(change - epsilon), try frame(change + epsilon))
        let within = GlassFidelityRig.difference(try frame(change + 3 * epsilon), try frame(change + 5 * epsilon))
        print("audit: step of \(2 * epsilon) across the band count change at \(change): \(across); the same step within one count: \(within)")
    }
}

/// The glass with every setting at its limit, at the end of the travel.
@MainActor
struct GlassExtremesTests {

    static let screen = CGSize(width: 1512, height: 982)

    /// Every mesh the glass builds, with every setting at an extreme, is
    /// finite and lies where the renderer can take it.
    @Test(arguments: [0.0, 0.5, 0.95, 0.99, 1.0])
    func meshesStayFiniteAtExtremes(progress: Double) throws {
        let extremes: [DepthTuning] = [
            DepthTuning(viewingDistance: 0.6, recession: 3, blurEvenness: 0, dimReach: 0.02, maxBlurRadius: 150, maxDim: 1),
            DepthTuning(viewingDistance: 12, recession: 3, blurEvenness: 1, dimReach: 1, maxBlurRadius: 150, maxDim: 1),
            DepthTuning(viewingDistance: 0.6, recession: 0.1, blurEvenness: 0.5, dimReach: 0.5, maxBlurRadius: 0, maxDim: 0),
            DepthTuning(viewingDistance: 2.7, recession: 2, blurEvenness: 0.4, dimReach: 0.7, maxBlurRadius: 55, maxDim: 0.4),
        ]
        for tuning in extremes {
            for maxLean in [10.0, 45.0, 85.0] {
                let ramp = LidEffectRamp(startAngle: 85.4, span: 64.59, maxLean: maxLean, recession: tuning.recession)
                let corners = DepthGeometry().corners(
                    startAngle: 85.4, currentAngle: ramp.pictureAngle(for: 85.4 - progress * 64.59),
                    viewingDistanceRatio: tuning.viewingDistance, recession: tuning.recession, screenSize: Self.screen
                )
                for corner in corners {
                    #expect(corner.x.isFinite && corner.y.isFinite, "corner \(corner) at lean \(maxLean) \(tuning)")
                }
                let lean = GlassLean(corners: corners, screenSize: Self.screen, padded: DepthRenderer.paddedFrame(screenSize: Self.screen, pixelScale: 2))
                let height = Double(Self.screen.height)
                let grid = lean.pictureGrid(bottom: 0, top: height, rows: 64)
                let parts = lean.meshParts(for: grid, layerFrame: CGRect(origin: .zero, size: Self.screen))
                for vertex in parts.vertices {
                    #expect(vertex.to.0.isFinite && vertex.to.1.isFinite, "vertex \(vertex.to) at lean \(maxLean) \(tuning)")
                    #expect(abs(vertex.to.0) < 100 && abs(vertex.to.1) < 100, "vertex far off the layer \(vertex.to) at lean \(maxLean) \(tuning)")
                }
                let sigma = { (picture: Double) in
                    BlurGradient().sigma(progress: progress, height: picture / height, maxBlurRadius: tuning.maxBlurRadius, evenness: tuning.blurEvenness)
                }
                for grid in FrostedGlassView.edgeGrids(lean: lean, sigma: sigma) {
                    guard let grid else { continue }
                    for row in grid.rows { for vertex in row {
                        #expect(vertex.picture.x.isFinite && vertex.picture.y.isFinite, "edge vertex \(vertex) at lean \(maxLean) \(tuning)")
                    } }
                    let parts = lean.meshParts(for: grid, layerFrame: CGRect(origin: .zero, size: Self.screen))
                    for vertex in parts.vertices {
                        #expect(vertex.to.0.isFinite && vertex.to.1.isFinite, "edge mesh vertex \(vertex.to)")
                    }
                }
                let stops = FrostedGlassView.shadeStops(progress: progress, tuning: tuning, gradient: BlurGradient(), height: height)
                #expect(stops.allSatisfy { $0.opacity >= 0 && $0.opacity <= 1 && $0.position >= 0 && $0.position <= height })
                #expect(zip(stops, stops.dropFirst()).allSatisfy { $0.position <= $1.position }, "shade stops out of order \(stops)")
                let bands = FrostBandLayout().bands(
                    for: FrostedGlassView.blurProfile(progress: progress, tuning: tuning, gradient: BlurGradient(), height: height),
                    maximumRadius: height / 2
                )
                for band in bands {
                    #expect(band.radius.isFinite && band.bottom.isFinite && band.top.isFinite)
                    #expect(band.fade.allSatisfy { $0.opacity >= 0 && $0.opacity <= 1 && $0.position.isFinite })
                    #expect(zip(band.fade, band.fade.dropFirst()).allSatisfy { $0.position <= $1.position }, "fade out of order \(band.fade)")
                }
                let view = FrostedGlassView(frame: NSRect(origin: .zero, size: Self.screen), scale: 2, samplesOtherWindows: false)
                view.apply(progress: progress, tuning: tuning, gradient: BlurGradient(), lean: lean)
                for layer in view.layer?.sublayers ?? [] {
                    #expect(layer.frame.origin.x.isFinite && layer.frame.origin.y.isFinite && layer.frame.width.isFinite && layer.frame.height.isFinite, "layer frame \(layer.frame)")
                    if let fade = layer.mask as? CAGradientLayer, let locations = fade.locations {
                        let values = locations.map(\.doubleValue)
                        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }, "fade locations out of order \(values)")
                        #expect(values.allSatisfy { $0 >= 0 && $0 <= 1 }, "fade locations off the band \(values)")
                    }
                }
            }
        }
    }

    /// Pictures of the glass at the end of the travel with extreme settings,
    /// for looking at. Run with `FIDELITY_DIR`.
    @Test(.enabled(if: GlassFidelityTests.directory != nil && ProcessInfo.processInfo.environment["FIDELITY_EXTREMES"] != nil))
    func picturesAtExtremes() throws {
        let rig = try #require(GlassFidelityRig(screen: Self.screen, scale: 2))
        let cases: [(String, DepthTuning, Double, Double)] = [
            ("max-all-near", DepthTuning(viewingDistance: 0.6, recession: 3, blurEvenness: 0, dimReach: 0.02, maxBlurRadius: 150, maxDim: 1), 85, 1.0),
            ("max-all-far", DepthTuning(viewingDistance: 12, recession: 3, blurEvenness: 1, dimReach: 1, maxBlurRadius: 150, maxDim: 1), 85, 1.0),
            ("max-lean-no-blur", DepthTuning(viewingDistance: 2.7, recession: 3, blurEvenness: 0.4, dimReach: 0.7, maxBlurRadius: 0, maxDim: 0), 85, 1.0),
            ("user-0.97", GlassFidelityTests.tuning, 70.33, 0.97),
            ("user-1.0", GlassFidelityTests.tuning, 70.33, 1.0),
        ]
        for (name, tuning, maxLean, progress) in cases {
            let ramp = LidEffectRamp(startAngle: 85.4, span: 64.59, maxLean: maxLean, recession: tuning.recession)
            let corners = DepthGeometry().corners(
                startAngle: 85.4, currentAngle: ramp.pictureAngle(for: 85.4 - progress * 64.59),
                viewingDistanceRatio: tuning.viewingDistance, recession: tuning.recession, screenSize: Self.screen
            )
            let lean = GlassLean(corners: corners, screenSize: Self.screen, padded: DepthRenderer.paddedFrame(screenSize: Self.screen, pixelScale: 2))
            let captured = try #require(rig.capture(corners: corners, progress: progress, tuning: tuning))
            let glass = try #require(rig.glass { $0.apply(progress: progress, tuning: tuning, gradient: BlurGradient(), lean: lean) })
            print("extremes \(name) corners \(corners.map { "(\(Int($0.x)),\(Int($0.y)))" }.joined()) \(GlassFidelityRig.difference(captured, glass))")
            GlassFidelityRig.write([captured, glass, GlassFidelityRig.amplified(captured, glass, gain: 8)],
                                   to: URL(fileURLWithPath: GlassFidelityTests.directory!).appendingPathComponent("extreme-\(name).png"))
        }
    }
}
