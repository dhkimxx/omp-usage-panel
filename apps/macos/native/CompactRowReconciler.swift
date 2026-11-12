import AppKit

// Keeps the two compact wing containers' ACTUAL subview hierarchy equal to the desired ordered views.
// Views keep their identity; a view may move directly between wings. Every changed container is emptied of
// its stale children before ANY desired child is attached, so a reparent into one wing can never be undone by
// the other wing's cleanup. Comparison uses actual parent/subview identity and order, not remembered arrays,
// so an already orphaned cached view is repaired even when the desired arrays did not change.
final class CompactRowReconciler {
    let leftContainer: NSView
    let rightContainer: NSView
    private(set) var leftItems: [NSView] = []
    private(set) var rightItems: [NSView] = []

    init(left: NSView, right: NSView) {
        leftContainer = left; rightContainer = right
    }

    private static func matches(_ container: NSView, _ desired: [NSView]) -> Bool {
        let actual = container.subviews
        return actual.count == desired.count && zip(actual, desired).allSatisfy { $0.0 === $0.1 }
    }

    // Returns true when the actual hierarchy changed.
    @discardableResult
    func apply(left: [NSView], right: [NSView]) -> Bool {
        leftItems = left; rightItems = right
        let leftChanged = !Self.matches(leftContainer, left)
        let rightChanged = !Self.matches(rightContainer, right)
        guard leftChanged || rightChanged else { return false }
        // Phase 1: detach from every changed container, including children that are no longer wanted.
        if leftChanged { leftContainer.subviews.forEach { $0.removeFromSuperview() } }
        if rightChanged { rightContainer.subviews.forEach { $0.removeFromSuperview() } }
        // Phase 2: attach. A desired view still parented elsewhere (an unchanged container cannot hold one that is
        // desired in the other wing, since then that container would not match) is moved by addSubview.
        if leftChanged { left.forEach { leftContainer.addSubview($0) } }
        if rightChanged { right.forEach { rightContainer.addSubview($0) } }
        return true
    }
}
