import Foundation
import CoreGraphics

func runDockModelTests() {
    runProviderDetailModelTests()
    let size = CGSize(width: 360, height: DashboardSizing.preferredSize(providerCount: 3, cameraHeight: 28).height)
    let epsilon: CGFloat = 0.0000001
    let screen = DockScreenMetrics(
        frame: CGRect(x: -1000.5, y: 30.25, width: 1000, height: 700),
        visibleFrame: CGRect(x: -1000.5, y: 50.25, width: 1000, height: 651),
        safeAreaTop: 28, menuBarHeight: 22,
        auxiliaryTopLeft: CGRect(x: -1000.5, y: 702.25, width: 400, height: 28),
        auxiliaryTopRight: CGRect(x: -440.5, y: 702.25, width: 440, height: 28))
    // Default: three controls on the right wing only (the legacy single-wing shape).
    func layout(_ metrics: DockScreenMetrics, _ state: DockPresentation, _ manual: CGPoint? = nil,
                left: Int = 0, right: Int = 3) -> DockLayout {
        guard let result = DockGeometry.layout(screen: metrics, presentation: state,
                                               preferredExpandedSize: size,
                                               leftCompactSlots: left, rightCompactSlots: right,
                                               manualTopCenter: manual) else {
            preconditionFailure("Expected usable layout")
        }
        return result
    }
    func global(_ rect: CGRect, in layout: DockLayout) -> CGRect {
        rect.offsetBy(dx: layout.frame.minX, dy: layout.frame.minY)
    }
    func equal(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < epsilon && abs(a.minY - b.minY) < epsilon &&
        abs(a.width - b.width) < epsilon && abs(a.height - b.height) < epsilon
    }
    func bounded(_ result: DockLayout, _ metrics: DockScreenMetrics) {
        precondition(result.frame.width > 0 && result.frame.height > 0)
        precondition(result.frame.minX >= metrics.frame.minX - epsilon &&
                     result.frame.maxX <= metrics.frame.maxX + epsilon)
        precondition(result.frame.minY >= max(metrics.frame.minY, metrics.visibleFrame.minY) - epsilon)
        precondition(result.frame.maxY <= metrics.frame.maxY + epsilon)
        for rect in [result.bodyRect, result.cameraRect, result.leftIndicatorRect, result.rightIndicatorRect] {
            precondition(rect.minX >= -epsilon && rect.minY >= -epsilon)
            precondition(rect.maxX <= result.frame.width + epsilon && rect.maxY <= result.frame.height + epsilon)
        }
        switch result.mode {
        case .notchConnected:
            precondition(abs(result.frame.maxY - metrics.frame.maxY) < epsilon)
            let camera = global(result.cameraRect, in: result)
            precondition(abs(camera.minX - metrics.auxiliaryTopLeft.maxX) < epsilon)
            precondition(abs(camera.maxX - metrics.auxiliaryTopRight.minX) < epsilon)
            precondition(abs(camera.maxY - metrics.frame.maxY) < epsilon)
            precondition(abs(camera.height - metrics.safeAreaTop) < epsilon)
            precondition(result.cameraRect.minX >= result.bodyRect.minX - epsilon)
            precondition(result.cameraRect.maxX <= result.bodyRect.maxX + epsilon)
            precondition(result.cameraRect.maxY <= result.bodyRect.maxY + epsilon)
            // Controls sit beside the camera, flush with the screen edge, never below or under it:
            // the left wing entirely left of it, the right wing entirely right of it.
            if !result.leftIndicatorRect.isEmpty {
                let wing = global(result.leftIndicatorRect, in: result)
                precondition(abs(wing.maxY - metrics.frame.maxY) < epsilon && wing.maxX <= camera.minX + epsilon)
            }
            if !result.rightIndicatorRect.isEmpty {
                let wing = global(result.rightIndicatorRect, in: result)
                precondition(abs(wing.maxY - metrics.frame.maxY) < epsilon && wing.minX >= camera.maxX - epsilon)
            }
        case .floating:
            precondition(result.frame.maxY <= metrics.safeTop + epsilon)
            precondition(result.cameraRect == .zero)
            if !result.leftIndicatorRect.isEmpty && !result.rightIndicatorRect.isEmpty {
                precondition(result.rightIndicatorRect.minX >= result.leftIndicatorRect.maxX - epsilon)
            }
        }
    }
    let compact = layout(screen, .compact)
    let expanded = layout(screen, .expanded)
    bounded(compact, screen)
    bounded(expanded, screen)
    precondition(compact.mode == .notchConnected && expanded.mode == .notchConnected)
    precondition(expanded.frame.midX == -520.5)
    // Three right slots: 26n+12 = 90pt wing attached to the right of the 160pt camera, camera-high;
    // the empty left wing is exactly zero and contributes nothing to the frame.
    precondition(compact.frame.width == 160 + 90 && compact.frame.height == 28)
    precondition(compact.bodyRect == CGRect(origin: .zero, size: compact.frame.size))
    precondition(compact.cameraRect.minX == 0 && compact.rightIndicatorRect.minX == 160 && compact.rightIndicatorRect.width == 90)
    precondition(compact.leftIndicatorRect == .zero)
    precondition(expanded.bodyRect.width >= expanded.cameraRect.width + 200)
    precondition(expanded.bodyRect.minX > 0 && expanded.bodyRect.maxX < expanded.frame.width)
    precondition(expanded.bodyRect.height == size.height && expanded.bodyRect.maxY == expanded.frame.height)
    precondition(equal(global(compact.cameraRect, in: compact), global(expanded.cameraRect, in: expanded)))
    precondition(equal(global(compact.rightIndicatorRect, in: compact), global(expanded.rightIndicatorRect, in: expanded)))
    precondition(expanded.leftIndicatorRect == .zero)

    // Compact is asymmetric: its midpoint is not the camera's, so the anchor is the camera.
    precondition(compact.frame.midX != expanded.frame.midX)
    precondition(DockGeometry.sharesAnchor(compact, expanded) && DockGeometry.sharesAnchor(expanded, compact))

    // A left-only wing mirrors around the same physical camera and the frame spans only it + camera.
    let compactLeft = layout(screen, .compact, left: 3, right: 0)
    let expandedLeft = layout(screen, .expanded, left: 3, right: 0)
    bounded(compactLeft, screen)
    bounded(expandedLeft, screen)
    precondition(compactLeft.frame.width == compact.frame.width && compactLeft.frame.height == compact.frame.height)
    precondition(compactLeft.cameraRect.minX == 90 && compactLeft.leftIndicatorRect.minX == 0 && compactLeft.leftIndicatorRect.width == 90)
    precondition(compactLeft.rightIndicatorRect == .zero)
    precondition(equal(global(compactLeft.cameraRect, in: compactLeft), global(compact.cameraRect, in: compact)))
    precondition(abs(global(compactLeft.leftIndicatorRect, in: compactLeft).maxX - screen.auxiliaryTopLeft.maxX) < epsilon)
    precondition(abs(global(compact.rightIndicatorRect, in: compact).minX - screen.auxiliaryTopRight.minX) < epsilon)
    precondition(abs(compactLeft.frame.maxX - screen.auxiliaryTopRight.minX) < epsilon)
    precondition(abs(compact.frame.minX - screen.auxiliaryTopLeft.maxX) < epsilon)
    precondition(equal(global(compactLeft.leftIndicatorRect, in: compactLeft), global(expandedLeft.leftIndicatorRect, in: expandedLeft)))
    precondition(DockGeometry.sharesAnchor(compactLeft, compact) && DockGeometry.sharesAnchor(compactLeft, expandedLeft))

    // Mixed wings: each wing is sized by its own count (26n+12) around the same camera, in one frame
    // spanning exactly both occupied wings and the camera. Expanded layouts keep both wings in place.
    let mixedCompact = layout(screen, .compact, left: 2, right: 3)
    let mixedExpanded = layout(screen, .expanded, left: 2, right: 3)
    bounded(mixedCompact, screen)
    bounded(mixedExpanded, screen)
    precondition(mixedCompact.frame.width == 64 + 160 + 90 && mixedCompact.frame.height == 28)
    precondition(mixedCompact.leftIndicatorRect == CGRect(x: 0, y: 0, width: 64, height: 28))
    precondition(mixedCompact.cameraRect.minX == 64 && mixedCompact.rightIndicatorRect.minX == 64 + 160)
    precondition(mixedCompact.rightIndicatorRect.width == 90 && mixedCompact.bodyRect == CGRect(origin: .zero, size: mixedCompact.frame.size))
    precondition(equal(global(mixedCompact.cameraRect, in: mixedCompact), global(compact.cameraRect, in: compact)))
    precondition(equal(global(mixedCompact.leftIndicatorRect, in: mixedCompact), global(mixedExpanded.leftIndicatorRect, in: mixedExpanded)))
    precondition(equal(global(mixedCompact.rightIndicatorRect, in: mixedCompact), global(mixedExpanded.rightIndicatorRect, in: mixedExpanded)))
    for other in [compact, compactLeft, expanded, mixedExpanded] {
        precondition(DockGeometry.sharesAnchor(mixedCompact, other) && DockGeometry.sharesAnchor(other, mixedCompact))
    }
    // Wings follow their own count exactly (26n+12) and never shrink the 22pt rings, independently.
    for count in 1...6 {
        let rightOnly = layout(screen, .compact, left: 0, right: count)
        precondition(rightOnly.rightIndicatorRect.width == CGFloat(26 * count + 12))
        precondition(rightOnly.frame.width == 160 + CGFloat(26 * count + 12))
        let both = layout(screen, .compact, left: count, right: 7 - count)
        precondition(both.leftIndicatorRect.width == CGFloat(26 * count + 12))
        precondition(both.rightIndicatorRect.width == CGFloat(26 * (7 - count) + 12))
        precondition(both.frame.width == 160 + CGFloat(26 * count + 12) + CGFloat(26 * (7 - count) + 12))
        precondition(equal(global(both.cameraRect, in: both), global(compact.cameraRect, in: compact)))
    }
    // Both wings empty: just the camera. Negative counts are empty; huge counts clamp per wing to the
    // wing's own physical capacity before any width arithmetic (left 14, right 16 on this screen).
    let cameraOnly = layout(screen, .compact, left: 0, right: 0)
    precondition(cameraOnly.frame.width == 160 && cameraOnly.leftIndicatorRect == .zero && cameraOnly.rightIndicatorRect == .zero)
    precondition(layout(screen, .compact, left: Int.min, right: -4) == cameraOnly)
    precondition(DockGeometry.compactCapacities(screen: screen) == CompactCapacities(left: 14, right: 16, total: 30))
    let capacityLimit = layout(screen, .compact, left: 14, right: 16)
    bounded(capacityLimit, screen)
    precondition(layout(screen, .compact, left: Int.max, right: Int.max) == capacityLimit)
    precondition(layout(screen, .expanded, left: Int.max, right: Int.max).mode == .notchConnected)
    bounded(layout(screen, .expanded, left: Int.max, right: Int.max), screen)
    precondition(capacityLimit.leftIndicatorRect.width == CGFloat(26 * 14 + 12) && capacityLimit.rightIndicatorRect.width == CGFloat(26 * 16 + 12))
    precondition(layout(screen, .compact, left: 13, right: 16).leftIndicatorRect.width < capacityLimit.leftIndicatorRect.width)
    precondition(layout(screen, .compact, left: 14, right: 15).rightIndicatorRect.width < capacityLimit.rightIndicatorRect.width)

    // Menu-bar size is not the camera depth, nor an attached dashboard's top constraint.
    let tallMenu = DockScreenMetrics(frame: screen.frame,
                                     visibleFrame: CGRect(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY,
                                                          width: screen.visibleFrame.width, height: 620),
                                     safeAreaTop: screen.safeAreaTop, menuBarHeight: 60,
                                     auxiliaryTopLeft: screen.auxiliaryTopLeft,
                                     auxiliaryTopRight: screen.auxiliaryTopRight)
    precondition(layout(tallMenu, .compact) == compact)
    precondition(layout(tallMenu, .expanded) == expanded)

    let deepCamera = DockScreenMetrics(frame: screen.frame, visibleFrame: screen.visibleFrame,
                                       safeAreaTop: 64, menuBarHeight: 22,
                                       auxiliaryTopLeft: CGRect(x: -1000.5, y: 666.25, width: 400, height: 64),
                                       auxiliaryTopRight: CGRect(x: -440.5, y: 666.25, width: 440, height: 64))
    let deepPreferred = DashboardSizing.preferredSize(providerCount: 3, cameraHeight: deepCamera.safeAreaTop)
    let deepExpanded = DockGeometry.layout(screen: deepCamera, presentation: .expanded,
                                           preferredExpandedSize: deepPreferred, leftCompactSlots: 1, rightCompactSlots: 3)!
    let deepCompact = DockGeometry.layout(screen: deepCamera, presentation: .compact,
                                          preferredExpandedSize: deepPreferred, leftCompactSlots: 1, rightCompactSlots: 3)!
    bounded(deepExpanded, deepCamera)
    bounded(deepCompact, deepCamera)
    precondition(deepExpanded.bodyRect.height == deepPreferred.height)
    precondition(deepExpanded.bodyRect.height - deepExpanded.cameraRect.height >= 200)
    // Compact height is max(camera depth, 28): a deep camera is matched, never exceeded.
    precondition(deepCompact.frame.height == 64 && deepCompact.leftIndicatorRect.height == 64 && deepCompact.rightIndicatorRect.height == 64)
    precondition(global(deepExpanded.rightIndicatorRect, in: deepExpanded).maxY == deepCamera.frame.maxY)
    precondition(!DockGeometry.sharesAnchor(compact, deepCompact))

    let noNotch = DockScreenMetrics(frame: screen.frame, visibleFrame: screen.visibleFrame,
                                    safeAreaTop: 0, menuBarHeight: 22,
                                    auxiliaryTopLeft: .zero, auxiliaryTopRight: .zero)
    let floating = layout(noNotch, .compact)
    let floatingExpanded = layout(noNotch, .expanded)
    bounded(floating, noNotch)
    bounded(floatingExpanded, noNotch)
    precondition(floating.mode == .floating && floatingExpanded.cameraRect == .zero)
    precondition(floating.frame.midX == noNotch.frame.midX)
    precondition(floating.frame.maxY < noNotch.safeTop && floating.frame.maxY == floatingExpanded.frame.maxY)
    precondition(floating.bodyRect == CGRect(origin: .zero, size: floating.frame.size))
    // Detached capsule: 28pt high, content (26n-4) plus 24pt.
    precondition(floating.frame.height == 28 && floating.frame.width == CGFloat(26 * 3 + 20))
    precondition(floating.leftIndicatorRect == .zero && floating.rightIndicatorRect == CGRect(x: 12, y: 0, width: 74, height: 28))
    precondition(DockGeometry.sharesAnchor(floating, floatingExpanded))
    precondition(!DockGeometry.sharesAnchor(floating, compact))
    precondition(equal(global(floating.rightIndicatorRect, in: floating), global(floatingExpanded.rightIndicatorRect, in: floatingExpanded)))
    precondition(floatingExpanded.rightIndicatorRect.height == 28 && floatingExpanded.rightIndicatorRect.maxY == floatingExpanded.frame.height)
    // Floating capacity is real, total and available to either group alone (not per side).
    precondition(DockGeometry.compactCapacities(screen: noNotch) == CompactCapacities(left: 37, right: 37, total: 37))
    precondition(DockGeometry.compactCapacities(screen: screen, manualTopCenter: CGPoint(x: 0, y: 500)) == CompactCapacities(left: 37, right: 37, total: 37))
    let widest = layout(noNotch, .compact, left: 0, right: Int.max)
    bounded(widest, noNotch)
    precondition(widest.frame.width == CGFloat(26 * 37 + 20))
    let widestLeft = layout(noNotch, .compact, left: Int.max, right: 0)
    precondition(widestLeft.frame.width == widest.frame.width && widestLeft.leftIndicatorRect.width == widest.rightIndicatorRect.width)
    // Both groups share the single capsule: the left group claims capacity first.
    let shared = layout(noNotch, .compact, left: Int.max, right: Int.max)
    precondition(shared.frame.width == widest.frame.width && shared.rightIndicatorRect == .zero)
    let partlyShared = layout(noNotch, .compact, left: 20, right: Int.max)
    precondition(partlyShared.frame.width == widest.frame.width)
    precondition(abs(partlyShared.rightIndicatorRect.width - CompactMetrics.contentWidth(slots: 17)) < epsilon)
    precondition(layout(noNotch, .compact, left: 0, right: 1).frame.width == 46)
    // Nothing at all still keeps a one-control capsule (a hover target), with no rows.
    let emptyCapsule = layout(noNotch, .compact, left: 0, right: 0)
    precondition(emptyCapsule.frame.width == 46 && emptyCapsule.leftIndicatorRect == .zero && emptyCapsule.rightIndicatorRect == .zero)

    // Floating/no-notch: ONE capsule, left group then right group at normal ring spacing, no camera gap.
    let capsule = layout(noNotch, .compact, left: 2, right: 1)
    let capsuleOpen = layout(noNotch, .expanded, left: 2, right: 1)
    bounded(capsule, noNotch)
    bounded(capsuleOpen, noNotch)
    precondition(capsule.mode == .floating && capsule.frame.width == CGFloat(26 * 3 + 20) && capsule.frame.height == 28)
    precondition(capsule.frame.width == layout(noNotch, .compact, left: 0, right: 3).frame.width)
    precondition(capsule.leftIndicatorRect == CGRect(x: 12, y: 0, width: 48, height: 28))
    precondition(capsule.rightIndicatorRect == CGRect(x: 12 + 48 + CompactMetrics.gap, y: 0, width: 22, height: 28))
    precondition(capsule.rightIndicatorRect.maxX + 12 == capsule.frame.width)
    precondition(equal(global(capsule.leftIndicatorRect, in: capsule), global(capsuleOpen.leftIndicatorRect, in: capsuleOpen)))
    precondition(equal(global(capsule.rightIndicatorRect, in: capsule), global(capsuleOpen.rightIndicatorRect, in: capsuleOpen)))
    // The same counts on a notch screen detached by a manual position keep the one capsule too.
    let detachedMixed = layout(screen, .compact, CGPoint(x: -500, y: 400), left: 2, right: 1)
    precondition(detachedMixed.mode == .floating && detachedMixed.frame.width == capsule.frame.width)
    precondition(detachedMixed.leftIndicatorRect == capsule.leftIndicatorRect && detachedMixed.rightIndicatorRect == capsule.rightIndicatorRect)

    let falseNotch = DockScreenMetrics(frame: screen.frame, visibleFrame: screen.visibleFrame,
                                       safeAreaTop: 28, menuBarHeight: 22,
                                       auxiliaryTopLeft: screen.auxiliaryTopLeft,
                                       auxiliaryTopRight: CGRect(x: -700, y: 702.25, width: 100, height: 28))
    precondition(layout(falseNotch, .compact).mode == .floating)
    let invalidAux = DockScreenMetrics(frame: screen.frame, visibleFrame: screen.visibleFrame,
                                       safeAreaTop: 28, menuBarHeight: 22,
                                       auxiliaryTopLeft: .zero, auxiliaryTopRight: screen.auxiliaryTopRight)
    precondition(layout(invalidAux, .expanded).mode == .floating)
    precondition(DockGeometry.compactCapacities(screen: falseNotch) == DockGeometry.compactCapacities(screen: noNotch))

    for point in [CGPoint(x: -2000, y: 2000), CGPoint(x: 500, y: -500), CGPoint(x: -500, y: 300)] {
        let a = layout(screen, .compact, point, left: 1, right: 2)
        let b = layout(screen, .expanded, point, left: 1, right: 2)
        bounded(a, screen)
        bounded(b, screen)
        precondition(a.mode == .floating && b.mode == .floating)
        precondition(a.frame.midX == b.frame.midX && a.frame.maxY == b.frame.maxY)
    }
    let tiny = DockScreenMetrics(frame: CGRect(x: 100.25, y: -50.5, width: 9, height: 8),
                                 visibleFrame: CGRect(x: 100.25, y: -49.5, width: 9, height: 6),
                                 safeAreaTop: 0, menuBarHeight: 2,
                                 auxiliaryTopLeft: .zero, auxiliaryTopRight: .zero)
    for state in [DockPresentation.compact, .expanded] {
        bounded(layout(tiny, state), tiny)
        bounded(layout(tiny, state, CGPoint(x: 0, y: 0)), tiny)
        bounded(layout(tiny, state, left: Int.max, right: Int.max), tiny)
    }
    let shortNotch = DockScreenMetrics(frame: CGRect(x: 100.25, y: -50.5, width: 80, height: 40),
                                       visibleFrame: CGRect(x: 100.25, y: -45.5, width: 80, height: 7),
                                       safeAreaTop: 28, menuBarHeight: 28,
                                       auxiliaryTopLeft: CGRect(x: 100.25, y: -38.5, width: 32, height: 28),
                                       auxiliaryTopRight: CGRect(x: 148.25, y: -38.5, width: 32, height: 28))
    // Too narrow for even one full wing: each ring overflows rather than shrinking, per wing.
    precondition(DockGeometry.compactCapacities(screen: shortNotch) == CompactCapacities(left: 1, right: 1, total: 2))
    for (left, right) in [(0, 1), (1, 0), (1, 1)] {
        let attached = layout(shortNotch, .compact, left: left, right: right)
        let open = layout(shortNotch, .expanded, left: left, right: right)
        bounded(attached, shortNotch)
        bounded(open, shortNotch)
        precondition(attached.frame.height == 28 && attached.frame.maxY == shortNotch.frame.maxY)
        precondition(open.frame.minY == shortNotch.visibleFrame.minY)
        precondition(DockGeometry.sharesAnchor(attached, open))
    }
    let coveredStrip = DockScreenMetrics(frame: shortNotch.frame,
                                         visibleFrame: CGRect(x: 100.25, y: -38.5, width: 80, height: 1),
                                         safeAreaTop: shortNotch.safeAreaTop, menuBarHeight: 28,
                                         auxiliaryTopLeft: shortNotch.auxiliaryTopLeft,
                                         auxiliaryTopRight: shortNotch.auxiliaryTopRight)
    precondition(DockGeometry.layout(screen: coveredStrip, presentation: .compact,
                                     preferredExpandedSize: size, leftCompactSlots: 1, rightCompactSlots: 2) == nil)
    let impossible = DockScreenMetrics(frame: screen.frame, visibleFrame: screen.visibleFrame,
                                       safeAreaTop: 1000, menuBarHeight: 22,
                                       auxiliaryTopLeft: .zero, auxiliaryTopRight: .zero)
    precondition(DockGeometry.layout(screen: impossible, presentation: .compact,
                                     preferredExpandedSize: size, leftCompactSlots: 0, rightCompactSlots: 1) == nil)
    precondition(DockGeometry.layout(screen: screen, presentation: .compact,
                                     preferredExpandedSize: size, leftCompactSlots: 0, rightCompactSlots: 1,
                                     manualTopCenter: CGPoint(x: CGFloat.nan, y: 0)) == nil)
    // A wing with genuinely no room on screen has zero capacity and never receives a slot.
    let edgeNotch = DockScreenMetrics(frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                      visibleFrame: CGRect(x: 0, y: 0, width: 100, height: 80),
                                      safeAreaTop: 20, menuBarHeight: 20,
                                      auxiliaryTopLeft: CGRect(x: 0, y: 80, width: 8, height: 20),
                                      auxiliaryTopRight: CGRect(x: 58, y: 80, width: 42, height: 20))
    let edgeCapacities = DockGeometry.compactCapacities(screen: edgeNotch)
    precondition(edgeCapacities.left == 0 && edgeCapacities.right >= 1 && edgeCapacities.total == edgeCapacities.right)
    if let edge = DockGeometry.layout(screen: edgeNotch, presentation: .compact, preferredExpandedSize: size,
                                      leftCompactSlots: 5, rightCompactSlots: 0) {
        precondition(edge.leftIndicatorRect == .zero && edge.rightIndicatorRect == .zero)
    }

    // Interpolation: every attached transition, in either direction and from any midpoint,
    // keeps the physical camera fixed; detached transitions keep the same center.
    func animate(_ a: DockLayout, _ b: DockLayout, _ metrics: DockScreenMetrics) {
        let fixedCamera = global(a.cameraRect, in: a)
        for step in 0...100 {
            let progress = CGFloat(step) / 100
            for (start, end) in [(a, b), (b, a)] {
                let current = DockGeometry.interpolate(from: start, to: end, progress: progress)
                precondition(current.mode == start.mode)
                bounded(current, metrics)
                precondition(abs(current.frame.maxY - start.frame.maxY) < epsilon)
                if current.mode == .notchConnected {
                    precondition(equal(global(current.cameraRect, in: current), fixedCamera))
                } else {
                    precondition(abs(current.frame.midX - start.frame.midX) < epsilon)
                }
            }
        }
        precondition(DockGeometry.interpolate(from: a, to: b, progress: -1) == a)
        precondition(DockGeometry.interpolate(from: a, to: b, progress: 2) == b)
        precondition(DockGeometry.interpolate(from: a, to: b, progress: .nan) == a)
        let interrupted = DockGeometry.interpolate(from: a, to: b, progress: 0.43)
        precondition(DockGeometry.interpolate(from: interrupted, to: a, progress: 0) == interrupted)
        precondition(DockGeometry.interpolate(from: interrupted, to: a, progress: 1) == a)
    }
    for metrics in [screen, noNotch, tiny, shortNotch] {
        for (left, right) in [(0, 1), (1, 0), (0, 3), (3, 0), (2, 3), (7, 7), (Int.max, Int.max), (0, 0)] {
            let preferred = DashboardSizing.preferredSize(providerCount: 7, cameraHeight: metrics.safeAreaTop)
            let start = DockGeometry.layout(screen: metrics, presentation: .compact,
                                            preferredExpandedSize: preferred, leftCompactSlots: left, rightCompactSlots: right)!
            let end = DockGeometry.layout(screen: metrics, presentation: .expanded,
                                          preferredExpandedSize: preferred, leftCompactSlots: left, rightCompactSlots: right)!
            precondition(DockGeometry.sharesAnchor(start, end))
            animate(start, end, metrics)
            let middle = DockGeometry.interpolate(from: start, to: end, progress: 0.43)
            animate(middle, start, metrics)
        }
    }
    // (Placement changes are applied without animation; a wing never needs to slide through the camera.)
    // Wings that fit inside the expanded frame stay exactly in place while they fade, on both sides.
    let leftStart = global(mixedCompact.leftIndicatorRect, in: mixedCompact)
    let rightStart = global(mixedCompact.rightIndicatorRect, in: mixedCompact)
    for step in 0...100 {
        let current = DockGeometry.interpolate(from: mixedCompact, to: mixedExpanded, progress: CGFloat(step) / 100)
        precondition(equal(global(current.leftIndicatorRect, in: current), leftStart))
        precondition(equal(global(current.rightIndicatorRect, in: current), rightStart))
    }
    // A plan that gains or loses a wing while the camera stays put: the shared camera and the wing
    // present at both ends never move, and an appearing/vanishing wing holds one screen position
    // instead of sweeping in from the frame origin.
    let oneWing = layout(screen, .compact, left: 0, right: 3)
    let twoWings = layout(screen, .compact, left: 2, right: 3)
    precondition(DockGeometry.sharesAnchor(oneWing, twoWings))
    animate(oneWing, twoWings, screen)
    let appearing = global(twoWings.leftIndicatorRect, in: twoWings)
    for step in 1..<100 {
        let current = DockGeometry.interpolate(from: oneWing, to: twoWings, progress: CGFloat(step) / 100)
        precondition(equal(global(current.rightIndicatorRect, in: current), global(oneWing.rightIndicatorRect, in: oneWing)))
        let visible = global(current.leftIndicatorRect, in: current)
        precondition(current.leftIndicatorRect.isEmpty || (abs(visible.maxX - appearing.maxX) < epsilon && visible.minX >= appearing.minX - epsilon))
    }
    for point in [CGPoint(x: -2000, y: 2000), CGPoint(x: 500, y: -500), CGPoint(x: -500, y: 300)] {
        animate(layout(screen, .compact, point), layout(screen, .expanded, point), screen)
        animate(layout(screen, .compact, point, left: 2, right: 1), layout(screen, .expanded, point, left: 2, right: 1), screen)
    }
    // Local body offsets also remain contained; interpolation cannot assume an origin of zero.
    let insetStart = DockLayout(frame: CGRect(x: -550, y: 670, width: 100, height: 30), mode: .floating,
                               bodyRect: CGRect(x: 10, y: 4, width: 80, height: 20),
                               cameraRect: .zero, leftIndicatorRect: .zero,
                               rightIndicatorRect: CGRect(x: 10, y: 14, width: 80, height: 10))
    let insetEnd = DockLayout(frame: CGRect(x: -700, y: 500, width: 400, height: 200), mode: .floating,
                             bodyRect: CGRect(x: 20, y: 8, width: 360, height: 180),
                             cameraRect: .zero, leftIndicatorRect: .zero,
                             rightIndicatorRect: CGRect(x: 20, y: 178, width: 360, height: 10))
    animate(insetStart, insetEnd, screen)
    var interaction = DockInteraction()
    precondition(interaction.presentation == .compact)
    interaction.setHover(true)
    precondition(interaction.presentation == .expanded)
    interaction.setPinned(true)
    interaction.setHover(false)
    precondition(interaction.presentation == .expanded)
    interaction.setMenuOpen(true)
    interaction.setPinned(false)
    precondition(interaction.presentation == .expanded)
    interaction.setDragging(true)
    interaction.setMenuOpen(false)
    precondition(interaction.presentation == .expanded)
    interaction.setDragging(false)
    precondition(interaction.presentation == .compact)
    interaction.setHover(true)
    interaction.setPinned(true)
    interaction.setMenuOpen(true)
    interaction.setDragging(true)
    interaction.dismiss()
    precondition(interaction.presentation == .compact && !interaction.isHovered && !interaction.isPinned &&
                 !interaction.isMenuOpen && !interaction.isDragging)

    // Explicitly opened overview and detail share a persistent hold. Hover exit
    // cannot close either; menu/drag holds remain independent when it is released.
    interaction.setPinned(true)
    interaction.setHover(false)
    precondition(interaction.presentation == .expanded)
    interaction.setMenuOpen(true)
    interaction.setPinned(false)
    precondition(interaction.presentation == .expanded)
    interaction.setMenuOpen(false)
    precondition(interaction.presentation == .compact)

    var gate = DockHoverGate()
    gate.dismiss(pointerInsideTarget: true)
    precondition(gate.requiresExit)
    gate.pointerMoved(insideTarget: true)
    precondition(gate.requiresExit)
    gate.pointerMoved(insideTarget: false)
    precondition(!gate.requiresExit)
    gate.pointerMoved(insideTarget: true)
    precondition(!gate.requiresExit)
    gate.dismiss(pointerInsideTarget: false)
    precondition(!gate.requiresExit)

    runPointerPolicyTests(screen: screen, compact: mixedCompact, expanded: mixedExpanded, floating: floating)

    // Independent presentation dimensions retain one manual anchor even when the
    // user places the board against a display edge. Reversal keeps the same top.
    for metrics in [screen, noNotch, tiny] {
        for point in [CGPoint(x: -2000, y: 2000), CGPoint(x: 500, y: 500)] {
            let overviewSize = CGSize(width: 720, height: 248)
            let detailSize = CGSize(width: 900, height: 610)
            let overview = DockGeometry.layout(screen: metrics, presentation: .expanded,
                                               preferredExpandedSize: overviewSize, leftCompactSlots: 1, rightCompactSlots: 2,
                                               manualTopCenter: point, preferredAnchorWidth: 900)!
            let detail = DockGeometry.layout(screen: metrics, presentation: .expanded,
                                             preferredExpandedSize: detailSize, leftCompactSlots: 1, rightCompactSlots: 2,
                                             manualTopCenter: point, preferredAnchorWidth: 900)!
            let closed = DockGeometry.layout(screen: metrics, presentation: .compact,
                                             preferredExpandedSize: overviewSize, leftCompactSlots: 1, rightCompactSlots: 2,
                                             manualTopCenter: point, preferredAnchorWidth: 900)!
            precondition(overview.frame.midX == detail.frame.midX && closed.frame.midX == detail.frame.midX)
            precondition(overview.frame.maxY == detail.frame.maxY && closed.frame.maxY == detail.frame.maxY)
            precondition(DockGeometry.sharesAnchor(closed, overview) && DockGeometry.sharesAnchor(overview, detail))
            animate(overview, detail, metrics)
        }
    }
    let detail = DockGeometry.layout(screen: screen, presentation: .expanded,
                                     preferredExpandedSize: CGSize(width: 900, height: 610),
                                     leftCompactSlots: 0, rightCompactSlots: 3)!
    animate(expanded, detail, screen)
    precondition(DockGeometry.layout(screen: screen, presentation: .compact,
                                     preferredExpandedSize: size, leftCompactSlots: 0, rightCompactSlots: 3,
                                     preferredAnchorWidth: .nan) == nil)

    // A fractional requested animation height must not become the drawing height
    // after AppKit realizes a different content size. Preserve real camera/wing
    // positions on both sides while making the silhouette meet the realized content top.
    for (left, right) in [(0, 3), (3, 0), (2, 3)] {
        let start = layout(screen, .compact, left: left, right: right)
        let end = layout(screen, .expanded, left: left, right: right)
        for scale in [CGFloat(1), 2] {
            for progress in [CGFloat(0.13), 0.37, 0.61, 0.89] {
                let requested = DockGeometry.interpolate(from: start, to: end, progress: progress)
                let width = (requested.frame.width * scale).rounded(.up) / scale
                let height = (requested.frame.height * scale).rounded(.up) / scale
                let actual = CGRect(x: requested.frame.minX, y: requested.frame.maxY - height,
                                    width: width, height: height)
                let realized = DockGeometry.reconciled(requested, to: actual)
                precondition(realized.frame == actual)
                precondition(abs(realized.bodyRect.maxY - height) < epsilon)
                precondition(abs(realized.bodyRect.maxX - (width - (requested.frame.width - requested.bodyRect.maxX))) < epsilon)
                precondition(equal(global(realized.cameraRect, in: realized), global(requested.cameraRect, in: requested)))
                // An absent wing is exactly .zero in both layouts (its "global" position is just the frame
                // origin, which legitimately differs); only occupied wings have a screen position.
                precondition((left == 0) == realized.leftIndicatorRect.isEmpty && (right == 0) == realized.rightIndicatorRect.isEmpty)
                precondition(left == 0 || equal(global(realized.leftIndicatorRect, in: realized), global(requested.leftIndicatorRect, in: requested)))
                precondition(right == 0 || equal(global(realized.rightIndicatorRect, in: realized), global(requested.rightIndicatorRect, in: requested)))
                let reversed = DockGeometry.interpolate(from: requested, to: start, progress: 0.3)
                precondition(abs(reversed.frame.maxY - start.frame.maxY) < epsilon)
                precondition(equal(global(reversed.cameraRect, in: reversed), global(start.cameraRect, in: start)))
            }
        }
    }
    // Detached layouts keep their center/top and both rows (size, order, spacing) under realized rounding too.
    let detachedStart = layout(noNotch, .compact, left: 2, right: 1)
    let detachedEnd = layout(noNotch, .expanded, left: 2, right: 1)
    for scale in [CGFloat(1), 2] {
        for progress in [CGFloat(0.13), 0.61] {
            let requested = DockGeometry.interpolate(from: detachedStart, to: detachedEnd, progress: progress)
            let width = (requested.frame.width * scale).rounded(.up) / scale
            let height = (requested.frame.height * scale).rounded(.up) / scale
            let actual = CGRect(x: requested.frame.midX - width / 2, y: requested.frame.maxY - height,
                                width: width, height: height)
            let realized = DockGeometry.reconciled(requested, to: actual)
            precondition(realized.frame == actual && abs(realized.bodyRect.maxY - height) < epsilon)
            precondition(equal(global(realized.leftIndicatorRect, in: realized), global(requested.leftIndicatorRect, in: requested)))
            precondition(equal(global(realized.rightIndicatorRect, in: realized), global(requested.rightIndicatorRect, in: requested)))
            precondition(abs(realized.rightIndicatorRect.minX - realized.leftIndicatorRect.maxX - CompactMetrics.gap) < epsilon)
        }
    }

    // Option-dragging a ring of an attached compact layout must carry the GRABBED GROUP with the pointer
    // when the panel detaches into one contiguous capsule: the camera gap vanishes but the grabbed rings
    // do not jump. The global cursor selects the group; the anchor is the capsule's top-center.
    let drag = CGPoint(x: -100, y: -230)
    func groupMinX(_ layout: DockLayout, _ side: CompactWingSide, slots: Int) -> CGFloat {
        let rect = side == .left ? layout.leftIndicatorRect : layout.rightIndicatorRect
        return CompactMetrics.rowMinX(in: global(rect, in: layout), attached: layout.mode == .notchConnected,
                                      side: side, slots: slots)
    }
    for (left, right) in [(0, 1), (0, 3), (3, 0), (1, 4), (2, 3), (4, 1)] {
        let attached = layout(screen, .compact, left: left, right: right)
        var grabs: [(CompactWingSide, CGPoint)] = []
        if left > 0 {
            let x = groupMinX(attached, .left, slots: left) + CompactMetrics.contentWidth(slots: left) / 2
            grabs.append((.left, CGPoint(x: x, y: attached.frame.maxY - 10)))
        }
        if right > 0 {
            let x = groupMinX(attached, .right, slots: right) + CompactMetrics.contentWidth(slots: right) / 2
            grabs.append((.right, CGPoint(x: x, y: attached.frame.maxY - 10)))
        }
        for (side, grab) in grabs {
            let anchor = DockGeometry.compactDragAnchor(attached, grabPoint: grab, leftSlots: left, rightSlots: right)
            precondition(abs(anchor.y - attached.frame.maxY) < epsilon)
            let detached = layout(screen, .compact, CGPoint(x: anchor.x + drag.x, y: anchor.y + drag.y), left: left, right: right)
            precondition(detached.mode == .floating)
            let slots = side == .left ? left : right
            let before = groupMinX(attached, side, slots: slots)
            let after = groupMinX(detached, side, slots: slots)
            precondition(abs((after - before) - drag.x) < epsilon)
            precondition(abs(detached.frame.maxY - (attached.frame.maxY + drag.y)) < epsilon)
            // Left then right group, contiguous at the normal ring spacing, no camera gap.
            if left > 0 && right > 0 {
                precondition(abs(groupMinX(detached, .right, slots: right) -
                                 (groupMinX(detached, .left, slots: left) + CompactMetrics.contentWidth(slots: left) + CompactMetrics.gap)) < epsilon)
            }
            // A detached capsule is already one centered row: same anchor either way, wherever grabbed.
            let detachedAnchor = DockGeometry.compactDragAnchor(detached, grabPoint: grab, leftSlots: left, rightSlots: right)
            precondition(abs(detachedAnchor.x - detached.frame.midX) < epsilon)
            precondition(abs(detachedAnchor.y - detached.frame.maxY) < epsilon)
        }
        // Grabbing on the camera picks the nearest group, never an absent one.
        let camera = global(attached.cameraRect, in: attached)
        let onCamera = DockGeometry.compactDragAnchor(attached, grabPoint: CGPoint(x: camera.midX, y: camera.midY),
                                                      leftSlots: left, rightSlots: right)
        precondition(onCamera.x.isFinite && abs(onCamera.y - attached.frame.maxY) < epsilon)
        if left == 0 || right == 0 {
            let only = left == 0 ? CompactWingSide.right : .left
            let detached = layout(screen, .compact, onCamera, left: left, right: right)
            precondition(abs(groupMinX(detached, only, slots: max(left, right)) - groupMinX(attached, only, slots: max(left, right))) < epsilon)
        }
    }
    // The cursor decides: grabbing the left group versus the right group of the same layout anchors
    // the capsule at different places, each keeping its own group's global position.
    let both = layout(screen, .compact, left: 2, right: 3)
    let leftGrab = CGPoint(x: global(both.leftIndicatorRect, in: both).midX, y: both.frame.maxY - 5)
    let rightGrab = CGPoint(x: global(both.rightIndicatorRect, in: both).midX, y: both.frame.maxY - 5)
    precondition(abs(DockGeometry.compactDragAnchor(both, grabPoint: leftGrab, leftSlots: 2, rightSlots: 3).x -
                     DockGeometry.compactDragAnchor(both, grabPoint: rightGrab, leftSlots: 2, rightSlots: 3).x) > 1)
    // Counts that name an absent wing, or none at all, fall back to the frame's own top-center.
    precondition(DockGeometry.compactDragAnchor(cameraOnly, grabPoint: leftGrab, leftSlots: 0, rightSlots: 0) ==
                 CGPoint(x: cameraOnly.frame.midX, y: cameraOnly.frame.maxY))

    runCompactSlotPlannerTests()
    runCompactRingPresentationTests()
}

