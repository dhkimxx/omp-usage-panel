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
    /// Local rectangles of the occupied compact groups; an empty wing/group is exactly `.zero`.
    let leftIndicatorRect: CGRect
    let rightIndicatorRect: CGRect

    var occupiedIndicatorRects: [CGRect] { [leftIndicatorRect, rightIndicatorRect].filter { !$0.isEmpty } }
}

// Fixed visual contract for the compact ring-only display.
enum CompactMetrics {
    static let ringDiameter: CGFloat = 22
    static let ringStroke: CGFloat = 2
    static let markFontSize: CGFloat = 8.5
    static let rowHeight: CGFloat = 28
    static let gap: CGFloat = 4
    static let cameraPadding: CGFloat = 10
    static let outerPadding: CGFloat = 6
    static let floatingPadding: CGFloat = 12
    // Far above any physical screen; keeps every Int-to-CGFloat conversion bounded.
    static let slotLimit = 4096

    static var slotPitch: CGFloat { ringDiameter + gap }
    // An empty wing/group (zero controls) occupies nothing.
    static func bounded(_ slots: Int) -> Int { min(max(slots, 0), slotLimit) }
    static func contentWidth(slots: Int) -> CGFloat {
        let count = bounded(slots)
        guard count > 0 else { return 0 }
        let n = CGFloat(count)
        return n * ringDiameter + (n - 1) * gap
    }
    // 26n + 12: camera-side and outer padding around one occupied wing; an empty wing is zero.
    static func wingWidth(_ slots: Int) -> CGFloat {
        bounded(slots) == 0 ? 0 : contentWidth(slots: slots) + cameraPadding + outerPadding
    }
    // 26n + 20: the detached capsule is content plus 24pt (never narrower than one control).
    static func floatingWidth(slots: Int) -> CGFloat { contentWidth(slots: max(1, slots)) + 2 * floatingPadding }

    // Left edge of one compact row inside its indicator region: attached rows hug the camera side
    // (left wing right-aligned, right wing left-aligned, overflowing outward); detached rows are
    // centered in their own region.
    static func rowMinX(in indicator: CGRect, attached: Bool, side: CompactWingSide, slots: Int) -> CGFloat {
        let width = contentWidth(slots: slots)
        guard attached else { return indicator.midX - width / 2 }
        return side == .right ? indicator.minX + cameraPadding : indicator.maxX - cameraPadding - width
    }

    private static func capacity(width: CGFloat, padding: CGFloat) -> Int {
        guard width.isFinite else { return 1 }
        let slots = ((width - padding + gap) / slotPitch).rounded(.down)
        return bounded(Int(min(max(slots, 1), CGFloat(slotLimit))))
    }
    static func capacity(forWingWidth width: CGFloat) -> Int {
        capacity(width: width, padding: cameraPadding + outerPadding)
    }
    static func floatingCapacity(forWidth width: CGFloat) -> Int {
        capacity(width: width, padding: 2 * floatingPadding)
    }
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

    private static func notchMargin(_ screen: DockScreenMetrics) -> CGFloat {
        min(8, screen.frame.width / 4,
            screen.auxiliaryTopLeft.maxX - screen.frame.minX,
            screen.frame.maxX - screen.auxiliaryTopRight.minX)
    }

    // The widest wing that stays on screen beside the fixed camera. It is a physical
    // bound only; it says nothing about menu-bar occupancy.
    private static func maximumWing(screen: DockScreenMetrics, side: CompactWingSide) -> CGFloat {
        let space = side == .right ? screen.frame.maxX - screen.auxiliaryTopRight.minX
                                   : screen.auxiliaryTopLeft.maxX - screen.frame.minX
        return max(0, space - notchMargin(screen))
    }

