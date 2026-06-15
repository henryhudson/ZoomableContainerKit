//
//  ZoomMathTests.swift
//  ZoomableContainerKitTests
//
//  Unit tests for the pure helpers behind `ZoomableContainer`. The gesture
//  state machine, native-pinch precedence, haptics, and bounce feel are
//  verified on device — outside these tests.
//

import Testing
import CoreGraphics
import Foundation
@testable import ZoomableContainerKit

// MARK: - fitZoom

@Suite("ZoomMath.fitZoom")
struct ZoomMathFitZoomTests {
    @Test("contain: the limiting axis fills exactly, the other gets margin")
    func containsBothAxes() {
        // Content 1000×500 into a 400×400 viewport: width ratio 0.4,
        // height ratio 0.8 → min = 0.4 (width is limiting).
        let z = ZoomMath.fitZoom(content: CGSize(width: 1000, height: 500),
                                 viewport: CGSize(width: 400, height: 400))
        #expect(abs(z - 0.4) < 0.0001)
    }

    @Test("height-limited content uses the height ratio")
    func heightLimited() {
        // Content 500×1000 into 400×400: width 0.8, height 0.4 → 0.4.
        let z = ZoomMath.fitZoom(content: CGSize(width: 500, height: 1000),
                                 viewport: CGSize(width: 400, height: 400))
        #expect(abs(z - 0.4) < 0.0001)
    }

    @Test("square content into square viewport is the side ratio")
    func square() {
        let z = ZoomMath.fitZoom(content: CGSize(width: 1200, height: 1200),
                                 viewport: CGSize(width: 600, height: 600))
        #expect(abs(z - 0.5) < 0.0001)
    }

    @Test("degenerate (zero) content returns 1 (no divide-by-zero)")
    func degenerate() {
        #expect(ZoomMath.fitZoom(content: .zero, viewport: CGSize(width: 400, height: 400)) == 1)
    }
}

// MARK: - anchorClamp

@Suite("ZoomMath.anchorClamp")
struct ZoomMathAnchorClampTests {
    @Test("content shorter than the anchor pins at the floor via topInset")
    func shorterPinsAtFloor() {
        // contentH 300, anchorY 500 → topInset 200, offset -200, pinned.
        let r = ZoomMath.anchorClamp(contentH: 300, boundsH: 800, anchorY: 500, currentOffsetY: 0)
        #expect(r.isPinnedAtFloor)
        #expect(r.topInset == 200)
        #expect(r.targetOffsetY == -200)
    }

    @Test("content taller than the anchor clamps offset into the hand-wall range")
    func tallerClampsRange() {
        // contentH 1000, anchorY 600 → floor offset 400 (1000-600),
        // ceiling 700 (1000-300). A request below the floor clamps up to 400.
        let low = ZoomMath.anchorClamp(contentH: 1000, boundsH: 800, anchorY: 600, currentOffsetY: 0)
        #expect(!low.isPinnedAtFloor)
        #expect(low.targetOffsetY == 400)          // clamped up to the floor
        // A request above the ceiling clamps down to 700.
        let high = ZoomMath.anchorClamp(contentH: 1000, boundsH: 800, anchorY: 600, currentOffsetY: 9999)
        #expect(high.targetOffsetY == 700)
        // In-range passes through.
        let mid = ZoomMath.anchorClamp(contentH: 1000, boundsH: 800, anchorY: 600, currentOffsetY: 550)
        #expect(mid.targetOffsetY == 550)
    }

    @Test("bottomInset accommodates the ceiling, not the floor (upward-pan range)")
    func bottomInsetForCeiling() {
        // boundsH 800, anchorY 600 → ceiling 300 → bottomInset 800-300 = 500.
        let r = ZoomMath.anchorClamp(contentH: 1000, boundsH: 800, anchorY: 600, currentOffsetY: 500)
        #expect(r.bottomInset == 500)
    }
}

// MARK: - allowPinch

