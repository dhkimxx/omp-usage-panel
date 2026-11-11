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
    func layout(_ metrics: DockScreenMetrics, _ state: DockPresentation, _ manual: CGPoint? = nil,
                slots: Int = 3, side: CompactWingSide = .right) -> DockLayout {
        guard let result = DockGeometry.layout(screen: metrics, presentation: state,
                                               preferredExpandedSize: size, compactSlots: slots, side: side,
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
        for rect in [result.bodyRect, result.cameraRect, result.indicatorRect] {
            precondition(rect.minX >= -epsilon && rect.minY >= -epsilon)
            precondition(rect.maxX <= result.frame.width + epsilon && rect.maxY <= result.frame.height + epsilon)
        }
        precondition(result.indicatorRect.width > 0 && result.indicatorRect.height > 0)
        switch result.mode {
        case .notchConnected:
            precondition(abs(result.frame.maxY - metrics.frame.maxY) < epsilon)
            let camera = global(result.cameraRect, in: result)
            let wing = global(result.indicatorRect, in: result)
            precondition(abs(camera.minX - metrics.auxiliaryTopLeft.maxX) < epsilon)
            precondition(abs(camera.maxX - metrics.auxiliaryTopRight.minX) < epsilon)
            precondition(abs(camera.maxY - metrics.frame.maxY) < epsilon)
            precondition(abs(camera.height - metrics.safeAreaTop) < epsilon)
            precondition(result.cameraRect.minX >= result.bodyRect.minX - epsilon)
            precondition(result.cameraRect.maxX <= result.bodyRect.maxX + epsilon)
            precondition(result.cameraRect.maxY <= result.bodyRect.maxY + epsilon)
            // Controls sit beside the camera, flush with the screen edge, never below or under it.
            precondition(abs(wing.maxY - metrics.frame.maxY) < epsilon)
            precondition(wing.minX >= camera.maxX - epsilon || wing.maxX <= camera.minX + epsilon)
        case .floating:
            precondition(result.frame.maxY <= metrics.safeTop + epsilon)
            precondition(result.cameraRect == .zero)
        }
    }
    let compact = layout(screen, .compact)
    let expanded = layout(screen, .expanded)
    bounded(compact, screen)
    bounded(expanded, screen)
    precondition(compact.mode == .notchConnected && expanded.mode == .notchConnected)
    precondition(expanded.frame.midX == -520.5)
    // Three slots: 26n+12 = 90pt wing attached to the right of the 160pt camera, camera-high.
    precondition(compact.frame.width == 160 + 90 && compact.frame.height == 28)
    precondition(compact.bodyRect == CGRect(origin: .zero, size: compact.frame.size))
    precondition(compact.cameraRect.minX == 0 && compact.indicatorRect.minX == 160 && compact.indicatorRect.width == 90)
    precondition(expanded.bodyRect.width >= expanded.cameraRect.width + 200)
    precondition(expanded.bodyRect.minX > 0 && expanded.bodyRect.maxX < expanded.frame.width)
    precondition(expanded.bodyRect.height == size.height && expanded.bodyRect.maxY == expanded.frame.height)
    precondition(equal(global(compact.cameraRect, in: compact), global(expanded.cameraRect, in: expanded)))
    precondition(equal(global(compact.indicatorRect, in: compact), global(expanded.indicatorRect, in: expanded)))

    // Compact is asymmetric: its midpoint is not the camera's, so the anchor is the camera.
    precondition(compact.frame.midX != expanded.frame.midX)
    precondition(DockGeometry.sharesAnchor(compact, expanded) && DockGeometry.sharesAnchor(expanded, compact))

    // The left wing mirrors around the same physical camera.
    let compactLeft = layout(screen, .compact, side: .left)
    let expandedLeft = layout(screen, .expanded, side: .left)
    bounded(compactLeft, screen)
    bounded(expandedLeft, screen)
    precondition(compactLeft.frame.width == compact.frame.width && compactLeft.frame.height == compact.frame.height)
    precondition(compactLeft.cameraRect.minX == 90 && compactLeft.indicatorRect.minX == 0 && compactLeft.indicatorRect.width == 90)
    precondition(equal(global(compactLeft.cameraRect, in: compactLeft), global(compact.cameraRect, in: compact)))
    precondition(abs(global(compactLeft.indicatorRect, in: compactLeft).maxX - screen.auxiliaryTopLeft.maxX) < epsilon)
    precondition(abs(global(compact.indicatorRect, in: compact).minX - screen.auxiliaryTopRight.minX) < epsilon)
    precondition(equal(global(compactLeft.indicatorRect, in: compactLeft), global(expandedLeft.indicatorRect, in: expandedLeft)))
    precondition(DockGeometry.sharesAnchor(compactLeft, compact) && DockGeometry.sharesAnchor(compactLeft, expandedLeft))

    // Wing width follows the slot count exactly (26n+12) and never shrinks the 22pt rings.
    for count in 1...6 {
        let wing = layout(screen, .compact, slots: count)
        precondition(wing.indicatorRect.width == CGFloat(26 * count + 12))
        precondition(wing.frame.width == 160 + CGFloat(26 * count + 12))
    }
    // Zero/negative slot counts still reserve one control; huge counts clamp to physical capacity
    // before any width arithmetic. Capacity differs per side because the camera is off-center.
    precondition(layout(screen, .compact, slots: 0) == layout(screen, .compact, slots: 1))
    precondition(layout(screen, .compact, slots: Int.min) == layout(screen, .compact, slots: 1))
    precondition(DockGeometry.compactCapacity(screen: screen, side: .right) == 16)
    precondition(DockGeometry.compactCapacity(screen: screen, side: .left) == 14)
    for (side, capacity) in [(CompactWingSide.right, 16), (.left, 14)] {
        precondition(DockGeometry.compactCapacity(screen: screen, side: side) == capacity)
        let full = layout(screen, .compact, slots: capacity, side: side)
        let overflow = layout(screen, .compact, slots: Int.max, side: side)
        bounded(full, screen)
        bounded(overflow, screen)
        precondition(overflow == full)
        precondition(full.indicatorRect.width == CGFloat(26 * capacity + 12))
        precondition(layout(screen, .compact, slots: capacity - 1, side: side).indicatorRect.width < full.indicatorRect.width)
        let huge = layout(screen, .expanded, slots: Int.max, side: side)
        bounded(huge, screen)
    }

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
                                           preferredExpandedSize: deepPreferred, compactSlots: 3)!
    let deepCompact = DockGeometry.layout(screen: deepCamera, presentation: .compact,
                                          preferredExpandedSize: deepPreferred, compactSlots: 3)!
    bounded(deepExpanded, deepCamera)
    bounded(deepCompact, deepCamera)
    precondition(deepExpanded.bodyRect.height == deepPreferred.height)
    precondition(deepExpanded.bodyRect.height - deepExpanded.cameraRect.height >= 200)
    // Compact height is max(camera depth, 28): a deep camera is matched, never exceeded.
    precondition(deepCompact.frame.height == 64 && deepCompact.indicatorRect.height == 64)
    precondition(global(deepExpanded.indicatorRect, in: deepExpanded).maxY == deepCamera.frame.maxY)
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
    precondition(floating.indicatorRect == floating.bodyRect)
    precondition(floatingExpanded.indicatorRect.height == 28 && floatingExpanded.indicatorRect.width == floating.frame.width)
    precondition(floatingExpanded.indicatorRect.midX == floatingExpanded.frame.width / 2)
    precondition(floatingExpanded.indicatorRect.maxY == floatingExpanded.frame.height)
    precondition(DockGeometry.sharesAnchor(floating, floatingExpanded))
    precondition(!DockGeometry.sharesAnchor(floating, compact))
    precondition(DockGeometry.compactCapacity(screen: noNotch, side: .right) == 37)
    precondition(DockGeometry.compactCapacity(screen: noNotch, side: .left) == 37)
    precondition(DockGeometry.compactCapacity(screen: screen, side: .right, manualTopCenter: CGPoint(x: 0, y: 500)) == 37)
    let widest = layout(noNotch, .compact, slots: Int.max)
    bounded(widest, noNotch)
    precondition(widest.frame.width == CGFloat(26 * 37 + 20))
    precondition(layout(noNotch, .compact, slots: 1).frame.width == 46)

    let falseNotch = DockScreenMetrics(frame: screen.frame, visibleFrame: screen.visibleFrame,
                                       safeAreaTop: 28, menuBarHeight: 22,
                                       auxiliaryTopLeft: screen.auxiliaryTopLeft,
                                       auxiliaryTopRight: CGRect(x: -700, y: 702.25, width: 100, height: 28))
    precondition(layout(falseNotch, .compact).mode == .floating)
    let invalidAux = DockScreenMetrics(frame: screen.frame, visibleFrame: screen.visibleFrame,
                                       safeAreaTop: 28, menuBarHeight: 22,
                                       auxiliaryTopLeft: .zero, auxiliaryTopRight: screen.auxiliaryTopRight)
    precondition(layout(invalidAux, .expanded).mode == .floating)

    for point in [CGPoint(x: -2000, y: 2000), CGPoint(x: 500, y: -500), CGPoint(x: -500, y: 300)] {
        let a = layout(screen, .compact, point)
        let b = layout(screen, .expanded, point)
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
        bounded(layout(tiny, state, slots: Int.max), tiny)
    }
    let shortNotch = DockScreenMetrics(frame: CGRect(x: 100.25, y: -50.5, width: 80, height: 40),
                                       visibleFrame: CGRect(x: 100.25, y: -45.5, width: 80, height: 7),
                                       safeAreaTop: 28, menuBarHeight: 28,
                                       auxiliaryTopLeft: CGRect(x: 100.25, y: -38.5, width: 32, height: 28),
                                       auxiliaryTopRight: CGRect(x: 148.25, y: -38.5, width: 32, height: 28))
    for side in [CompactWingSide.right, .left] {
        // Too narrow for even one full wing: the ring overflows rather than shrinking.
        precondition(DockGeometry.compactCapacity(screen: shortNotch, side: side) == 1)
        let attached = layout(shortNotch, .compact, side: side)
        let open = layout(shortNotch, .expanded, side: side)
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
                                     preferredExpandedSize: size, compactSlots: 3) == nil)
    let impossible = DockScreenMetrics(frame: screen.frame, visibleFrame: screen.visibleFrame,
                                       safeAreaTop: 1000, menuBarHeight: 22,
                                       auxiliaryTopLeft: .zero, auxiliaryTopRight: .zero)
    precondition(DockGeometry.layout(screen: impossible, presentation: .compact,
                                     preferredExpandedSize: size, compactSlots: 1) == nil)
    precondition(DockGeometry.layout(screen: screen, presentation: .compact,
                                     preferredExpandedSize: size, compactSlots: 1,
                                     manualTopCenter: CGPoint(x: CGFloat.nan, y: 0)) == nil)

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
        for side in [CompactWingSide.right, .left] {
            for slots in [1, 3, 7, Int.max] {
                let preferred = DashboardSizing.preferredSize(providerCount: 7, cameraHeight: metrics.safeAreaTop)
                let start = DockGeometry.layout(screen: metrics, presentation: .compact,
                                                preferredExpandedSize: preferred, compactSlots: slots, side: side)!
                let end = DockGeometry.layout(screen: metrics, presentation: .expanded,
                                              preferredExpandedSize: preferred, compactSlots: slots, side: side)!
                precondition(DockGeometry.sharesAnchor(start, end))
                animate(start, end, metrics)
                let middle = DockGeometry.interpolate(from: start, to: end, progress: 0.43)
                animate(middle, start, metrics)
            }
        }
    }
    // (Side changes are applied without animation; a wing never needs to slide through the camera.)
    // A wing that fits inside the expanded frame stays exactly in place while it fades.
    let wingStart = global(compact.indicatorRect, in: compact)
    for step in 0...100 {
        let current = DockGeometry.interpolate(from: compact, to: expanded, progress: CGFloat(step) / 100)
        precondition(equal(global(current.indicatorRect, in: current), wingStart))
    }
    for point in [CGPoint(x: -2000, y: 2000), CGPoint(x: 500, y: -500), CGPoint(x: -500, y: 300)] {
        animate(layout(screen, .compact, point), layout(screen, .expanded, point), screen)
    }
    // Local body offsets also remain contained; interpolation cannot assume an origin of zero.
    let insetStart = DockLayout(frame: CGRect(x: -550, y: 670, width: 100, height: 30), mode: .floating,
                               bodyRect: CGRect(x: 10, y: 4, width: 80, height: 20),
                               cameraRect: .zero, indicatorRect: CGRect(x: 10, y: 14, width: 80, height: 10))
    let insetEnd = DockLayout(frame: CGRect(x: -700, y: 500, width: 400, height: 200), mode: .floating,
                             bodyRect: CGRect(x: 20, y: 8, width: 360, height: 180),
                             cameraRect: .zero, indicatorRect: CGRect(x: 20, y: 178, width: 360, height: 10))
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

    runPointerPolicyTests(screen: screen, compact: compact, expanded: expanded, floating: floating)

    // Independent presentation dimensions retain one manual anchor even when the
    // user places the board against a display edge. Reversal keeps the same top.
    for metrics in [screen, noNotch, tiny] {
        for point in [CGPoint(x: -2000, y: 2000), CGPoint(x: 500, y: 500)] {
            let overviewSize = CGSize(width: 720, height: 248)
            let detailSize = CGSize(width: 900, height: 610)
            let overview = DockGeometry.layout(screen: metrics, presentation: .expanded,
                                               preferredExpandedSize: overviewSize, compactSlots: 3,
                                               manualTopCenter: point, preferredAnchorWidth: 900)!
            let detail = DockGeometry.layout(screen: metrics, presentation: .expanded,
                                             preferredExpandedSize: detailSize, compactSlots: 3,
                                             manualTopCenter: point, preferredAnchorWidth: 900)!
            let closed = DockGeometry.layout(screen: metrics, presentation: .compact,
                                             preferredExpandedSize: overviewSize, compactSlots: 3,
                                             manualTopCenter: point, preferredAnchorWidth: 900)!
            precondition(overview.frame.midX == detail.frame.midX && closed.frame.midX == detail.frame.midX)
            precondition(overview.frame.maxY == detail.frame.maxY && closed.frame.maxY == detail.frame.maxY)
            precondition(DockGeometry.sharesAnchor(closed, overview) && DockGeometry.sharesAnchor(overview, detail))
            animate(overview, detail, metrics)
        }
    }
    let detail = DockGeometry.layout(screen: screen, presentation: .expanded,
                                     preferredExpandedSize: CGSize(width: 900, height: 610), compactSlots: 3)!
    animate(expanded, detail, screen)
    precondition(DockGeometry.layout(screen: screen, presentation: .compact,
                                     preferredExpandedSize: size, compactSlots: 3,
                                     preferredAnchorWidth: .nan) == nil)

    // A fractional requested animation height must not become the drawing height
    // after AppKit realizes a different content size. Preserve real camera/wing
    // positions while making the silhouette meet the realized content top.
    for side in [CompactWingSide.right, .left] {
        let start = layout(screen, .compact, side: side)
        let end = layout(screen, .expanded, side: side)
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
                precondition(equal(global(realized.indicatorRect, in: realized), global(requested.indicatorRect, in: requested)))
                let reversed = DockGeometry.interpolate(from: requested, to: start, progress: 0.3)
                precondition(abs(reversed.frame.maxY - start.frame.maxY) < epsilon)
                precondition(equal(global(reversed.cameraRect, in: reversed), global(start.cameraRect, in: start)))
            }
        }
    }
    // Detached layouts keep their center/top under realized rounding too.
    for scale in [CGFloat(1), 2] {
        for progress in [CGFloat(0.13), 0.61] {
            let requested = DockGeometry.interpolate(from: floating, to: floatingExpanded, progress: progress)
            let width = (requested.frame.width * scale).rounded(.up) / scale
            let height = (requested.frame.height * scale).rounded(.up) / scale
            let actual = CGRect(x: requested.frame.midX - width / 2, y: requested.frame.maxY - height,
                                width: width, height: height)
            let realized = DockGeometry.reconciled(requested, to: actual)
            precondition(realized.frame == actual && abs(realized.bodyRect.maxY - height) < epsilon)
        }
    }

    // Option-dragging a ring of an attached compact wing must carry that ring with the pointer when
    // the panel detaches. The wing frame's midpoint is the camera+wing center, not the rings', so the
    // grab anchor is the visible row's top-center.
    let drag = CGPoint(x: -100, y: -230)
    for side in [CompactWingSide.right, .left] {
        for slots in [1, 3, 5] {
            let attached = layout(screen, .compact, slots: slots, side: side)
            let anchor = DockGeometry.compactDragAnchor(attached, side: side, slots: slots)
            let before = CompactMetrics.rowMinX(in: global(attached.indicatorRect, in: attached), attached: true,
                                                side: side, slots: slots)
            precondition(abs(anchor.y - attached.frame.maxY) < epsilon)
            precondition(abs(attached.frame.midX - anchor.x) > 1)
            let detached = layout(screen, .compact, CGPoint(x: anchor.x + drag.x, y: anchor.y + drag.y),
                                  slots: slots, side: side)
            precondition(detached.mode == .floating)
            let after = CompactMetrics.rowMinX(in: global(detached.indicatorRect, in: detached), attached: false,
                                               side: side, slots: slots)
            for index in Set([0, slots - 1]) {
                let offset = 11 + CGFloat(index) * CompactMetrics.slotPitch
                precondition(abs((after + offset) - (before + offset) - drag.x) < epsilon)
            }
            precondition(abs(detached.frame.maxY - (attached.frame.maxY + drag.y)) < epsilon)
            // A detached compact row is already centered in its frame: same anchor either way.
            let detachedAnchor = DockGeometry.compactDragAnchor(detached, side: side, slots: slots)
            precondition(abs(detachedAnchor.x - detached.frame.midX) < epsilon)
            precondition(abs(detachedAnchor.y - detached.frame.maxY) < epsilon)
        }
    }

    runCompactSlotPlannerTests()
    runCompactRingPresentationTests()
}