    // Independent physical slot capacities for the placement `layout` would
    // choose. An attached notch computes each side of the fixed camera separately; a floating
    // capsule is one row whose total capacity is real, so either group can use all of it.
    static func compactCapacities(screen: DockScreenMetrics, manualTopCenter: CGPoint? = nil) -> CompactCapacities {
        let frame = screen.frame
        guard finite(frame), frame.width > 0 else { return CompactCapacities(left: 1, right: 1, total: 1) }
        if manualTopCenter == nil, notch(in: screen) != nil {
            // Each wing is bounded by its own physical width; a wing with no room at all is zero.
            let leftWing = maximumWing(screen: screen, side: .left)
            let rightWing = maximumWing(screen: screen, side: .right)
            let left = leftWing > 0 ? CompactMetrics.capacity(forWingWidth: leftWing) : 0
            let right = rightWing > 0 ? CompactMetrics.capacity(forWingWidth: rightWing) : 0
            return CompactCapacities(left: left, right: right, total: left + right)
        }
        let capacity = CompactMetrics.floatingCapacity(forWidth: frame.width - 2 * min(8, frame.width / 4))
        return CompactCapacities(left: capacity, right: capacity, total: capacity)
    }

    // `leftCompactSlots` / `rightCompactSlots` are the ACTUAL planned control counts per wing;
    // either may be zero (that wing is then absent). Attached, the frame spans only the occupied
    // wings and the real camera. Detached/no-notch, both groups share one capsule.
    static func layout(screen: DockScreenMetrics, presentation: DockPresentation,
                       preferredExpandedSize: CGSize, leftCompactSlots: Int, rightCompactSlots: Int,
                       manualTopCenter: CGPoint? = nil,
                       preferredAnchorWidth: CGFloat? = nil) -> DockLayout? {
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
        if let width = preferredAnchorWidth, !width.isFinite || width <= 0 { return nil }

        let bottom = max(frame.minY, visible.minY)
        let notch = manualTopCenter == nil ? notch(in: screen) : nil
        let isCompact = presentation == .compact
        if let notch {
            let cameraHeight = screen.safeAreaTop
            let availableHeight = frame.maxY - bottom
            guard cameraHeight < availableHeight else { return nil }
            let stripHeight = min(10, availableHeight - cameraHeight)
            // Keep the camera's real position fixed even on asymmetric screen layouts.
            let margin = notchMargin(screen)
            let leftLimit = maximumWing(screen: screen, side: .left)
            let rightLimit = maximumWing(screen: screen, side: .right)
            let leftSlots = leftLimit > 0 ? min(CompactMetrics.bounded(leftCompactSlots), CompactMetrics.capacity(forWingWidth: leftLimit)) : 0
            let rightSlots = rightLimit > 0 ? min(CompactMetrics.bounded(rightCompactSlots), CompactMetrics.capacity(forWingWidth: rightLimit)) : 0
            // An empty wing is exactly zero wide.
            let leftWing = leftSlots == 0 ? 0 : min(CompactMetrics.wingWidth(leftSlots), leftLimit)
            let rightWing = rightSlots == 0 ? 0 : min(CompactMetrics.wingWidth(rightSlots), rightLimit)
            let compactHeight = min(max(cameraHeight, CompactMetrics.rowHeight), availableHeight)
            let availableWidth = 2 * min(notch.center - frame.minX - margin,
                                         frame.maxX - margin - notch.center)
            let desiredWidth = isCompact ? leftWing + notch.width + rightWing :
                max(preferredExpandedSize.width, notch.width + 200) + 36
            let width = isCompact ? desiredWidth : min(desiredWidth, availableWidth)
            let minimumHeight = cameraHeight + stripHeight
            let height = isCompact ? compactHeight :
                min(max(preferredExpandedSize.height, minimumHeight), availableHeight)
            guard width.isFinite, height.isFinite, leftSlots == 0 || leftWing > 0, rightSlots == 0 || rightWing > 0,
                  width >= notch.width, height >= cameraHeight else { return nil }
            let notchLeft = screen.auxiliaryTopLeft.maxX
            let notchRight = screen.auxiliaryTopRight.minX
            let frameMinX = isCompact ? notchLeft - leftWing : notch.center - width / 2
            let bodyInset = isCompact ? 0 : min(18, (width - notch.width) / 2)
            let body = CGRect(x: bodyInset, y: 0, width: width - 2 * bodyInset, height: height)
            let camera = CGRect(x: notchLeft - frameMinX, y: height - cameraHeight,
                                width: notch.width, height: cameraHeight)
            // Wings sit beside the camera; no row hangs below it. Expanded layouts keep the same
            // global wings (clipped to the frame) so fading controls never jump.
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            func wing(x: CGFloat, width wingWidth: CGFloat) -> CGRect {
                guard wingWidth > 0 else { return .zero }
                let rect = CGRect(x: x - frameMinX, y: height - compactHeight, width: wingWidth, height: compactHeight)
                    .intersection(bounds)
                return rect.isNull ? .zero : rect
            }
            return DockLayout(frame: CGRect(x: frameMinX, y: frame.maxY - height,
                                             width: width, height: height),
                              mode: .notchConnected, bodyRect: body, cameraRect: camera,
                              leftIndicatorRect: wing(x: notchLeft - leftWing, width: leftWing),
                              rightIndicatorRect: wing(x: notchRight, width: rightWing))
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
        // Capacity is derived from the width before any slot count becomes a length. The one
        // capsule holds both groups, so they share its capacity (left first).
        let capacity = CompactMetrics.floatingCapacity(forWidth: availableWidth)
        let leftSlots = min(CompactMetrics.bounded(leftCompactSlots), capacity)
        let rightSlots = min(CompactMetrics.bounded(rightCompactSlots), capacity - leftSlots)
        let compactWidth = CompactMetrics.floatingWidth(slots: leftSlots + rightSlots)
        let desiredWidth = isCompact ? compactWidth : preferredExpandedSize.width
        let desiredHeight: CGFloat = isCompact ? CompactMetrics.rowHeight : preferredExpandedSize.height
        let width = min(desiredWidth, availableWidth)
        let requestedTop = manualTopCenter?.y ?? (safeTop - automaticGap)
        let minimumTop = bottom + min(CompactMetrics.rowHeight, maxHeight)
        let top = min(max(requestedTop, minimumTop), safeTop - automaticGap)
        let height = min(desiredHeight, top - bottom)
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        // A detached compact panel reserves enough horizontal room to open in place.
        let anchorWidth = manualTopCenter == nil ? width :
            min(max(compactWidth, preferredAnchorWidth ?? preferredExpandedSize.width), availableWidth)
        let requestedCenter = manualTopCenter?.x ?? frame.midX
        let center = min(max(requestedCenter, minX + anchorWidth / 2), maxX - anchorWidth / 2)
        let body = CGRect(x: 0, y: 0, width: width, height: height)
        let stripHeight = min(CompactMetrics.rowHeight, height)
        // Left group, one normal ring gap, right group: contiguous and centered, no camera gap.
        let rowMinX = (width - CompactMetrics.contentWidth(slots: leftSlots + rightSlots)) / 2
        func row(x: CGFloat, slots: Int) -> CGRect {
            guard slots > 0 else { return .zero }
            let rect = CGRect(x: x, y: height - stripHeight, width: CompactMetrics.contentWidth(slots: slots),
                              height: stripHeight).intersection(body)
            return rect.isNull ? .zero : rect
        }
        let rightMinX = rowMinX + (leftSlots > 0 ? CompactMetrics.contentWidth(slots: leftSlots) + CompactMetrics.gap : 0)
        return DockLayout(frame: CGRect(x: center - width / 2, y: top - height, width: width, height: height),
                          mode: .floating, bodyRect: body, cameraRect: .zero,
                          leftIndicatorRect: row(x: rowMinX, slots: leftSlots),
                          rightIndicatorRect: row(x: rightMinX, slots: rightSlots))
    }

    static func globalRect(_ rect: CGRect, in layout: DockLayout) -> CGRect {
        rect.offsetBy(dx: layout.frame.minX, dy: layout.frame.minY)
    }

    // The global top-center a detached capsule must take for the grabbed compact group to keep its
    // exact screen position. Attached rows hug the camera from both sides (with the camera gap
    // between them); the detached capsule is one contiguous row (left group, ring gap, right group)
    // centered on the anchor. `grabPoint` is the global cursor: it selects the group under (or
    // nearest to) it, so removing the camera gap never makes the grabbed rings jump. A layout that
    // is already detached is one centered row, so its top-center is the anchor.
    static func compactDragAnchor(_ layout: DockLayout, grabPoint: CGPoint, leftSlots: Int, rightSlots: Int) -> CGPoint {
        let top = layout.frame.maxY
        guard layout.mode == .notchConnected else { return CGPoint(x: layout.frame.midX, y: top) }
        func group(_ rect: CGRect, side: CompactWingSide, slots: Int) -> (minX: CGFloat, maxX: CGFloat, slots: Int)? {
            let count = CompactMetrics.bounded(slots)
            guard count > 0, !rect.isEmpty else { return nil }
            let minX = CompactMetrics.rowMinX(in: globalRect(rect, in: layout), attached: true, side: side, slots: count)
            return (minX, minX + CompactMetrics.contentWidth(slots: count), count)
        }
        let left = group(layout.leftIndicatorRect, side: .left, slots: leftSlots)
        let right = group(layout.rightIndicatorRect, side: .right, slots: rightSlots)
        func distance(_ group: (minX: CGFloat, maxX: CGFloat, slots: Int)) -> CGFloat {
            grabPoint.x < group.minX ? group.minX - grabPoint.x : max(0, grabPoint.x - group.maxX)
        }
        let grabbedMinX: CGFloat, offset: CGFloat
        switch (left, right) {
        case (nil, nil):
            return CGPoint(x: layout.frame.midX, y: top)
        case (let only?, nil):
            grabbedMinX = only.minX; offset = 0
        case (nil, let only?):
            grabbedMinX = only.minX; offset = 0
        case (let l?, let r?):
            if distance(l) <= distance(r) { grabbedMinX = l.minX; offset = 0 }
            else { grabbedMinX = r.minX; offset = CGFloat(l.slots) * CompactMetrics.slotPitch }
        }
        let total = (left?.slots ?? 0) + (right?.slots ?? 0)
        let rowMinX = grabbedMinX - offset
        return CGPoint(x: rowMinX + CompactMetrics.contentWidth(slots: total) / 2, y: top)
    }

    // Layouts may interpolate only when the physical anchor is shared: the same
    // top edge and, attached, the same global camera (compact wings are asymmetric,
    // so equal midpoints are neither required nor sufficient); detached, the same center.
    static func sharesAnchor(_ a: DockLayout, _ b: DockLayout) -> Bool {
        let tolerance: CGFloat = 0.0005
        guard a.mode == b.mode, abs(a.frame.maxY - b.frame.maxY) <= tolerance else { return false }
        if a.mode == .notchConnected {
            let left = globalRect(a.cameraRect, in: a), right = globalRect(b.cameraRect, in: b)
            return abs(left.minX - right.minX) <= tolerance && abs(left.maxX - right.maxX) <= tolerance &&
                abs(left.minY - right.minY) <= tolerance && abs(left.maxY - right.maxY) <= tolerance
        }
        return abs(a.frame.midX - b.frame.midX) <= tolerance
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
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        func rect(_ a: CGRect, _ b: CGRect) -> CGRect {
            let x = min(width, max(0, mix(a.minX, b.minX)))
            let y = min(height, max(0, mix(a.minY, b.minY)))
            return CGRect(x: x, y: y,
                          width: min(width - x, max(0, mix(a.width, b.width))),
                          height: min(height - y, max(0, mix(a.height, b.height))))
        }
        // The camera and compact rows are mixed in screen space and only then expressed in the
        // interpolated frame, so a rect that is the same on screen at both ends stays exactly
        // there throughout, however the frame moves. An absent (empty) wing at one end holds the
        // other end's screen position instead of sweeping in from the frame origin.
        func screenFixed(_ pick: (DockLayout) -> CGRect) -> CGRect {
            let a = pick(from), b = pick(to)
            guard !a.isEmpty || !b.isEmpty else { return .zero }
            let ga = globalRect(a.isEmpty ? b : a, in: a.isEmpty ? to : from)
            let gb = globalRect(b.isEmpty ? a : b, in: b.isEmpty ? from : to)
            let mixed = CGRect(x: mix(ga.minX, gb.minX), y: mix(ga.minY, gb.minY),
                               width: mix(ga.width, gb.width), height: mix(ga.height, gb.height))
            let local = mixed.offsetBy(dx: -frame.minX, dy: -frame.minY).intersection(bounds)
            return local.isNull ? .zero : local
        }
        return DockLayout(frame: frame, mode: from.mode,
                          bodyRect: rect(from.bodyRect, to.bodyRect),
                          cameraRect: screenFixed { $0.cameraRect },
                          leftIndicatorRect: screenFixed { $0.leftIndicatorRect },
                          rightIndicatorRect: screenFixed { $0.rightIndicatorRect })
    }

    // AppKit owns the content view's realized size. Reconcile the drawing regions
    // when a requested fractional animation frame is rounded by the window.
    static func reconciled(_ layout: DockLayout, to frame: CGRect) -> DockLayout {
        func insetRect(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: rect.minY,
                   width: max(0, frame.width - rect.minX - (layout.frame.width - rect.maxX)),
                   height: max(0, frame.height - rect.minY - (layout.frame.height - rect.maxY)))
        }
        let bounds = CGRect(origin: .zero, size: frame.size)
        func screenFixed(_ rect: CGRect) -> CGRect {
            guard !rect.isEmpty else { return .zero }
            let moved = rect.offsetBy(dx: layout.frame.minX - frame.minX,
                                      dy: layout.frame.minY - frame.minY).intersection(bounds)
            return moved.isNull ? .zero : moved
        }
        // A detached row keeps its exact size, stays on the realized top edge and keeps its
        // centering when rounding widens the frame; both rows move together.
        let centeredShift = (frame.width - layout.frame.width) / 2
        func topAligned(_ rect: CGRect) -> CGRect {
            guard !rect.isEmpty else { return .zero }
            let moved = CGRect(x: rect.minX + centeredShift, y: frame.height - (layout.frame.height - rect.minY),
                               width: rect.width, height: rect.height).intersection(bounds)
            return moved.isNull ? .zero : moved
        }
        let attached = layout.mode == .notchConnected
        return DockLayout(frame: frame, mode: layout.mode, bodyRect: insetRect(layout.bodyRect),
                          cameraRect: screenFixed(layout.cameraRect),
                          leftIndicatorRect: attached ? screenFixed(layout.leftIndicatorRect) : topAligned(layout.leftIndicatorRect),
                          rightIndicatorRect: attached ? screenFixed(layout.rightIndicatorRect) : topAligned(layout.rightIndicatorRect))
    }
}

