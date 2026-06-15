//
//  ZoomMath.swift
//  ZoomableContainerKit
//
//  Pure (stateless, UIKit-free) helpers behind `ZoomableContainer`. Kept
//  separate so the behaviour is unit-testable without a running scroll
//  view. Native UIScrollView pinch now owns zoom + focal anchoring, so the
//  old rubber-band / focal-offset helpers are gone; what remains is the
//  fit-zoom math, the drone-camera bottom-anchor clamp, the two-finger
//  pinch veto, and the deterministic double-tap rect.
//
//  Mostly internal — the apps reach the gesture math only through
//  `ZoomableContainer`. `fitZoom` is public because hosts legitimately reuse
//  the contain-fit formula for their own layout (e.g. sizing a hand region to
//  the camera's zoom floor). Tests use `@testable import ZoomableContainerKit`.
//

import CoreGraphics

public enum ZoomMath {

    // MARK: - Fit zoom

    /// "Contain" fit-zoom: the largest scale at which `content` fits
    /// entirely inside `viewport` — both axes. `min` of the two axis
    /// ratios (the limiting axis fills exactly, the other gets margin).
    /// Contrast "cover" (`max`), which fills one axis and crops the other.
    public static func fitZoom(content: CGSize, viewport: CGSize) -> CGFloat {
        guard content.width > 0, content.height > 0 else { return 1 }
        return Swift.min(viewport.width / content.width,
                         viewport.height / content.height)
    }

    // MARK: - Bottom-anchor clamp (drone camera)

    /// Result of `anchorClamp` — what the scroll-view delegate should
    /// write back to `contentInset.top`, `contentInset.bottom`, and
    /// `contentOffset.y` to enforce the bottom-anchor invariant.
    struct AnchorClampResult: Equatable {
        /// Padding above the content. Non-zero only when the content is
        /// shorter than the anchor line, pushing its bottom down to land
        /// on the anchor.
        let topInset: CGFloat
        /// Padding below the content, sized so UIScrollView's natural max
        /// scroll permits reaching `offsetYMax` (the upward-pan range).
        let bottomInset: CGFloat
        /// The clamped `contentOffset.y` to enforce on this frame.
        let targetOffsetY: CGFloat
        /// True iff content is shorter than the anchor line (pinned at floor).
        let isPinnedAtFloor: Bool
    }

    /// Pure math for the bottom-anchor enforcement. Two regimes:
    ///
    /// 1. **Content shorter than anchor**: stretch `topInset` to push the
    ///    content's bottom down to `anchorY`; `targetOffsetY = -topInset`.
    /// 2. **Content taller than anchor**: clamp `contentOffset.y` into
    ///    `[contentH - anchorY, contentH - anchorY * 0.5]`. The floor is
    ///    "content bottom at the anchor line"; the ceiling lets the user
    ///    lift the content until its bottom sits halfway up the play area.
    static func anchorClamp(
        contentH: CGFloat,
        boundsH: CGFloat,
        anchorY: CGFloat,
        currentOffsetY: CGFloat
    ) -> AnchorClampResult {
        let bottomFloorY = anchorY
        let bottomCeilY = anchorY * 0.5
        // bottomInset must accommodate the CEILING, not the floor — else
        // UIScrollView's natural max scroll collapses onto the floor and
        // the upward-pan range stops working.
        let bottomInset = Swift.max(0, boundsH - bottomCeilY)

        if contentH < bottomFloorY {
            let topInset = bottomFloorY - contentH
            return AnchorClampResult(
                topInset: topInset,
                bottomInset: bottomInset,
                targetOffsetY: -topInset,
                isPinnedAtFloor: true
            )
        }

        let offsetYMin = contentH - bottomFloorY    // bottom at floor
        let offsetYMax = contentH - bottomCeilY     // bottom at ceiling
        let clampedY = Swift.max(offsetYMin, Swift.min(offsetYMax, currentOffsetY))
        return AnchorClampResult(
            topInset: 0,
            bottomInset: bottomInset,
            targetOffsetY: clampedY,
            isPinnedAtFloor: false
        )
    }

    // MARK: - Pinch veto

    /// Decides whether a two-finger pinch should be allowed to begin, given
    /// the identifiers of the interactive elements under each finger (or
    /// `nil` if a finger is on empty background).
    ///
    /// Rule: veto only when the two fingers are on *different* non-nil
    /// elements (interpreted as two independent drags). Every other case —
    /// both on background, only one on an element, or both on the same
    /// element — allows the pinch.
    static func allowPinch(
        idUnderFinger0: AnyHashable?,
        idUnderFinger1: AnyHashable?
    ) -> Bool {
        if let a = idUnderFinger0, let b = idUnderFinger1, a != b {
            return false
        }
        return true
    }

    // MARK: - Double-tap

    /// Builds a content-coord rect that `UIScrollView.zoom(to:)` will fit
    /// to produce exactly `targetScale` centred on `tapInContent`.
    /// `targetScale` must be > 0; non-positive returns a zero rect.
    static func doubleTapZoomRect(
        tapInContent: CGPoint,
        targetScale: CGFloat,
        scrollBounds: CGSize
    ) -> CGRect {
        guard targetScale > 0 else { return .zero }
        let w = scrollBounds.width / targetScale
        let h = scrollBounds.height / targetScale
        return CGRect(
            x: tapInContent.x - w / 2,
            y: tapInContent.y - h / 2,
            width: w,
            height: h
        )
    }
}
