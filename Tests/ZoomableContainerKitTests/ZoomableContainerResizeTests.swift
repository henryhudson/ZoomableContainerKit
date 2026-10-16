//
//  ZoomableContainerResizeTests.swift
//  ZoomableContainerKitTests
//
//  Drives the real container (its UIScrollView, hosted by SwiftUI in a
//  window) through the size changes an iPhone Duo fold or a turn makes, and
//  reads back what UIKit would put on screen. No mocks. A fold cannot be
//  scripted on the Duo simulator, so a window resize stands in for one.
//

import Testing
import SwiftUI
import UIKit
@testable import ZoomableContainerKit

@MainActor
@Suite("ZoomableContainer across a resize", .serialized)
struct ZoomableContainerResizeTests {

    // MARK: Free-floating (Hansard's chambers)

    @Test("a chamber zoomed all the way out stays fitted and centred through a turn and back")
    func fittedChamberStaysFittedThroughATurn() async throws {
        let stage = await Stage(CGSize(width: 400, height: 800), chamber(CGSize(width: 600, height: 1200)))
        let scrollView = try #require(stage.scrollView)
        #expect(abs(scrollView.zoomScale - 400.0 / 600) < 0.001)

        await stage.resize(CGSize(width: 800, height: 400))
        #expect(abs(scrollView.zoomScale - 400.0 / 1200) < 0.001)
        let centre = try visibleCentre(of: scrollView)
        #expect(abs(centre.x - 300) < 0.5)
        #expect(abs(centre.y - 600) < 0.5)
        // The chamber is narrower than the view: a drag cannot leave it
        // off-centre, because the only offset in range is the centred one.
        let centred = (200 - scrollView.bounds.width) / 2
        #expect(abs(-scrollView.adjustedContentInset.left - centred) < 0.5)
        #expect(abs(scrollView.contentSize.width - scrollView.bounds.width + scrollView.adjustedContentInset.right - centred) < 0.5)

        await stage.resize(CGSize(width: 400, height: 800))
        #expect(abs(scrollView.zoomScale - 400.0 / 600) < 0.001)
        let back = try visibleCentre(of: scrollView)
        #expect(abs(back.x - 300) < 0.5)
        #expect(abs(back.y - 600) < 0.5)
    }

    @Test("a pinched-in zoom and place survive a turn")
    func pinchedPlaceSurvivesATurn() async throws {
        let stage = await Stage(CGSize(width: 400, height: 800), chamber(CGSize(width: 600, height: 1200)))
        let scrollView = try #require(stage.scrollView)
        scrollView.zoomScale = 1.5
        scrollView.contentOffset = CGPoint(x: 330 * 1.5 - 200, y: 720 * 1.5 - 400)
        await stage.settle()
        let before = try visibleCentre(of: scrollView)
        #expect(abs(before.x - 330) < 0.5)
        #expect(abs(before.y - 720) < 0.5)

        await stage.resize(CGSize(width: 800, height: 400))
        #expect(abs(scrollView.zoomScale - 1.5) < 0.001)
        let after = try visibleCentre(of: scrollView)
        #expect(abs(after.x - 330) < 0.5)
        #expect(abs(after.y - 720) < 0.5)
    }

    @Test("the visible centre keeps its fractions when the chamber is laid out larger or smaller",
          arguments: [CGSize(width: 1500, height: 3000), CGSize(width: 800, height: 1600)])
    func centreKeepsItsFractions(newContent: CGSize) async throws {
        let stage = await Stage(CGSize(width: 400, height: 800),
                                chamber(CGSize(width: 1000, height: 2000), initialZoom: 1))
        let scrollView = try #require(stage.scrollView)
        // 30 percent across and 60 percent down.
        scrollView.contentOffset = CGPoint(x: 300 - 200, y: 1200 - 400)
        await stage.settle()

        await stage.show(chamber(newContent, initialZoom: 1))
        #expect(abs(scrollView.zoomScale - 1) < 0.001)
        let centre = try visibleCentre(of: scrollView)
        #expect(abs(centre.x - newContent.width * 0.3) < 0.5)
        #expect(abs(centre.y - newContent.height * 0.6) < 0.5)
    }

    // MARK: Drone camera (Deck's table)

