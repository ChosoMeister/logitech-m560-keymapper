import AppKit
import ApplicationServices
import CoreGraphics
import CoreFoundation
import IOKit

private typealias IOHIDEventRef = UnsafeMutableRawPointer

@_silgen_name("CGEventCopyIOHIDEvent")
private func copyIOHIDEvent(_ event: UnsafeRawPointer) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOHIDEventGetSenderID")
private func hidEventSenderID(_ event: IOHIDEventRef) -> UInt64

private let targetVendorID: Int64 = 0x046d
private let targetReceiverProductID: Int64 = 0xc52b
private let injectedEventMarker: Int64 = 0x4d353630
private let registrySearchParents: UInt32 = 2
private let registrySearchRecursive: UInt32 = 1
private let diagnoseOnly = CommandLine.arguments.contains("--diagnose")
private let checkPermissionsOnly = CommandLine.arguments.contains("--check-permissions")
private let traceTilts = CommandLine.arguments.contains("--trace")

private final class SenderCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [UInt64: Bool] = [:]

    func isM560Receiver(_ senderID: UInt64) -> Bool {
        lock.lock()
        if let cached = entries[senderID] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let matches = readIdentity(senderID).map {
            $0.vendor == targetVendorID && $0.product == targetReceiverProductID
        } ?? false

        lock.lock()
        entries[senderID] = matches
        lock.unlock()
        return matches
    }

    private func readIdentity(_ senderID: UInt64) -> (vendor: Int64, product: Int64)? {
        guard let matching = IORegistryEntryIDMatching(senderID) else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        func number(_ name: String) -> Int64? {
            let value = "IOService".withCString { plane in
                IORegistryEntrySearchCFProperty(
                    service,
                    plane,
                    name as CFString,
                    kCFAllocatorDefault,
                    registrySearchParents | registrySearchRecursive
                )
            }
            return (value as? NSNumber)?.int64Value
        }

        guard let vendor = number("VendorID") ?? number("idVendor"),
              let product = number("ProductID") ?? number("idProduct")
        else { return nil }
        return (vendor, product)
    }
}

private let senderCache = SenderCache()

private final class PointerSource: @unchecked Sendable {
    private let lock = NSLock()
    private var lastSourceWasM560 = false

    func update(senderID: UInt64?) {
        let isTarget = senderID.map(senderCache.isM560Receiver) ?? false
        lock.lock()
        lastSourceWasM560 = isTarget
        lock.unlock()
    }

    func isM560Fallback() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return lastSourceWasM560
    }
}

private let pointerSource = PointerSource()
private let injectionQueue = DispatchQueue(label: "M560Mapper.event-injection", qos: .userInteractive)

private func eventName(_ type: CGEventType) -> String {
    switch type {
    case .flagsChanged: return "flagsChanged"
    case .keyDown: return "keyDown"
    case .keyUp: return "keyUp"
    case .otherMouseDown: return "otherMouseDown"
    case .otherMouseUp: return "otherMouseUp"
    default: return "other"
    }
}

private func senderID(for event: CGEvent) -> UInt64? {
    let eventPointer = Unmanaged.passUnretained(event).toOpaque()
    guard let hidEvent = copyIOHIDEvent(eventPointer) else { return nil }
    defer { hidEvent.release() }
    return hidEventSenderID(hidEvent.toOpaque())
}

private func postShortcut(keyCode: CGKeyCode, modifiers: CGEventFlags) {
    let modifierKeyCode: CGKeyCode
    if modifiers.contains(.maskControl) {
        modifierKeyCode = 0x3b
    } else if modifiers.contains(.maskCommand) {
        modifierKeyCode = 0x37
    } else {
        modifierKeyCode = 0
    }
    guard let source = CGEventSource(stateID: .hidSystemState),
          let modifierDown = CGEvent(keyboardEventSource: source, virtualKey: modifierKeyCode, keyDown: true),
          let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false),
          let modifierUp = CGEvent(keyboardEventSource: source, virtualKey: modifierKeyCode, keyDown: false)
    else { return }

    let keyFlags: CGEventFlags = [0x7b, 0x7c].contains(keyCode)
        ? modifiers.union([.maskNumericPad, .maskSecondaryFn])
        : modifiers
    modifierDown.flags = modifiers
    keyDown.flags = keyFlags
    keyUp.flags = keyFlags
    modifierUp.flags = []
    for event in [modifierDown, keyDown, keyUp, modifierUp] {
        event.setIntegerValueField(.eventSourceUserData, value: injectedEventMarker)
    }
    modifierDown.post(tap: .cghidEventTap)
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
    modifierUp.post(tap: .cghidEventTap)
}