@Suite("ZoomMath.allowPinch")
struct ZoomMathAllowPinchTests {
    @Test("both fingers on empty background → allow pinch")
    func bothNil() {
        #expect(ZoomMath.allowPinch(idUnderFinger0: nil, idUnderFinger1: nil))
    }

    @Test("one finger on element, one on background → allow pinch")
    func oneNil() {
        let card: AnyHashable = "card-1"
        #expect(ZoomMath.allowPinch(idUnderFinger0: card, idUnderFinger1: nil))
        #expect(ZoomMath.allowPinch(idUnderFinger0: nil, idUnderFinger1: card))
    }

    @Test("both fingers on the SAME element → allow pinch")
    func sameElement() {
        let card: AnyHashable = "card-1"
        #expect(ZoomMath.allowPinch(idUnderFinger0: card, idUnderFinger1: card))
    }

    @Test("both fingers on DIFFERENT elements → veto (two drags, not a pinch)")
    func differentElements() {
        #expect(!ZoomMath.allowPinch(idUnderFinger0: "card-1", idUnderFinger1: "card-2"))
    }

    @Test("predicate is symmetric")
    func symmetric() {
        let a: AnyHashable = "a", b: AnyHashable = "b"
        #expect(ZoomMath.allowPinch(idUnderFinger0: a, idUnderFinger1: b)
                == ZoomMath.allowPinch(idUnderFinger0: b, idUnderFinger1: a))
    }

    @Test("works across hashable key types")
    func mixedKeys() {
        #expect(!ZoomMath.allowPinch(idUnderFinger0: 1, idUnderFinger1: 2))
        let a = UUID(), b = UUID()
        #expect(!ZoomMath.allowPinch(idUnderFinger0: a, idUnderFinger1: b))
        #expect(ZoomMath.allowPinch(idUnderFinger0: a, idUnderFinger1: a))
    }
}

// MARK: - doubleTapZoomRect

@Suite("ZoomMath.doubleTapZoomRect")
struct ZoomMathDoubleTapRectTests {
    @Test("rect size equals bounds divided by target scale")
    func rectSizeFromScale() {
        let r = ZoomMath.doubleTapZoomRect(tapInContent: CGPoint(x: 100, y: 100),
                                           targetScale: 2.0,
                                           scrollBounds: CGSize(width: 400, height: 800))
        #expect(r.width == 200)
        #expect(r.height == 400)
    }

    @Test("rect is centred on the tap point")
    func rectCentredOnTap() {
        let r = ZoomMath.doubleTapZoomRect(tapInContent: CGPoint(x: 100, y: 100),
                                           targetScale: 2.0,
                                           scrollBounds: CGSize(width: 400, height: 800))
        #expect(r.midX == 100)
        #expect(r.midY == 100)
    }

    @Test("framing is device-independent (covers 1/targetScale of the viewport)")
    func deviceIndependentFraming() {
        let phone = ZoomMath.doubleTapZoomRect(tapInContent: CGPoint(x: 200, y: 400),
                                               targetScale: 2.5,
                                               scrollBounds: CGSize(width: 400, height: 800))
        let pad = ZoomMath.doubleTapZoomRect(tapInContent: CGPoint(x: 200, y: 400),
                                             targetScale: 2.5,
                                             scrollBounds: CGSize(width: 1024, height: 1366))
        #expect(abs(phone.width / 400 - 1.0 / 2.5) < 0.0001)
        #expect(abs(pad.width / 1024 - 1.0 / 2.5) < 0.0001)
    }

    @Test("non-positive target scale returns a zero rect (defensive guard)")
    func nonPositiveIsSafe() {
        #expect(ZoomMath.doubleTapZoomRect(tapInContent: CGPoint(x: 1, y: 1), targetScale: 0,
                                           scrollBounds: CGSize(width: 400, height: 800)) == .zero)
        #expect(ZoomMath.doubleTapZoomRect(tapInContent: CGPoint(x: 1, y: 1), targetScale: -1,
                                           scrollBounds: CGSize(width: 400, height: 800)) == .zero)
    }
}
