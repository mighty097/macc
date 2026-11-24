import AppKit
import CoreGraphics
import ApplicationServices
import CoreFoundation

struct WindowSurfaceInfo {
    let windowID: CGWindowID
    let ownerName: String
    let frame: CGRect // AppKit points, relative to the target display, bottom-left origin.
}

enum WindowGeometryProvider {
    static func visibleWindowSurfaces(on screen: NSScreen) -> [WindowSurfaceInfo] {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return []
        }

        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        let quartzDisplayFrame = CGDisplayBounds(displayID)
        let cocoaDisplayFrame = screen.frame
        let ownPID = ProcessInfo.processInfo.processIdentifier

        guard let entries = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        var results: [WindowSurfaceInfo] = []
        results.reserveCapacity(entries.count)

        // Core Graphics returns visible windows front-to-back. Preserve that ordering;
        // the renderer uses it to stop snow landing on occluded parts of background windows.
        for entry in entries {
            let ownerPID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            if ownerPID == ownPID { continue }

            let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            guard layer == 0 else { continue }

            let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0
            guard alpha > 0.05 else { continue }

            guard
                let rawBounds = entry[kCGWindowBounds as String] as? NSDictionary,
                let quartzRect = CGRect(dictionaryRepresentation: rawBounds as CFDictionary),
                quartzRect.width >= 90,
                quartzRect.height >= 45
            else {
                continue
            }

            let cocoaRect = CGRect(
                x: cocoaDisplayFrame.minX + quartzRect.minX - quartzDisplayFrame.minX,
                y: cocoaDisplayFrame.minY + quartzDisplayFrame.maxY - quartzRect.maxY,
                width: quartzRect.width,
                height: quartzRect.height
            )
            let clipped = cocoaRect.intersection(cocoaDisplayFrame)
            guard !clipped.isNull, clipped.width > 90, clipped.height > 30 else { continue }

            let windowID = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
            guard windowID != 0 else { continue }
            let ownerName = entry[kCGWindowOwnerName as String] as? String ?? "Unknown"

            results.append(WindowSurfaceInfo(
                windowID: windowID,
                ownerName: ownerName,
                frame: clipped.offsetBy(dx: -cocoaDisplayFrame.minX, dy: -cocoaDisplayFrame.minY)
            ))
        }
        return results
    }

    // MARK: Dock geometry via Accessibility

    private static var dockAXCacheDate: TimeInterval = 0
    private static var dockAXCacheWasRead = false
    private static var cachedDockAXFrame: CGRect?

    /// Returns the bottom Dock panel as a rectangle local to this display.
    /// The AXList describes the actual Dock strip; full-screen Dock helper
    /// windows from CGWindowList are intentionally not used as geometry.
    static func dockSurfaceFrame(on screen: NSScreen) -> CGRect? {
        guard let axFrame = currentDockAXFrame(),
              let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }

        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        let quartzDisplayFrame = CGDisplayBounds(displayID)
        guard quartzDisplayFrame.width > 0, quartzDisplayFrame.height > 0 else { return nil }

        // kAXPositionAttribute and CGDisplayBounds both use global top-left
        // coordinates. SnowfallMac's NSView uses local bottom-left coordinates.
        let localFrame = CGRect(
            x: axFrame.minX - quartzDisplayFrame.minX,
            y: quartzDisplayFrame.maxY - axFrame.maxY,
            width: axFrame.width,
            height: axFrame.height
        )
        let displayBounds = CGRect(origin: .zero, size: screen.frame.size)
        let clipped = localFrame.intersection(displayBounds)
        guard !clipped.isNull, !clipped.isEmpty else { return nil }

        // This implementation intentionally recognizes a horizontal Dock at
        // the bottom edge. It rejects the full-display helper window and other
        // unrelated AX lists. Side/top Dock layouts can be added separately.
        guard clipped.minY <= 100,
              clipped.maxY <= 220,
              clipped.width >= max(160, displayBounds.width * 0.15),
              clipped.width <= displayBounds.width * 0.95,
              clipped.height >= 28,
              clipped.height <= 180 else {
            return nil
        }
        return clipped
    }

    private static func currentDockAXFrame() -> CGRect? {
        let now = ProcessInfo.processInfo.systemUptime
        if dockAXCacheWasRead, now - dockAXCacheDate < 1.0 {
            return cachedDockAXFrame
        }
        dockAXCacheWasRead = true
        dockAXCacheDate = now
        cachedDockAXFrame = nil

        // Accessibility permission is per process. Terminal permission used
        // by the diagnostic script does not automatically authorize the app.
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.dock"
              ).first else {
            return nil
        }

        let application = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var candidates: [CGRect] = []
        var visited = 0

        func readAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return error == .success ? value : nil
        }

        func readFrame(_ element: AXUIElement) -> CGRect? {
            guard let positionRef = readAttribute(element, "AXPosition"),
                  let sizeRef = readAttribute(element, "AXSize"),
                  CFGetTypeID(positionRef) == AXValueGetTypeID(),
                  CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
                return nil
            }
            let positionValue = positionRef as! AXValue
            let sizeValue = sizeRef as! AXValue
            var position = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(positionValue, .cgPoint, &position),
                  AXValueGetValue(sizeValue, .cgSize, &size),
                  size.width > 0, size.height > 0 else {
                return nil
            }
            return CGRect(origin: position, size: size)
        }

        func walk(_ element: AXUIElement, depth: Int) {
            guard visited < 250, depth <= 6 else { return }
            visited += 1

            if let role = readAttribute(element, "AXRole") as? String,
               role == "AXList",
               let frame = readFrame(element),
               frame.width >= 160,
               frame.height >= 28,
               frame.height <= 180 {
                candidates.append(frame)
            }

            guard let childrenValue = readAttribute(element, "AXChildren"),
                  let children = childrenValue as? [AXUIElement] else {
                return
            }
            for child in children {
                walk(child, depth: depth + 1)
                if visited >= 250 { break }
            }
        }

        walk(application, depth: 0)
        // The Dock's primary AXList is the broadest candidate; individual
        // AXDockItem rectangles are deliberately not treated as separate ledges.
        cachedDockAXFrame = candidates.max {
            ($0.width * $0.height) < ($1.width * $1.height)
        }
        return cachedDockAXFrame
    }

}
