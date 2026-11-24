import AppKit
import CoreGraphics
import MetalKit
import IOKit.ps

// MARK: - Rendering layers

enum SnowRenderLayer {
    case background // Behind normal application windows.
    case foreground // Above windows: flakes, piles and mouse interaction.
}

private struct Snowflake {
    var position: CGPoint
    var velocity: CGVector
    var radius: CGFloat
    var alpha: CGFloat
    var phase: CGFloat
    var rotation: CGFloat
    var rotationSpeed: CGFloat
    var wobbleSpeed: CGFloat
    var wobbleAmplitude: CGFloat
    var spriteIndex: Int
    var depth: CGFloat
    var life: CGFloat // Positive means a timed lifetime; negative means persistent.
    var sourceSurfaceID: Int?
}

private struct SnowSurface {
    let id: Int
    let frame: CGRect
    let supportY: CGFloat
    let ownerName: String
    let isBottomEdge: Bool
    let isTarget: Bool

    var cornerInset: CGFloat {
        if isBottomEdge { return 0 }
        // The Dock has a pill-shaped footprint. Keep the snow shelf on its
        // straight upper section instead of letting it hang past the rounded ends.
        if ownerName == "Dock" { return min(34, max(18, frame.height * 0.46)) }
        return 12
    }
    var left: CGFloat { frame.minX + cornerInset }
    var right: CGFloat { frame.maxX - cornerInset }
}

private final class SnowPile {
    var lastFrame: CGRect
    var lastSurface: SnowSurface
    var fresh: [CGFloat]
    var packed: [CGFloat]
    var lastSeenAt: TimeInterval
    var pendingMovementX: CGFloat = 0
    var pendingMovementY: CGFloat = 0
    var pendingMovementDistance: CGFloat = 0

    init(surface: SnowSurface, binCount: Int, now: TimeInterval) {
        lastFrame = surface.frame
        lastSurface = surface
        fresh = Array(repeating: 0, count: max(1, binCount))
        packed = Array(repeating: 0, count: max(1, binCount))
        lastSeenAt = now
    }

    var count: Int { min(fresh.count, packed.count) }

    func height(at index: Int) -> CGFloat {
        guard index >= 0, index < count else { return 0 }
        return fresh[index] + packed[index]
    }

    func resize(to newCount: Int) {
        let count = max(1, newCount)
        guard count != fresh.count else { return }
        fresh = Self.resample(fresh, to: count)
        packed = Self.resample(packed, to: count)
    }

    private static func resample(_ source: [CGFloat], to count: Int) -> [CGFloat] {
        guard !source.isEmpty else { return Array(repeating: 0, count: count) }
        if count == 1 { return [source[source.count / 2]] }
        return (0..<count).map { index in
            let t = CGFloat(index) / CGFloat(count - 1)
            let oldPosition = t * CGFloat(max(0, source.count - 1))
            let lower = min(source.count - 1, Int(oldPosition))
            let upper = min(source.count - 1, lower + 1)
            let fraction = oldPosition - CGFloat(lower)
            return source[lower] * (1 - fraction) + source[upper] * fraction
        }
    }

    func totalHeight() -> CGFloat {
        guard count > 0 else { return 0 }
        return (0..<count).reduce(CGFloat.zero) { $0 + height(at: $1) }
    }
}

/// Transparent, click-through snow renderer. Uses AppKit points and a bottom-left origin.
/// AppDelegate creates one background instance and one foreground instance per display.
final class SnowOverlayView: NSView {
    // MARK: Configuration exposed to the menu bar controller

    let renderLayer: SnowRenderLayer
    var intensity: SnowIntensity = .normal {
        didSet { resizeAmbientFlakes() }
    }
    var finderOnly = false
    var accumulateOnBottom = true

    // MARK: Simulation state

    private let screen: NSScreen
    private let binWidth: CGFloat = 4
    private let missingSurfaceGracePeriod: TimeInterval = 1.25
    private let maximumBurstFlakes = 300
    private var maximumSnowHeight: CGFloat { max(8, intensity.maximumPileHeight) }
    private let baseWindStrength: CGFloat = 150

    private var ambientFlakes: [Snowflake] = []
    private var burstFlakes: [Snowflake] = []
    private var surfaces: [SnowSurface] = [] // CGWindowList order: front to back.
    private var piles: [Int: SnowPile] = [:]
    private var flakeSprites: [CGImage] = []
    private var lightDriftGradient: CGGradient?
    private var darkDriftGradient: CGGradient?
    private var metalParticleView: SnowParticleMetalView?

    private var timer: Timer?
    private var lastTick: TimeInterval = 0
    private var lastSurfaceScan: TimeInterval = 0
    private var elapsed: CGFloat = 0
    private var previousMouse: CGPoint?
    private var lastHapticTime: TimeInterval = 0
    private var lastPowerCheck: TimeInterval = 0
    private var onBatteryPower = false
    private var clearFadeRemaining: CGFloat = 0
    private var isDisplayCovered = false
    private var didClearForFullScreen = false

    private var isDarkAppearance: Bool {
        let appearance = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return appearance == .darkAqua
    }

