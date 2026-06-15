//
//  ZoomableContainer.swift
//  ZoomableContainerKit
//
//  A reusable UIScrollView-backed zoomable SwiftUI container — no host-app
//  dependencies. Everything host-specific enters via `ZoomConfig` (knobs)
//  and `ZoomHooks` (optional closures).
//
//  Why UIScrollView (not SwiftUI MagnifyGesture + scaleEffect)
//    `UIScrollView.zoomScale` mutates `layer.transform` on the render
//    server, off the SwiftUI update graph — smooth over hundreds of hosted
//    subviews. A `@State`-driven transform re-evaluates the enclosing
//    `ForEach` body every gesture tick, which tanks large trees (a 650-seat
//    chamber, a 52-card table). As of iOS 26 there is still no native
//    SwiftUI 2D zoom that avoids that, so this representable is the substrate.
//
//  Pinch model
//    UIScrollView's BUILT-IN pinch owns zoom + focal anchoring (inset-aware,
//    atomic). A no-zoom arbitrator recogniser rides alongside it, cancelling
//    in-flight child taps on two-finger-down (so no stray navigation fires
//    mid-pinch) and ticking the limit haptic. Two-fingers-on-two-elements is
//    vetoed (both the zoom and the arbitrator) so it reads as two drags.
//

import SwiftUI
import UIKit

public struct ZoomableContainer<Content: View>: UIViewRepresentable {
    /// Unscaled size of the content world. Drives fit-zoom and the
    /// bottom-anchor reference height.
    public let contentSize: CGSize
    public var config: ZoomConfig
    public var hooks: ZoomHooks
    /// When this value changes (after the first layout), the camera re-frames
    /// to `config.initialZoom` — e.g. resetting framing on entering a match.
    public var refitKey: AnyHashable?
    @ViewBuilder public var content: () -> Content

    public init(
        contentSize: CGSize,
        config: ZoomConfig = ZoomConfig(),
        hooks: ZoomHooks = ZoomHooks(),
        refitKey: AnyHashable? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.contentSize = contentSize
        self.config = config
        self.hooks = hooks
        self.refitKey = refitKey
        self.content = content
    }

    /// Hosted-view size: `contentSize` width, height overridden when
    /// `config.hostedContentHeight` is set (taller hittable surface).
    private var hostedSize: CGSize {
        CGSize(width: contentSize.width, height: config.hostedContentHeight ?? contentSize.height)
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeUIView(context: Context) -> UIScrollView {
        let scrollView = VetoingScrollView()
        scrollView.delegate = context.coordinator
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.bouncesZoom = config.bouncesZoom
        scrollView.bounces = true
        scrollView.decelerationRate = config.decelerationFast ? .fast : .normal
        scrollView.minimumZoomScale = 0.1
        scrollView.maximumZoomScale = config.maxZoom
        scrollView.backgroundColor = .clear

        // Drone camera manages insets explicitly — stop UIKit auto-adjusting.
        if hooks.bottomAnchorY != nil {
            scrollView.contentInsetAdjustmentBehavior = .never
        }
        // Per-element drag surface: forward single-finger touches to child
        // SwiftUI gestures immediately (low-latency card drags). We must NOT
        // set canCancelContentTouches=false — the built-in pinch needs to
        // cancel content touches to take over and zoom, and disabling that
        // kills pinch outright. Single-finger drags are instead protected
        // from the scroll pan by panVeto at shouldBegin (finger-count
        // independent), so leaving canCancelContentTouches at its default
        // (true) gives working pinch AND working drags.
        if hooks.panVeto != nil {
            scrollView.delaysContentTouches = false
        }
        scrollView.panVeto = hooks.panVeto
        scrollView.hitTestBypass = hooks.hitTestBypass
        scrollView.builtInPinchShouldBegin = { [weak coordinator = context.coordinator] pinch in
            coordinator?.pinchAllowedToBegin(pinch) ?? true
        }

        // Built-in pinch stays enabled; arbitrator rides alongside.
        let arbitrator = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleArbitratorPinch(_:))
        )
        arbitrator.delegate = context.coordinator
        arbitrator.cancelsTouchesInView = true
        scrollView.addGestureRecognizer(arbitrator)

        if config.doubleTapEnabled {
            let doubleTap = UITapGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handleDoubleTap(_:))
            )
            doubleTap.numberOfTapsRequired = 2
            scrollView.addGestureRecognizer(doubleTap)
        }

        // View-only hosting adapter — no addChild, so no double appearance
        // callbacks. The hosted tree reads SwiftUI environment from its
        // SwiftUI parent, not the UIKit responder chain.
        let hosting = UIHostingController(rootView: content())
        hosting.view.backgroundColor = .clear
        hosting.view.frame = CGRect(origin: .zero, size: hostedSize)
        scrollView.addSubview(hosting.view)
        scrollView.contentSize = contentSize
        context.coordinator.hostedView = hosting.view
        context.coordinator.hostingController = hosting

        sync(context.coordinator)
        context.coordinator.seenRefitKey = refitKey
        context.coordinator.hasSeenRefitKey = true

        scrollView.onFirstValidLayout = { [weak scrollView, weak coordinator = context.coordinator] in
            guard let scrollView, let coordinator else { return }
            coordinator.applyInitialZoom(in: scrollView)
        }
        return scrollView
    }

    public func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.hostingController?.rootView = content()
        sync(context.coordinator)
        if let vetoing = scrollView as? VetoingScrollView {
            vetoing.panVeto = hooks.panVeto
            vetoing.hitTestBypass = hooks.hitTestBypass
        }

        // Resize when the hosted size changes. Compare against bounds.size,
        // NOT frame.size — the zoom transform inflates frame.size by
        // zoomScale and would trip a false reset loop every tick.
        let currentSize = context.coordinator.hostedView?.bounds.size ?? .zero
        if currentSize != hostedSize {
            context.coordinator.hostedView?.frame = CGRect(origin: .zero, size: hostedSize)
            scrollView.contentSize = contentSize
            context.coordinator.hasSetInitialZoom = false
        }

        // Re-fit on a refitKey transition (after the makeUIView seed), unless
        // a pinch is in flight — never yank the user's zoom mid-gesture.
        if context.coordinator.hasSeenRefitKey,
           context.coordinator.seenRefitKey != refitKey,
           !context.coordinator.isPinching {
            context.coordinator.seenRefitKey = refitKey
            context.coordinator.hasSetInitialZoom = false
        }

        let bounds = scrollView.bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return }

        // Keep canonical limits synced (mirror applyInitialZoom's fit math).
        let playAreaH: CGFloat = {
            if let provider = hooks.bottomAnchorY {
                let v = provider()
                if v > 0 { return v }
            }
            return bounds.height
        }()
        let fit = ZoomMath.fitZoom(content: contentSize, viewport: CGSize(width: bounds.width, height: playAreaH))
        let effectiveMin = max(config.minZoom, fit)
        scrollView.minimumZoomScale = effectiveMin
        scrollView.maximumZoomScale = config.maxZoom
        context.coordinator.realMinZoom = effectiveMin
        context.coordinator.realMaxZoom = config.maxZoom

        context.coordinator.applyInitialZoom(in: scrollView)
    }

    private func sync(_ coordinator: Coordinator) {
        coordinator.config = config
        coordinator.hooks = hooks
        coordinator.contentWorldSize = contentSize
    }
}