struct DockInteraction {
    private(set) var isHovered = false
    private(set) var isPinned = false
    private(set) var isMenuOpen = false
    private(set) var isDragging = false

    var presentation: DockPresentation {
        isHovered || isPinned || isMenuOpen || isDragging ? .expanded : .compact
    }

    mutating func setHover(_ value: Bool) { isHovered = value }
    mutating func setPinned(_ value: Bool) { isPinned = value }
    mutating func setMenuOpen(_ value: Bool) { isMenuOpen = value }
    mutating func setDragging(_ value: Bool) { isDragging = value }
    mutating func dismiss() {
        isHovered = false
        isPinned = false
        isMenuOpen = false
        isDragging = false
    }
}

// Only real pointer movement can release dismissal suppression. Tracking-area
// changes during a window resize must not count as leaving the hover target
// (the final compact frame while compact).
struct DockHoverGate {
    private(set) var requiresExit = false

    mutating func dismiss(pointerInsideTarget: Bool) {
        requiresExit = pointerInsideTarget
    }

    mutating func pointerMoved(insideTarget: Bool) {
        if !insideTarget { requiresExit = false }
    }
}

// One policy for every pointer entry path (tracking areas, global/local monitors,
// post-hold reconciliation, delayed entry). Compact previews from anywhere in the
// final compact frame (camera, rings, More/configure, padding, or the detached
// capsule); the compact target stays that final frame even while the window is
// still animating wider. Once a preview or pinned view is expanded, the whole
// current panel retains hover.
enum DockPointerPolicy {
    // The pointer can rest exactly on a screen/panel edge, so edges count as inside.
    static func contains(_ rect: CGRect, _ point: CGPoint) -> Bool {
        guard !rect.isEmpty, point.x.isFinite, point.y.isFinite else { return false }
        return point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
    }

