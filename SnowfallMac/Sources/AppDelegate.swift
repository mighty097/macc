import AppKit
import CoreGraphics

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var overlays: [OverlayEntry] = []
    private var isSnowEnabled = true
    private var finderOnlyEnabled = false
    private var intensity: SnowIntensity = .normal

    private var toggleMenuItem: NSMenuItem!
    private var finderOnlyMenuItem: NSMenuItem!
    private var intensityMenuItems: [NSMenuItem] = []
    private var screenObserver: NSObjectProtocol?
    private var screenSleepObserver: NSObjectProtocol?
    private var screenWakeObserver: NSObjectProtocol?
    private var screensAreAsleep = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()
        rebuildOverlays()
        setSnowEnabled(true)

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rebuildOverlays()
            self?.setSnowEnabled(self?.isSnowEnabled ?? true)
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        screenSleepObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] _ in
            self?.setScreensAsleep(true)
        }
        screenWakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] _ in
            self?.setScreensAsleep(false)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        if let screenSleepObserver { workspaceCenter.removeObserver(screenSleepObserver) }
        if let screenWakeObserver { workspaceCenter.removeObserver(screenWakeObserver) }
        overlays.forEach {
            $0.backgroundView.stop()
            $0.foregroundView.stop()
        }
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Snowfall")
            button.image?.isTemplate = true
            button.toolTip = "Snowfall — снег на окнах"
        }

        let menu = NSMenu()
        menu.delegate = self

        toggleMenuItem = NSMenuItem(title: "Остановить снег", action: #selector(toggleSnow), keyEquivalent: "")
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)

        let clearItem = NSMenuItem(title: "Очистить сугробы", action: #selector(clearSnow), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        finderOnlyMenuItem = NSMenuItem(title: "Только Finder", action: #selector(toggleFinderOnly), keyEquivalent: "")
        finderOnlyMenuItem.target = self
        finderOnlyMenuItem.state = .off
        menu.addItem(finderOnlyMenuItem)
        menu.addItem(.separator())

        let intensityRoot = NSMenuItem(title: "Интенсивность", action: nil, keyEquivalent: "")
        let intensityMenu = NSMenu()
        intensityMenuItems = SnowIntensity.allCases.map { value in
            let item = NSMenuItem(title: value.title, action: #selector(selectIntensity(_:)), keyEquivalent: "")
            item.target = self
            item.tag = value.rawValue
            item.state = value == intensity ? .on : .off
            intensityMenu.addItem(item)
            return item
        }
        intensityRoot.submenu = intensityMenu
        menu.addItem(intensityRoot)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Выйти", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        toggleMenuItem.title = isSnowEnabled ? "Остановить снег" : "Включить снег"
        finderOnlyMenuItem.state = finderOnlyEnabled ? .on : .off
        for item in intensityMenuItems {
            item.state = item.tag == intensity.rawValue ? .on : .off
        }
    }

    private func rebuildOverlays() {
        overlays.forEach {
            $0.backgroundWindow.orderOut(nil)
            $0.foregroundWindow.orderOut(nil)
            $0.backgroundView.stop()
            $0.foregroundView.stop()
        }
        overlays.removeAll()

        for screen in NSScreen.screens {
            let localFrame = NSRect(origin: .zero, size: screen.frame.size)
            let backgroundView = SnowOverlayView(frame: localFrame, screen: screen, renderLayer: .background)
            let foregroundView = SnowOverlayView(frame: localFrame, screen: screen, renderLayer: .foreground)
            backgroundView.intensity = intensity
            foregroundView.intensity = intensity
            foregroundView.finderOnly = finderOnlyEnabled

            let backgroundWindow = makeOverlayWindow(screen: screen, view: backgroundView)
            let foregroundWindow = makeOverlayWindow(screen: screen, view: foregroundView)

            // Keep the distant snow between desktop icons and regular application windows.
            let desktopLevel = Int(CGWindowLevelForKey(.desktopIconWindow)) + 1
            backgroundWindow.level = NSWindow.Level(rawValue: desktopLevel)
            // Above the Dock and application windows, but below the system menu bar.
            foregroundWindow.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)

            overlays.append(OverlayEntry(
                backgroundWindow: backgroundWindow,
                foregroundWindow: foregroundWindow,
                backgroundView: backgroundView,
                foregroundView: foregroundView
            ))
        }
    }

    private func makeOverlayWindow(screen: NSScreen, view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
        window.contentView = view
        return window
    }

    private func setSnowEnabled(_ enabled: Bool) {
        isSnowEnabled = enabled
        for entry in overlays {
            entry.backgroundView.intensity = intensity
            entry.foregroundView.intensity = intensity
            entry.foregroundView.finderOnly = finderOnlyEnabled

            if enabled && !screensAreAsleep {
                entry.backgroundWindow.orderFrontRegardless()
                entry.foregroundWindow.orderFrontRegardless()
                entry.backgroundView.start()
                entry.foregroundView.start()
            } else {
                entry.backgroundView.stop()
                entry.foregroundView.stop()
                entry.backgroundWindow.orderOut(nil)
                entry.foregroundWindow.orderOut(nil)
            }
        }
        toggleMenuItem?.title = enabled ? "Остановить снег" : "Включить снег"
    }

    private func setScreensAsleep(_ asleep: Bool) {
        screensAreAsleep = asleep
        for entry in overlays {
            if asleep || !isSnowEnabled {
                entry.backgroundView.stop()
                entry.foregroundView.stop()
                entry.backgroundWindow.orderOut(nil)
                entry.foregroundWindow.orderOut(nil)
            } else {
                entry.backgroundWindow.orderFrontRegardless()
                entry.foregroundWindow.orderFrontRegardless()
                entry.backgroundView.start()
                entry.foregroundView.start()
            }
        }
    }

    @objc private func toggleSnow() {
        setSnowEnabled(!isSnowEnabled)
    }

    @objc private func clearSnow() {
        for entry in overlays {
            entry.foregroundView.clearSnow()
        }
    }

    @objc private func toggleFinderOnly() {
        finderOnlyEnabled.toggle()
        for entry in overlays {
            entry.foregroundView.finderOnly = finderOnlyEnabled
            entry.foregroundView.clearSnow()
        }
        finderOnlyMenuItem.state = finderOnlyEnabled ? .on : .off
    }

    @objc private func selectIntensity(_ sender: NSMenuItem) {
        guard let selected = SnowIntensity(rawValue: sender.tag) else { return }
        intensity = selected
        for entry in overlays {
            entry.backgroundView.intensity = selected
            entry.foregroundView.intensity = selected
        }
        for item in intensityMenuItems {
            item.state = item.tag == selected.rawValue ? .on : .off
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private struct OverlayEntry {
    let backgroundWindow: NSWindow
    let foregroundWindow: NSWindow
    let backgroundView: SnowOverlayView
    let foregroundView: SnowOverlayView
}
