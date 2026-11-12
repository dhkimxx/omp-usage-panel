import AppKit

// Exercises the real NSView/NSButton hierarchy; no callbacks or mocks.
@main struct CompactRowReconcilerTests {
    static func button(_ title: String) -> NSButton {
        let button = NSButton(frame: .zero); button.title = title; return button
    }
    static func rig() -> (CompactRowReconciler, NSView, NSView, [String: NSButton]) {
        let left = NSView(), right = NSView()
        let buttons = Dictionary(uniqueKeysWithValues: ["codex", "go", "mini", "cmd"].map { ($0, button($0)) })
        return (CompactRowReconciler(left: left, right: right), left, right, buttons)
    }
    static func expect(_ container: NSView, _ views: [NSView], _ message: String) {
        precondition(container.subviews.count == views.count
                     && zip(container.subviews, views).allSatisfy { $0.0 === $0.1 }, message)
        precondition(views.allSatisfy { $0.superview === container }, message)
    }
    static func main() {
        // Direct cached RIGHT -> LEFT: the moved view must stay attached to its new parent.
        do {
            let (rows, left, right, b) = rig()
            rows.apply(left: [], right: [b["codex"]!, b["go"]!, b["mini"]!])
            let identity = b["codex"]!
            rows.apply(left: [b["codex"]!], right: [b["go"]!, b["mini"]!])
            expect(left, [identity], "moved view must remain in left wing")
            expect(right, [b["go"]!, b["mini"]!], "right wing keeps remaining views in order")
            precondition(identity.superview === left)
        }
        // Simultaneous swap between wings.
        do {
            let (rows, left, right, b) = rig()
            rows.apply(left: [b["codex"]!, b["go"]!], right: [b["mini"]!, b["cmd"]!])
            rows.apply(left: [b["mini"]!, b["cmd"]!], right: [b["codex"]!, b["go"]!])
            expect(left, [b["mini"]!, b["cmd"]!], "left receives former right views")
            expect(right, [b["codex"]!, b["go"]!], "right receives former left views")
        }
        // Reorder within one wing and removal of a view that is no longer desired.
        do {
            let (rows, left, right, b) = rig()
            rows.apply(left: [b["codex"]!, b["go"]!], right: [b["mini"]!])
            rows.apply(left: [b["go"]!, b["codex"]!], right: [])
            expect(left, [b["go"]!, b["codex"]!], "reorder is applied")
            expect(right, [], "stale right child is detached")
            precondition(b["mini"]!.superview == nil)
        }
        // Unchanged reapply keeps identity, order and parents, and reports no hierarchy change.
        do {
            let (rows, left, right, b) = rig()
            rows.apply(left: [b["codex"]!], right: [b["go"]!])
            precondition(rows.apply(left: [b["codex"]!], right: [b["go"]!]) == false)
            expect(left, [b["codex"]!], "left unchanged"); expect(right, [b["go"]!], "right unchanged")
        }
        // Orphan repair: a cached view detached behind the reconciler's back is reattached with identical desired arrays.
        do {
            let (rows, left, right, b) = rig()
            rows.apply(left: [b["codex"]!], right: [b["go"]!, b["mini"]!])
            b["codex"]!.removeFromSuperview()
            precondition(rows.apply(left: [b["codex"]!], right: [b["go"]!, b["mini"]!]) == true)
            expect(left, [b["codex"]!], "orphaned view repaired")
            expect(right, [b["go"]!, b["mini"]!], "unaffected wing preserved")
        }
        // Orphan that was reparented to the wrong wing is repaired too.
        do {
            let (rows, left, right, b) = rig()
            rows.apply(left: [b["codex"]!], right: [b["go"]!])
            right.addSubview(b["codex"]!)
            rows.apply(left: [b["codex"]!], right: [b["go"]!])
            expect(left, [b["codex"]!], "view returned to desired wing")
            expect(right, [b["go"]!], "wrong-wing child removed")
        }
    }
}