    static func wantsHover(point: CGPoint, presentation: DockPresentation,
                           panelFrame: CGRect, compactTarget: CGRect) -> Bool {
        switch presentation {
        case .compact: return contains(compactTarget, point)
        case .expanded: return contains(panelFrame, point)
        }
    }
}

// Provider marks are presentation only: membership, clicks and persistence always
// use the real provider ID. Recognized real providers get familiar marks; anything
// else gets a deterministic initials fallback.
enum CompactMark {
    private static let rules: [(needle: String, mark: String)] = [
        ("codex", "CX"), ("opencodego", "GO"), ("minimax", "MM"), ("commandcode", "CC"),
        ("mistral", "MI"), ("anthropic", "AN"), ("claude", "AN")
    ]

    private static func normalized(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func initials(_ text: String) -> String? {
        let words = text.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        if words.count >= 2, let first = words[0].first, let second = words[1].first {
            return String([first, second]).uppercased()
        }
        guard let word = words.first else { return nil }
        return String(word.prefix(2)).uppercased()
    }

    static func monogram(provider: String, label: String) -> String {
        for source in [provider, label] {
            let key = normalized(source)
            for rule in rules where key.contains(rule.needle) { return rule.mark }
        }
        return initials(label) ?? initials(provider) ?? "?"
    }
}

// What one ring draws. The arc alone is clamped to 0...100; the exact value, the
// over-limit cue and every warning stay in the text and flags.
struct CompactRingPresentation: Equatable {
    enum Arc: Equatable {
        case unknown
        case fraction(Double)
    }

