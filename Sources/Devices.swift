import Foundation
import IOKit.hid

/// A pointing device the helper can be pointed at. Identified by vendor and
/// product id, which is what both the IOKit registry lookups and the HID++
/// matching dictionaries need.
struct PointingDevice: Identifiable, Hashable {
    let vendorID: Int64
    let productID: Int64
    let name: String
    /// True when the device exposes a vendor collection, which is where extra
    /// buttons report themselves on a Logitech receiver.
    let hasVendorCollection: Bool
    /// True when it presents a mouse collection. Devices without one are not
    /// pointing devices at all, whatever else they expose.
    let hasMouseCollection: Bool

    var id: String { Self.identifier(vendorID: vendorID, productID: productID) }

    static func identifier(vendorID: Int64, productID: Int64) -> String {
        String(format: "%04x:%04x", vendorID, productID)
    }

    var hexIdentifier: String { id }
}

/// The devices currently attached, as the picker in the panel shows them.
enum DeviceCatalog {
    /// Anything that presents as a mouse, plus its sibling collections on the
    /// same physical device, collapsed to one entry per vendor/product pair.
    static func connected() -> [PointingDevice] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>
        else { return [] }

        var found: [String: PointingDevice] = [:]
        for device in devices {
            guard let vendor = number(device, kIOHIDVendorIDKey),
                  let product = number(device, kIOHIDProductIDKey)
            else { continue }
            let page = number(device, kIOHIDPrimaryUsagePageKey) ?? 0
            let usage = number(device, kIOHIDPrimaryUsageKey) ?? 0

            let isMouse = page == 0x01 && (usage == 0x02 || usage == 0x01)
            let isVendorCollection = page == 0xFF00
            guard isMouse || isVendorCollection else { continue }

            let key = PointingDevice.identifier(vendorID: vendor, productID: product)
            let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String)
                ?? "Unknown device"
            let existing = found[key]
            found[key] = PointingDevice(
                vendorID: vendor,
                productID: product,
                name: existing?.name ?? name,
                hasVendorCollection: isVendorCollection || (existing?.hasVendorCollection ?? false),
                hasMouseCollection: isMouse || (existing?.hasMouseCollection ?? false)
            )
        }

        // Keyboard backlights and motion sensors also expose vendor
        // collections; without a mouse collection they are not candidates.
        return found.values
            .filter(\.hasMouseCollection)
            .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    private static func number(_ device: IOHIDDevice, _ key: String) -> Int64? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.int64Value
    }
}
