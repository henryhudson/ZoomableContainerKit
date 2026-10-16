//
//  ZoomableContainerCoordinator.swift
//  ZoomableContainerKit
//
//  The scroll-view delegate + gesture-delegate. UIKit's built-in pinch
//  owns zoom and focal anchoring (inset-aware, atomic); this coordinator
//  only positions the content (centring / bottom-anchor), ticks the limit
//  haptic, runs double-tap, mirrors the transform, and arbitrates pinch
//  vs. child taps/drags.
//
//  Two layout modes, chosen by whether `hooks.bottomAnchorY` is supplied:
//    - free-floating (nil): centre the content in both axes.
//    - drone camera (set):  centre horizontally; pin the content's bottom
//      to the anchor line vertically every tick.
//
//  A change of size (an iPhone Duo fold, a turn, a re-measured hand line,
//  a re-laid-out chamber) keeps the zoom, clamped to the new limits, and
//  the place: the free-floating camera keeps the same fraction of the
//  content in the middle of the view; the drone camera re-runs its
//  bottom-right framing.
//

import SwiftUI
import UIKit

extension ZoomableContainer {
    @MainActor
    public final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var hostedView: UIView?
        var hostingController: UIHostingController<Content>?
        var hasSetInitialZoom = false

        // Re-fit support: a change in the container's `refitKey` (once seen)
        // resets `hasSetInitialZoom` so the camera re-frames.
        var seenRefitKey: AnyHashable?
        var hasSeenRefitKey = false
        /// True while a pinch the arbitrator accepted is in flight — guards
        /// the refit transition from yanking the user's zoom mid-gesture.
        var isPinching = false

        // Mirrored from the container on every update.
        var config = ZoomConfig()
        var hooks = ZoomHooks()
        /// The content WORLD size (the `contentSize` the host passed), used
        /// for fit-zoom and the bottom-anchor clamp — NOT the hosted view's
        /// frame, which may be taller via `hostedContentHeight`.
        var contentWorldSize: CGSize = .zero

        /// Hosted-view size: `contentWorldSize` width, height overridden when
        /// `config.hostedContentHeight` is set (taller hittable surface).
        var hostedSize: CGSize {
            CGSize(width: contentWorldSize.width, height: config.hostedContentHeight ?? contentWorldSize.height)
        }

        // Canonical (non-bounced) zoom limits, kept in sync.
        var realMinZoom: CGFloat = 0
        var realMaxZoom: CGFloat = 1

        /// The sizes the camera was last framed for. When any of them
        /// changes, the camera is re-framed rather than started over.
        struct Framing: Equatable {
            var bounds: CGSize
            var hostedSize: CGSize
            var worldSize: CGSize
        }
        private var framing: Framing?
        /// Free-floating: the content point in the middle of the view,
        /// kept current so a resize can put it back.
        private var visibleCentre: CGPoint = .zero

        private var hasPulsedAtLimit = false
        private lazy var limitHaptic = UIImpactFeedbackGenerator(style: .soft)

        // MARK: UIScrollViewDelegate

        public func viewForZooming(in scrollView: UIScrollView) -> UIView? { hostedView }

        public func scrollViewDidZoom(_ scrollView: UIScrollView) {
            applyLayout(in: scrollView)
            fireLimitHaptic(in: scrollView)
            noteVisibleCentre(in: scrollView)
            hooks.onTransformChange?(scrollView.zoomScale, scrollView.contentOffset)
        }

