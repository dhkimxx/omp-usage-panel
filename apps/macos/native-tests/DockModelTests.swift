import Foundation
import CoreGraphics

func runDockModelTests() {
    let size = CGSize(width: 360, height: DashboardSizing.preferredSize(providerCount: 3, cameraHeight: 28).height)
    let epsilon: CGFloat = 0.0000001
    let screen = DockScreenMetrics(
        frame: CGRect(x: -1000.5, y: 30.25, width: 1000, height: 700),
        visibleFrame: CGRect(x: -1000.5, y: 50.25, width: 1000, height: 651),
        safeAreaTop: 28, menuBarHeight: 22,
        auxiliaryTopLeft: CGRect(x: -1000.5, y: 702.25, width: 400, height: 28),
        auxiliaryTopRight: CGRect(x: -440.5, y: 702.25, width: 440, height: 28))
    func layout(_ metrics: DockScreenMetrics, _ state: DockPresentation, _ manual: CGPoint? = nil) -> DockLayout {
        guard let result = DockGeometry.layout(screen: metrics, presentation: state,
                                               preferredExpandedSize: size, providerCount: 3,
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
            let strip = global(result.indicatorRect, in: result)
            precondition(abs(camera.minX - metrics.auxiliaryTopLeft.maxX) < epsilon)
            precondition(abs(camera.maxX - metrics.auxiliaryTopRight.minX) < epsilon)
            precondition(abs(camera.maxY - metrics.frame.maxY) < epsilon)
            precondition(abs(camera.height - metrics.safeAreaTop) < epsilon)
            precondition(result.cameraRect.minX >= result.bodyRect.minX - epsilon)
            precondition(result.cameraRect.maxX <= result.bodyRect.maxX + epsilon)
            precondition(result.cameraRect.maxY <= result.bodyRect.maxY + epsilon)
            precondition(abs(strip.maxY - camera.minY) < epsilon)
            precondition(strip.minY >= result.frame.minY - epsilon)
            precondition(abs(strip.minX - camera.minX) < epsilon && abs(strip.width - camera.width) < epsilon)
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
    precondition(compact.frame.midX == -520.5 && expanded.frame.midX == -520.5)
    precondition(compact.frame.width == 160 && compact.frame.height == screen.safeAreaTop + 10)
    precondition(compact.bodyRect == CGRect(origin: .zero, size: compact.frame.size))
    precondition(expanded.bodyRect.width >= expanded.cameraRect.width + 200)
    precondition(expanded.bodyRect.minX > 0 && expanded.bodyRect.maxX < expanded.frame.width)
    precondition(expanded.bodyRect.height == size.height && expanded.bodyRect.maxY == expanded.frame.height)
    precondition(global(compact.cameraRect, in: compact) == global(expanded.cameraRect, in: expanded))
    precondition(global(compact.indicatorRect, in: compact) == global(expanded.indicatorRect, in: expanded))

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
                                           preferredExpandedSize: deepPreferred, providerCount: 3)!
    bounded(deepExpanded, deepCamera)
    precondition(deepExpanded.bodyRect.height == deepPreferred.height)
    precondition(deepExpanded.bodyRect.height - deepExpanded.cameraRect.height >= 200)
    precondition(global(deepExpanded.indicatorRect, in: deepExpanded).maxY ==
                 deepCamera.frame.maxY - deepCamera.safeAreaTop)

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
    precondition(floating.indicatorRect.maxY == floating.frame.height)
    precondition(floatingExpanded.indicatorRect.height == 16)

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
    }
    let shortNotch = DockScreenMetrics(frame: CGRect(x: 100.25, y: -50.5, width: 80, height: 40),
                                       visibleFrame: CGRect(x: 100.25, y: -45.5, width: 80, height: 7),
                                       safeAreaTop: 28, menuBarHeight: 28,
                                       auxiliaryTopLeft: CGRect(x: 100.25, y: -38.5, width: 32, height: 28),
                                       auxiliaryTopRight: CGRect(x: 148.25, y: -38.5, width: 32, height: 28))
    for state in [DockPresentation.compact, .expanded] {
        let result = layout(shortNotch, state)
        bounded(result, shortNotch)
        precondition(result.indicatorRect.height == 7)
        precondition(result.frame.minY == shortNotch.visibleFrame.minY)
    }
    let coveredStrip = DockScreenMetrics(frame: shortNotch.frame,
                                         visibleFrame: CGRect(x: 100.25, y: -38.5, width: 80, height: 1),
                                         safeAreaTop: shortNotch.safeAreaTop, menuBarHeight: 28,
                                         auxiliaryTopLeft: shortNotch.auxiliaryTopLeft,
                                         auxiliaryTopRight: shortNotch.auxiliaryTopRight)
    precondition(DockGeometry.layout(screen: coveredStrip, presentation: .compact,
                                     preferredExpandedSize: size, providerCount: 3) == nil)
    let impossible = DockScreenMetrics(frame: screen.frame, visibleFrame: screen.visibleFrame,
                                       safeAreaTop: 1000, menuBarHeight: 22,
                                       auxiliaryTopLeft: .zero, auxiliaryTopRight: .zero)
    precondition(DockGeometry.layout(screen: impossible, presentation: .compact,
                                     preferredExpandedSize: size, providerCount: 0) == nil)
    precondition(DockGeometry.layout(screen: screen, presentation: .compact,
                                     preferredExpandedSize: size, providerCount: 0,
                                     manualTopCenter: CGPoint(x: CGFloat.nan, y: 0)) == nil)

    func animate(_ a: DockLayout, _ b: DockLayout, _ metrics: DockScreenMetrics) {
        let fixedCamera = global(a.cameraRect, in: a)
        let fixedStrip = global(a.indicatorRect, in: a)
        for step in 0...100 {
            let progress = CGFloat(step) / 100
            for (start, end) in [(a, b), (b, a)] {
                let current = DockGeometry.interpolate(from: start, to: end, progress: progress)
                precondition(current.mode == start.mode)
                bounded(current, metrics)
                precondition(abs(current.frame.midX - start.frame.midX) < epsilon)
                precondition(abs(current.frame.maxY - start.frame.maxY) < epsilon)
                if current.mode == .notchConnected {
                    precondition(equal(global(current.cameraRect, in: current), fixedCamera))
                    precondition(equal(global(current.indicatorRect, in: current), fixedStrip))
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
        let preferred = DashboardSizing.preferredSize(providerCount: 7, cameraHeight: metrics.safeAreaTop)
        let start = DockGeometry.layout(screen: metrics, presentation: .compact,
                                        preferredExpandedSize: preferred, providerCount: 7)!
        let end = DockGeometry.layout(screen: metrics, presentation: .expanded,
                                      preferredExpandedSize: preferred, providerCount: 7)!
        animate(start, end, metrics)
        let middle = DockGeometry.interpolate(from: start, to: end, progress: 0.43)
        animate(middle, start, metrics)
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
    interaction.setDetailOpen(true)
    interaction.setHover(false)
    precondition(interaction.presentation == .expanded)
    interaction.setMenuOpen(true)
    interaction.setDetailOpen(false)
    precondition(interaction.presentation == .expanded)
    interaction.setDragging(true)
    interaction.setMenuOpen(false)
    precondition(interaction.presentation == .expanded)
    interaction.setDragging(false)
    precondition(interaction.presentation == .compact)
    interaction.setHover(true)
    interaction.setDetailOpen(true)
    interaction.setMenuOpen(true)
    interaction.setDragging(true)
    interaction.dismiss()
    precondition(interaction.presentation == .compact && !interaction.isHovered && !interaction.isDetailOpen &&
                 !interaction.isMenuOpen && !interaction.isDragging)
}