// Compact previews from anywhere in the final compact frame; once expanded the whole
// current panel holds hover.
private func runPointerPolicyTests(screen: DockScreenMetrics, compact: DockLayout,
                                   expanded: DockLayout, floating: DockLayout) {
    let target = compact.frame
    let camera = DockGeometry.globalRect(compact.cameraRect, in: compact)
    let wing = compact.rightIndicatorRect.offsetBy(dx: compact.frame.minX, dy: compact.frame.minY)
    let leftWing = compact.leftIndicatorRect.offsetBy(dx: compact.frame.minX, dy: compact.frame.minY)
    let ring = CGPoint(x: wing.midX, y: wing.midY)
    let leftRing = CGPoint(x: leftWing.midX, y: leftWing.midY)

    func compactWants(_ point: CGPoint, panelFrame: CGRect = compact.frame, target: CGRect = target) -> Bool {
        DockPointerPolicy.wantsHover(point: point, presentation: .compact, panelFrame: panelFrame,
                                     compactTarget: target)
    }
    // Every attached compact zone previews: camera, rings, wing padding and all four edges
    // (the pointer can rest exactly on the screen's top edge).
    for point in [CGPoint(x: camera.midX, y: camera.midY), ring,
                  CGPoint(x: wing.minX + 1, y: wing.midY), CGPoint(x: wing.maxX - 1, y: wing.midY),
                  CGPoint(x: leftRing.x, y: leftRing.y),
                  CGPoint(x: camera.midX, y: screen.frame.maxY),
                  CGPoint(x: target.minX, y: target.minY), CGPoint(x: target.maxX, y: target.maxY)] {
        precondition(compactWants(point))
    }
    // Just outside the final compact frame never previews.
    for point in [CGPoint(x: target.minX - 0.5, y: target.midY), CGPoint(x: target.maxX + 0.5, y: target.midY),
                  CGPoint(x: target.midX, y: target.minY - 0.5), CGPoint(x: CGFloat.nan, y: target.midY)] {
        precondition(!compactWants(point))
    }
    precondition(!compactWants(ring, target: .zero))
    // A detached capsule is one whole compact target as well.
    for point in [CGPoint(x: floating.frame.midX, y: floating.frame.midY),
                  CGPoint(x: floating.frame.minX, y: floating.frame.minY),
                  CGPoint(x: floating.frame.maxX, y: floating.frame.maxY)] {
        precondition(compactWants(point, panelFrame: floating.frame, target: floating.frame))
    }
    precondition(!compactWants(CGPoint(x: floating.frame.maxX + 1, y: floating.frame.midY),
                               panelFrame: floating.frame, target: floating.frame))
    precondition(!compactWants(CGPoint(x: floating.frame.midX, y: floating.frame.minY - 1),
                               panelFrame: floating.frame, target: floating.frame))

    // A preview or pinned panel keeps hover across its whole current body, including the former wing.
    for point in [CGPoint(x: expanded.frame.midX, y: expanded.frame.midY), ring,
                  CGPoint(x: expanded.frame.minX, y: expanded.frame.maxY)] {
        precondition(DockPointerPolicy.wantsHover(point: point, presentation: .expanded,
                                                  panelFrame: expanded.frame, compactTarget: target))
    }
    precondition(!DockPointerPolicy.wantsHover(point: CGPoint(x: expanded.frame.maxX + 1, y: expanded.frame.midY),
                                               presentation: .expanded, panelFrame: expanded.frame,
                                               compactTarget: target))
    // Closing: the window is still the wide expanded frame, but compact entry uses only the
    // final compact frame, so the vacated expanded area cannot retrigger a preview.
    let vacated = CGPoint(x: expanded.frame.midX, y: expanded.frame.minY)
    precondition(expanded.frame.contains(vacated) && !DockPointerPolicy.contains(target, vacated))
    precondition(!compactWants(vacated, panelFrame: expanded.frame))
    precondition(compactWants(ring, panelFrame: expanded.frame))

    // Dismissal uses the same full target: only leaving the compact frame releases the gate.
    let cameraPoint = CGPoint(x: camera.midX, y: camera.midY)
    let outside = CGPoint(x: target.maxX + 1, y: target.midY)
    var gate = DockHoverGate()
    gate.dismiss(pointerInsideTarget: DockPointerPolicy.contains(target, cameraPoint))
    precondition(gate.requiresExit)
    gate.pointerMoved(insideTarget: DockPointerPolicy.contains(target, ring))
    precondition(gate.requiresExit)
    gate.pointerMoved(insideTarget: DockPointerPolicy.contains(target, cameraPoint))
    precondition(gate.requiresExit)
    gate.pointerMoved(insideTarget: DockPointerPolicy.contains(target, outside))
    precondition(!gate.requiresExit)
    // Dismissing over a ring suppresses reopening until the pointer really exits.
    gate.dismiss(pointerInsideTarget: DockPointerPolicy.contains(target, ring))
    precondition(gate.requiresExit)
    gate.pointerMoved(insideTarget: DockPointerPolicy.contains(target, cameraPoint))
    precondition(gate.requiresExit)
    gate.pointerMoved(insideTarget: DockPointerPolicy.contains(target, outside))
    precondition(!gate.requiresExit)
    // Dismissing outside the compact frame needs no exit first.
    gate.dismiss(pointerInsideTarget: DockPointerPolicy.contains(target, outside))
    precondition(!gate.requiresExit)
}

