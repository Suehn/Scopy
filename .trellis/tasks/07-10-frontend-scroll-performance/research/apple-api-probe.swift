import AppKit
import QuartzCore

@MainActor
private final class DisplayLinkTarget: NSObject {
    @objc func tick(_ displayLink: CADisplayLink) {
        _ = displayLink.targetTimestamp
    }
}

@MainActor
private func verifyAppKitContracts(
    view: NSView,
    scrollView: NSScrollView,
    event: NSEvent,
    target: DisplayLinkTarget
) {
    let viewDisplayLink = view.displayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))
    viewDisplayLink.add(to: .main, forMode: .common)
    viewDisplayLink.invalidate()

    if let screen = view.window?.screen ?? NSScreen.main {
        let screenDisplayLink = screen.displayLink(
            target: target,
            selector: #selector(DisplayLinkTarget.tick(_:))
        )
        screenDisplayLink.add(to: .main, forMode: .common)
        screenDisplayLink.invalidate()
    }

    _ = scrollView.verticalScroller?.testPart(event.locationInWindow)
    _ = scrollView.horizontalScroller?.testPart(event.locationInWindow)

    let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) {
        monitoredEvent in
        monitoredEvent
    }
    if let monitor {
        NSEvent.removeMonitor(monitor)
    }

    _ = NSScrollView.willStartLiveScrollNotification
    _ = NSScrollView.didEndLiveScrollNotification
    _ = NSScreen.main?.maximumFramesPerSecond
}
