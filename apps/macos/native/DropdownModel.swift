import Foundation
import CoreGraphics

/// One row of the shared custom dropdown. `id` is an opaque, stable presentation identity (never displayed);
/// duplicate titles stay distinct rows. `action` captures the typed domain value, so a choice is never derived
/// from the title or from a mutable row index.
struct DropdownItem {
    let id: String
    let title: String
    let subtitle: String?
    let mark: String?
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void

    init(id: String, title: String, subtitle: String? = nil, mark: String? = nil,
         isSelected: Bool = false, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.mark = mark
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.action = action
    }
}

/// `selection`: the popup becomes the key window and owns the keyboard (provider/account pickers).
/// `preserveEditor`: the popup never becomes key; the owning text editor keeps focus and marked text, and the owner
/// forwards navigation through `DropdownPopupController.navigate`.
enum DropdownFocusMode { case selection, preserveEditor }

enum DropdownNavigation { case up, down, first, last, activate, cancel }

/// What one navigation command did to the list.
enum DropdownOutcome: Equatable {
    /// The highlight moved to this row.
    case moved(Int)
    /// Handled, but the highlight stayed put (already at an end, or already on the target).
    case unchanged
    /// Activate this row.
    case activate(Int)
    case cancel
    /// Nothing to act on (no enabled row, or activate without a highlight): the key belongs to the caller.
    case ignored
}

/// Highlight state of the list, independent of AppKit. Disabled rows are never highlighted and are skipped.
/// Movement clamps at both ends; it does not wrap.
struct DropdownListState: Equatable {
    struct Row: Equatable {
        let id: String
        let isEnabled: Bool
        let isSelected: Bool
    }

    /// `automatic`: start on the selected enabled row, else the first enabled row (pickers own the keyboard).
    /// `explicit`: start with no highlight so Return never commits a row the user did not choose (text editors).
    enum Highlighting { case automatic, explicit }

    private(set) var rows: [Row]
    private(set) var highlighted: Int?
    let highlighting: Highlighting

    init(rows: [Row], highlighting: Highlighting) {
        self.rows = rows
        self.highlighting = highlighting
        highlighted = nil
        highlighted = initialHighlight()
    }

    private var enabledIndices: [Int] { rows.indices.filter { rows[$0].isEnabled } }

    private func initialHighlight() -> Int? {
        guard highlighting == .automatic else { return nil }
        return rows.firstIndex(where: { $0.isSelected && $0.isEnabled }) ?? rows.firstIndex(where: \.isEnabled)
    }

    /// The CURRENT row for a stable id, only while it is present and enabled. Row activation resolves through this at
    /// the moment of the click, so a list that was reordered or pruned while a press was in flight can never run a
    /// different or removed choice; an index captured earlier is never trusted.
    func enabledIndex(forID id: String) -> Int? {
        rows.firstIndex(where: { $0.id == id && $0.isEnabled })
    }

    /// The row to scroll into view: the highlighted row, else the selected row.
    var revealIndex: Int? { highlighted ?? rows.firstIndex(where: \.isSelected) }

    /// Replaces the rows (same popup, same anchor). The highlight follows its row by id when that row is still
    /// enabled; otherwise it falls back to the initial rule.
    mutating func replace(rows newRows: [Row]) {
        let previousID = highlighted.map { rows[$0].id }
        rows = newRows
        if let previousID, let index = newRows.firstIndex(where: { $0.id == previousID && $0.isEnabled }) {
            highlighted = index
        } else {
            highlighted = initialHighlight()
        }
    }

    /// Pointer hover. Returns whether the highlight changed. Disabled and out-of-range rows are ignored.
    @discardableResult
    mutating func hover(_ index: Int) -> Bool {
        guard rows.indices.contains(index), rows[index].isEnabled, highlighted != index else { return false }
        highlighted = index
        return true
    }

    mutating func apply(_ command: DropdownNavigation) -> DropdownOutcome {
        let enabled = enabledIndices
        switch command {
        case .cancel:
            return .cancel
        case .activate:
            guard let highlighted, rows.indices.contains(highlighted), rows[highlighted].isEnabled else { return .ignored }
            return .activate(highlighted)
        case .up, .down, .first, .last:
            guard let first = enabled.first, let last = enabled.last else { return .ignored }
            let target: Int
            switch command {
            case .first: target = first
            case .last: target = last
            case .down:
                if let highlighted { target = enabled.first(where: { $0 > highlighted }) ?? highlighted } else { target = first }
            default:
                if let highlighted { target = enabled.last(where: { $0 < highlighted }) ?? highlighted } else { target = last }
            }
            guard target != highlighted else { return .unchanged }
            highlighted = target
            return .moved(target)
        }
    }
}

/// Fixed list geometry and screen placement.
enum DropdownMetrics {
    static let listInset: CGFloat = 6
    static let minimumWidth: CGFloat = 168
    static let maximumWidth: CGFloat = 380
    static let maximumVisibleRows = 9
    static let gap: CGFloat = 4

    static func rowHeight(hasSubtitle: Bool) -> CGFloat { hasSubtitle ? 38 : 28 }

    /// Full (unscrolled) height of the rows plus the vertical insets.
    static func contentHeight(rowCount: Int, rowHeight: CGFloat) -> CGFloat {
        CGFloat(max(rowCount, 1)) * rowHeight + listInset * 2
    }

    /// Height before the screen clamp: the content, capped at `maximumVisibleRows` rows.
    static func cappedHeight(rowCount: Int, rowHeight: CGFloat) -> CGFloat {
        min(contentHeight(rowCount: rowCount, rowHeight: rowHeight),
            CGFloat(maximumVisibleRows) * rowHeight + listInset * 2)
    }

    /// Content width, at least as wide as the anchor (never below `minimumWidth`) and never above `maximumWidth`.
    static func width(content: CGFloat, anchorWidth: CGFloat) -> CGFloat {
        min(maximumWidth, max(content, anchorWidth, minimumWidth))
    }
}

enum DropdownPlacement {
    /// Frame in AppKit screen coordinates (bottom-left origin, nonzero origins allowed). Prefers below the anchor with
    /// its leading edge aligned, flips above when that is the only side the full height fits, and otherwise takes the
    /// side with more room and shrinks to it. The result always lies inside `visible`.
    static func frame(anchor: CGRect, size: CGSize, visible: CGRect, gap: CGFloat = DropdownMetrics.gap) -> CGRect {
        let width = min(size.width, visible.width)
        var x = anchor.minX
        if x + width > visible.maxX { x = visible.maxX - width }
        if x < visible.minX { x = visible.minX }

        let below = anchor.minY - gap - visible.minY
        let above = visible.maxY - (anchor.maxY + gap)
        var height = min(size.height, visible.height)
        var y: CGFloat
        if height <= below {
            y = anchor.minY - gap - height
        } else if height <= above {
            y = anchor.maxY + gap
        } else if below >= above, below > 0 {
            height = min(height, below)
            y = anchor.minY - gap - height
        } else if above > 0 {
            height = min(height, above)
            y = anchor.maxY + gap
        } else {
            // The anchor is outside the visible frame: keep the list on screen.
            y = visible.maxY - height
        }
        y = min(max(y, visible.minY), visible.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