private func compactTestCard(_ provider: String, label: String? = nil, percent: Double? = 50,
                             value: String? = nil, severity: String = "normal", issue: Bool = false) -> DashboardCard {
    let name = label ?? provider
    return DashboardCard(provider: provider, label: name,
                         value: value ?? (percent.map { $0.isFinite ? "\(Int($0))%" : "—" } ?? "—"),
                         severity: severity, percent: percent, metric: "Metric", context: "Account",
                         tooltip: "\(name): tooltip", window: nil, showPace: false,
                         hasIssue: issue || percent == nil || !(percent?.isFinite ?? false))
}

private func uniformCapacity(_ count: Int) -> CompactCapacities {
    CompactCapacities(left: count, right: count, total: count)
}

private func runCompactSlotPlannerTests() {
    // Left wing first, then right wing: the flattened order a reader sees.
    func summary(_ plan: CompactSlotPlan) -> [String] {
        plan.slots.map { slot in
            switch slot {
            case .provider(let ring): return ring.provider
            case .more(let more): return more.text
            case .configure: return "configure"
            }
        }
    }
    func wings(_ plan: CompactSlotPlan) -> ([String], [String]) {
        func names(_ slots: [CompactSlot]) -> [String] {
            summary(CompactSlotPlan(leftSlots: slots, rightSlots: [], selectedCount: 0, hiddenProviderIDs: []))
        }
        return (names(plan.leftSlots), names(plan.rightSlots))
    }
    func plan(_ cards: [DashboardCard], _ selected: [String]?, max: Int, capacity: Int = 1000,
              capacities: CompactCapacities? = nil, defaultSide: CompactWingSide = .right,
              sides: [String: CompactWingSide] = [:],
              aliases: ExactConfigMap = [:], issue: String = "") -> CompactSlotPlan {
        CompactSlotPlanner.plan(cards: cards,
                                preferences: CompactPreferences(maximumVisibleSlots: max, selectedProviderIDs: selected,
                                                                defaultSide: defaultSide, providerSides: sides),
                                physicalCapacity: capacities ?? uniformCapacity(capacity),
                                aliases: aliases, issue: issue)
    }
    let cards = ["a", "b", "c", "d", "e", "f"].map { compactTestCard($0) }

    // The maximum counts every control including More; membership is independent of it.
    let over = plan(cards, ["a", "b", "c", "d", "e"], max: 3)
    precondition(summary(over) == ["a", "b", "+3"] && over.selectedCount == 5 && over.hiddenProviderIDs == ["c", "d", "e"])
    precondition(summary(plan(cards, ["a"], max: 3)) == ["a"])
    precondition(summary(plan(cards, ["a", "b", "c"], max: 3)) == ["a", "b", "c"])
    precondition(plan(cards, ["a", "b", "c"], max: 3).hiddenProviderIDs.isEmpty)
    // One slot is only More(+n) once more than one provider is selected.
    precondition(summary(plan(cards, ["a"], max: 1)) == ["a"])
    precondition(summary(plan(cards, ["a", "b"], max: 1)) == ["+2"])
    precondition(summary(plan(cards, ["a", "b", "c", "d"], max: 1)) == ["+4"])
    // Above three: exact fit has no More; one over folds the last ring into it.
    precondition(summary(plan(cards, ["a", "b", "c", "d", "e", "f"], max: 6)) == ["a", "b", "c", "d", "e", "f"])
    precondition(summary(plan(cards, ["a", "b", "c", "d", "e", "f"], max: 5)) == ["a", "b", "c", "d", "+2"])
    precondition(summary(plan(cards, ["a", "b", "c", "d", "e", "f"], max: 2)) == ["a", "+5"])
    // Non-positive/pathological limits are bounded before use; they cannot trap or allocate.
    precondition(summary(plan(cards, ["a", "b"], max: 0)) == ["+2"])
    precondition(summary(plan(cards, ["a", "b"], max: -7)) == ["+2"])
    precondition(summary(plan(cards, ["a", "b"], max: Int.min)) == ["+2"])
    precondition(summary(plan(cards, ["a", "b", "c"], max: Int.max, capacity: Int.max)) == ["a", "b", "c"])
    // Physical capacity (at least one total) can cap a larger user maximum.
    precondition(summary(plan(cards, ["a", "b", "c", "d"], max: 10, capacity: 2)) == ["a", "+3"])
    precondition(summary(plan(cards, ["a", "b", "c", "d"], max: 10, capacity: 0)) == ["+4"])
    precondition(summary(plan(cards, ["a", "b", "c", "d"], max: Int.max, capacity: 3)) == ["a", "b", "+2"])

    // Legacy all-one-side behavior: without overrides every ring and More share the default wing.
    let legacyLeft = plan(cards, ["a", "b", "c", "d", "e"], max: 3, defaultSide: .left)
    precondition(wings(legacyLeft) == (["a", "b", "+3"], []) && legacyLeft.hiddenProviderIDs == ["c", "d", "e"])
    precondition(wings(over) == ([], ["a", "b", "+3"]))
    let legacySix = ["a", "b", "c", "d", "e", "f"]
    precondition(wings(plan(cards, legacySix, max: 6, capacity: 14, defaultSide: .left)) == (legacySix, []))

    // Mixed sides keep each provider on its own wing and the upstream order within each wing.
    let sidesAC: [String: CompactWingSide] = ["a": .left, "c": .left]
    let split = plan(cards, ["a", "b", "c", "d", "e", "f"], max: 6, sides: sidesAC)
    precondition(wings(split) == (["a", "c"], ["b", "d", "e", "f"]) && split.hiddenProviderIDs.isEmpty)
    precondition(split.slots(on: .left) == split.leftSlots && split.slots(on: .right) == split.rightSlots)
    precondition(split.slots == split.leftSlots + split.rightSlots)
    // Selection order is irrelevant; upstream order is used on each wing.
    precondition(wings(plan(cards, ["d", "c", "b", "a"], max: 6, sides: sidesAC)) == (["a", "c"], ["b", "d"]))
    // An override for a deselected provider changes nothing now and is honored later; an override
    // equal to the default behaves like none.
    precondition(wings(plan(cards, ["a", "b"], max: 6, sides: ["a": .right, "z": .left])) == ([], ["a", "b"]))

    // ONE budget across both wings, More included, even when more rings would physically fit.
    let budgeted = plan(cards, ["a", "b", "c", "d", "e", "f"], max: 4, sides: ["a": .left, "b": .left])
    precondition(wings(budgeted) == (["a", "b"], ["c", "+3"]) && budgeted.slots.count == 4)
    precondition(budgeted.hiddenProviderIDs == ["d", "e", "f"] && budgeted.selectedCount == 6)
    // More is reserved on the wing of the FIRST hidden provider and lists hidden providers of
    // both wings, including the opposite one.
    let alternating = plan(cards, ["a", "b", "c", "d"], max: 3,
                           sides: ["a": .left, "b": .right, "c": .left, "d": .right])
    precondition(wings(alternating) == (["a", "+2"], ["b"]) && alternating.slots.count == 3)
    precondition(alternating.hiddenProviderIDs == ["c", "d"])
    guard case .more(let acrossWings) = alternating.leftSlots[1] else { preconditionFailure("Expected More") }
    precondition(acrossWings.count == 2 && acrossWings.tooltip.contains("c — ") && acrossWings.tooltip.contains("d — "))
    // Never more than the maximum in total, even for 1 with mixed sides: only More, on the wing
    // of the first (upstream-ordered) provider.
    for (first, second) in [(CompactWingSide.left, CompactWingSide.right), (.right, .left)] {
        let single = plan(cards, ["a", "b"], max: 1, sides: ["a": first, "b": second])
        precondition(single.slots.count == 1 && summary(single) == ["+2"])
        precondition(single.slots(on: first).count == 1 && single.slots(on: second).isEmpty)
    }
    // A lone provider at max 1 stays a ring on its own wing.
    precondition(wings(plan(cards, ["b"], max: 1, sides: ["b": .left])) == (["b"], []))

    // Physical capacity bounds each wing separately; a ring that does not fit its own wing is
    // hidden, never moved to the other one.
    let capped = plan(cards, ["a", "b", "c", "d", "e"], max: 10,
                      capacities: CompactCapacities(left: 2, right: 5, total: 7),
                      sides: ["a": .left, "b": .left, "c": .left])
    precondition(wings(capped) == (["a", "+2"], ["d", "e"]) && capped.hiddenProviderIDs == ["b", "c"])
    // Exhausting each wing's own capacity leaves no room for More except by giving up a ring.
    let full = plan(cards, ["a", "b", "c", "d"], max: 10,
                    capacities: CompactCapacities(left: 1, right: 1, total: 2),
                    sides: ["a": .left, "b": .left, "c": .right, "d": .right])
    precondition(wings(full) == (["+3"], ["c"]) && full.hiddenProviderIDs == ["a", "b", "d"] && full.slots.count == 2)
    // The total capacity also bounds both wings together.
    let total = plan(cards, ["a", "b", "c", "d"], max: 10,
                     capacities: CompactCapacities(left: 4, right: 4, total: 3),
                     sides: ["a": .left, "b": .left, "c": .right, "d": .right])
    precondition(total.slots.count == 3 && wings(total).0 == ["a", "b"] && wings(total).1 == ["+2"])
    // A floating capsule's capacity is real for either group alone.
    precondition(wings(plan(cards, ["a", "b", "c", "d"], max: 10, capacity: 3, defaultSide: .left)) == (["a", "b", "+2"], []))
    precondition(wings(plan(cards, ["a", "b"], max: 10, capacity: 3, sides: ["a": .left])) == (["a"], ["b"]))
    // A wing with genuinely zero physical room never receives a ring; More alone may use the other wing.
    let noLeft = plan(cards, ["a", "b"], max: 10, capacities: CompactCapacities(left: 0, right: 5, total: 5),
                      sides: ["a": .left])
    precondition(wings(noLeft) == ([], ["b", "+1"]) && noLeft.hiddenProviderIDs == ["a"])
    let noRight = plan(cards, ["a", "b"], max: 10, capacities: CompactCapacities(left: 5, right: 0, total: 5),
                       sides: ["a": .left])
    precondition(wings(noRight) == (["a", "+1"], []) && noRight.hiddenProviderIDs == ["b"])

    // Current upstream order wins; selected IDs the data lacks follow in selection order.
    let missing = plan(cards, ["e", "missing2", "a", "missing1"], max: 10, aliases: ["missing1": "Alias One"])
    precondition(summary(missing) == ["a", "e", "missing2", "missing1"])
    guard case .provider(let absent) = missing.slots[3], case .provider(let plain) = missing.slots[2],
          case .provider(let present) = missing.slots[0] else { preconditionFailure("Expected rings") }
    precondition(!absent.isReported && absent.arc == .unknown && !absent.hasWarning && !absent.isOverLimit)
    precondition(absent.label == "Alias One")
    precondition(plain.label == "missing2" && !plain.isReported)
    precondition(present.isReported && present.arc == .fraction(0.5))
    // A missing provider keeps its own wing override.
    precondition(wings(plan(cards, ["a", "gone"], max: 10, sides: ["gone": .left])) == (["gone"], ["a"]))
    // Missing selections still count toward capacity and More, without borrowing a metric.
    let overflowMissing = plan(cards, ["a", "missing1", "missing2"], max: 2)
    precondition(summary(overflowMissing) == ["a", "+2"] && overflowMissing.hiddenProviderIDs == ["missing1", "missing2"])
    guard case .more(let more) = overflowMissing.slots[1] else { preconditionFailure("Expected More") }
    precondition(more.count == 2)
    precondition(!more.hasWarning)
    // Selection with no data at all keeps its membership as truthful unknown rings.
    let noData = plan([], ["x", "y"], max: 3)
    precondition(summary(noData) == ["x", "y"] && noData.selectedCount == 2)

    // nil (uninitialized) and [] (explicitly none) both show one configure affordance on the default
    // wing, not More, and never a placeholder on the other wing.
    let uninitialized = plan(cards, nil, max: 3)
    let none = plan(cards, [], max: 3, issue: "Stale: failed")
    precondition(summary(uninitialized) == ["configure"] && summary(none) == ["configure"])
    precondition(uninitialized.selectedCount == 0 && none.hiddenProviderIDs.isEmpty)
    guard case .configure(let first) = uninitialized.slots[0], case .configure(let second) = none.slots[0] else {
        preconditionFailure("Expected configure")
    }
    precondition(!first.hasIssue && second.hasIssue)
    precondition(summary(plan(cards, [], max: 1)) == ["configure"])
    precondition(wings(plan(cards, [], max: 3, defaultSide: .left)) == (["configure"], []))
    precondition(wings(plan(cards, nil, max: 3, defaultSide: .right)) == ([], ["configure"]))
    precondition(wings(plan(cards, [], max: 3, capacities: CompactCapacities(left: 0, right: 4, total: 4),
                            defaultSide: .left)) == ([], ["configure"]))

    // Duplicate selected IDs collapse; equal aliases stay distinct providers.
    precondition(summary(plan(cards, ["a", "a", "b"], max: 5)) == ["a", "b"])
    let aliased = [compactTestCard("x", label: "Same"), compactTestCard("y", label: "Same")]
    let both = plan(aliased, ["y", "x"], max: 5)
    precondition(summary(both) == ["x", "y"])
    guard case .provider(let x) = both.slots[0], case .provider(let y) = both.slots[1] else {
        preconditionFailure("Expected rings")
    }
    precondition(x.tooltip != y.tooltip)
    // Hiding one of them keeps the exact provider that was selected.
    precondition(summary(plan(aliased, ["y"], max: 5)) == ["y"])
    // Same inputs plan identically (no hidden rotation by data or severity).
    precondition(plan(cards, ["a", "c"], max: 3) == plan(cards, ["a", "c"], max: 3))
    let louder = cards.map { compactTestCard($0.provider, percent: 99, severity: "critical") }
    precondition(summary(plan(louder, ["a", "c", "e"], max: 3)) == summary(plan(cards, ["a", "c", "e"], max: 3)))

    // Large hidden sets keep a bounded count label and tooltip.
    let many = (0..<200).map { compactTestCard("p\($0)") }
    let crowded = plan(many, many.map { $0.provider }, max: 3)
    guard case .more(let crowd) = crowded.slots[2] else { preconditionFailure("Expected More") }
    precondition(crowded.slots.count == 3 && crowd.count == 198 && crowd.text == "99+")
    precondition(crowd.tooltip.split(separator: "\n").count <= 14)
    precondition(plan(cards, ["a", "b"], max: 100).slots.count == 2)

    // Restart with a saved selection, then a first collection failure: no cards at all, but the
    // supplied issue must stay visible on every missing ring and on More — as a warning, never
    // as quota overage. Plain absence (healthy data lacking the provider) stays quiet.
    let failure = "Unavailable: collector failed"
    let saved = ["gone1", "gone2", "gone3"]
    let failed = plan([], saved, max: 5, issue: failure)
    precondition(summary(failed) == saved)
    for slot in failed.slots {
        guard case .provider(let ring) = slot else { preconditionFailure("Expected rings") }
        precondition(ring.hasWarning && !ring.isOverLimit && !ring.isReported && ring.arc == .unknown)
    }
    let failedMore = plan([], saved, max: 1, issue: failure)
    precondition(summary(failedMore) == ["+3"])
    guard case .more(let failedCollapsed) = failedMore.slots[0] else { preconditionFailure("Expected More") }
    precondition(failedCollapsed.hasWarning)
    let quiet = plan(cards, saved, max: 1)
    guard case .more(let quietMore) = quiet.slots[0] else { preconditionFailure("Expected More") }
    precondition(!quietMore.hasWarning)
    guard case .provider(let quietRing) = plan(cards, ["gone1"], max: 3).slots[0] else { preconditionFailure("Expected ring") }
    precondition(!quietRing.hasWarning)
    // A mix keeps warnings per entry: the data-backed ring is unchanged, the missing one warns.
    let mixed = plan(cards, ["a", "gone1"], max: 5, issue: failure)
    guard case .provider(let backed) = mixed.slots[0], case .provider(let lost) = mixed.slots[1] else {
        preconditionFailure("Expected rings")
    }
    precondition(backed.isReported && lost.hasWarning && !lost.isOverLimit)
}

