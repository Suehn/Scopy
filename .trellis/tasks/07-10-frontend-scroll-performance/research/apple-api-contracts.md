# Apple API Contracts for the Scroll Work

## Source policy

The project-requested local Cupertino server was unavailable and its upstream repository returned HTTP 404 on 2026-07-10. With user authorization, Codex now has a user-level MCP named `cupertino` backed by `https://xdocs.dev/mcp` (`apple-docs` server 3.4.3, unauthenticated). The server was initialized, its tools were listed, and an AppKit search plus document expansion succeeded. Direct Apple Developer pages remain the source links; the current compiler is the final signature/availability check.

## Verified contracts

- `NSView.displayLink(target:selector:) -> CADisplayLink` and `NSScreen.displayLink(target:selector:) -> CADisplayLink` are macOS 14 AppKit entry points. The view-owned link follows the view and suspends while it is hidden/off-display; the screen-owned link follows the chosen display without that view-visibility gate. The deterministic test driver therefore uses the current scroll view's screen (falling back to the main screen) while still applying commands to the production `NSScrollView`. Sources: https://developer.apple.com/documentation/appkit/nsview/displaylink(target:selector:) and https://developer.apple.com/documentation/appkit/nsscreen/displaylink(target:selector:).
- `NSScreen.maximumFramesPerSecond: Int` reports the screen's supported maximum rate; it is a capability/threshold input, not proof that frames were presented. Source: https://developer.apple.com/documentation/appkit/nsscreen/maximumframespersecond.
- `NSEvent.addLocalMonitorForEvents(matching:handler:) -> Any?` observes app events before normal dispatch and the handler returns the event (or `nil` to stop dispatch). Apple warns nested control/menu tracking loops may consume events before the monitor sees them, so owned detach/live-scroll cleanup is still required. Source: https://developer.apple.com/documentation/appkit/nsevent/addlocalmonitorforevents(matching:handler:).
- `NSScroller.testPart(_ point: NSPoint) -> NSScroller.Part` expects a window-coordinate point and reports the part a mouse-down would hit; `.noPart` is the non-actionable result. This is safer than treating the whole scroll view as a scrollbar. Source: https://developer.apple.com/documentation/appkit/nsscroller/testpart(_:).
- `NSScrollView.verticalScroller` and `horizontalScroller` may be non-`nil` even when not displayed. Hit testing must therefore include view/window visibility and `testPart`, not property existence alone. Source: https://developer.apple.com/documentation/appkit/nsscrollview/verticalscroller.
- `NSScrollView.willStartLiveScrollNotification` and `.didEndLiveScrollNotification` are main-thread live-tracking boundaries available since macOS 10.9; Apple explicitly includes scroller tracking such as thumb dragging. Source: https://developer.apple.com/documentation/appkit/nsscrollview/willstartlivescrollnotification and https://developer.apple.com/documentation/appkit/nsscrollview/didendlivescrollnotification.
- `NSWindow.didChangeOcclusionStateNotification` is available since macOS 10.9. Its notification object is the affected `NSWindow`; after receiving it, code reads the window's current `occlusionState` and can stop work the user cannot see. This is the compatible panel-clock visibility boundary; the macOS 26-only concurrency message is intentionally not used. Source: https://developer.apple.com/documentation/appkit/nswindow/didchangeocclusionstatenotification and https://developer.apple.com/documentation/appkit/nswindow/occlusionstate-swiftproperty.

## Availability decision

`project.yml` targets macOS 14.0, and both AppKit display-link entry points were introduced with macOS 14. They therefore do not need a runtime fallback inside this project baseline. No macOS 26/27-only notification-message APIs will be used; the existing notification names, including `NSWindow.didChangeOcclusionStateNotification`, remain the compatible path.

`apple-api-probe.swift` is compiled with `-target arm64-apple-macos14.0` to prove the exact Swift signatures used by the implementation.
