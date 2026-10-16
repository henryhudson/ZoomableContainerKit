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
        // contentH 300, anchorY 500 → topInset 200, offset -200.
        let r = ZoomMath.anchorClamp(contentH: 300, boundsH: 800, anchorY: 500)
        #expect(r.topInset == 200)
        #expect(r.targetOffsetY == -r.topInset)
    }

    @Test("content taller than the anchor pins the bottom on the divider (no lift)")
    func tallerPinsBottom() {
        // contentH 1000, anchorY 600 → bottom on the divider ⇒ offset 400,
        // and no topInset (the bottom is the sole anchor).
        let r = ZoomMath.anchorClamp(contentH: 1000, boundsH: 800, anchorY: 600)
        let pinned: CGFloat = 1000 - 600
        #expect(r.targetOffsetY == pinned)
        #expect(r.topInset == 0)
    }

    @Test("bottomInset covers the viewport area below the anchor line")
    func bottomInsetCoversGap() {
        // boundsH 800, anchorY 600 → bottomInset 800-600 = 200.
        let r = ZoomMath.anchorClamp(contentH: 1000, boundsH: 800, anchorY: 600)
        #expect(r.bottomInset == 200)
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

// MARK: - Hand-wall invariant

@Suite("ZoomMath hand-wall invariant — no card renders past anchorY")
struct ZoomMathHandWallInvariantTests {
    /// Where a content-space point lands in the viewport, given the zoom and
    /// the clamped offset the delegate writes back. Pure render math.
    private static func cardViewportY(contentY: CGFloat, zoomScale: CGFloat, clampedOffsetY: CGFloat) -> CGFloat {
        contentY * zoomScale - clampedOffsetY
    }

    @Test("Content-bottom card at floor renders exactly at anchor")
    func contentBottomAtFloorIsAnchor() {
        let contentH: CGFloat = 1800 * 1.0
        let clamp = ZoomMath.anchorClamp(contentH: contentH, boundsH: 900, anchorY: 700)
        let vpY = Self.cardViewportY(contentY: 1800, zoomScale: 1.0, clampedOffsetY: clamp.targetOffsetY)
        #expect(abs(vpY - 700) < 0.0001)
    }

    @Test("Tall content renders its bottom exactly at the anchor (no gap)")
    func largeNominalContentRendersBottomExactlyAtAnchor() {
        // Content far taller than the anchor: the bottom pins ON the anchor,
        // never above it — the old pan-up gap is gone regardless of altitude.
        let contentH: CGFloat = 1800 * 1.0
        let clamp = ZoomMath.anchorClamp(contentH: contentH, boundsH: 900, anchorY: 700)
        let vpY = Self.cardViewportY(contentY: 1800, zoomScale: 1.0, clampedOffsetY: clamp.targetOffsetY)
        #expect(abs(vpY - 700) < 0.0001)
    }

    @Test("Sweep: every card at every zoom stays at or above the anchor")
    func sweepNeverCrossesAnchor() {
        let anchorY: CGFloat = 700
        let boundsH: CGFloat = 900
        let contentWorldH: CGFloat = 1800
        let zooms: [CGFloat] = [0.39, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0]
        let contentYs: [CGFloat] = stride(from: 0, through: 1800, by: 100).map { CGFloat($0) }
        for zoom in zooms {
            let contentH = contentWorldH * zoom
            let clamp = ZoomMath.anchorClamp(contentH: contentH, boundsH: boundsH, anchorY: anchorY)
            for contentY in contentYs {
                let vpY = Self.cardViewportY(contentY: contentY, zoomScale: zoom, clampedOffsetY: clamp.targetOffsetY)
                #expect(vpY <= anchorY + 0.01, "Wall breach at zoom=\(zoom), contentY=\(contentY): vpY=\(vpY)")
            }
        }
    }

    @Test("iPad shape: wall holds at contain-fit on taller viewport")
    func iPadShapeHoldsWall() {
        let anchorY: CGFloat = 1100
        let boundsH: CGFloat = 1366
        let contentH: CGFloat = 1800 * 0.76
        let clamp = ZoomMath.anchorClamp(contentH: contentH, boundsH: boundsH, anchorY: anchorY)
        let vpY = Self.cardViewportY(contentY: 1800, zoomScale: 0.76, clampedOffsetY: clamp.targetOffsetY)
        #expect(vpY <= anchorY + 0.01)
    }
}

// MARK: - Keeping place across a resize

@Suite("ZoomMath.carriedCentre")
struct ZoomMathCarriedCentreTests {
    @Test("a centre 30 percent across and 60 percent down keeps its fractions as the content grows or shrinks",
          arguments: [CGSize(width: 1500, height: 3000), CGSize(width: 500, height: 1000), CGSize(width: 1200, height: 900)])
    func keepsFractions(newContent: CGSize) {
        let centre = ZoomMath.carriedCentre(CGPoint(x: 300, y: 1200),
                                            from: CGSize(width: 1000, height: 2000),
                                            to: newContent)
        #expect(abs(centre.x / newContent.width - 0.3) < 0.0001)
        #expect(abs(centre.y / newContent.height - 0.6) < 0.0001)
    }

    @Test("a centre past the content's edges is clamped inside the new content")
    func clampedInside() {
        let centre = ZoomMath.carriedCentre(CGPoint(x: -50, y: 2400),
                                            from: CGSize(width: 1000, height: 2000),
                                            to: CGSize(width: 500, height: 1000))
        #expect(centre == CGPoint(x: 0, y: 1000))
    }

    @Test("empty old content carries to the middle of the new content")
    func emptyOldContent() {
        let centre = ZoomMath.carriedCentre(CGPoint(x: 10, y: 10), from: .zero, to: CGSize(width: 600, height: 400))
        #expect(centre == CGPoint(x: 300, y: 200))
    }
}

@Suite("ZoomMath.carriedZoom")
struct ZoomMathCarriedZoomTests {
    @Test("a zoom inside the new limits is kept")
    func keptInsideLimits() {
        #expect(ZoomMath.carriedZoom(1.5, oldFloor: 0.4, newFloor: 0.6, ceiling: 5) == 1.5)
    }

    @Test("a zoom below the new floor rises to it")
    func risesToNewFloor() {
        #expect(ZoomMath.carriedZoom(0.5, oldFloor: 0.4, newFloor: 0.6, ceiling: 5) == 0.6)
    }

    @Test("a zoom above the ceiling falls to it")
    func fallsToCeiling() {
        #expect(ZoomMath.carriedZoom(6, oldFloor: 0.4, newFloor: 0.6, ceiling: 5) == 5)
    }

    @Test("zoomed all the way out stays all the way out, whether the floor rises or falls",
          arguments: [CGFloat(0.3), CGFloat(0.6)])
    func atFloorFollowsTheFloor(newFloor: CGFloat) {
        #expect(ZoomMath.carriedZoom(0.4, oldFloor: 0.4, newFloor: newFloor, ceiling: 5) == newFloor)
    }
}

@Suite("ZoomMath.centringOffset")
struct ZoomMathCentringOffsetTests {
    @Test("puts the point at the middle of the viewport when the content overfills it")
    func centresThePoint() {
        let offset = ZoomMath.centringOffset(on: CGPoint(x: 450, y: 1800), zoom: 1,
                                             viewport: CGSize(width: 400, height: 800),
                                             content: CGSize(width: 1500, height: 3000))
        #expect(offset == CGPoint(x: 250, y: 1400))
    }

    @Test("works in scaled points at any zoom")
    func appliesTheZoom() {
        let offset = ZoomMath.centringOffset(on: CGPoint(x: 450, y: 1800), zoom: 2,
                                             viewport: CGSize(width: 400, height: 800),
                                             content: CGSize(width: 1500, height: 3000))
        #expect(offset == CGPoint(x: 700, y: 3200))
    }

    @Test("stops at the content's edges rather than showing past them")
    func staysInsideTheEdges() {
        let offset = ZoomMath.centringOffset(on: CGPoint(x: 1490, y: 10), zoom: 1,
                                             viewport: CGSize(width: 400, height: 800),
                                             content: CGSize(width: 1500, height: 3000))
        #expect(offset == CGPoint(x: 1100, y: 0))
    }

    @Test("centres an axis the content does not fill, wherever the point is")
    func centresAnAxisTheContentDoesNotFill() {
        let offset = ZoomMath.centringOffset(on: CGPoint(x: 10, y: 1800), zoom: 1,
                                             viewport: CGSize(width: 400, height: 800),
                                             content: CGSize(width: 300, height: 3000))
        #expect(offset == CGPoint(x: -50, y: 1400))
    }
}