        public func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // Only the drone camera re-clamps on pan; free-floating centring
            // doesn't change as the user scrolls within the inset bounds.
            if hooks.bottomAnchorY != nil { enforceBottomAnchor(in: scrollView) }
            noteVisibleCentre(in: scrollView)
            hooks.onTransformChange?(scrollView.zoomScale, scrollView.contentOffset)
        }

        // MARK: Layout

        func applyLayout(in scrollView: UIScrollView) {
            if hooks.bottomAnchorY != nil {
                centerHorizontally(in: scrollView)
                enforceBottomAnchor(in: scrollView)
            } else {
                centerContent(in: scrollView)
            }
        }

        /// Free-floating: centre both axes via contentInset. This is now the
        /// SOLE writer of scroll geometry (the built-in pinch owns offset),
        /// so the old inset-vs-manual-offset fight is gone. The epsilon
        /// guard stops sub-pixel inset noise from re-laying-out every tick.
        func centerContent(in scrollView: UIScrollView) {
            let bounds = scrollView.bounds.size
            // The world, not `contentSize`: UIKit keeps that already scaled
            // by the zoom, so scaling it again mis-centres at any zoom but 1.
            let content = contentWorldSize
            let scale = scrollView.zoomScale
            let insetX = max(0, (bounds.width - content.width * scale) / 2)
            let insetY = max(0, (bounds.height - content.height * scale) / 2)
            let cur = scrollView.contentInset
            if abs(cur.left - insetX) > 0.5 || abs(cur.top - insetY) > 0.5 {
                scrollView.contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
            }
        }

        /// Drone: horizontal centring only — the vertical insets/offset are
        /// owned by `enforceBottomAnchor`. Splitting the axes by function
        /// keeps the two writers from racing on `contentInset`.
        func centerHorizontally(in scrollView: UIScrollView) {
            let bounds = scrollView.bounds.size
            let content = contentWorldSize
            let scale = scrollView.zoomScale
            let insetX = max(0, (bounds.width - content.width * scale) / 2)
            let cur = scrollView.contentInset
            if abs(cur.left - insetX) > 0.01 || abs(cur.right - insetX) > 0.01 {
                scrollView.contentInset = UIEdgeInsets(top: cur.top, left: insetX, bottom: cur.bottom, right: insetX)
            }
        }

        /// Pin the content world's bottom to the anchor line every tick.
        /// Anchors against `contentWorldSize.height` (not the hosted view,
        /// which may be taller), so below-anchor hosted content stays
        /// hittable without changing how the world fits or pins.
        func enforceBottomAnchor(in scrollView: UIScrollView) {
            let contentH = contentWorldSize.height * scrollView.zoomScale
            let boundsH = scrollView.bounds.size.height
            let anchorY: CGFloat = {
                if let provider = hooks.bottomAnchorY {
                    let v = provider()
                    if v > 0 { return v }
                }
                return boundsH
            }()
            let clamp = ZoomMath.anchorClamp(
                contentH: contentH,
                boundsH: boundsH,
                anchorY: anchorY
            )
            let cur = scrollView.contentInset
            if abs(cur.top - clamp.topInset) > 0.01 || abs(cur.bottom - clamp.bottomInset) > 0.01 {
                scrollView.contentInset = UIEdgeInsets(
                    top: clamp.topInset, left: cur.left, bottom: clamp.bottomInset, right: cur.right
                )
            }
            if abs(scrollView.contentOffset.y - clamp.targetOffsetY) > 0.01 {
                scrollView.contentOffset.y = clamp.targetOffsetY
            }
        }

        // MARK: Settling

        /// Brings the camera up to date: from `updateUIView` on every
        /// update, and from the scroll view's layout, since a size-only
        /// change (a fold, a turn) re-lays the view out without one.
        func settle(in scrollView: UIScrollView) {
            resizeHostedView(in: scrollView)
            let bounds = scrollView.bounds.size
            guard bounds.width > 0, bounds.height > 0 else { return }
            if !hasSetInitialZoom {
                applyInitialZoom(in: scrollView)
            } else if let framing, framing != currentFraming(of: scrollView) {
                reframe(from: framing, in: scrollView)
            } else {
                syncZoomLimits(in: scrollView)
                applyLayout(in: scrollView)
            }
        }

        /// Layout runs on every scroll, so settle only when there is work.
        func didLayout(_ scrollView: UIScrollView) {
            guard !hasSetInitialZoom || framing != currentFraming(of: scrollView) else { return }
            settle(in: scrollView)
        }

        /// Resizes the hosted view in place. Its frame is undefined under
        /// the zoom transform, so bounds and centre are written instead.
        /// The zoom is not set to 1 first: the setter clamps to the zoom
        /// limits, so it would not reach 1 under a floor above 1.
        private func resizeHostedView(in scrollView: UIScrollView) {
            guard let hostedView, hostedView.bounds.size != hostedSize else { return }
            let zoom = scrollView.zoomScale
            hostedView.bounds = CGRect(origin: .zero, size: hostedSize)
            hostedView.center = CGPoint(x: hostedSize.width * zoom / 2, y: hostedSize.height * zoom / 2)
            scrollView.contentSize = CGSize(width: hostedSize.width * zoom, height: hostedSize.height * zoom)
        }

        /// Syncs the limits to the view: the floor is the zoom at which
        /// the world fits the play area, or the caller's floor if higher.
        @discardableResult
        private func syncZoomLimits(in scrollView: UIScrollView) -> CGFloat {
            let playArea = CGSize(width: scrollView.bounds.width, height: playAreaHeight(in: scrollView))
            let effectiveMin = max(config.minZoom, ZoomMath.fitZoom(content: contentWorldSize, viewport: playArea))
            scrollView.minimumZoomScale = effectiveMin
            scrollView.maximumZoomScale = config.maxZoom
            realMinZoom = effectiveMin
            realMaxZoom = config.maxZoom
            return effectiveMin
        }

        /// Drone: down to the anchor line. Free-floating: the whole view.
        private func playAreaHeight(in scrollView: UIScrollView) -> CGFloat {
            if let provider = hooks.bottomAnchorY {
                let v = provider()
                if v > 0 { return v }
            }
            return scrollView.bounds.height
        }

        // MARK: Initial zoom

        /// One-shot: configure fit-zoom + limits + the starting altitude.
        /// Idempotent via `hasSetInitialZoom`. Reads mirrored coordinator
        /// state so values published after `makeUIView` still reach it.
        func applyInitialZoom(in scrollView: UIScrollView) {
            guard !hasSetInitialZoom else { return }
            let bounds = scrollView.bounds.size
            guard bounds.width > 0, bounds.height > 0 else { return }
            guard contentWorldSize.width > 0, contentWorldSize.height > 0 else { return }

            let effectiveMin = syncZoomLimits(in: scrollView)
            let initial: CGFloat = {
                if let iz = config.initialZoom { return min(config.maxZoom, max(effectiveMin, iz)) }
                return effectiveMin   // nil ⇒ start at fit (free-floating)
            }()
            scrollView.zoomScale = initial
            hasSetInitialZoom = true

            applyLayout(in: scrollView)

            // Drone only: frame the start on the world's bottom-right corner
            // (where freshly dealt cards land). Free-floating stays centred.
            if hooks.bottomAnchorY != nil { frameBottomRight(in: scrollView) }
            didFrame(in: scrollView)
        }

        // MARK: Re-framing after a resize

        /// Keeps the zoom, clamped to the new limits, and the place. A
        /// camera zoomed all the way out stays all the way out.
        private func reframe(from old: Framing, in scrollView: UIScrollView) {
            let zoom = scrollView.zoomScale
            let oldFloor = realMinZoom
            let newFloor = syncZoomLimits(in: scrollView)
            let carried = ZoomMath.carriedZoom(zoom, oldFloor: oldFloor, newFloor: newFloor, ceiling: config.maxZoom)
            if scrollView.zoomScale != carried { scrollView.zoomScale = carried }
            applyLayout(in: scrollView)

            if hooks.bottomAnchorY != nil {
                frameBottomRight(in: scrollView)
            } else {
                let centre = ZoomMath.carriedCentre(visibleCentre, from: old.worldSize, to: contentWorldSize)
                scrollView.contentOffset = ZoomMath.centringOffset(
                    on: centre, zoom: carried, viewport: scrollView.bounds.size, content: contentWorldSize
                )
            }
            didFrame(in: scrollView)
        }

        /// Drone: frame the world's bottom-right corner. A world narrower
        /// than the view sits in the middle, where its insets centre it.
        private func frameBottomRight(in scrollView: UIScrollView) {
            let scaledW = contentWorldSize.width * scrollView.zoomScale
            let width = scrollView.bounds.width
            scrollView.contentOffset.x = scaledW > width ? scaledW - width : (scaledW - width) / 2
            enforceBottomAnchor(in: scrollView)
        }

        private func didFrame(in scrollView: UIScrollView) {
            framing = currentFraming(of: scrollView)
            noteVisibleCentre(in: scrollView)
            hooks.onTransformChange?(scrollView.zoomScale, scrollView.contentOffset)
        }

        private func currentFraming(of scrollView: UIScrollView) -> Framing {
            Framing(bounds: scrollView.bounds.size, hostedSize: hostedSize, worldSize: contentWorldSize)
        }

        /// Skipped mid-resize, while the view no longer matches its framing:
        /// the middle of the view is not yet back on the right content.
        private func noteVisibleCentre(in scrollView: UIScrollView) {
            guard hooks.bottomAnchorY == nil, let hostedView,
                  framing == currentFraming(of: scrollView) else { return }
            let middle = CGPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY)
            visibleCentre = scrollView.convert(middle, to: hostedView)
        }

        // MARK: Haptic

        private func fireLimitHaptic(in scrollView: UIScrollView) {
            guard config.hapticsAtLimits else { return }
            let z = scrollView.zoomScale
            let overshooting = z > realMaxZoom + 0.0001 || z < realMinZoom - 0.0001
            if overshooting, !hasPulsedAtLimit {
                limitHaptic.impactOccurred()
                hasPulsedAtLimit = true
            } else if !overshooting {
                hasPulsedAtLimit = false
            }
        }

        // MARK: Gestures

        /// No-zoom arbitrator: the built-in pinch zooms; this only cancels
        /// in-flight child taps (`cancelsTouchesInView`) on two-finger-down
        /// and arms the haptic. Never touches `zoomScale`/`contentOffset`.
        @objc func handleArbitratorPinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began:
                isPinching = true
                if config.hapticsAtLimits { limitHaptic.prepare() }
                hasPulsedAtLimit = false
            case .ended, .cancelled, .failed:
                isPinching = false
                hasPulsedAtLimit = false
            default:
                break
            }
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView,
                  let content = hostedView else { return }
            if scrollView.zoomScale > realMinZoom * 1.1 {
                scrollView.setZoomScale(realMinZoom, animated: true)
                return
            }
            let zoomRect = ZoomMath.doubleTapZoomRect(
                tapInContent: gesture.location(in: content),
                targetScale: realMinZoom * config.doubleTapZoomMultiplier,
                scrollBounds: scrollView.bounds.size
            )
            scrollView.zoom(to: zoomRect, animated: true)
        }

        /// Shared veto for both the built-in pinch (via VetoingScrollView)
        /// and the arbitrator: global gate first, then the two-different-
        /// elements rule.
        func pinchAllowedToBegin(_ pinch: UIPinchGestureRecognizer) -> Bool {
            if let allowed = hooks.pinchAllowed, !allowed() { return false }
            guard let resolver = hooks.elementIdAtPoint,
                  let content = hostedView,
                  pinch.numberOfTouches >= 2
            else {
                return true
            }
            let p0 = pinch.location(ofTouch: 0, in: content)
            let p1 = pinch.location(ofTouch: 1, in: content)
            return ZoomMath.allowPinch(idUnderFinger0: resolver(p0), idUnderFinger1: resolver(p1))
        }

        // MARK: UIGestureRecognizerDelegate

        public func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        /// Veto for the arbitrator (and any recogniser whose delegate is
        /// this coordinator). The built-in pinch is gated separately via
        /// `VetoingScrollView.builtInPinchShouldBegin`.
        public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pinch = gestureRecognizer as? UIPinchGestureRecognizer else { return true }
            return pinchAllowedToBegin(pinch)
        }
    }
}