    init(frame frameRect: NSRect, screen: NSScreen, renderLayer: SnowRenderLayer = .foreground) {
        self.screen = screen
        self.renderLayer = renderLayer
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        buildFlakeSprites()
        buildDriftGradient()
        resizeAmbientFlakes()
        if let device = MTLCreateSystemDefaultDevice() {
            let particleView = SnowParticleMetalView(frame: bounds, device: device)
            if particleView.isRendererReady {
                particleView.autoresizingMask = [.width, .height]
                addSubview(particleView)
                metalParticleView = particleView
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { false }

    deinit {
        timer?.invalidate()
    }

    // MARK: Public lifecycle

    func start() {
        guard timer == nil else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        lastPowerCheck = lastTick
        onBatteryPower = isOnBatteryPower()
        resizeAmbientFlakes()
        if renderLayer == .foreground {
            refreshSurfaces()
            lastSurfaceScan = lastTick
        }
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let displayFPS = min(120, max(60, screen.maximumFramesPerSecond))
        let targetFPS = onBatteryPower ? 30 : displayFPS
        metalParticleView?.preferredFramesPerSecond = targetFPS
        let interval = 1.0 / Double(targetFPS)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        ambientFlakes.removeAll(keepingCapacity: true)
        burstFlakes.removeAll(keepingCapacity: true)
        metalParticleView?.update(particles: [])
        metalParticleView?.draw()
        needsDisplay = true
    }

    /// Gradually melts the piles instead of removing them in one frame.
    func clearSnow() {
        clearFadeRemaining = 1.25
        for pile in piles.values {
            for index in 0..<pile.count {
                let removed = pile.fresh[index] * 0.72
                pile.fresh[index] -= removed
                pile.packed[index] = max(0, pile.packed[index] - pile.packed[index] * 0.16)
            }
        }
        needsDisplay = true
    }

    // MARK: Soft sprite generation

    private func buildFlakeSprites() {
        let specifications: [(size: Int, blobs: [(x: CGFloat, y: CGFloat, r: CGFloat, alpha: CGFloat)])] = [
            (32, [(0.48, 0.48, 0.48, 0.92), (0.28, 0.34, 0.18, 0.42)]),
            (48, [(0.50, 0.50, 0.48, 0.95), (0.31, 0.43, 0.22, 0.48), (0.68, 0.60, 0.20, 0.36)]),
            (64, [(0.50, 0.50, 0.49, 0.85), (0.31, 0.39, 0.25, 0.42), (0.69, 0.62, 0.22, 0.32), (0.49, 0.73, 0.16, 0.24)])
        ]
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        flakeSprites = specifications.compactMap { spec in
            guard let context = CGContext(
                data: nil,
                width: spec.size,
                height: spec.size,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }

            for blob in spec.blobs {
                let center = CGPoint(x: CGFloat(spec.size) * blob.x, y: CGFloat(spec.size) * blob.y)
                let radius = CGFloat(spec.size) * blob.r * 0.5
                let colors = [
                    CGColor(colorSpace: colorSpace, components: [0.99, 0.995, 1.0, blob.alpha])!,
                    CGColor(colorSpace: colorSpace, components: [0.94, 0.97, 1.0, blob.alpha * 0.44])!,
                    CGColor(colorSpace: colorSpace, components: [0.90, 0.95, 1.0, 0.0])!
                ] as CFArray
                guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 0.48, 1]) else { continue }
                context.drawRadialGradient(
                    gradient,
                    startCenter: center,
                    startRadius: 0,
                    endCenter: center,
                    endRadius: radius,
                    options: [.drawsAfterEndLocation]
                )
            }
            return context.makeImage()
        }
    }

    private func buildDriftGradient() {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let lightColors: [CGColor] = [
            CGColor(colorSpace: colorSpace, components: [1.0, 1.0, 1.0, 0.98])!,
            CGColor(colorSpace: colorSpace, components: [0.94, 0.97, 1.0, 0.96])!,
            CGColor(colorSpace: colorSpace, components: [0.76, 0.84, 0.94, 0.92])!
        ]
        let darkColors: [CGColor] = [
            CGColor(colorSpace: colorSpace, components: [0.90, 0.94, 1.0, 0.94])!,
            CGColor(colorSpace: colorSpace, components: [0.76, 0.84, 0.96, 0.92])!,
            CGColor(colorSpace: colorSpace, components: [0.48, 0.60, 0.78, 0.90])!
        ]
        lightDriftGradient = CGGradient(colorsSpace: colorSpace, colors: lightColors as CFArray, locations: [0, 0.52, 1])
        darkDriftGradient = CGGradient(colorsSpace: colorSpace, colors: darkColors as CFArray, locations: [0, 0.52, 1])
    }

    // MARK: Particle creation and depth layers

    private func resizeAmbientFlakes() {
        let fraction: CGFloat = renderLayer == .background ? 0.36 : 0.64
        let powerSaving: CGFloat = onBatteryPower ? 0.60 : 1.0
        let target = max(28, Int(CGFloat(intensity.maximumParticles) * fraction * powerSaving))
        if ambientFlakes.count < target {
            for _ in ambientFlakes.count..<target {
                ambientFlakes.append(makeAmbientFlake(randomY: true))
            }
        } else if ambientFlakes.count > target {
            ambientFlakes.removeLast(ambientFlakes.count - target)
        }
    }

    private func makeAmbientFlake(randomY: Bool) -> Snowflake {
        let roll = CGFloat.random(in: 0...1)
        let depth: CGFloat
        let radius: CGFloat
        let fallSpeed: CGFloat
        let alpha: CGFloat
        let sprite: Int

        if renderLayer == .background {
            depth = CGFloat.random(in: 0.34...0.60)
            radius = CGFloat.random(in: 1.4...3.3)
            fallSpeed = CGFloat.random(in: intensity.fallSpeed) * 0.72
            alpha = CGFloat.random(in: 0.24...0.53)
            sprite = 0
        } else if roll < 0.52 {
            depth = CGFloat.random(in: 0.58...0.78)
            radius = CGFloat.random(in: 3.1...5.5)
            fallSpeed = CGFloat.random(in: intensity.fallSpeed) * 0.90
            alpha = CGFloat.random(in: 0.48...0.78)
            sprite = 1
        } else {
            depth = CGFloat.random(in: 0.79...1.05)
            radius = CGFloat.random(in: 5.0...9.5)
            fallSpeed = CGFloat.random(in: intensity.fallSpeed) * 1.08
            alpha = CGFloat.random(in: 0.36...0.72)
            sprite = 2
        }

        return Snowflake(
            position: CGPoint(
                x: CGFloat.random(in: -28...max(bounds.width + 28, 29)),
                y: randomY ? CGFloat.random(in: 0...max(bounds.height, 1)) : bounds.height + CGFloat.random(in: 12...60)
            ),
            velocity: CGVector(dx: CGFloat.random(in: -5...5), dy: -fallSpeed),
            radius: radius,
            alpha: alpha,
            phase: CGFloat.random(in: 0...(CGFloat.pi * 2)),
            rotation: CGFloat.random(in: 0...(CGFloat.pi * 2)),
            rotationSpeed: CGFloat.random(in: -1.2...1.2),
            wobbleSpeed: CGFloat.random(in: 0.55...1.45),
            wobbleAmplitude: CGFloat.random(in: 3...11) * depth,
            spriteIndex: min(sprite, max(0, flakeSprites.count - 1)),
            depth: depth,
            life: -1,
            sourceSurfaceID: nil
        )
    }

    private func spawnPowder(at point: CGPoint, velocity: CGVector, count: Int, sourceSurfaceID: Int?) {
        guard !flakeSprites.isEmpty else { return }
        for _ in 0..<count {
            guard burstFlakes.count < maximumBurstFlakes else { return }
            let sprite = Int.random(in: 1..<flakeSprites.count)
            burstFlakes.append(Snowflake(
                position: CGPoint(
                    x: point.x + CGFloat.random(in: -3...3),
                    y: point.y + CGFloat.random(in: -2...2)
                ),
                velocity: CGVector(
                    dx: velocity.dx + CGFloat.random(in: -34...34),
                    dy: velocity.dy + CGFloat.random(in: -24...25)
                ),
                radius: CGFloat.random(in: 3.2...7.8),
                alpha: CGFloat.random(in: 0.56...0.94),
                phase: CGFloat.random(in: 0...(CGFloat.pi * 2)),
                rotation: CGFloat.random(in: 0...(CGFloat.pi * 2)),
                rotationSpeed: CGFloat.random(in: -2.2...2.2),
                wobbleSpeed: CGFloat.random(in: 0.8...1.8),
                wobbleAmplitude: CGFloat.random(in: 3...8),
                spriteIndex: sprite,
                depth: 0.88,
                life: -1, // Dislodged snow persists until it lands on a lower surface or the screen edge.
                sourceSurfaceID: sourceSurfaceID
            ))
        }
    }

    // MARK: Wind field

    /// Smooth scalar potential. Its perpendicular gradient gives a low-cost 2-D curl field.
    private func windPotential(x: CGFloat, y: CGFloat, time: CGFloat) -> CGFloat {
        let p1 = sin(x * 0.0032 + time * 0.45) * cos(y * 0.0028 - time * 0.31)
        let p2 = 0.5 * sin((x * 0.0061 - y * 0.0053) + time * 0.72)
        let p3 = 0.25 * cos((x * 0.011 + y * 0.009) - time * 1.15)
        return p1 + p2 + p3
    }

    private func curlWind(at point: CGPoint) -> CGVector {
        let epsilon: CGFloat = 3
        let dPsiDy = (windPotential(x: point.x, y: point.y + epsilon, time: elapsed)
            - windPotential(x: point.x, y: point.y - epsilon, time: elapsed)) / (2 * epsilon)
        let dPsiDx = (windPotential(x: point.x + epsilon, y: point.y, time: elapsed)
            - windPotential(x: point.x - epsilon, y: point.y, time: elapsed)) / (2 * epsilon)
        return CGVector(
            dx: dPsiDy * baseWindStrength,
            dy: -dPsiDx * baseWindStrength * 0.42
        )
    }

    // MARK: Window and Dock surfaces

    private func refreshSurfaces() {
        guard renderLayer == .foreground else { return }
        let windowInfos = WindowGeometryProvider.visibleWindowSurfaces(on: screen)
        var updated: [SnowSurface] = []
        var fullScreenWindowFound = false

        for info in windowInfos {
            let localFrame = info.frame
            let isTarget = !finderOnly || info.ownerName == "Finder"
            let surface = SnowSurface(
                id: Int(info.windowID),
                frame: localFrame,
                supportY: localFrame.maxY,
                ownerName: info.ownerName,
                isBottomEdge: false,
                isTarget: isTarget
            )
            updated.append(surface)

            let nearFullScreen = localFrame.width >= bounds.width * 0.985
                && localFrame.height >= bounds.height * 0.985
                && abs(localFrame.minX) < 8
                && abs(localFrame.minY) < 8
            if nearFullScreen { fullScreenWindowFound = true }
        }

        if accumulateOnBottom {
            // Dock is a real, limited-width support from its Accessibility AXList
            // bounds, not a synthetic shelf spanning the entire display.
            if let dockFrame = WindowGeometryProvider.dockSurfaceFrame(on: screen) {
                updated.insert(SnowSurface(
                    id: -3,
                    frame: dockFrame,
                    supportY: dockFrame.maxY,
                    ownerName: "Dock",
                    isBottomEdge: false,
                    isTarget: !finderOnly
                ), at: 0)
            }

            updated.append(SnowSurface(
                id: -2,
                frame: CGRect(x: 0, y: 0, width: bounds.width, height: 4),
                supportY: 0,
                ownerName: "Screen edge",
                isBottomEdge: true,
                isTarget: true
            ))
        }

        surfaces = updated
        isDisplayCovered = fullScreenWindowFound
        syncPilesWithSurfaces()
    }

    private func syncPilesWithSurfaces() {
        let now = ProcessInfo.processInfo.systemUptime
        var activeIDs = Set<Int>()

        for surface in surfaces where surface.isTarget {
            activeIDs.insert(surface.id)
            let usableWidth = max(1, surface.right - surface.left)
            let binCount = max(1, Int(ceil(usableWidth / binWidth)))

            if let pile = piles[surface.id] {
                pile.lastSeenAt = now
                let dx = surface.frame.minX - pile.lastFrame.minX
                let dy = surface.frame.minY - pile.lastFrame.minY
                pile.pendingMovementX += dx
                pile.pendingMovementY += dy
                pile.pendingMovementDistance += hypot(dx, dy)

                if pile.pendingMovementDistance >= 4 {
                    let movementX = pile.pendingMovementX
                    let movementY = pile.pendingMovementY
                    let movementDistance = pile.pendingMovementDistance
                    let sheddingRatio = min(0.30, max(0.0015, movementDistance / 2600))
                    shedPile(
                        pile,
                        from: pile.lastSurface,
                        movementX: movementX,
                        movementY: movementY,
                        ratio: sheddingRatio
                    )
                    pile.pendingMovementX = 0
                    pile.pendingMovementY = 0
                    pile.pendingMovementDistance = 0
                }

                pile.resize(to: binCount)
                pile.lastFrame = surface.frame
                pile.lastSurface = surface
            } else {
                piles[surface.id] = SnowPile(surface: surface, binCount: binCount, now: now)
            }
        }

        var temporarilyMissingSurfaces: [SnowSurface] = []
        for id in Array(piles.keys) where !activeIDs.contains(id) {
            guard let pile = piles[id] else { continue }
            if now - pile.lastSeenAt < missingSurfaceGracePeriod {
                // Keep rendering/colliding against its last known position while
                // CGWindowList temporarily omits a moving or animating window.
                temporarilyMissingSurfaces.append(pile.lastSurface)
                continue
            }

            piles.removeValue(forKey: id)
            shedPile(pile, from: pile.lastSurface, movementX: 0, movementY: 0, ratio: 1)
        }
        surfaces.append(contentsOf: temporarilyMissingSurfaces)
    }

    private func isOccluded(_ point: CGPoint, before surfaceIndex: Int) -> Bool {
        guard surfaceIndex > 0 else { return false }
        for index in 0..<min(surfaceIndex, surfaces.count) {
            let upper = surfaces[index]
            if !upper.isBottomEdge && upper.frame.contains(point) {
                return true
            }
        }
        return false
    }

    private func isOccluded(_ rect: CGRect, before surfaceIndex: Int) -> Bool {
        guard surfaceIndex > 0, !rect.isNull, !rect.isEmpty else { return false }
        for index in 0..<min(surfaceIndex, surfaces.count) {
            let upper = surfaces[index]
            if !upper.isBottomEdge && upper.frame.intersects(rect) {
                return true
            }
        }
        return false
    }

    private func pileIndex(for x: CGFloat, on surface: SnowSurface) -> Int {
        let raw = Int((x - surface.left) / binWidth)
        let count = piles[surface.id]?.count ?? 1
        return max(0, min(count - 1, raw))
    }

    private func depositSnow(on surface: SnowSurface, x: CGFloat, amount: CGFloat) {
        guard let pile = piles[surface.id], pile.count > 0 else { return }
        let center = pileIndex(for: x, on: surface)
        // A Gaussian footprint makes each landing form a small rounded pillow.
        for offset in -3...3 {
            let index = center + offset
            guard index >= 0, index < pile.count else { continue }
            let weight = exp(-CGFloat(offset * offset) / 4.2)
            let freshAmount = amount * weight
            let total = pile.height(at: index)
            let accepted = min(freshAmount, max(0, maximumSnowHeight - total))
            pile.fresh[index] += accepted
        }
    }

    private func relaxPile(_ pile: SnowPile, deltaTime: CGFloat) {
        guard pile.count > 2 else { return }
        let timeScale = max(0, deltaTime * 60)
        // Avalanche relaxation: transfer only enough snow to keep a natural repose slope.
        let maxSlope: CGFloat = 1.45
        for index in 0..<(pile.count - 1) {
            let left = pile.height(at: index)
            let right = pile.height(at: index + 1)
            let difference = left - right
            if difference > maxSlope {
                let transfer = (difference - maxSlope) * 0.18 * timeScale
                let loose = min(pile.fresh[index], transfer)
                pile.fresh[index] -= loose
                pile.fresh[index + 1] += loose
            } else if difference < -maxSlope {
                let transfer = (abs(difference) - maxSlope) * 0.18 * timeScale
                let loose = min(pile.fresh[index + 1], transfer)
                pile.fresh[index + 1] -= loose
                pile.fresh[index] += loose
            }
        }
        // A tiny amount of fresh powder compacts into a denser base over time.
        for index in 0..<pile.count {
            let compaction = min(pile.fresh[index], 0.00035 * timeScale)
            pile.fresh[index] -= compaction
            pile.packed[index] += compaction
        }
    }


    private func spillPileEdges(_ pile: SnowPile, deltaTime dt: CGFloat) {
        guard pile.count > 1, dt > 0 else { return }

        let surface = pile.lastSurface
        for index in [0, pile.count - 1] {
            let edgeHeight = pile.height(at: index)
            let overflow = max(0, edgeHeight - 1.45)
            guard overflow > 0 else { continue }

            let freshSpill = min(pile.fresh[index], overflow * dt * 0.85)
            let packedSpill = min(pile.packed[index], overflow * dt * 0.06)
            let removed = freshSpill + packedSpill
            guard removed > 0 else { continue }

            pile.fresh[index] -= freshSpill
            pile.packed[index] -= packedSpill

            if removed >= 0.05 {
                let direction: CGFloat = index == 0 ? -1 : 1
                let x = index == 0 ? surface.left : surface.right
                let isDock = surface.ownerName == "Dock"
                // Snow leaving a Dock end must clear the panel's rounded footprint
                // before dropping; otherwise it can appear suspended beside the Dock
                // or fall invisibly through the panel onto the screen edge below it.
                let horizontalSpeed: CGFloat = isDock ? 130 : 25
                let initialFallSpeed: CGFloat = isDock ? -8 : -20
                spawnPowder(
                    at: CGPoint(x: x, y: surface.supportY + edgeHeight * 0.55),
                    velocity: CGVector(dx: direction * horizontalSpeed, dy: initialFallSpeed),
                    count: 1,
                    sourceSurfaceID: surface.id
                )
            }
        }
    }

    private func shedPile(
        _ pile: SnowPile,
        from surface: SnowSurface,
        movementX: CGFloat,
        movementY: CGFloat,
        ratio: CGFloat
    ) {
        guard ratio > 0 else { return }
        for index in 0..<pile.count {
            let height = pile.height(at: index)
            guard height > 0.12 else { continue }
            let removedFresh = pile.fresh[index] * ratio
            let packedRatio: CGFloat = ratio >= 0.999 ? 1 : ratio * 0.46
            let removedPacked = pile.packed[index] * packedRatio
            let removed = removedFresh + removedPacked
            pile.fresh[index] -= removedFresh
            pile.packed[index] -= removedPacked
            guard removed > 0.08 else { continue }

            let x = surface.left + (CGFloat(index) + 0.5) * binWidth
            let y = surface.supportY + height * 0.55
            let dx = max(-180, min(180, -movementX * 2.5))
            let dy: CGFloat = -32
            let count = min(6, max(1, Int(removed / 2.2)))
            spawnPowder(at: CGPoint(x: x, y: y), velocity: CGVector(dx: dx, dy: dy), count: count, sourceSurfaceID: surface.id)
        }
    }

    // MARK: Mouse interaction: swept path, brush, soft powder and air wake

    private func currentMouseLocal() -> CGPoint {
        let global = NSEvent.mouseLocation
        return CGPoint(x: global.x - screen.frame.minX, y: global.y - screen.frame.minY)
    }

    private func distance(from point: CGPoint, toSegmentStart start: CGPoint, end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0.001 else { return hypot(point.x - start.x, point.y - start.y) }
        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        let projection = CGPoint(x: start.x + t * dx, y: start.y + t * dy)
        return hypot(point.x - projection.x, point.y - projection.y)
    }

    private func applyMouseInteraction(deltaTime dt: CGFloat) {
        let current = currentMouseLocal()
        defer { previousMouse = current }
        guard let previous = previousMouse else { return }

        let dx = current.x - previous.x
        let dy = current.y - previous.y
        let distanceTravelled = hypot(dx, dy)
        guard distanceTravelled > 0.8,
              bounds.insetBy(dx: -36, dy: -36).contains(current) else { return }

        let speed = min(1200, distanceTravelled / max(dt, 0.001))
        let brushRadius = min(44, 22 + distanceTravelled * 0.22)
        let swipeVelocity = CGVector(dx: dx / max(dt, 0.001) * 0.16, dy: dy / max(dt, 0.001) * 0.13)
        let sweepMinX = min(previous.x, current.x) - brushRadius
        let sweepMaxX = max(previous.x, current.x) + brushRadius
        let minMouseY = min(previous.y, current.y)
        let maxMouseY = max(previous.y, current.y)
        let swipePower = min(0.78, 0.16 + speed / 1800)
        let packedSwipeFactor = min(0.78, speed / 720)
        var removedVolume: CGFloat = 0

        for (surfaceIndex, surface) in surfaces.enumerated() where surface.isTarget {
            guard let pile = piles[surface.id], pile.count > 0 else { continue }
            guard maxMouseY >= surface.supportY - brushRadius,
                  minMouseY <= surface.supportY + maximumSnowHeight + brushRadius else { continue }

            var changed = false
            var particleWeight: CGFloat = 0
            var particleX: CGFloat = 0
            var particleY: CGFloat = 0
            var particleVelocityX: CGFloat = 0
            var particleVelocityY: CGFloat = 0
            let first = max(0, Int(floor((sweepMinX - surface.left) / binWidth)))
            let last = min(pile.count - 1, Int(floor((sweepMaxX - surface.left) / binWidth)))
            guard first <= last else { continue }

            // Process each affected bin once. The closest point on the full cursor
            // segment gives the same swept-brush shape without repeatedly scraping
            // the same snow at every intermediate sample.
            for index in first...last {
                let x = surface.left + (CGFloat(index) + 0.5) * binWidth
                if !surface.isBottomEdge,
                   isOccluded(CGPoint(x: x, y: surface.supportY + 1.5), before: surfaceIndex) { continue }
                let total = pile.height(at: index)
                guard total > 0.35 else { continue }
                let crest = CGPoint(x: x, y: surface.supportY + total * 0.62)
                let d = distance(from: crest, toSegmentStart: previous, end: current)
                guard d < brushRadius else { continue }

                let falloff = pow(max(0, 1 - d / brushRadius), 1.65)
                let freshRemoved = pile.fresh[index] * swipePower * falloff
                let packedRemoved = pile.packed[index] * swipePower * falloff * packedSwipeFactor
                let removed = freshRemoved + packedRemoved
                guard removed > 0.12 else { continue }

                pile.fresh[index] = max(0, pile.fresh[index] - freshRemoved)
                pile.packed[index] = max(0, pile.packed[index] - packedRemoved)
                removedVolume += removed
                changed = true

                if removed > 0.55 {
                    let side: CGFloat = (dx * (crest.y - current.y) - dy * (crest.x - current.x)) >= 0 ? 1 : -1
                    let swirl = CGVector(dx: -swipeVelocity.dy * side * 0.18, dy: swipeVelocity.dx * side * 0.18)
                    let velocity = CGVector(
                        dx: swipeVelocity.dx * 0.45 + swirl.dx,
                        dy: swipeVelocity.dy * 0.30 + swirl.dy - 18
                    )
                    particleWeight += removed
                    particleX += x * removed
                    particleY += (surface.supportY + total * 0.68) * removed
                    particleVelocityX += velocity.dx * removed
                    particleVelocityY += velocity.dy * removed
                }
            }
            if particleWeight > 1.0 {
                let center = CGPoint(x: particleX / particleWeight, y: particleY / particleWeight)
                let velocity = CGVector(
                    dx: particleVelocityX / particleWeight,
                    dy: particleVelocityY / particleWeight
                )
                let particleCount = min(5, max(1, Int(particleWeight / 3.5)))
                spawnPowder(at: center, velocity: velocity, count: particleCount, sourceSurfaceID: surface.id)
            }
            if changed { relaxPile(pile, deltaTime: dt) }

            // The surface array is top-to-bottom: a top window protects piles behind it.
            _ = surfaceIndex
        }

        // A moving hand creates a small curl in nearby ambient flakes.
        let wakeRadius: CGFloat = 76
        for index in ambientFlakes.indices {
            let offset = CGPoint(
                x: ambientFlakes[index].position.x - current.x,
                y: ambientFlakes[index].position.y - current.y
            )
            let d = hypot(offset.x, offset.y)
            guard d > 1, d < wakeRadius else { continue }
            let falloff = (1 - d / wakeRadius) * ambientFlakes[index].depth
            let side: CGFloat = (dx * offset.y - dy * offset.x) >= 0 ? 1 : -1
            let swirlX = -dy * side * 0.018
            let swirlY = dx * side * 0.018
            ambientFlakes[index].velocity.dx += (dx * 0.12 + swirlX + offset.x / d * 5) * falloff
            ambientFlakes[index].velocity.dy += (dy * 0.08 + swirlY) * falloff
        }

        if removedVolume > 14, ProcessInfo.processInfo.systemUptime - lastHapticTime > 0.12 {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            lastHapticTime = ProcessInfo.processInfo.systemUptime
        }
    }

    // MARK: Simulation loop and collisions

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = CGFloat(min(0.05, max(0.001, now - lastTick)))
        lastTick = now
        elapsed += dt

        if now - lastPowerCheck > 20 {
            lastPowerCheck = now
            let latestPowerState = isOnBatteryPower()
            if latestPowerState != onBatteryPower {
                onBatteryPower = latestPowerState
                resizeAmbientFlakes()
                scheduleTimer()
            }
        }

        if renderLayer == .foreground, now - lastSurfaceScan > 0.16 {
            refreshSurfaces()
            lastSurfaceScan = now
        }

        // Full-screen windows pause the foreground simulation to avoid covering movies/games.
        if renderLayer == .foreground, isDisplayCovered {
            if !didClearForFullScreen {
                didClearForFullScreen = true
                metalParticleView?.update(particles: [])
                metalParticleView?.draw()
                needsDisplay = true
            }
            return
        }
        didClearForFullScreen = false

        if renderLayer == .foreground {
            applyMouseInteraction(deltaTime: dt)
        }

        updateAmbientFlakes(deltaTime: dt)
        updateBurstFlakes(deltaTime: dt)
        let freshMeltFactor = exp(-dt * 0.0008)
        let packedMeltFactor = exp(-dt * 0.00018)
        for pile in piles.values {
            relaxPile(pile, deltaTime: dt)
            spillPileEdges(pile, deltaTime: dt)
            for index in 0..<pile.count {
                pile.fresh[index] *= freshMeltFactor
                pile.packed[index] *= packedMeltFactor
            }
        }
        if clearFadeRemaining > 0 {
            let fadeTime = min(dt, clearFadeRemaining)
            let fade = exp(-fadeTime * 2.6)
            for pile in piles.values {
                for index in 0..<pile.count {
                    pile.fresh[index] *= fade
                    pile.packed[index] *= fade
                }
            }
            clearFadeRemaining = max(0, clearFadeRemaining - fadeTime)
        }
        updateMetalParticles()
        needsDisplay = true
    }