// Compact previews from anywhere in the final compact frame; once expanded the whole
// current panel holds hover.
private func runPointerPolicyTests(screen: DockScreenMetrics, compact: DockLayout,
                                   expanded: DockLayout, floating: DockLayout) {
    let target = compact.frame
    let camera = DockGeometry.globalRect(compact.cameraRect, in: compact)
    let wing = compact.indicatorRect.offsetBy(dx: compact.frame.minX, dy: compact.frame.minY)
    let ring = CGPoint(x: wing.midX, y: wing.midY)

    func compactWants(_ point: CGPoint, panelFrame: CGRect = compact.frame, target: CGRect = target) -> Bool {
        DockPointerPolicy.wantsHover(point: point, presentation: .compact, panelFrame: panelFrame,
                                     compactTarget: target)
    }
    // Every attached compact zone previews: camera, rings, wing padding and all four edges
    // (the pointer can rest exactly on the screen's top edge).
    for point in [CGPoint(x: camera.midX, y: camera.midY), ring,
                  CGPoint(x: wing.minX + 1, y: wing.midY), CGPoint(x: wing.maxX - 1, y: wing.midY),
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

private func runCompactSlotPlannerTests() {
    func summary(_ plan: CompactSlotPlan) -> [String] {
        plan.slots.map { slot in
            switch slot {
            case .provider(let ring): return ring.provider
            case .more(let more): return more.text
            case .configure: return "configure"
            }
        }
    }
    func plan(_ cards: [DashboardCard], _ selected: [String]?, max: Int, capacity: Int = 1000,
              aliases: ExactConfigMap = [:], issue: String = "") -> CompactSlotPlan {
        CompactSlotPlanner.plan(cards: cards, selectedProviderIDs: selected, maximumVisibleSlots: max,
                                physicalCapacity: capacity, aliases: aliases, issue: issue)
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
    // Physical capacity (at least one) can cap a larger user maximum.
    precondition(summary(plan(cards, ["a", "b", "c", "d"], max: 10, capacity: 2)) == ["a", "+3"])
    precondition(summary(plan(cards, ["a", "b", "c", "d"], max: 10, capacity: 0)) == ["+4"])
    precondition(summary(plan(cards, ["a", "b", "c", "d"], max: Int.max, capacity: 3)) == ["a", "b", "+2"])

    // Current upstream order wins; selected IDs the data lacks follow in selection order.
    let missing = plan(cards, ["e", "missing2", "a", "missing1"], max: 10, aliases: ["missing1": "Alias One"])
    precondition(summary(missing) == ["a", "e", "missing2", "missing1"])
    guard case .provider(let absent) = missing.slots[3], case .provider(let plain) = missing.slots[2],
          case .provider(let present) = missing.slots[0] else { preconditionFailure("Expected rings") }
    precondition(!absent.isReported && absent.arc == .unknown && !absent.hasWarning && !absent.isOverLimit)
    precondition(absent.label == "Alias One")
    precondition(plain.label == "missing2" && !plain.isReported)
    precondition(present.isReported && present.arc == .fraction(0.5))
    // Missing selections still count toward capacity and More, without borrowing a metric.
    let overflowMissing = plan(cards, ["a", "missing1", "missing2"], max: 2)
    precondition(summary(overflowMissing) == ["a", "+2"] && overflowMissing.hiddenProviderIDs == ["missing1", "missing2"])
    guard case .more(let more) = overflowMissing.slots[1] else { preconditionFailure("Expected More") }
    precondition(more.count == 2)
    precondition(!more.hasWarning)
    // Selection with no data at all keeps its membership as truthful unknown rings.
    let noData = plan([], ["x", "y"], max: 3)
    precondition(summary(noData) == ["x", "y"] && noData.selectedCount == 2)

    // nil (uninitialized) and [] (explicitly none) both show the configure affordance, not More.
    let uninitialized = plan(cards, nil, max: 3)
    let none = plan(cards, [], max: 3, issue: "Stale: failed")
    precondition(summary(uninitialized) == ["configure"] && summary(none) == ["configure"])
    precondition(uninitialized.selectedCount == 0 && none.hiddenProviderIDs.isEmpty)
    guard case .configure(let first) = uninitialized.slots[0], case .configure(let second) = none.slots[0] else {
        preconditionFailure("Expected configure")
    }
    precondition(!first.hasIssue && second.hasIssue)
    precondition(summary(plan(cards, [], max: 1)) == ["configure"])

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
