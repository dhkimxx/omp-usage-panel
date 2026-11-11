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
    static func bounded(_ slots: Int) -> Int { min(max(slots, 1), slotLimit) }
    static func contentWidth(slots: Int) -> CGFloat {
        let n = CGFloat(bounded(slots))
        return n * ringDiameter + (n - 1) * gap
    }
    // 26n + 12: camera-side and outer padding around the row.
    static func wingWidth(_ slots: Int) -> CGFloat { contentWidth(slots: slots) + cameraPadding + outerPadding }
    // 26n + 20: the detached capsule is content plus 24pt.
    static func floatingWidth(slots: Int) -> CGFloat { contentWidth(slots: slots) + 2 * floatingPadding }

    // Left edge of the compact row inside its indicator region: attached rows start at the
    // camera-side padding (overflowing outward); detached rows are centered.
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

    // Physical slot capacity (always at least one) for the placement `layout` would choose.
    static func compactCapacity(screen: DockScreenMetrics, side: CompactWingSide,
                                manualTopCenter: CGPoint? = nil) -> Int {
        let frame = screen.frame
        guard finite(frame), frame.width > 0 else { return 1 }
        if manualTopCenter == nil, notch(in: screen) != nil {
            return CompactMetrics.capacity(forWingWidth: maximumWing(screen: screen, side: side))
        }
        return CompactMetrics.floatingCapacity(forWidth: frame.width - 2 * min(8, frame.width / 4))
    }

    static func layout(screen: DockScreenMetrics, presentation: DockPresentation,
                       preferredExpandedSize: CGSize, compactSlots: Int,
                       side: CompactWingSide = .right,
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
            let wingLimit = maximumWing(screen: screen, side: side)
            let slots = min(max(compactSlots, 1), CompactMetrics.capacity(forWingWidth: wingLimit))
            let wing = min(CompactMetrics.wingWidth(slots), wingLimit)
            let compactHeight = min(max(cameraHeight, CompactMetrics.rowHeight), availableHeight)
            let availableWidth = 2 * min(notch.center - frame.minX - margin,
                                         frame.maxX - margin - notch.center)
            let desiredWidth = isCompact ? notch.width + wing :
                max(preferredExpandedSize.width, notch.width + 200) + 36
            let width = isCompact ? desiredWidth : min(desiredWidth, availableWidth)
            let minimumHeight = cameraHeight + stripHeight
            let height = isCompact ? compactHeight :
                min(max(preferredExpandedSize.height, minimumHeight), availableHeight)
            guard width.isFinite, height.isFinite, wing > 0, width >= notch.width, height >= cameraHeight else { return nil }
            let notchLeft = screen.auxiliaryTopLeft.maxX
            let notchRight = screen.auxiliaryTopRight.minX
            let frameMinX = isCompact ? (side == .right ? notchLeft : notchLeft - wing)
                                      : notch.center - width / 2
            let bodyInset = isCompact ? 0 : min(18, (width - notch.width) / 2)
            let body = CGRect(x: bodyInset, y: 0, width: width - 2 * bodyInset, height: height)
            let camera = CGRect(x: notchLeft - frameMinX, y: height - cameraHeight,
                                width: notch.width, height: cameraHeight)
            // The wing sits beside the camera; no row hangs below it. Expanded layouts keep
            // the same global wing (clipped to the frame) so fading controls never jump.
            let wingX = side == .right ? notchRight : notchLeft - wing
            let indicators = CGRect(x: wingX - frameMinX, y: height - compactHeight,
                                    width: wing, height: compactHeight)
                .intersection(CGRect(x: 0, y: 0, width: width, height: height))
            return DockLayout(frame: CGRect(x: frameMinX, y: frame.maxY - height,
                                             width: width, height: height),
                              mode: .notchConnected, bodyRect: body,
                              cameraRect: camera, indicatorRect: indicators.isNull ? .zero : indicators)
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
        // Capacity is derived from the width before any slot count becomes a length.
        let slots = min(max(compactSlots, 1), CompactMetrics.floatingCapacity(forWidth: availableWidth))
        let compactWidth = CompactMetrics.floatingWidth(slots: slots)
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
        let stripWidth = min(compactWidth, width)
        return DockLayout(frame: CGRect(x: center - width / 2, y: top - height, width: width, height: height),
                          mode: .floating, bodyRect: body, cameraRect: .zero,
                          indicatorRect: CGRect(x: (width - stripWidth) / 2, y: height - stripHeight,
                                                width: stripWidth, height: stripHeight))
    }

    static func globalRect(_ rect: CGRect, in layout: DockLayout) -> CGRect {
        rect.offsetBy(dx: layout.frame.minX, dy: layout.frame.minY)
    }

    // The visible compact row's top-center in screen space. Attached rows hug the camera side
    // of the wing (asymmetric padding) and detached rows are centered, so this is not the
    // frame's midpoint. A drag that grabs a ring must anchor here to follow the pointer exactly.
    static func compactDragAnchor(_ layout: DockLayout, side: CompactWingSide, slots: Int) -> CGPoint {
        let indicator = globalRect(layout.indicatorRect, in: layout)
        let minX = CompactMetrics.rowMinX(in: indicator, attached: layout.mode == .notchConnected,
                                          side: side, slots: slots)
        return CGPoint(x: minX + CompactMetrics.contentWidth(slots: slots) / 2, y: indicator.maxY)
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
        let indicators: CGRect
        if layout.mode == .notchConnected {
            indicators = screenFixed(layout.indicatorRect)
        } else {
            let rect = layout.indicatorRect
            indicators = CGRect(x: rect.minX, y: frame.height - (layout.frame.height - rect.minY),
                                width: max(0, frame.width - rect.minX - (layout.frame.width - rect.maxX)),
                                height: rect.height).intersection(bounds)
        }
        return DockLayout(frame: frame, mode: layout.mode, bodyRect: insetRect(layout.bodyRect),
                          cameraRect: screenFixed(layout.cameraRect), indicatorRect: indicators)
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
    let hasIssue: Bool
    let tooltip: String
    let accessibilityLabel: String

    init(uninitialized: Bool, issue: String, collecting: Bool) {
        let issue = issue.trimmingCharacters(in: .whitespacesAndNewlines)
        hasIssue = !issue.isEmpty
        var lines = ["Compact display settings",
                     uninitialized ? "Choose which providers appear here"
                                   : "No providers selected — choose which providers appear here"]
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

struct CompactSlotPlan: Equatable {
    let slots: [CompactSlot]
    let selectedCount: Int
    let hiddenProviderIDs: [String]
}

enum CompactSlotPlanner {
    // `maximumVisibleSlots` counts every compact control including More. Membership is
    // independent of it: n selected providers over capacity c show c-1 rings and
    // More(+n-c+1); c == 1 shows only More(+n). Rings never shrink to fit more.
    static func plan(cards: [DashboardCard], selectedProviderIDs: [String]?,
                     maximumVisibleSlots: Int, physicalCapacity: Int,
                     aliases: ExactConfigMap = [:], issue: String = "",
                     collecting: Bool = false) -> CompactSlotPlan {
        var seen = Set<String>()
        let selected = (selectedProviderIDs ?? []).filter { seen.insert($0).inserted }
        var firstCard: [String: DashboardCard] = [:]
        for card in cards where firstCard[card.provider] == nil { firstCard[card.provider] = card }
        // Current upstream order first; selected IDs the data lacks follow in selection order.
        var entries: [CompactRingPresentation] = []
        var included = Set<String>()
        for card in cards where seen.contains(card.provider) && included.insert(card.provider).inserted {
            entries.append(CompactRingPresentation(card: card))
        }
        for id in selected where firstCard[id] == nil {
            entries.append(CompactRingPresentation(missingProvider: id, label: aliases[id] ?? id, issue: issue))
        }
        guard !entries.isEmpty else {
            return CompactSlotPlan(
                slots: [.configure(CompactConfigurePresentation(uninitialized: selectedProviderIDs == nil,
                                                                issue: issue, collecting: collecting))],
                selectedCount: 0, hiddenProviderIDs: [])
        }
        let capacity = max(1, min(maximumVisibleSlots, max(1, physicalCapacity)))
        if entries.count <= capacity {
            return CompactSlotPlan(slots: entries.map { .provider($0) }, selectedCount: entries.count,
                                   hiddenProviderIDs: [])
        }
        let shown = capacity - 1
        let hidden = Array(entries.dropFirst(shown))
        var slots: [CompactSlot] = entries.prefix(shown).map { CompactSlot.provider($0) }
        slots.append(.more(CompactMorePresentation(hidden: hidden)))
        return CompactSlotPlan(slots: slots, selectedCount: entries.count,
                               hiddenProviderIDs: hidden.map { $0.provider })
    }
}
