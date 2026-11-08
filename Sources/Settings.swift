import AppKit
import Combine
import ServiceManagement

/// User-visible state, persisted in UserDefaults and mirrored into the
/// lock-protected options the event tap reads on its own thread.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "enabled")
            applyRunState()
        }
    }
    @Published var middleClick: Bool {
        didSet {
            defaults.set(middleClick, forKey: "middleClick")
            MapperOptions.shared.middleClick = middleClick
        }
    }
    @Published var spaceSwitching: Bool {
        didSet {
            defaults.set(spaceSwitching, forKey: "spaceSwitching")
            MapperOptions.shared.spaceSwitching = spaceSwitching
        }
    }
    @Published var tiltNavigation: Bool {
        didSet {
            defaults.set(tiltNavigation, forKey: "tiltNavigation")
            MapperOptions.shared.tiltNavigation = tiltNavigation
        }
    }
    @Published var launchAtLogin: Bool {
        didSet { applyLoginItem() }
    }
    /// Set when the tap could not be created, i.e. permission is missing.
    @Published var permissionDenied = false

    private init() {
        defaults.register(defaults: [
            "enabled": true,
            "middleClick": true,
            "spaceSwitching": true,
            "tiltNavigation": true,
        ])
        enabled = defaults.bool(forKey: "enabled")
        middleClick = defaults.bool(forKey: "middleClick")
        spaceSwitching = defaults.bool(forKey: "spaceSwitching")
        tiltNavigation = defaults.bool(forKey: "tiltNavigation")
        launchAtLogin = SMAppService.mainApp.status == .enabled
        trace("launch at login: \(Self.describe(SMAppService.mainApp.status))")

        MapperOptions.shared.middleClick = middleClick
        MapperOptions.shared.spaceSwitching = spaceSwitching
        MapperOptions.shared.tiltNavigation = tiltNavigation
    }

    static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "enabled"
        case .notRegistered: return "notRegistered"
        case .notFound: return "notFound"
        case .requiresApproval: return "requiresApproval"
        @unknown default: return "unknown"
        }
    }

    var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    func applyRunState() {
        if enabled {
            let started = EventMapper.shared.start()
            if started, !WheelButtonMonitor.isRunning {
                _ = WheelButtonMonitor.start()
            }
            permissionDenied = !started
        } else {
            EventMapper.shared.stop()
            permissionDenied = false
        }
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
    }

    private func applyLoginItem() {
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            trace("launch at login -> \(Self.describe(SMAppService.mainApp.status))")
        } catch {
            trace("launch at login change failed: \(error.localizedDescription)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
