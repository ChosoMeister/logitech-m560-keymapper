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
            devices = DeviceCatalog.connected()
        applyDevice(restartMonitor: false)
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

    /// The mouse being acted on, as "vvvv:pppp". Everything the helper does is
    /// filtered to this device, so it can be pointed at mice other than the
    /// M560 it was written for.
    @Published var deviceID: String {
        didSet {
            defaults.set(deviceID, forKey: "deviceID")
            applyDevice()
        }
    }
    @Published var devices: [PointingDevice] = []

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
        deviceID = defaults.string(forKey: "deviceID")
            ?? PointingDevice.identifier(vendorID: defaultVendorID, productID: defaultProductID)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        trace("launch at login: \(Self.describe(SMAppService.mainApp.status))")

        devices = DeviceCatalog.connected()
        applyDevice(restartMonitor: false)
        MapperOptions.shared.middleClick = middleClick
        MapperOptions.shared.spaceSwitching = spaceSwitching
        MapperOptions.shared.tiltNavigation = tiltNavigation
    }

    /// Re-reads the attached devices, keeping the current selection if it is
    /// still present so unplugging something else does not retarget the app.
    func refreshDevices() {
        devices = DeviceCatalog.connected()
    }

    private func applyDevice(restartMonitor: Bool = true) {
        let parts = deviceID.split(separator: ":")
        guard parts.count == 2,
              let vendor = Int64(parts[0], radix: 16),
              let product = Int64(parts[1], radix: 16)
        else { return }
        MapperOptions.shared.vendorID = vendor
        MapperOptions.shared.productID = product
        SenderCache.shared.forget()
        trace("target device: \(deviceID)")
        if restartMonitor, enabled {
            WheelButtonMonitor.restart()
        }
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
            // The monitor posts clicks on its own, so leaving it running would
            // keep the wheel button working while the panel says "paused".
            WheelButtonMonitor.stop()
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
            deviceID = defaults.string(forKey: "deviceID")
            ?? PointingDevice.identifier(vendorID: defaultVendorID, productID: defaultProductID)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
