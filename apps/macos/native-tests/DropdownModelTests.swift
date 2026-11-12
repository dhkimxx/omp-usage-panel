import Foundation
import CoreGraphics

func runDropdownModelTests() {
    func rows(_ spec: [(String, Bool, Bool)]) -> [DropdownListState.Row] {
        spec.map { .init(id: $0.0, isEnabled: $0.1, isSelected: $0.2) }
    }

    // Automatic start: the selected enabled row, else the first enabled row (never a disabled one).
    precondition(DropdownListState(rows: rows([("a", false, false), ("b", true, false), ("c", true, true)]),
                                   highlighting: .automatic).highlighted == 2)
    precondition(DropdownListState(rows: rows([("a", false, false), ("b", true, false)]),
                                   highlighting: .automatic).highlighted == 1)
    precondition(DropdownListState(rows: rows([("a", true, true), ("b", true, false)]),
                                   highlighting: .explicit).highlighted == nil)

    // Movement skips disabled rows and clamps at both ends; duplicate titles are irrelevant to identity.
    var state = DropdownListState(rows: rows([("a", true, false), ("b", false, false), ("c", true, false), ("d", true, false)]),
                                  highlighting: .automatic)
    precondition(state.highlighted == 0)
    precondition(state.apply(.down) == .moved(2))
    precondition(state.apply(.down) == .moved(3))
    precondition(state.apply(.down) == .unchanged && state.highlighted == 3)
    precondition(state.apply(.up) == .moved(2))
    precondition(state.apply(.first) == .moved(0))
    precondition(state.apply(.first) == .unchanged)
    precondition(state.apply(.up) == .unchanged && state.highlighted == 0)
    precondition(state.apply(.last) == .moved(3))

    // From no highlight: Down enters at the first enabled row, Up at the last. Activate needs a highlight.
    var editor = DropdownListState(rows: rows([("a", false, false), ("b", true, false), ("c", true, false)]), highlighting: .explicit)
    precondition(editor.apply(.activate) == .ignored)
    precondition(editor.apply(.up) == .moved(2))
    var editor2 = DropdownListState(rows: editor.rows, highlighting: .explicit)
    precondition(editor2.apply(.down) == .moved(1))
    precondition(editor2.apply(.activate) == .activate(1))
    precondition(editor2.apply(.cancel) == .cancel)

    // Nothing enabled or nothing listed: movement and activation belong to the caller; cancel is still handled.
    var inert = DropdownListState(rows: rows([("a", false, false)]), highlighting: .automatic)
    precondition(inert.highlighted == nil)
    precondition(inert.apply(.down) == .ignored && inert.apply(.activate) == .ignored && inert.apply(.cancel) == .cancel)
    var none = DropdownListState(rows: [], highlighting: .automatic)
    precondition(none.apply(.last) == .ignored && none.revealIndex == nil)

    // Hover never highlights a disabled or missing row and reports real changes only.
    var hover = DropdownListState(rows: rows([("a", true, false), ("b", false, false)]), highlighting: .explicit)
    precondition(!hover.hover(1) && !hover.hover(9) && hover.highlighted == nil)
    precondition(hover.hover(0) && !hover.hover(0))

    // Replacing rows keeps the highlight on the same id even when it moves; otherwise it falls back.
    var replaced = DropdownListState(rows: rows([("a", true, false), ("b", true, false)]), highlighting: .explicit)
    _ = replaced.hover(1)
    replaced.replace(rows: rows([("x", true, false), ("b", true, false)]))
    precondition(replaced.highlighted == 1)
    replaced.replace(rows: rows([("b", false, false), ("y", true, false)]))
    precondition(replaced.highlighted == nil)
    var auto = DropdownListState(rows: rows([("a", true, false)]), highlighting: .automatic)
    auto.replace(rows: rows([("p", true, false), ("q", true, true)]))
    precondition(auto.highlighted == 1 && auto.revealIndex == 1)
    // An explicit-mode list reveals its selected row without highlighting it.
    precondition(DropdownListState(rows: rows([("a", true, false), ("b", true, true)]), highlighting: .explicit).revealIndex == 1)

    // Activation resolves by stable id against the CURRENT rows: reorder follows the id, removed or disabled rows
    // resolve to nothing, and duplicate titles are distinct because only ids are compared.
    var resolving = DropdownListState(rows: rows([("p", true, false), ("q", true, false), ("r", true, false)]), highlighting: .explicit)
    precondition(resolving.enabledIndex(forID: "q") == 1)
    resolving.replace(rows: rows([("r", true, false), ("q", true, false), ("p", true, false)]))
    precondition(resolving.enabledIndex(forID: "p") == 2 && resolving.enabledIndex(forID: "r") == 0)
    resolving.replace(rows: rows([("r", true, false), ("p", false, false)]))
    precondition(resolving.enabledIndex(forID: "q") == nil && resolving.enabledIndex(forID: "p") == nil)
    precondition(resolving.enabledIndex(forID: "missing") == nil)

    // Width: anchor-wide minimum, hard maximum.
    precondition(DropdownMetrics.width(content: 50, anchorWidth: 90) == DropdownMetrics.minimumWidth)
    precondition(DropdownMetrics.width(content: 50, anchorWidth: 240) == 240)
    precondition(DropdownMetrics.width(content: 900, anchorWidth: 240) == DropdownMetrics.maximumWidth)
    let row = DropdownMetrics.rowHeight(hasSubtitle: false)
    precondition(DropdownMetrics.cappedHeight(rowCount: 100, rowHeight: row) ==
                 CGFloat(DropdownMetrics.maximumVisibleRows) * row + DropdownMetrics.listInset * 2)
    precondition(DropdownMetrics.contentHeight(rowCount: 0, rowHeight: row) == row + DropdownMetrics.listInset * 2)

    // Placement on a screen with a nonzero origin (AppKit bottom-left coordinates).
    let visible = CGRect(x: -1000, y: 50, width: 1000, height: 650)
    let size = CGSize(width: 200, height: 300)
    let below = DropdownPlacement.frame(anchor: CGRect(x: -800, y: 600, width: 60, height: 24), size: size, visible: visible)
    precondition(below == CGRect(x: -800, y: 600 - DropdownMetrics.gap - 300, width: 200, height: 300))
    // Near the bottom it flips above when the full height fits there.
    let flipped = DropdownPlacement.frame(anchor: CGRect(x: -800, y: 100, width: 60, height: 24), size: size, visible: visible)
    precondition(flipped.minY == 124 + DropdownMetrics.gap && flipped.height == 300)
    // Near the right edge it shifts left; it never leaves the visible frame; too tall shrinks to the larger side.
    let edge = DropdownPlacement.frame(anchor: CGRect(x: -20, y: 600, width: 20, height: 24), size: size, visible: visible)
    precondition(edge.maxX == visible.maxX && edge.minX >= visible.minX)
    let tall = DropdownPlacement.frame(anchor: CGRect(x: -800, y: 400, width: 60, height: 24),
                                       size: CGSize(width: 200, height: 640), visible: visible)
    precondition(tall.minY >= visible.minY && tall.maxY <= visible.maxY && tall.height < 640)
    let off = DropdownPlacement.frame(anchor: CGRect(x: 5000, y: 5000, width: 20, height: 20), size: size, visible: visible)
    precondition(visible.contains(off))
}