private func runCompactRingPresentationTests() {
    func ring(_ percent: Double?, value: String? = nil, issue: Bool = false) -> CompactRingPresentation {
        CompactRingPresentation(card: compactTestCard("mistral", percent: percent, value: value, issue: issue))
    }
    // nil and non-finite are unknown, never zero; known zero is a real empty arc.
    for unknown in [nil, Double.nan, Double.infinity, -Double.infinity] as [Double?] {
        let presentation = ring(unknown)
        precondition(presentation.arc == .unknown && !presentation.isOverLimit)
        precondition(presentation.isReported)
    }
    precondition(ring(0, value: "0%").arc == .fraction(0))
    precondition(ring(0, value: "0%").valueText == "0%" && !ring(0, value: "0%").hasWarning)
    precondition(ring(-5).arc == .fraction(0))
    // The arc alone clamps; near-100 is not rounded into exhaustion and 100 is not an overage.
    guard case .fraction(let nearFull) = ring(99.95, value: "99.9%").arc else { preconditionFailure("Expected known arc") }
    precondition(abs(nearFull - 0.9995) < 1e-12 && nearFull < 1)
    precondition(!ring(99.95, value: "99.9%").isOverLimit)
    precondition(ring(100, value: "100%").arc == .fraction(1) && !ring(100, value: "100%").isOverLimit)
    let over = ring(104, value: "104%")
    precondition(over.arc == .fraction(1) && over.isOverLimit)
    precondition(over.valueText == "104%")
    precondition(ring(100.0001, value: "100%").isOverLimit)
    // A source/provider warning is not an overage, and an overage is not hidden by a quiet source.
    let warned = ring(50, issue: true)
    precondition(warned.hasWarning && !warned.isOverLimit)
    precondition(!ring(50).hasWarning && !ring(50).isOverLimit)
    precondition(CompactRingPresentation.isOverLimit(percent: 100) == false)
    precondition(CompactRingPresentation.isOverLimit(percent: nil) == false)
    precondition(CompactRingPresentation.isOverLimit(percent: .infinity) == false)
    precondition(CompactRingPresentation.isOverLimit(percent: 100.5))

    // A hidden over-limit/warned provider is still surfaced by More.
    let hidden = CompactMorePresentation(hidden: [over, warned, ring(10)])
    precondition(hidden.count == 3 && hidden.text == "+3" && hidden.hasWarning)
    precondition(CompactMorePresentation(hidden: [ring(10)]).hasWarning == false)

    // Marks: familiar for recognized real providers, deterministic fallback otherwise.
    for (provider, label, mark) in [("openai-codex", "OpenAI Codex", "CX"), ("opencode-go", "OpenCode Go", "GO"),
                                    ("minimax-code-cn", "MiniMax", "MM"), ("commandcode", "Command Code", "CC"),
                                    ("mistral", "Mistral", "MI"), ("anthropic", "Anthropic", "AN"),
                                    ("work", "My Claude", "AN"), ("work", "Mistral Team", "MI"),
                                    ("my-provider", "My Provider", "MP"), ("zed", "Zed", "ZE"),
                                    ("x", "", "X"), ("", "", "?"), ("--", "  ", "?")] {
        precondition(CompactMark.monogram(provider: provider, label: label) == mark)
    }
    precondition(CompactMark.monogram(provider: "unknown-one", label: "Same") ==
                 CompactMark.monogram(provider: "unknown-two", label: "Same"))
}
