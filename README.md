# ZoomableContainerKit

A reusable, native-feeling `UIScrollView`-backed zoomable SwiftUI container —
no host-app dependencies. Pinch zoom is UIScrollView's **built-in** (focal-point,
inset-aware) pinch; the package only positions content, ticks a limit haptic,
runs double-tap, mirrors the transform, and arbitrates pinch vs. child taps/drags.

Used by **Hansard** (free-floating chambers) and **DaDeckOfCards** (a bottom-anchored
"drone camera" over a card table) from one source of truth.

## Why UIScrollView

`UIScrollView.zoomScale` mutates `layer.transform` on the render server, off the
SwiftUI update graph — smooth over hundreds of hosted subviews. A `@State`-driven
transform re-evaluates the enclosing `ForEach` body every gesture tick, which tanks
large trees. As of iOS 26 there is still no native SwiftUI 2D zoom that avoids that.

## API

```swift
ZoomableContainer(
    contentSize: CGSize,
    config: ZoomConfig = .init(),   // static knobs
    hooks:  ZoomHooks  = .init(),   // optional @MainActor closures
    refitKey: AnyHashable? = nil,   // change to re-frame to initialZoom
) { /* your SwiftUI content */ }
```

`ZoomConfig` — `maxZoom`, `minZoom`, `initialZoom` (`nil` = start at fit),
`doubleTapEnabled`, `doubleTapZoomMultiplier`, `hapticsAtLimits`, `bouncesZoom`,
`decelerationFast`, `hostedContentHeight`.

`ZoomHooks` — `elementIdAtPoint` (two-fingers-on-two-elements veto), `panVeto`,
`hitTestBypass`, `pinchAllowed`, `onTransformChange`, `bottomAnchorY` (drone pin).
Each `nil` (default) gives the Photos-app behaviour for that axis.

## Two patterns

**Free-floating (Hansard):** content centres in both axes; springy zoom-out.

```swift
ZoomableContainer(contentSize: layout.size,
                  config: ZoomConfig(maxZoom: 5)) {
    CommonsChamberView(...)
}
```

**Drone camera (DaDeckOfCards):** content's bottom pins to an anchor line; hard
floor (no below-fit shrink).

```swift
ZoomableContainer(
    contentSize: TableCoordinateSystem.tableSize,
    config: ZoomConfig(maxZoom: 3, minZoom: tableMinZoom, initialZoom: padStartScale,
                       doubleTapEnabled: false, bouncesZoom: false,
                       decelerationFast: true, hostedContentHeight: tallerSurface),
    hooks: ZoomHooks(elementIdAtPoint: { deck.cardId(at: $0).map(AnyHashable.init) },
                     panVeto: { deck.shouldVetoTablePan(at: $0) },
                     hitTestBypass: { ... },
                     onTransformChange: { z, o in deck.mirror(z, o) },
                     bottomAnchorY: { deck.handLineY })
) { TableView(...) }
```

## Resizing

A change of size (an iPhone Duo fold, a turn, a new `hostedContentHeight`, new
content) frames a camera the user has not moved afresh, as on its first layout,
so a first framing on a placeholder layout does not stick. A camera the user has
moved keeps its zoom, clamped to the new limits; a camera zoomed all the way out
stays all the way out. The free-floating camera keeps the same fraction of the
content in the middle of the view; the drone camera re-runs its bottom-right
framing. A resize that arrives in steps (the bounds, then the content or the
anchor) carries the place the user left at every step, not the clamp of the step
before. Only a new `refitKey` starts a moved camera over.

A fraction of the content is the same place only while the layout keeps its
shape. A host whose layout transposes, running across in a wide window and down
in a tall one, must change `refitKey` when it transposes (for example
`refitKey: isLandscape`), so a turn starts the camera over rather than landing
on a different part of the content at the old zoom.

## Testing

Pure logic (`ZoomMath`: fit-zoom, anchor clamp, the zoom and place carried
across a resize, pinch veto, double-tap rect) is unit-tested.
`ZoomableContainerResizeTests` drives the real scroll view, hosted in a window,
through resizes in both modes. Gesture feel, native-pinch precedence, haptics,
bounce, and a real fold are verified on device.

```
xcodebuild -scheme ZoomableContainerKit -destination 'platform=iOS Simulator,name=iPhone 17' test
```

Platform floor: iOS 16 (so both apps can depend on it). Swift 6 language mode.