private func enqueueShortcut(keyCode: CGKeyCode, modifiers: CGEventFlags) {
    injectionQueue.async {
        postShortcut(keyCode: keyCode, modifiers: modifiers)
    }
}

private func callback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if event.getIntegerValueField(.eventSourceUserData) == injectedEventMarker {
        return Unmanaged.passUnretained(event)
    }
    if [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(type) {
        pointerSource.update(senderID: senderID(for: event))
        return Unmanaged.passUnretained(event)
    }
    let sender = senderID(for: event)
    let isReceiver = sender.map(senderCache.isM560Receiver) ?? false
    if diagnoseOnly {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        let line = "diag type=\(eventName(type)) key=\(keyCode) button=\(button) flags=\(event.flags.rawValue) sender=\(sender.map(String.init) ?? "none") receiver=\(isReceiver)\n"
        FileHandle.standardError.write(Data(line.utf8))
        return Unmanaged.passUnretained(event)
    }
    if type == .otherMouseDown || type == .otherMouseUp {
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        let attributedToM560 = sender.map(senderCache.isM560Receiver) ?? pointerSource.isM560Fallback()
        if traceTilts {
            let line = "tilt type=\(eventName(type)) button=\(button) sender=\(sender.map(String.init) ?? "none") fallback_m560=\(pointerSource.isM560Fallback()) target=\(attributedToM560)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        guard attributedToM560, button == 3 || button == 4 else {
            return Unmanaged.passUnretained(event)
        }
        if type == .otherMouseDown {
            FileHandle.standardError.write(Data("map tilt button=\(button) -> browser-navigation\n".utf8))
            enqueueShortcut(keyCode: button == 3 ? 0x21 : 0x1e, modifiers: .maskCommand)
        }
        return nil
    }
    guard isReceiver else {
        return Unmanaged.passUnretained(event)
    }
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    switch type {
    case .flagsChanged:
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let commandIsDown = event.flags.contains(.maskCommand)
        // macOS virtual key 0x36 is right Command. Convert its
        // press to Control+Left (previous Space), and suppress both edges.
        if keyCode == 0x36 {
            if commandIsDown {
                enqueueShortcut(keyCode: 0x7b, modifiers: .maskControl)
            }
            return nil
        }
        // M560 back button reports left Command+D. Swallow the modifier edge;
        // the D key event below performs the desktop navigation.
        if keyCode == 0x37 { return nil }
        return Unmanaged.passUnretained(event)

    case .keyDown, .keyUp:
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == 0x02, event.flags.contains(.maskCommand) else {
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown {
            enqueueShortcut(keyCode: 0x7c, modifiers: .maskControl)
        }
        return nil

    default:
        return Unmanaged.passUnretained(event)
    }
}

let eventTypes: [CGEventType] = [
    .flagsChanged,
    .keyDown,
    .keyUp,
    .otherMouseDown,
    .otherMouseUp,
    .mouseMoved,
    .leftMouseDragged,
    .rightMouseDragged,
    .otherMouseDragged,
]
let eventMask = eventTypes.reduce(CGEventMask(0)) { mask, type in
    mask | (CGEventMask(1) << type.rawValue)
}

if checkPermissionsOnly {
    print("accessibilityTrusted=\(AXIsProcessTrusted())")
    exit(0)
}

guard let tap = CGEvent.tapCreate(
    tap: .cghidEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: eventMask,
    callback: callback,
    userInfo: nil
) else {
    fputs("Could not create the input event tap. Grant Accessibility/Input Monitoring access to this executable and run it again.\n", stderr)
    exit(2)
}

let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
if diagnoseOnly {
    print("M560 diagnostic active (read-only). Press the requested button, then Control-C to stop.")
} else {
    print("M560 mapper active. Only events from Logitech receiver 046d:c52b are eligible. Press Control-C to stop.")
}
CFRunLoopRun()
