import AppKit

// `main.swift` is Swift's special top-level entry-point file.
// Do not combine it with the `@main` attribute.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let appDelegate = AppDelegate()
application.delegate = appDelegate

application.run()

