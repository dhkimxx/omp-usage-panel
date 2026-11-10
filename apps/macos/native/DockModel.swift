import Foundation
import CoreGraphics

enum DockPresentation: Equatable {
    case compact, expanded
}

enum DockPlacementMode: Equatable {
    case notchConnected, floating
}

struct DockScreenMetrics: Equatable {
    let frame: CGRect
    let visibleFrame: CGRect
    let safeAreaTop: CGFloat
    let menuBarHeight: CGFloat
    let auxiliaryTopLeft: CGRect
    let auxiliaryTopRight: CGRect

    var safeTop: CGFloat {
        frame.maxY - max(safeAreaTop, frame.maxY - visibleFrame.maxY, menuBarHeight, 0)
    }
}

struct DockLayout: Equatable {
    let frame: CGRect
    let mode: DockPlacementMode
    let bodyRect: CGRect
    let cameraRect: CGRect
    let indicatorRect: CGRect
}

enum DockGeometry {
    private static func finite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite &&
        rect.width.isFinite && rect.height.isFinite &&
        rect.minX.isFinite && rect.maxX.isFinite && rect.minY.isFinite && rect.maxY.isFinite
    }

    private static func notch(in screen: DockScreenMetrics) -> (center: CGFloat, width: CGFloat)? {
        let left = screen.auxiliaryTopLeft
        let right = screen.auxiliaryTopRight
        let frame = screen.frame
        guard screen.safeAreaTop > 0, finite(left), finite(right),
              left.width > 0, left.height > 0, right.width > 0, right.height > 0,
              left.minX >= frame.minX, right.maxX <= frame.maxX,
              left.minY >= frame.minY, right.minY >= frame.minY,
              left.maxY <= frame.maxY, right.maxY <= frame.maxY,
              left.maxY > frame.maxY - screen.safeAreaTop,
              right.maxY > frame.maxY - screen.safeAreaTop,
              left.maxX < right.minX else { return nil }
        let width = right.minX - left.maxX
        guard width.isFinite, width > 0, width <= frame.width else { return nil }
        return (left.maxX + width / 2, width)
    }

    static func layout(screen: DockScreenMetrics, presentation: DockPresentation,
                       preferredExpandedSize: CGSize, providerCount: Int,
                       manualTopCenter: CGPoint? = nil) -> DockLayout? {
        let frame = screen.frame
        let visible = screen.visibleFrame
        guard finite(frame), finite(visible), frame.width > 0, frame.height > 0,
              visible.width > 0, visible.height > 0,
              screen.safeAreaTop.isFinite, screen.menuBarHeight.isFinite,
              screen.safeTop.isFinite,
              preferredExpandedSize.width.isFinite, preferredExpandedSize.height.isFinite,
              preferredExpandedSize.width > 0, preferredExpandedSize.height > 0,
              visible.maxX > frame.minX, visible.minX < frame.maxX,
              visible.maxY > frame.minY, visible.minY < frame.maxY else { return nil }
        if let point = manualTopCenter, !point.x.isFinite || !point.y.isFinite { return nil }

        let bottom = max(frame.minY, visible.minY)
        let notch = manualTopCenter == nil ? notch(in: screen) : nil
        if let notch {
            let cameraHeight = screen.safeAreaTop
            let availableHeight = frame.maxY - bottom
            guard cameraHeight < availableHeight else { return nil }
            let stripHeight = min(10, availableHeight - cameraHeight)
            // Keep the camera's real center fixed even on asymmetric screen layouts.
            let margin = min(8, frame.width / 4,
                             screen.auxiliaryTopLeft.maxX - frame.minX,
                             frame.maxX - screen.auxiliaryTopRight.minX)
            let availableWidth = 2 * min(notch.center - frame.minX - margin,
                                         frame.maxX - margin - notch.center)
            let desiredWidth = presentation == .compact ? notch.width :
                max(preferredExpandedSize.width, notch.width + 200) + 36
            let width = min(desiredWidth, availableWidth)
            let minimumHeight = cameraHeight + stripHeight
            let height = presentation == .compact ? minimumHeight :
                min(max(preferredExpandedSize.height, minimumHeight), availableHeight)
            guard width.isFinite, height.isFinite, width >= notch.width, height > cameraHeight else { return nil }
            let bodyInset = presentation == .compact ? 0 : min(18, (width - notch.width) / 2)
            let body = CGRect(x: bodyInset, y: 0, width: width - 2 * bodyInset, height: height)
            let camera = CGRect(x: (width - notch.width) / 2, y: height - cameraHeight,
                                width: notch.width, height: cameraHeight)
            let indicators = CGRect(x: camera.minX, y: camera.minY - stripHeight,
                                    width: notch.width, height: stripHeight)
            return DockLayout(frame: CGRect(x: notch.center - width / 2, y: frame.maxY - height,
                                             width: width, height: height),
                              mode: .notchConnected, bodyRect: body,
                              cameraRect: camera, indicatorRect: indicators)
        }

        let safeTop = min(frame.maxY, screen.safeTop)
        let availableHeight = safeTop - bottom
        guard availableHeight.isFinite, availableHeight > 0 else { return nil }
        let margin = min(8, frame.width / 4)
        let minX = frame.minX + margin
        let maxX = frame.maxX - margin
        let availableWidth = maxX - minX
        guard availableWidth.isFinite, availableWidth > 0 else { return nil }
        let automaticGap: CGFloat = manualTopCenter == nil ? min(6, availableHeight / 2) : 0
        let maxHeight = availableHeight - automaticGap
        // Bound the count before converting it, including for pathological inputs.
        let compactWidth = CGFloat(100 + min(max(providerCount, 0), 11) * 4)
        let desiredWidth = presentation == .compact ? compactWidth : preferredExpandedSize.width
        let desiredHeight: CGFloat = presentation == .compact ? 16 : preferredExpandedSize.height
        let width = min(desiredWidth, availableWidth)
        let requestedTop = manualTopCenter?.y ?? (safeTop - automaticGap)
        let minimumTop = bottom + min(16, maxHeight)
        let top = min(max(requestedTop, minimumTop), safeTop - automaticGap)
        let height = min(desiredHeight, top - bottom)
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        // A detached compact panel reserves enough horizontal room to open in place.
        let anchorWidth = manualTopCenter == nil ? width :
            min(max(compactWidth, preferredExpandedSize.width), availableWidth)
        let requestedCenter = manualTopCenter?.x ?? frame.midX
        let center = min(max(requestedCenter, minX + anchorWidth / 2), maxX - anchorWidth / 2)
        let body = CGRect(x: 0, y: 0, width: width, height: height)
        let stripHeight = min(16, height)
        return DockLayout(frame: CGRect(x: center - width / 2, y: top - height, width: width, height: height),
                          mode: .floating, bodyRect: body, cameraRect: .zero,
                          indicatorRect: CGRect(x: 0, y: height - stripHeight, width: width, height: stripHeight))
    }

    static func interpolate(from: DockLayout, to: DockLayout, progress: CGFloat) -> DockLayout {
        let progress = progress.isNaN ? 0 : min(1, max(0, progress))
        if progress == 0 { return from }
        if progress == 1 { return to }
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            a == b ? a : (1 - progress) * a + progress * b
        }
        let width = mix(from.frame.width, to.frame.width)
        let height = mix(from.frame.height, to.frame.height)
        // Top-center interpolation keeps the attached screen edge and floating anchor fixed.
        let center = mix(from.frame.midX, to.frame.midX)
        let top = mix(from.frame.maxY, to.frame.maxY)
        let frame = CGRect(x: center - width / 2, y: top - height, width: width, height: height)
        func rect(_ a: CGRect, _ b: CGRect) -> CGRect {
            let x = min(width, max(0, mix(a.minX, b.minX)))
            let y = min(height, max(0, mix(a.minY, b.minY)))
            return CGRect(x: x, y: y,
                          width: min(width - x, max(0, mix(a.width, b.width))),
                          height: min(height - y, max(0, mix(a.height, b.height))))
        }
        // Local rectangles move with the changing frame origin. Their global camera
        // and footer positions therefore remain fixed throughout attached transitions.
        return DockLayout(frame: frame, mode: from.mode,
                          bodyRect: rect(from.bodyRect, to.bodyRect),
                          cameraRect: rect(from.cameraRect, to.cameraRect),
                          indicatorRect: rect(from.indicatorRect, to.indicatorRect))
    }
}

struct DockInteraction {
    private(set) var isHovered = false
    private(set) var isDetailOpen = false
    private(set) var isMenuOpen = false
    private(set) var isDragging = false

    var presentation: DockPresentation {
        isHovered || isDetailOpen || isMenuOpen || isDragging ? .expanded : .compact
    }

    mutating func setHover(_ value: Bool) { isHovered = value }
    mutating func setDetailOpen(_ value: Bool) { isDetailOpen = value }
    mutating func setMenuOpen(_ value: Bool) { isMenuOpen = value }
    mutating func setDragging(_ value: Bool) { isDragging = value }
    mutating func dismiss() {
        isHovered = false
        isDetailOpen = false
        isMenuOpen = false
        isDragging = false
    }
}