    let provider: String
    let label: String
    let mark: String
    let arc: Arc
    let severity: String
    let valueText: String
    let isOverLimit: Bool
    let hasWarning: Bool
    let isReported: Bool
    let tooltip: String
    let accessibilityLabel: String

    // Only a finite raw percentage above 100 is an overage; DashboardCard.hasIssue is not.
    static func isOverLimit(percent: Double?) -> Bool {
        guard let percent, percent.isFinite else { return false }
        return percent > 100
    }

    // nil and non-finite are unknown, never zero. Known zero is a real empty arc.
    static func arc(percent: Double?) -> Arc {
        guard let percent, percent.isFinite else { return .unknown }
        return .fraction(min(1, max(0, percent / 100)))
    }

    init(card: DashboardCard) {
        let over = Self.isOverLimit(percent: card.percent)
        let arc = Self.arc(percent: card.percent)
        provider = card.provider
        label = card.label
        mark = CompactMark.monogram(provider: card.provider, label: card.label)
        self.arc = arc
        severity = card.severity
        valueText = arc == .unknown ? "usage unknown" : card.value
        isOverLimit = over
        hasWarning = card.hasIssue
        isReported = true
        var lines: [String] = []
        if over { lines.append("Over limit: \(card.value) used") }
        else if arc == .unknown { lines.append("Usage unknown") }
        lines.append(card.tooltip)
        lines.append("Provider ID: \(card.provider)")
        tooltip = lines.joined(separator: "\n")
        var parts = [card.label, valueText]
        if over { parts.append("over limit") }
        if card.hasIssue { parts.append("attention required") }
        accessibilityLabel = parts.joined(separator: ", ")
    }

