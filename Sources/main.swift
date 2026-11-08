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
        startPermissionWatchdog()
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

    /// Granting Accessibility does not restart the app, and the tap is only
    /// attempted once at launch, so without this the app sits dead until the
    /// user quits and reopens it. Retry quietly while permission is missing.
    private func startPermissionWatchdog() {
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                let settings = Settings.shared
                guard settings.enabled, !EventMapper.shared.isRunning else { return }
                settings.applyRunState()
                if EventMapper.shared.isRunning {
                    self.refreshStatusIcon()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
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

if arguments.contains("--hidlisten") {
    MapperOptions.shared.trace = true
    HIDPlusPlus.listen(seconds: 45)
    exit(0)
}

if arguments.contains("--hidpp") {
    MapperOptions.shared.trace = true
    HIDPlusPlus.probe()
    exit(0)
}

if arguments.contains("--diagnose") || arguments.contains("--headless") {
    EventMapper.shared.diagnoseOnly = arguments.contains("--diagnose")
    // --diagnose exists to dump raw events, so it implies tracing.
    MapperOptions.shared.trace = true
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
    // Tracing can also be switched on without rebuilding:
    //   defaults write com.mustafa.m560mapper trace -bool YES
    MapperOptions.shared.trace = arguments.contains("--trace")
        || UserDefaults.standard.bool(forKey: "trace")
    // The delegate must outlive this scope; NSApplication holds it weakly.
    appDelegate = delegate
    app.run()
}
