//
//  ZoomConfig.swift
//  ZoomableContainerKit
//
//  The public configuration surface. Everything host-specific enters the
//  container through these two value types — there are no host-type
//  references inside the package. `ZoomConfig` is the static knobs;
//  `ZoomHooks` is the optional closures (all `@MainActor`, since they run
//  inside UIKit gesture/scroll callbacks on the main thread).
//

import CoreGraphics

/// Static configuration. Defaults reproduce a Photos-style free-floating
/// zoom; override fields for a bespoke surface (e.g. a card table).
public struct ZoomConfig: Sendable {
    /// Absolute upper zoom bound (1.0 = unscaled content pixels).
    public var maxZoom: CGFloat
    /// Additional caller floor, combined with the dynamic fit-zoom via
    /// `max`, so the effective minimum is whichever is higher — the user can
    /// never zoom out past "content fills the play area." Default `0` means
    /// fit-zoom is the only floor (the free-floating case); a drone camera
    /// passes a higher value to tighten it.
    public var minZoom: CGFloat
    /// Scale applied at first valid layout. `nil` (default) starts at the
    /// fit-zoom (whole content visible) — the free-floating case. A value
    /// starts the camera at that scale, clamped into `[effectiveMin, maxZoom]`.
    public var initialZoom: CGFloat?
    /// When false, double-tap does nothing — the host owns double-tap.
    public var doubleTapEnabled: Bool
    /// Double-tap target scale = `effectiveMin * doubleTapZoomMultiplier`.
    public var doubleTapZoomMultiplier: CGFloat
    /// Soft haptic on the first frame a pinch bounces past a zoom limit.
    public var hapticsAtLimits: Bool
    /// Native `UIScrollView.bouncesZoom` — springy rubber-band past BOTH
    /// limits. `true` (default) reads like Photos. Set `false` for a hard
    /// floor (e.g. a drone camera that must not shrink the world below the
    /// play area); note this also removes the spring at max.
    public var bouncesZoom: Bool
    /// `.fast` deceleration (arrested pan, card table) vs `.normal`
    /// (gliding exploration, the default).
    public var decelerationFast: Bool
    /// Optional override for the HOSTED VIEW's height, decoupled from
    /// `contentSize`. When set LARGER than `contentSize.height`, the hosted
    /// SwiftUI surface extends below the content world (so content drawn
    /// below `contentSize.height` stays hittable) while fit-zoom,
    /// `scrollView.contentSize`, and the bottom anchor keep referencing
    /// `contentSize.height`. `nil` (default) sizes the hosted view exactly
    /// to `contentSize`.
    public var hostedContentHeight: CGFloat?

    public init(
        maxZoom: CGFloat = 3.0,
        minZoom: CGFloat = 0,
        initialZoom: CGFloat? = nil,
        doubleTapEnabled: Bool = true,
        doubleTapZoomMultiplier: CGFloat = 2.5,
        hapticsAtLimits: Bool = true,
        bouncesZoom: Bool = true,
        decelerationFast: Bool = false,
        hostedContentHeight: CGFloat? = nil
    ) {
        self.maxZoom = maxZoom
        self.minZoom = minZoom
        self.initialZoom = initialZoom
        self.doubleTapEnabled = doubleTapEnabled
        self.doubleTapZoomMultiplier = doubleTapZoomMultiplier
        self.hapticsAtLimits = hapticsAtLimits
        self.bouncesZoom = bouncesZoom
        self.decelerationFast = decelerationFast
        self.hostedContentHeight = hostedContentHeight
    }
}

/// Optional host callbacks. Each `nil` (the default) yields the Photos-app
/// behaviour for that axis. All run on the main actor (UIKit gesture/scroll
/// callbacks), so closures may touch `@MainActor` host state directly.
public struct ZoomHooks {
    /// Stable identifier for the interactive element at a *content* point,
    /// or `nil` on empty background. When set, a two-finger touch on two
    /// *different* non-nil elements is read as two drags and the pinch is
    /// vetoed (both the zoom and the tap-cancel arbitrator).
    public var elementIdAtPoint: (@MainActor (CGPoint) -> AnyHashable?)?
    /// Single-finger pan veto, called with the touch in *content* coords
    /// before the scroll view's pan begins. Return `true` to suppress the
    /// pan so a SwiftUI `DragGesture` on the hit element can claim it.
    public var panVeto: (@MainActor (CGPoint) -> Bool)?
    /// Hit-test passthrough, called with the touch in *viewport* (window)
    /// coords. Return `true` to make the scroll view transparent there so
    /// the touch falls through to chrome beneath it.
    public var hitTestBypass: (@MainActor (CGPoint) -> Bool)?
    /// Global pinch gate, checked before any element veto. Return `false`
    /// to suppress pinch outright (e.g. "a card drag is in progress").
    public var pinchAllowed: (@MainActor () -> Bool)?
    /// Called every zoom/scroll frame with the current transform — mirror
    /// it onto observable host state (a zoom badge, a shared offset).
    public var onTransformChange: (@MainActor (_ zoomScale: CGFloat, _ contentOffset: CGPoint) -> Void)?
    /// Viewport-Y to pin the content's bottom to on every tick (the drone
    /// camera). `nil` (default) = free-floating: the content is centred in
    /// both axes and there is no bottom anchor.
    public var bottomAnchorY: (@MainActor () -> CGFloat)?

    public init(
        elementIdAtPoint: (@MainActor (CGPoint) -> AnyHashable?)? = nil,
        panVeto: (@MainActor (CGPoint) -> Bool)? = nil,
        hitTestBypass: (@MainActor (CGPoint) -> Bool)? = nil,
        pinchAllowed: (@MainActor () -> Bool)? = nil,
        onTransformChange: (@MainActor (_ zoomScale: CGFloat, _ contentOffset: CGPoint) -> Void)? = nil,
        bottomAnchorY: (@MainActor () -> CGFloat)? = nil
    ) {
        self.elementIdAtPoint = elementIdAtPoint
        self.panVeto = panVeto
        self.hitTestBypass = hitTestBypass
        self.pinchAllowed = pinchAllowed
        self.onTransformChange = onTransformChange
        self.bottomAnchorY = bottomAnchorY
    }
}