    private func updateAmbientFlakes(deltaTime dt: CGFloat) {
        let globalWind = sin(elapsed * 0.32) * 7 + sin(elapsed * 0.79) * 3
        for index in ambientFlakes.indices {
            var flake = ambientFlakes[index]
            let previous = flake.position
            let curl = curlWind(at: flake.position)

            flake.phase += dt * flake.wobbleSpeed
            flake.velocity.dx += (curl.dx + globalWind * flake.depth + sin(flake.phase) * flake.wobbleAmplitude) * dt
            flake.velocity.dx *= exp(-0.28 * dt)
            flake.velocity.dx = min(42, max(-42, flake.velocity.dx))
            let targetFallSpeed: CGFloat = flake.depth < 0.6 ? 25 : (flake.depth < 0.85 ? 36 : 48)
            let verticalSpeedError = -targetFallSpeed - flake.velocity.dy
            let verticalResponse = min(CGFloat(1), dt * CGFloat(0.75))
            flake.velocity.dy += verticalSpeedError * verticalResponse
            flake.rotation += flake.rotationSpeed * dt
            flake.position.x += flake.velocity.dx * dt
            flake.position.y += flake.velocity.dy * dt

            if renderLayer == .foreground,
               let landedSurface = landingSurface(from: previous, to: flake.position) {
                depositSnow(on: landedSurface, x: flake.position.x, amount: flake.radius * 0.22)
                flake = makeAmbientFlake(randomY: false)
            } else if flake.position.y < -24 {
                flake = makeAmbientFlake(randomY: false)
            } else if flake.position.x < -42 {
                flake.position.x = bounds.width + 36
            } else if flake.position.x > bounds.width + 42 {
                flake.position.x = -36
            }
            ambientFlakes[index] = flake
        }
    }