    // A selected provider that the current usage data does not contain. It keeps its
    // membership and shows no borrowed metric or identity. A supplied collection/source
    // issue (e.g. a first refresh failing after restart) stays visible as a warning —
    // never as a quota overage.
    init(missingProvider: String, label: String, issue: String = "") {
        let issue = issue.trimmingCharacters(in: .whitespacesAndNewlines)
        provider = missingProvider
        self.label = label
        mark = CompactMark.monogram(provider: missingProvider, label: label)
        arc = .unknown
        severity = "unknown"
        valueText = "not reported"
        isOverLimit = false
        hasWarning = !issue.isEmpty
        isReported = false
        var lines = [label, "Not reported in the current usage data"]
        if !issue.isEmpty { lines.append(issue) }
        lines.append("Provider ID: \(missingProvider)")
        tooltip = lines.joined(separator: "\n")
        accessibilityLabel = "\(label), not reported\(issue.isEmpty ? "" : ", attention required")"
    }
}

struct CompactMorePresentation: Equatable {
    let count: Int
    let text: String
    let hasWarning: Bool
    let tooltip: String
    let accessibilityLabel: String

    init(hidden: [CompactRingPresentation]) {
        count = hidden.count
        text = hidden.count > 99 ? "99+" : "+\(hidden.count)"
        hasWarning = hidden.contains { $0.hasWarning || $0.isOverLimit }
        let noun = hidden.count == 1 ? "provider" : "providers"
        var lines = ["\(hidden.count) more \(noun) — open the overview"]
        for entry in hidden.prefix(12) {
            var line = "• \(entry.label) — \(entry.valueText)"
            if entry.isOverLimit { line += " (over limit)" }
            else if entry.hasWarning { line += " (attention required)" }
            lines.append(line)
        }
        if hidden.count > 12 { lines.append("…and \(hidden.count - 12) more") }
        tooltip = lines.joined(separator: "\n")
        accessibilityLabel = "\(hidden.count) more \(noun)\(hasWarning ? ", attention required" : "")"
    }
}

struct CompactConfigurePresentation: Equatable {
    // Why no ring is shown: no choice was ever made, an explicit empty choice, or a saved choice whose providers
    // the latest successful collection no longer reports.
    enum Reason: Equatable { case uninitialized, noneSelected, noneConnected }

