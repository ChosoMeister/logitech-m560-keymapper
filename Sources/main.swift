import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var eventMonitor: Any?
    private var observation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = Settings.shared

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "computermouse.fill",
            accessibilityDescription: "M560 Mapper"
        )
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))

        popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PanelView(settings: settings))

        settings.applyRunState()
        if settings.enabled, settings.permissionDenied {
            settings.requestAccessibilityPermission()
        }
        refreshStatusIcon()

        // Keep the menu bar glyph in step with the on/off switch.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatusIcon() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        EventMapper.shared.stop()
    }

    private func refreshStatusIcon() {
        let on = Settings.shared.enabled && !Settings.shared.permissionDenied
        statusItem.button?.appearsDisabled = !on
        statusItem.button?.toolTip = on ? "M560 Mapper — active" : "M560 Mapper — paused"
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        }
    }
}

// MARK: - Entry point

nonisolated(unsafe) var appDelegate: AppDelegate?

let arguments = CommandLine.arguments

if arguments.contains("--check-permissions") {
    print("accessibilityTrusted=\(AXIsProcessTrusted())")
    exit(0)
}

if arguments.contains("--diagnose") || arguments.contains("--headless") {
    EventMapper.shared.diagnoseOnly = arguments.contains("--diagnose")
    MapperOptions.shared.trace = arguments.contains("--trace")
    guard EventMapper.shared.start() else {
        fputs("Could not create the input event tap. Grant Accessibility/Input Monitoring access and run it again.\n", stderr)
        exit(2)
    }
    print(EventMapper.shared.diagnoseOnly
        ? "M560 diagnostic active (read-only). Press the requested button, then Control-C to stop."
        : "M560 mapper active (headless). Press Control-C to stop.")
    CFRunLoopRun()
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    MapperOptions.shared.trace = arguments.contains("--trace")
    // The delegate must outlive this scope; NSApplication holds it weakly.
    appDelegate = delegate
    app.run()
}