    private func landingSurface(from old: CGPoint, to new: CGPoint, excludingSurfaceID: Int? = nil) -> SnowSurface? {
        guard new.y < old.y else { return nil }
        for (index, surface) in surfaces.enumerated() where surface.isTarget {
            if surface.id == excludingSurfaceID && !surface.isBottomEdge { continue }
            guard new.x >= surface.left, new.x <= surface.right else { continue }
            let pile = piles[surface.id]
            let bin = pileIndex(for: new.x, on: surface)
            let pileHeight = pile?.height(at: bin) ?? 0
            let top = surface.supportY + pileHeight
            guard old.y >= top, new.y <= top else { continue }
            let occlusionPoint = CGPoint(x: new.x, y: surface.supportY + 1.5)
            if surface.isBottomEdge || !isOccluded(occlusionPoint, before: index) {
                return surface
            }
        }
        return nil
    }

    private func updateBurstFlakes(deltaTime dt: CGFloat) {
        guard !burstFlakes.isEmpty else { return }
        for index in burstFlakes.indices.reversed() {
            var flake = burstFlakes[index]
            let previous = flake.position
            let hasTimedLifetime = flake.life > 0
            if hasTimedLifetime { flake.life -= dt }
            flake.phase += dt * flake.wobbleSpeed
            let curl = curlWind(at: flake.position)

            // Strong air resistance makes swept snow drift as powder, not sparks.
            flake.velocity.dx += curl.dx * dt * 0.16
            flake.velocity.dx *= exp(-2.15 * dt)
            flake.velocity.dy += (-30 + curl.dy * 0.08) * dt
            flake.velocity.dy *= exp(-0.36 * dt)
            flake.velocity.dx = min(230, max(-230, flake.velocity.dx))
            flake.velocity.dy = min(90, max(-160, flake.velocity.dy))
            flake.rotation += flake.rotationSpeed * dt
            flake.position.x += (flake.velocity.dx + sin(flake.phase) * 7) * dt
            flake.position.y += flake.velocity.dy * dt

            // Clamp before collision detection so an edge particle cannot skip
            // the bottom support on the same frame that it crosses the display edge.
            if flake.position.x < 0 {
                flake.position.x = 0
                flake.velocity.dx = abs(flake.velocity.dx) * 0.35
            } else if flake.position.x > bounds.width {
                flake.position.x = bounds.width
                flake.velocity.dx = -abs(flake.velocity.dx) * 0.35
            }

            if let landed = landingSurface(from: previous, to: flake.position, excludingSurfaceID: flake.sourceSurfaceID) {
                depositSnow(on: landed, x: flake.position.x, amount: flake.radius * 0.13)
                burstFlakes.remove(at: index)
                continue
            }

            if (hasTimedLifetime && flake.life <= 0) || flake.position.y < -40 {
                burstFlakes.remove(at: index)
            } else {
                burstFlakes[index] = flake
            }
        }
    }

