import Foundation
import IOKit.hid

/// Must be a plain function: a C function pointer cannot carry context.
private func hidReportSeen(
    _ context: UnsafeMutableRawPointer?,
    _ result: IOReturn,
    _ sender: UnsafeMutableRawPointer?,
    _ type: IOHIDReportType,
    _ reportID: UInt32,
    _ bytes: UnsafeMutablePointer<UInt8>,
    _ length: CFIndex
) {
    guard let context else { return }
    let label = Unmanaged<HIDLabel>.fromOpaque(context).takeUnretainedValue().text
    let data = Array(UnsafeBufferPointer(start: bytes, count: length))
    // The receiver's keyboard endpoint polls with an all-zero report every
    // 24ms; logging those buries anything the button actually sends.
    guard data.contains(where: { $0 != 0 }) else { return }
    let dump = data.map { String(format: "%02x", $0) }.joined(separator: " ")
    // Report 0x02 from the receiver is [device, buttons_lo, buttons_hi, ...].
    // Pointer motion is noise here; only the button bits matter.
    var note = ""
    if reportID == 0x02, data.count > 2 {
        let buttons = Int(data[1]) | (Int(data[2]) << 8)
        if data[3...].allSatisfy({ $0 == 0 }) || buttons != 0 {
            note = " buttons=0b" + String(buttons, radix: 2)
        } else {
            return
        }
    }
    let line = "hid++ \(label) report id=0x\(String(reportID, radix: 16)) \(dump)\(note)"
    print(line)
    trace(line)
}

final class HIDLabel {
    let text: String
    init(_ text: String) { self.text = text }
}

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

    /// Writing to the device is blocked, but reading is not. If the wheel
    /// button also emits a raw HID report alongside its keyboard chord, that
    /// report is a reliable signal with real edges, and no write is needed.
    /// Listens on every collection the receiver exposes.
    static func listen(seconds: TimeInterval) {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: Int(targetVendorID),
            kIOHIDProductIDKey: Int(targetReceiverProductID),
        ] as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>
        else {
            report("manager open failed")
            return
        }

        var buffers: [UnsafeMutablePointer<UInt8>] = []
        for device in devices {
            let page = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?.intValue ?? 0
            let usage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? NSNumber)?.intValue ?? 0
            guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
                report("could not open collection page=0x\(String(page, radix: 16)) usage=\(usage)")
                continue
            }
            let size = 64
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            buffers.append(buffer)
            let label = "page=0x\(String(page, radix: 16)) usage=\(usage)"
            let context = Unmanaged.passRetained(HIDLabel(label)).toOpaque()
            IOHIDDeviceRegisterInputReportCallback(device, buffer, size, hidReportSeen, context)
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            report("listening on \(label)")
        }

        report("press the wheel button now")
        CFRunLoopRunInMode(.defaultMode, seconds, false)
        report("listen window closed")
    }

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

// MARK: - Live monitor

/// The wheel button reports itself over HID++ as well as through the keyboard
/// chords, and that report is the reliable one: a capture of four presses gave
/// four clean press/release pairs, where the chords dropped half of them. This
/// reads those reports directly.
///
/// Report shape, long report 0x11 from device 1, feature index 0x0a:
///
///     11 01 0a 00 | 00 af   button down, control id 0x00af
///     11 01 0a 00 | 00 00   all diverted buttons up
///
/// Only reading is needed, which macOS allows; the write that would be needed
/// to divert a button is refused, but this button already reports this way.
enum WheelButtonMonitor {
    static let controlID: UInt16 = 0x00af
    private static let featureIndex: UInt8 = 0x0a

    /// The manager must outlive start(): releasing it closes the device, and
    /// the callback then never fires again.
    nonisolated(unsafe) private static var manager: IOHIDManager?
    nonisolated(unsafe) private static var device: IOHIDDevice?
    nonisolated(unsafe) private static var buffer: UnsafeMutablePointer<UInt8>?
    nonisolated(unsafe) private static var thread: Thread?

    private(set) nonisolated(unsafe) static var isRunning = false

    static func start() -> Bool {
        guard !isRunning else { return true }
        let hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = hidManager
        IOHIDManagerSetDeviceMatching(hidManager, [
            kIOHIDVendorIDKey: Int(targetVendorID),
            kIOHIDProductIDKey: Int(targetReceiverProductID),
        ] as CFDictionary)
        guard IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(hidManager) as? Set<IOHIDDevice>,
              let collection = devices.first(where: { device in
                  (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?
                      .intValue == 0xFF00
              }),
              IOHIDDeviceOpen(collection, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
        else {
            trace("wheel monitor: could not open the HID++ collection")
            return false
        }

        device = collection
        let size = 64
        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        buffer = storage

        let ready = DispatchSemaphore(value: 0)
        let worker = Thread {
            IOHIDDeviceRegisterInputReportCallback(collection, storage, size, wheelReportSeen, nil)
            IOHIDDeviceScheduleWithRunLoop(collection, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
            isRunning = true
            ready.signal()
            CFRunLoopRun()
        }
        worker.name = "M560Mapper.wheel-monitor"
        worker.qualityOfService = .userInteractive
        worker.start()
        thread = worker
        ready.wait()
        trace("wheel monitor: reading HID++ reports")
        return true
    }
}

/// C callback: no context, so it reads the shared state directly.
private func wheelReportSeen(
    _ context: UnsafeMutableRawPointer?,
    _ result: IOReturn,
    _ sender: UnsafeMutableRawPointer?,
    _ type: IOHIDReportType,
    _ reportID: UInt32,
    _ bytes: UnsafeMutablePointer<UInt8>,
    _ length: CFIndex
) {
    guard length >= 6 else { return }
    let data = UnsafeBufferPointer(start: bytes, count: length)
    guard data[0] == 0x11, data[2] == 0x0a, data[3] == 0x00 else { return }
    let control = UInt16(data[4]) << 8 | UInt16(data[5])

    guard MapperOptions.shared.middleClick else { return }
    if control == WheelButtonMonitor.controlID {
        if WheelButton.shared.press() {
            trace("wheel button down (hid++ control 0x00af)")
            enqueueMiddleButton(down: true)
        }
    } else if control == 0 {
        if WheelButton.shared.release() {
            trace("wheel button up (hid++)")
            enqueueMiddleButton(down: false)
        }
    }
}

/// Press state for the button, driven by real HID++ edges rather than guessed
/// from keyboard chords, so holding and dragging are genuine.
final class WheelButton: @unchecked Sendable {
    static let shared = WheelButton()
    private let lock = NSLock()
    private var isDown = false

    func press() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !isDown else { return false }
        isDown = true
        return true
    }

    func release() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard isDown else { return false }
        isDown = false
        return true
    }

    var held: Bool {
        lock.lock(); defer { lock.unlock() }
        return isDown
    }
}
