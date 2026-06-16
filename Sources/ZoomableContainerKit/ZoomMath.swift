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
        /// Padding below the content so the scroll view's content inset covers
        /// the area below the anchor line.
        let bottomInset: CGFloat
        /// The clamped `contentOffset.y` to enforce on this frame.
        let targetOffsetY: CGFloat
    }

    /// Pure math for the bottom-anchor enforcement. The content's bottom is
    /// PINNED to the anchor line — it can neither drift above it (a gap of
    /// backdrop above the divider reads as broken) nor below. Two regimes:
    ///
    /// 1. **Content shorter than anchor**: stretch `topInset` to push the
    ///    content's bottom down onto `anchorY`; `targetOffsetY = -topInset`.
    /// 2. **Content taller than anchor**: fix `contentOffset.y` at
    ///    `contentH - anchorY` (bottom exactly on the anchor); vertical pan
    ///    is not offered — the camera changes altitude by zoom, not by
    ///    sliding the table up.
    static func anchorClamp(
        contentH: CGFloat,
        boundsH: CGFloat,
        anchorY: CGFloat
    ) -> AnchorClampResult {
        // Covers the viewport area below the anchor so the scroll view's
        // natural offset range permits the pinned position.
        let bottomInset = Swift.max(0, boundsH - anchorY)

        if contentH < anchorY {
            let topInset = anchorY - contentH
            return AnchorClampResult(
                topInset: topInset,
                bottomInset: bottomInset,
                targetOffsetY: -topInset
            )
        }

        // Taller: pin the bottom on the anchor — offset is fixed, not a range.
        return AnchorClampResult(
            topInset: 0,
            bottomInset: bottomInset,
            targetOffsetY: contentH - anchorY
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