    private func updateMetalParticles() {
        guard let metalParticleView else { return }
        let mouse = currentMouseLocal()
        var renderList = ambientFlakes
        if renderLayer == .foreground {
            renderList.append(contentsOf: burstFlakes)
        }

        let packets: [SnowGPUInstance] = renderList.compactMap { flake in
            let focusFade: CGFloat
            if flake.life < 0, flake.depth > 0.82 {
                let distance = hypot(flake.position.x - mouse.x, flake.position.y - mouse.y)
                let normalized = min(1, distance / 92)
                focusFade = 0.15 + 0.85 * normalized * normalized
            } else {
                focusFade = 1
            }
            let lifeFade = flake.life > 0 ? min(1, flake.life * 0.8) : 1
            let alpha = flake.alpha * focusFade * lifeFade
            guard alpha > 0.015 else { return nil }

            let backingScale = window?.backingScaleFactor ?? screen.backingScaleFactor
            return SnowGPUInstance(
                center: SIMD2<Float>(Float(flake.position.x * backingScale), Float(flake.position.y * backingScale)),
                radius: Float(flake.radius * backingScale),
                alpha: Float(alpha),
                rotation: Float(flake.rotation),
                softness: Float(flake.depth)
            )
        }
        metalParticleView.update(particles: packets)
        metalParticleView.draw()
    }

