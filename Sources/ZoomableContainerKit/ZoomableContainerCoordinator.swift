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

import SwiftUI
import UIKit

extension ZoomableContainer {
    @MainActor
    public final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var hostedView: UIView?
        var hostingController: UIHostingController<Content>?
        var hasSetInitialZoom = false

        // Mirrored from the container on every update.
        var config = ZoomConfig()
        var hooks = ZoomHooks()
        /// The content WORLD size (the `contentSize` the host passed), used
        /// for fit-zoom and the bottom-anchor clamp — NOT the hosted view's
        /// frame, which may be taller via `hostedContentHeight`.
        var contentWorldSize: CGSize = .zero

        // Canonical (non-bounced) zoom limits, kept in sync.
        var realMinZoom: CGFloat = 0
        var realMaxZoom: CGFloat = 1

        private var hasPulsedAtLimit = false
        private lazy var limitHaptic = UIImpactFeedbackGenerator(style: .soft)

        // MARK: UIScrollViewDelegate

        public func viewForZooming(in scrollView: UIScrollView) -> UIView? { hostedView }

        public func scrollViewDidZoom(_ scrollView: UIScrollView) {
            applyLayout(in: scrollView)
            fireLimitHaptic(in: scrollView)
            hooks.onTransformChange?(scrollView.zoomScale, scrollView.contentOffset)
        }

        public func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // Only the drone camera re-clamps on pan; free-floating centring
            // doesn't change as the user scrolls within the inset bounds.
            if hooks.bottomAnchorY != nil { enforceBottomAnchor(in: scrollView) }
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
            let content = scrollView.contentSize
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
            let content = scrollView.contentSize
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
                anchorY: anchorY,
                currentOffsetY: scrollView.contentOffset.y
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

        // MARK: Initial zoom

        /// One-shot: configure fit-zoom + limits + the starting altitude.
        /// Idempotent via `hasSetInitialZoom`. Reads mirrored coordinator
        /// state so values published after `makeUIView` still reach it.
        func applyInitialZoom(in scrollView: UIScrollView) {
            guard !hasSetInitialZoom else { return }
            let bounds = scrollView.bounds.size
            guard bounds.width > 0, bounds.height > 0 else { return }
            let content = contentWorldSize
            guard content.width > 0, content.height > 0 else { return }

            let playAreaH: CGFloat = {
                if let provider = hooks.bottomAnchorY {
                    let v = provider()
                    if v > 0 { return v }
                }
                return bounds.height
            }()
            let fit = ZoomMath.fitZoom(content: content, viewport: CGSize(width: bounds.width, height: playAreaH))
            let effectiveMin = max(config.minZoom, fit)
            let initial: CGFloat = {
                if let iz = config.initialZoom { return min(config.maxZoom, max(effectiveMin, iz)) }
                return effectiveMin   // nil ⇒ start at fit (free-floating)
            }()

            scrollView.minimumZoomScale = effectiveMin
            scrollView.maximumZoomScale = config.maxZoom
            realMinZoom = effectiveMin
            realMaxZoom = config.maxZoom
            scrollView.zoomScale = initial
            hasSetInitialZoom = true

            applyLayout(in: scrollView)

            // Drone only: frame the start on the world's bottom-right corner
            // (where freshly dealt cards land). Free-floating stays centred.
            if hooks.bottomAnchorY != nil {
                let scaledW = content.width * initial
                if scaledW > bounds.width { scrollView.contentOffset.x = scaledW - bounds.width }
                enforceBottomAnchor(in: scrollView)
            }
            hooks.onTransformChange?(scrollView.zoomScale, scrollView.contentOffset)
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
                if config.hapticsAtLimits { limitHaptic.prepare() }
                hasPulsedAtLimit = false
            case .ended, .cancelled, .failed:
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