    let reason: Reason
    let hasIssue: Bool
    let tooltip: String
    let accessibilityLabel: String

    init(reason: Reason, issue: String, collecting: Bool) {
        self.reason = reason
        let issue = issue.trimmingCharacters(in: .whitespacesAndNewlines)
        hasIssue = !issue.isEmpty
        let hint: String
        switch reason {
        case .uninitialized: hint = "Choose which providers appear here"
        case .noneSelected: hint = "No providers selected — choose which providers appear here"
        case .noneConnected: hint = "No selected provider is connected — choose which providers appear here"
        }
        var lines = ["Compact display settings", hint]
        if collecting { lines.append("Collecting usage…") }
        if hasIssue { lines.append(issue) }
        tooltip = lines.joined(separator: "\n")
        accessibilityLabel = "Compact display settings\(hasIssue ? ", attention required" : "")"
    }
}

enum CompactSlot: Equatable {
    case provider(CompactRingPresentation)
    case more(CompactMorePresentation)
    case configure(CompactConfigurePresentation)

    // Stable view identity, so controls are reused across data refreshes.
    var key: String {
        switch self {
        case .provider(let ring): return "provider\u{0}\(ring.provider)"
        case .more: return "more"
        case .configure: return "configure"
        }
    }
}

struct CompactCapacities: Equatable {
    let left: Int
    let right: Int
    let total: Int
}

struct CompactSlotPlan: Equatable {
    let leftSlots: [CompactSlot]
    let rightSlots: [CompactSlot]
    let selectedCount: Int
    let hiddenProviderIDs: [String]