    private func isOnBatteryPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return false
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            if let state = description[kIOPSPowerSourceStateKey] as? String,
               state == kIOPSBatteryPowerValue {
                return true
            }
        }
        return false
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(dirtyRect)
        if renderLayer == .foreground, isDisplayCovered { return }

        if renderLayer == .foreground {
            drawSnowdrifts(in: context)
        }
        if metalParticleView == nil {
            drawFlakes(ambientFlakes, in: context, fadesNearCursor: true)
            if renderLayer == .foreground {
                drawFlakes(burstFlakes, in: context, fadesNearCursor: false)
            }
        }
    }

    private func drawFlakes(_ flakes: [Snowflake], in context: CGContext, fadesNearCursor: Bool) {
        guard !flakeSprites.isEmpty else { return }
        let mouse = currentMouseLocal()
        context.saveGState()

        for flake in flakes {
            let focusFade: CGFloat
            if fadesNearCursor, flake.depth > 0.82 {
                let distance = hypot(flake.position.x - mouse.x, flake.position.y - mouse.y)
                let normalized = min(1, distance / 92)
                focusFade = 0.15 + 0.85 * normalized * normalized
            } else {
                focusFade = 1
            }

            let lifeFade = flake.life > 0 ? min(1, flake.life * 0.8) : 1
            let alpha = flake.alpha * focusFade * lifeFade
            guard alpha > 0.015 else { continue }

            let image = flakeSprites[min(flake.spriteIndex, flakeSprites.count - 1)]
            let widthScale = 0.58 + 0.42 * abs(cos(flake.rotation * 1.7))
            let width = flake.radius * 2 * widthScale
            let height = flake.radius * 2

            context.saveGState()
            context.setAlpha(alpha)
            context.translateBy(x: flake.position.x, y: flake.position.y)
            context.rotate(by: flake.rotation)
            let rect = CGRect(x: -width * 0.5, y: -height * 0.5, width: width, height: height)
            context.draw(image, in: rect)
            context.restoreGState()
        }

        context.restoreGState()
    }

    private func drawSnowdrifts(in context: CGContext) {
        // CGWindowList order is front-to-back. Mask each rear pile wherever an upper
        // window currently covers it, without deleting the stored snow underneath.
        for surfaceIndex in surfaces.indices.reversed() {
            let surface = surfaces[surfaceIndex]
            guard surface.isTarget, let pile = piles[surface.id], pile.count > 0 else { continue }

            let visibleHeights: [CGFloat] = (0..<pile.count).map { index in
                let x = surface.left + (CGFloat(index) + 0.5) * binWidth
                let height = pile.height(at: index)
                let pileColumn = CGRect(
                    x: x - binWidth * 0.5,
                    y: surface.supportY - 3,
                    width: binWidth,
                    height: height + 3
                )
                return !surface.isBottomEdge && isOccluded(pileColumn, before: surfaceIndex) ? 0 : height
            }

            var runStart: Int?
            for index in 0...visibleHeights.count {
                let height = index < visibleHeights.count ? visibleHeights[index] : 0
                if height > 0.30, runStart == nil {
                    runStart = index
                } else if height <= 0.30, let start = runStart {
                    let end = index - 1
                    drawDriftSegment(visibleHeights, surface: surface, range: start...end, in: context)
                    runStart = nil
                }
            }
        }
    }

    private func drawDriftSegment(
        _ heights: [CGFloat],
        surface: SnowSurface,
        range: ClosedRange<Int>,
        in context: CGContext
    ) {
        guard !range.isEmpty else { return }
        let startX = surface.left
        let supportY = surface.supportY
        let baseY = supportY - (surface.isBottomEdge ? 0 : 2.5)
        let firstX = startX + CGFloat(range.lowerBound) * binWidth
        let lastX = min(surface.right, startX + CGFloat(range.upperBound + 1) * binWidth)
        guard lastX > firstX else { return }

        var crestPoints: [CGPoint] = []
        crestPoints.reserveCapacity(range.count + 1)
        for index in range {
            let centerX = startX + (CGFloat(index) + 0.5) * binWidth
            let height = heights[index]
            let smallRidge = sin(CGFloat(index) * 1.73 + CGFloat(surface.id) * 0.11) * 0.42
            crestPoints.append(CGPoint(x: centerX, y: supportY + height + smallRidge))
        }
        guard let first = crestPoints.first else { return }

        let path = CGMutablePath()
        // Rounded ends, and a slight soft lip that sits over the window's top border.
        path.move(to: CGPoint(x: firstX, y: baseY))
        path.addQuadCurve(
            to: CGPoint(x: first.x, y: first.y),
            control: CGPoint(x: firstX + min(8, binWidth * 1.7), y: baseY + 1)
        )
        if crestPoints.count > 1 {
            for pointIndex in 0..<(crestPoints.count - 1) {
                let current = crestPoints[pointIndex]
                let next = crestPoints[pointIndex + 1]
                let midpoint = CGPoint(x: (current.x + next.x) * 0.5, y: (current.y + next.y) * 0.5)
                path.addQuadCurve(to: midpoint, control: current)
            }
        }
        path.addQuadCurve(
            to: CGPoint(x: lastX, y: baseY),
            control: CGPoint(x: lastX - min(8, binWidth * 1.7), y: baseY + 1)
        )
        path.closeSubpath()

        context.saveGState()
        let shadowColor = NSColor(calibratedRed: 0.10, green: 0.18, blue: 0.29, alpha: isDarkAppearance ? 0.38 : 0.25).cgColor
        context.setShadow(offset: CGSize(width: 0, height: -2.2), blur: 4.2, color: shadowColor)
        context.addPath(path)
        context.setFillColor(NSColor.white.withAlphaComponent(isDarkAppearance ? 0.91 : 0.97).cgColor)
        context.fillPath()
        context.restoreGState()

        if let gradient = (isDarkAppearance ? darkDriftGradient : lightDriftGradient) {
            context.saveGState()
            context.addPath(path)
            context.clip()
            let highest = crestPoints.map(\.y).max() ?? supportY + 2
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: highest),
                end: CGPoint(x: 0, y: baseY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
            context.restoreGState()
        }

        // Soft, broken highlight rather than a hard continuous outline.
        context.saveGState()
        context.setStrokeColor(NSColor.white.withAlphaComponent(isDarkAppearance ? 0.54 : 0.72).cgColor)
        context.setLineWidth(0.75)
        let highlight = CGMutablePath()
        highlight.move(to: first)
        for point in crestPoints.dropFirst() {
            highlight.addLine(to: point)
        }
        context.addPath(highlight)
        context.strokePath()
        context.restoreGState()

        // Rare tiny crystals glint briefly inside the drift.
        for index in range where index % 9 == Int(elapsed * 1.7) % 9 {
            let sparkle = sin(elapsed * 2.6 + CGFloat(index) * 1.7 + CGFloat(surface.id))
            guard sparkle > 0.78 else { continue }
            let x = startX + (CGFloat(index) + 0.5) * binWidth
            let y = supportY + heights[index] * 0.64
            context.setFillColor(NSColor.white.withAlphaComponent(0.26 + sparkle * 0.5).cgColor)
            context.fillEllipse(in: CGRect(x: x, y: y, width: 1.1, height: 1.1))
        }
    }
}