    @Test("a zoomed-out table keeps its zoom across a fold and re-frames on its right and bottom edges")
    func tableKeepsZoomAcrossAFold() async throws {
        let anchor = Anchor(y: 600)
        let stage = await Stage(CGSize(width: 400, height: 800), table(hostedHeight: 2000, refitKey: 0, anchor: anchor))
        let scrollView = try #require(stage.scrollView)
        #expect(abs(scrollView.zoomScale - 1) < 0.001)
        scrollView.zoomScale = 0.5
        await stage.settle()

        anchor.y = 500
        await stage.resize(CGSize(width: 300, height: 700))
        await stage.show(table(hostedHeight: 2100, refitKey: 0, anchor: anchor))
        #expect(abs(scrollView.zoomScale - 0.5) < 0.001)
        let corner = try onScreen(CGPoint(x: 1200, y: 1800), in: scrollView)
        #expect(abs(corner.x - scrollView.bounds.width) < 0.5)
        #expect(abs(corner.y - anchor.y) < 0.5)
    }

    @Test("a new refit key still re-frames the table to its starting zoom")
    func refitKeyStillReframes() async throws {
        let anchor = Anchor(y: 600)
        let stage = await Stage(CGSize(width: 400, height: 800), table(hostedHeight: 2000, refitKey: 0, anchor: anchor))
        let scrollView = try #require(stage.scrollView)
        scrollView.zoomScale = 0.5
        await stage.settle()

        await stage.show(table(hostedHeight: 2000, refitKey: 1, anchor: anchor))
        #expect(abs(scrollView.zoomScale - 1) < 0.001)
        let corner = try onScreen(CGPoint(x: 1200, y: 1800), in: scrollView)
        #expect(abs(corner.x - scrollView.bounds.width) < 0.5)
        #expect(abs(corner.y - anchor.y) < 0.5)
    }
}

// MARK: - Harness

/// A window hosting one container, resized and re-rendered by the tests.
@MainActor
private final class Stage<Root: View> {
    let window: UIWindow
    let host: UIHostingController<Root>

    init(_ size: CGSize, _ root: Root) async {
        host = UIHostingController(rootView: root)
        window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        await settle()
    }

    var scrollView: UIScrollView? { Self.scrollView(in: window) }

    func settle() async {
        window.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(50))
        window.layoutIfNeeded()
    }

    func resize(_ size: CGSize) async {
        window.frame = CGRect(origin: .zero, size: size)
        await settle()
    }

    func show(_ root: Root) async {
        host.rootView = root
        await settle()
    }

    private static func scrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? VetoingScrollView { return scrollView }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }
}

@MainActor
private final class Anchor {
    var y: CGFloat
    init(y: CGFloat) { self.y = y }
}

@MainActor
private func chamber(_ contentSize: CGSize, initialZoom: CGFloat? = nil) -> some View {
    ZoomableContainer(contentSize: contentSize, config: ZoomConfig(maxZoom: 5, initialZoom: initialZoom)) {
        Color.gray
    }
    .ignoresSafeArea()
}

@MainActor
private func table(hostedHeight: CGFloat, refitKey: Int, anchor: Anchor) -> some View {
    ZoomableContainer(
        contentSize: CGSize(width: 1200, height: 1800),
        config: ZoomConfig(maxZoom: 3, minZoom: 0.25, initialZoom: 1, doubleTapEnabled: false,
                           bouncesZoom: false, decelerationFast: true, hostedContentHeight: hostedHeight),
        hooks: ZoomHooks(bottomAnchorY: { anchor.y }),
        refitKey: refitKey
    ) {
        Color.green
    }
    .ignoresSafeArea()
}

/// The content point at the middle of the view.
@MainActor
private func visibleCentre(of scrollView: UIScrollView) throws -> CGPoint {
    let content = try #require(scrollView.delegate?.viewForZooming?(in: scrollView))
    return scrollView.convert(CGPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY), to: content)
}

/// Where a content point lands in the view, measured from its top-left.
@MainActor
private func onScreen(_ point: CGPoint, in scrollView: UIScrollView) throws -> CGPoint {
    let content = try #require(scrollView.delegate?.viewForZooming?(in: scrollView))
    let inScrollView = scrollView.convert(point, from: content)
    return CGPoint(x: inScrollView.x - scrollView.bounds.minX, y: inScrollView.y - scrollView.bounds.minY)
}
