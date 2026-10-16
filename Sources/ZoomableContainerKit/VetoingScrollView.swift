//
//  VetoingScrollView.swift
//  ZoomableContainerKit
//
//  UIScrollView subclass used by `ZoomableContainer`. Responsibilities:
//    - Consult `panVeto` before the built-in pan begins (single-finger
//      drag on an element yields to SwiftUI's per-element DragGesture).
//    - Consult `builtInPinchShouldBegin` before the built-in pinch begins
//      (two fingers on two different elements ⇒ two drags, not a zoom).
//    - Consult `hitTestBypass` to fall through to chrome beneath.
//    - Fire `onLayout` after every layout pass with non-zero bounds —
//      `updateUIView` can fire once with `.zero` bounds and not re-fire,
//      and does not fire at all on a size-only change (a fold, a turn), so
//      the initial zoom and the re-framing after a resize need this trigger.
//

import UIKit

final class VetoingScrollView: UIScrollView {
    var panVeto: (@MainActor (CGPoint) -> Bool)?
    var hitTestBypass: (@MainActor (CGPoint) -> Bool)?
    /// Gate for the *built-in* pinch (the one that actually zooms). The
    /// container wires this to the coordinator's veto so a two-cards touch
    /// suppresses zoom as well as the tap-cancel arbitrator.
    var builtInPinchShouldBegin: (@MainActor (UIPinchGestureRecognizer) -> Bool)?
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width > 0, bounds.height > 0 { onLayout?() }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer, let veto = panVeto {
            let viewPoint = panGestureRecognizer.location(in: self)
            let contentPoint = CGPoint(
                x: (viewPoint.x + contentOffset.x) / max(zoomScale, 0.0001),
                y: (viewPoint.y + contentOffset.y) / max(zoomScale, 0.0001)
            )
            if veto(contentPoint) { return false }
        }
        if let pinch = gestureRecognizer as? UIPinchGestureRecognizer,
           pinch === pinchGestureRecognizer,
           let gate = builtInPinchShouldBegin,
           !gate(pinch) {
            return false
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let bypass = hitTestBypass {
            let globalPoint = convert(point, to: nil)
            if bypass(globalPoint) { return nil }
        }
        return super.hitTest(point, with: event)
    }
}
