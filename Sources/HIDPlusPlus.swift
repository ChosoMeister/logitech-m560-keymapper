import Foundation
import IOKit.hid

/// Probe for talking to the mouse over HID++ instead of reading the keyboard
/// chords its firmware emits. The chords are unreliable — some presses send
/// one chord, some the other, some both — so the aim is to ask the device to
/// divert the wheel button and report it as a raw HID++ notification instead.
///
/// Writing to the receiver's vendor collection needs Input Monitoring, which
/// is why this runs inside the signed bundle rather than from a shell.
enum HIDPlusPlus {
    private static let shortReportID: CFIndex = 0x10
    private static let softwareID: UInt8 = 0x0a

    static func probe() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: Int(targetVendorID),
            kIOHIDProductIDKey: Int(targetReceiverProductID),
        ] as CFDictionary)

        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>
        else {
            report("manager open failed: Input Monitoring denied")
            return
        }

        let vendorCollection = devices.first { device in
            (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?
                .intValue == 0xFF00
        }
        guard let device = vendorCollection else {
            report("no HID++ collection on the receiver")
            return
        }

        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            report("device open failed: \(describe(openResult))")
            return
        }
        defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

        let inbox = Inbox()
        var buffer = [UInt8](repeating: 0, count: 64)
        IOHIDDeviceRegisterInputReportCallback(device, &buffer, buffer.count, { context, _, _, _, reportID, bytes, length in
            let inbox = Unmanaged<Inbox>.fromOpaque(context!).takeUnretainedValue()
            var report: [UInt8] = [UInt8(reportID)]
            report.append(contentsOf: UnsafeBufferPointer(start: bytes, count: length))
            inbox.append(report)
        }, Unmanaged.passUnretained(inbox).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        report("HID++ collection open; pinging device slots")
        var reachable = false
        for slot: UInt8 in 1...6 {
            guard let pong = exchange(device, inbox, [0x10, slot, 0x00, 0x10 | softwareID, 0x00, 0x00, 0x5a]) else {
                continue
            }
            report("slot \(slot) answered: \(hex(pong))")
            reachable = true
            inspect(device, inbox, slot: slot)
        }
        if !reachable {
            report("no slot answered: the receiver accepted the write but nothing replied")
        }
    }

    /// Asks whether the device exposes feature 0x1b04, which is what allows a
    /// button to be diverted away from its hardwired keyboard chord.
    private static func inspect(_ device: IOHIDDevice, _ inbox: Inbox, slot: UInt8) {
        guard let answer = exchange(device, inbox, [0x10, slot, 0x00, softwareID, 0x1b, 0x04, 0x00]) else {
            report("  slot \(slot): no answer for feature 0x1b04")
            return
        }
        report("  slot \(slot) getFeature(0x1b04): \(hex(answer))")
        guard answer.count > 4, answer[4] != 0 else {
            report("  slot \(slot): 0x1b04 unsupported, the wheel button cannot be diverted")
            return
        }
        let featureIndex = answer[4]
        report("  slot \(slot): 0x1b04 at index \(featureIndex)")
        if let count = exchange(device, inbox, [0x10, slot, featureIndex, softwareID, 0x00, 0x00, 0x00]) {
            report("  slot \(slot) control count: \(hex(count))")
        }
    }

    private static func exchange(_ device: IOHIDDevice, _ inbox: Inbox, _ bytes: [UInt8]) -> [UInt8]? {
        inbox.drain()
        var payload = Array(bytes.dropFirst())
        let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, shortReportID, &payload, payload.count)
        guard result == kIOReturnSuccess else {
            report("  write refused: \(describe(result))")
            return nil
        }
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.05, true)
            if let reply = inbox.take() { return reply }
        }
        return nil
    }

    private static func describe(_ result: IOReturn) -> String {
        "0x" + String(UInt32(bitPattern: result), radix: 16)
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private static func report(_ message: String) {
        print(message)
        trace("hid++ " + message)
    }

    private final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var reports: [[UInt8]] = []

        func append(_ report: [UInt8]) {
            lock.lock(); reports.append(report); lock.unlock()
        }

        func take() -> [UInt8]? {
            lock.lock()
            defer { lock.unlock() }
            return reports.isEmpty ? nil : reports.removeFirst()
        }

        func drain() {
            lock.lock(); reports.removeAll(); lock.unlock()
        }
    }
}