// MARK: - Instanced Metal particle renderer

private struct SnowGPUInstance {
    var center: SIMD2<Float>
    var radius: Float
    var alpha: Float
    var rotation: Float
    var softness: Float
}

private struct SnowGPUUniforms {
    var viewportSize: SIMD2<Float>
}

/// Uses one instanced draw call for all particles. Snowdrifts remain vector-drawn by AppKit,
/// which keeps their geometry easy to tune while moving the high-count particle layer to GPU.
private final class SnowParticleMetalView: MTKView, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?
    private var particleBuffer: MTLBuffer?
    private var bufferCapacity = 0
    private var instanceCount = 0
    private static let spriteShader = """
    #include <metal_stdlib>
    using namespace metal;

    struct SnowParticle {
        float2 center;
        float radius;
        float alpha;
        float rotation;
        float softness;
    };

    struct SnowUniforms { float2 viewportSize; };

    struct SnowVertexOut {
        float4 position [[position]];
        float2 uv;
        float alpha;
        float softness;
    };

    vertex SnowVertexOut snowVertex(
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]],
        const device SnowParticle* particles [[buffer(0)]],
        constant SnowUniforms& uniforms [[buffer(1)]]
    ) {
        const float2 corners[6] = {
            float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0),
            float2(-1.0, 1.0), float2(1.0, -1.0), float2(1.0, 1.0)
        };
        SnowParticle particle = particles[instanceID];
        float2 corner = corners[vertexID];
        float cosine = cos(particle.rotation);
        float sine = sin(particle.rotation);
        float2 rotated = float2(
            corner.x * cosine - corner.y * sine,
            corner.x * sine + corner.y * cosine
        );
        float2 pixel = particle.center + rotated * particle.radius;
        float2 clip = float2(
            pixel.x / uniforms.viewportSize.x * 2.0 - 1.0,
            pixel.y / uniforms.viewportSize.y * 2.0 - 1.0
        );
        SnowVertexOut output;
        output.position = float4(clip, 0.0, 1.0);
        output.uv = rotated;
        output.alpha = particle.alpha;
        output.softness = particle.softness;
        return output;
    }

    fragment half4 snowFragment(SnowVertexOut input [[stage_in]]) {
        float distanceFromCenter = length(input.uv);
        float2 lobeA = input.uv - float2(-0.20, 0.10);
        float2 lobeB = input.uv - float2(0.18, -0.17);
        float core = exp(-distanceFromCenter * distanceFromCenter * mix(3.0, 4.6, input.softness));
        float lobe = max(exp(-dot(lobeA, lobeA) * 15.0) * 0.24,
                         exp(-dot(lobeB, lobeB) * 18.0) * 0.18);
        float innerEdge = mix(0.40, 0.64, input.softness);
        float feather = 1.0 - smoothstep(innerEdge, 1.0, distanceFromCenter);
        float alpha = min(1.0, feather * (core + lobe) * input.alpha);
        half3 snowColor = half3(0.94, 0.975, 1.0);
        return half4(snowColor * half(alpha), half(alpha));
    }
    """

    var isRendererReady: Bool { pipeline != nil && commandQueue != nil }

    init(frame: CGRect, device: MTLDevice) {
        let library = try? device.makeLibrary(source: Self.spriteShader, options: nil)
        let vertex = library?.makeFunction(name: "snowVertex")
        let fragment = library?.makeFunction(name: "snowFragment")
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let pipelineState = (vertex != nil && fragment != nil) ? try? device.makeRenderPipelineState(descriptor: descriptor) : nil

        pipeline = pipelineState
        commandQueue = device.makeCommandQueue()
        super.init(frame: frame, device: device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = false
        wantsLayer = true
        layer?.isOpaque = false
        delegate = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(particles: [SnowGPUInstance]) {
        instanceCount = particles.count
        guard !particles.isEmpty else { return }

        if particles.count > bufferCapacity {
            bufferCapacity = max(particles.count, max(64, bufferCapacity * 2))
            particleBuffer = device?.makeBuffer(
                length: MemoryLayout<SnowGPUInstance>.stride * bufferCapacity,
                options: .storageModeShared
            )
        }

        guard let particleBuffer else { return }
        particles.withUnsafeBytes { source in
            guard let address = source.baseAddress else { return }
            particleBuffer.contents().copyMemory(from: address, byteCount: source.count)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipeline,
              let commandQueue,
              let pass = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)

        if instanceCount > 0, let particleBuffer {
            var uniforms = SnowGPUUniforms(viewportSize: SIMD2<Float>(
                Float(drawableSize.width),
                Float(drawableSize.height)
            ))
            encoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<SnowGPUUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: instanceCount)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