    var slots: [CompactSlot] { leftSlots + rightSlots }
    func slots(on side: CompactWingSide) -> [CompactSlot] { side == .left ? leftSlots : rightSlots }
}

enum CompactSlotPlanner {
    // `maximumVisibleSlots` is ONE budget for every compact control on both wings, including the
    // single aggregate More control. Membership is independent of it. Each provider keeps its own
    // wing (never moved to fit) and the wings are bounded independently by physical capacity.
    // On overflow one slot is reserved for More on the wing of the first provider that cannot be
    // shown; the remaining providers are then chosen greedily in their existing order. More lists
    // every hidden provider, whichever wing it prefers.
    //
    // `connectedProviders` is the last roster a successful collection CONFIRMED (nil until one did: first load,
    // restart; see ConnectedProviders, which keeps it through later stale/failed refreshes). A selected provider
    // the cards lack is drawn as a not-reported placeholder only while no roster is known; once it is known to be
    // disconnected it is simply not drawn. The saved selection is never rewritten, so a provider that
    // reconnects returns to its place.
    static func plan(cards: [DashboardCard], preferences: CompactPreferences,
                     physicalCapacity: CompactCapacities,
                     aliases: ExactConfigMap = [:], issue: String = "",
                     collecting: Bool = false,
                     connectedProviders: Set<ExactString>? = nil) -> CompactSlotPlan {
        let preferences = preferences.normalized
        let selected = preferences.selectedProviderIDs ?? []
        // Membership is by exact string identity (never Swift canonical equivalence), like every provider ID.
        let selectedSet = Set(selected.map(\.exactKey))
        var firstCard: [ExactString: DashboardCard] = [:]
        for card in cards where firstCard[card.provider.exactKey] == nil { firstCard[card.provider.exactKey] = card }
        // Current upstream order first; selected IDs the data lacks (and that are not known to be
        // disconnected) follow in selection order.
        func stillConnected(_ id: String) -> Bool { connectedProviders?.contains(id.exactKey) ?? true }
        var entries: [CompactRingPresentation] = []
        var included = Set<ExactString>()
        for card in cards where selectedSet.contains(card.provider.exactKey) && included.insert(card.provider.exactKey).inserted {
            entries.append(CompactRingPresentation(card: card))
        }
        for id in selected where firstCard[id.exactKey] == nil && stillConnected(id) {
            entries.append(CompactRingPresentation(missingProvider: id, label: aliases[id] ?? id, issue: issue))
        }
        let sides = entries.map { preferences.side(for: $0.provider) }
        // A wing may have genuinely zero physical room; nothing is forced into it. At least one wing
        // must exist for the plan to show anything, so a fully degenerate input keeps the right wing.
        let leftLimit = max(0, physicalCapacity.left)
        var rightLimit = max(0, physicalCapacity.right)
        if leftLimit == 0 && rightLimit == 0 { rightLimit = 1 }
        guard !entries.isEmpty else {
            let reason: CompactConfigurePresentation.Reason = preferences.selectedProviderIDs == nil ? .uninitialized
                : selected.isEmpty ? .noneSelected : .noneConnected
            let configure = [CompactSlot.configure(CompactConfigurePresentation(
                reason: reason, issue: issue, collecting: collecting))]
            // The default wing, unless it has no physical room at all.
            let onLeft = preferences.defaultSide == .left ? leftLimit > 0 : rightLimit == 0
            return CompactSlotPlan(leftSlots: onLeft ? configure : [], rightSlots: onLeft ? [] : configure,
                                   selectedCount: 0, hiddenProviderIDs: [])
        }
        let budget = max(1, min(preferences.maximumVisibleSlots, max(1, physicalCapacity.total)))

        // Greedy in existing order: a provider whose wing is full is skipped (never moved),
        // and choosing stops once the total ring budget is spent.
        func choose(rings: Int, left: Int, right: Int) -> [Bool] {
            var shown = [Bool](repeating: false, count: entries.count)
            var leftUsed = 0, rightUsed = 0, total = 0
            for index in entries.indices {
                guard total < rings else { break }
                if sides[index] == .left {
                    guard leftUsed < left else { continue }
                    leftUsed += 1
                } else {
                    guard rightUsed < right else { continue }
                    rightUsed += 1
                }
                shown[index] = true
                total += 1
            }
            return shown
        }

        var shown = choose(rings: budget, left: leftLimit, right: rightLimit)
        var moreSide: CompactWingSide?
        if shown.contains(false) {
            // One slot of the single budget goes to More, on the wing of the first hidden provider.
            let probe = choose(rings: budget - 1, left: leftLimit, right: rightLimit)
            var side = sides[probe.firstIndex(of: false) ?? 0]
            // More is a real control too: only a wing with genuinely zero physical room hands it to
            // the other wing. Provider rings themselves are never moved.
            if side == .left, leftLimit == 0 { side = .right }
            else if side == .right, rightLimit == 0 { side = .left }
            shown = choose(rings: budget - 1,
                           left: leftLimit - (side == .left ? 1 : 0),
                           right: rightLimit - (side == .right ? 1 : 0))
            moreSide = side
        }
        let hidden = entries.indices.filter { !shown[$0] }.map { entries[$0] }
        func wing(_ side: CompactWingSide) -> [CompactSlot] {
            var result = entries.indices.filter { shown[$0] && sides[$0] == side }.map { CompactSlot.provider(entries[$0]) }
            if moreSide == side { result.append(.more(CompactMorePresentation(hidden: hidden))) }
            return result
        }
        return CompactSlotPlan(leftSlots: wing(.left), rightSlots: wing(.right),
                               selectedCount: entries.count, hiddenProviderIDs: hidden.map { $0.provider })
    }
}
