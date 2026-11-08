import AppKit
import ApplicationServices
import CoreGraphics
import CoreFoundation
import IOKit

typealias IOHIDEventRef = UnsafeMutableRawPointer

@_silgen_name("CGEventCopyIOHIDEvent")
func copyIOHIDEvent(_ event: UnsafeRawPointer) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOHIDEventGetSenderID")
func hidEventSenderID(_ event: IOHIDEventRef) -> UInt64

let targetVendorID: Int64 = 0x046d
let targetReceiverProductID: Int64 = 0xc52b
let injectedEventMarker: Int64 = 0x4d353630
private let registrySearchParents: UInt32 = 2
private let registrySearchRecursive: UInt32 = 1

// MARK: - Device identity

final class SenderCache: @unchecked Sendable {
    static let shared = SenderCache()
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

final class PointerSource: @unchecked Sendable {
    static let shared = PointerSource()
    private let lock = NSLock()
    private var lastSourceWasM560 = false

    func update(senderID: UInt64?) {
        let isTarget = senderID.map(SenderCache.shared.isM560Receiver) ?? false
        lock.lock()
        lastSourceWasM560 = isTarget
        lock.unlock()
    }

    func isM560Fallback() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return lastSourceWasM560
    }

    private var lastSample: CFAbsoluteTime = 0
    private static let sampleInterval: CFAbsoluteTime = 0.2

    /// Rate limits the expensive IOHID lookup done for pointer motion.
    func shouldResample() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        defer { lock.unlock() }
        guard now - lastSample >= Self.sampleInterval else { return false }
        lastSample = now
        return true
    }
}

// MARK: - Mapper

/// Runtime switches the GUI can flip while the tap is live.
final class MapperOptions: @unchecked Sendable {
    static let shared = MapperOptions()
    private let lock = NSLock()
    private var _middleClick = true
    private var _spaceSwitching = true
    private var _tiltNavigation = true
    private var _trace = false

    var middleClick: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _middleClick }
        set { lock.lock(); _middleClick = newValue; lock.unlock() }
    }
    var spaceSwitching: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _spaceSwitching }
        set { lock.lock(); _spaceSwitching = newValue; lock.unlock() }
    }
    var tiltNavigation: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _tiltNavigation }
        set { lock.lock(); _tiltNavigation = newValue; lock.unlock() }
    }
    var trace: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _trace }
        set { lock.lock(); _trace = newValue; lock.unlock() }
    }
}

/// One physical press of the wheel button emits two chords in sequence: the
/// Option+Command pair, then Control+Command+Tab a few hundred milliseconds
/// behind it. Both must map to a single click, so the second one inside this
/// window is dropped. There is no held state to track: the chord is momentary
/// even when the button is held, so every press is one complete click.
private final class MiddleButtonState: @unchecked Sendable {
    static let shared = MiddleButtonState()
    private static let window: CFAbsoluteTime = 1.0

    private let lock = NSLock()
    private var lastFiredAt: CFAbsoluteTime = 0

    /// Returns true when a click should be emitted for this chord.
    func fire() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        defer { lock.unlock() }
        guard now - lastFiredAt >= Self.window else { return false }
        lastFiredAt = now
        return true
    }
}

let injectionQueue = DispatchQueue(label: "M560Mapper.event-injection", qos: .userInteractive)

func eventName(_ type: CGEventType) -> String {
    switch type {
    case .flagsChanged: return "flagsChanged"
    case .keyDown: return "keyDown"
    case .keyUp: return "keyUp"
    case .otherMouseDown: return "otherMouseDown"
    case .otherMouseUp: return "otherMouseUp"
    case .otherMouseDragged: return "otherMouseDragged"
    default: return "other"
    }
}

func senderID(for event: CGEvent) -> UInt64? {
    let eventPointer = Unmanaged.passUnretained(event).toOpaque()
    guard let hidEvent = copyIOHIDEvent(eventPointer) else { return nil }
    defer { hidEvent.release() }
    return hidEventSenderID(hidEvent.toOpaque())
}

/// Mapping decisions and lifecycle. Carries no key information.
private func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    trace(message)
}

/// Raw event detail, including key codes. Recorded only while tracing is on.
private func logVerbose(_ message: @autoclosure () -> String) {
    guard MapperOptions.shared.trace else { return }
    let text = message()
    FileHandle.standardError.write(Data((text + "\n").utf8))
    traceVerbose(text)
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
    injectionQueue.async { postShortcut(keyCode: keyCode, modifiers: modifiers) }
}

private func currentPointerLocation() -> CGPoint {
    CGEvent(source: nil)?.location ?? NSEvent.mouseLocation
}

/// Posts one edge of a genuine middle mouse button, exactly as a three-button
/// mouse would: button 2, click state 1, no modifier flags.
private func postMiddleButton(down: Bool) {
    guard let source = CGEventSource(stateID: .hidSystemState),
          let event = CGEvent(
              mouseEventSource: source,
              mouseType: down ? .otherMouseDown : .otherMouseUp,
              mouseCursorPosition: currentPointerLocation(),
              mouseButton: .center
          )
    else { return }
    event.flags = []
    event.setIntegerValueField(.mouseEventButtonNumber, value: 2)
    event.setIntegerValueField(.mouseEventClickState, value: 1)
    event.setIntegerValueField(.eventSourceUserData, value: injectedEventMarker)
    event.post(tap: .cghidEventTap)
}

/// The wheel button's chord is momentary: the capture showed press and
/// release 8ms apart whether the button is tapped or held down. A held
/// synthetic button therefore had no way to learn it should let go, and when
/// a release edge was missed it stayed down until the next press, landing on
/// whatever was under the pointer seconds later. So emit one complete click.
func enqueueMiddleClick() {
    injectionQueue.async {
        postMiddleButton(down: true)
        usleep(20_000)
        postMiddleButton(down: false)
    }
}

// MARK: - Tap callback

func mapperCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    let isInjected = event.getIntegerValueField(.eventSourceUserData) == injectedEventMarker
    if isInjected, !EventMapper.shared.diagnoseOnly {
        return Unmanaged.passUnretained(event)
    }
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        EventMapper.shared.reenableTap()
        return nil
    }

    let options = MapperOptions.shared

    if [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(type) {
        // Pointer motion arrives at the device's full report rate. Reading the
        // backing IOHID event costs far more than this callback's time budget
        // allows at that rate, so sample the pointer's owner occasionally
        // instead of on every move; it only feeds the wheel-tilt fallback.
        if PointerSource.shared.shouldResample() {
            pointerSourceUpdate(event)
        }
        return Unmanaged.passUnretained(event)
    }

    let sender = senderID(for: event)
    let isReceiver = sender.map(SenderCache.shared.isM560Receiver) ?? false

    if EventMapper.shared.diagnoseOnly {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        logVerbose("diag\(isInjected ? "[ours]" : "") type=\(eventName(type)) key=\(keyCode) button=\(button) flags=\(event.flags.rawValue) sender=\(sender.map(String.init) ?? "none") receiver=\(isReceiver)")
        return Unmanaged.passUnretained(event)
    }

    if type == .otherMouseDown || type == .otherMouseUp {
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        let attributedToM560 = sender.map(SenderCache.shared.isM560Receiver) ?? PointerSource.shared.isM560Fallback()
        logVerbose("tilt type=\(eventName(type)) button=\(button) sender=\(sender.map(String.init) ?? "none") fallback_m560=\(PointerSource.shared.isM560Fallback()) target=\(attributedToM560)")
        guard options.tiltNavigation, attributedToM560, button == 3 || button == 4 else {
            return Unmanaged.passUnretained(event)
        }
        if type == .otherMouseDown {
            enqueueShortcut(keyCode: button == 3 ? 0x21 : 0x1e, modifiers: .maskCommand)
        }
        return nil
    }

    if isReceiver {
        logVerbose("recv type=\(eventName(type)) key=\(event.getIntegerValueField(.keyboardEventKeycode)) flags=\(String(event.flags.rawValue, radix: 16))")
    }

    guard isReceiver else { return Unmanaged.passUnretained(event) }

    switch type {
    case .flagsChanged:
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let commandIsDown = event.flags.contains(.maskCommand)
        // macOS virtual key 0x36 is right Command: the M560 forward side button.
        if keyCode == 0x36 {
            guard options.spaceSwitching else { return Unmanaged.passUnretained(event) }
            if commandIsDown { enqueueShortcut(keyCode: 0x7b, modifiers: .maskControl) }
            return nil
        }
        // The wheel button mostly reports a modifier-only chord: left Option
        // and left Command pressed together, with no key event at all. On this
        // device that pair is unambiguous, because the side buttons report
        // right Command and Command+D instead. Treat the pair going down as
        // the button going down, and either modifier lifting as its release.
        if options.middleClick, keyCode == 0x3a || keyCode == 0x37 {
            if event.flags.contains(.maskAlternate), commandIsDown {
                if MiddleButtonState.shared.fire() {
                    log("map wheel chord (option+command) -> middle click")
                    enqueueMiddleClick()
                }
                return nil
            }
        }
        // Left Command is part of both the back-button chord and the wheel chord.
        if keyCode == 0x37 {
            guard options.spaceSwitching || options.middleClick else {
                return Unmanaged.passUnretained(event)
            }
            return nil
        }
        // The wheel click chord also carries left Option and left Control.
        if keyCode == 0x3a || keyCode == 0x3b {
            guard options.middleClick else { return Unmanaged.passUnretained(event) }
            return nil
        }
        return Unmanaged.passUnretained(event)

    case .keyDown, .keyUp:
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isMiddleButtonChord = keyCode == 0x30
            && event.flags.contains(.maskCommand)
            && event.flags.contains(.maskControl)
        if options.middleClick, type == .keyDown, isMiddleButtonChord {
            if MiddleButtonState.shared.fire() {
                log("map wheel chord (control+command+tab) -> middle click")
                enqueueMiddleClick()
            }
            return nil
        }
        if options.middleClick, type == .keyUp, keyCode == 0x30 {
            return nil
        }
        guard options.spaceSwitching, keyCode == 0x02, event.flags.contains(.maskCommand) else {
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown { enqueueShortcut(keyCode: 0x7c, modifiers: .maskControl) }
        return nil

    default:
        return Unmanaged.passUnretained(event)
    }
}

private func pointerSourceUpdate(_ event: CGEvent) {
    PointerSource.shared.update(senderID: senderID(for: event))
}

// MARK: - Tap lifecycle

final class EventMapper {
    static let shared = EventMapper()

    private(set) var isRunning = false
    var diagnoseOnly = false
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    nonisolated(unsafe) private static var loggedPermissionFailure = false
    private var tapRunLoop: CFRunLoop?
    private var tapThread: Thread?

    private static let eventTypes: [CGEventType] = [
        .flagsChanged, .keyDown, .keyUp,
        .otherMouseDown, .otherMouseUp,
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
    ]

    private static let eventMask = eventTypes.reduce(CGEventMask(0)) { mask, type in
        mask | (CGEventMask(1) << type.rawValue)
    }

    /// The tap runs on its own high-priority thread. On the main runloop any
    /// SwiftUI work would sit in front of the callback, and because a tap
    /// callback blocks delivery of every event it sees, that showed up as
    /// system-wide input lag.
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        let ready = DispatchSemaphore(value: 0)
        var created = false

        let thread = Thread { [weak self] in
            guard let self else { ready.signal(); return }
            guard let tap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: Self.eventMask,
                callback: mapperCallback,
                userInfo: nil
            ) else {
                // The watchdog retries every two seconds; say so once rather
                // than filling the log while permission is pending.
                if !Self.loggedPermissionFailure {
                    Self.loggedPermissionFailure = true
                    log("tap creation failed: no Accessibility permission (retrying)")
                }
                ready.signal()
                return
            }

            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            self.tap = tap
            self.runLoopSource = source
            self.tapRunLoop = CFRunLoopGetCurrent()
            created = true
            Self.loggedPermissionFailure = false
            log("tap created and enabled on its own thread")
            ready.signal()

            CFRunLoopRun()

            // Reached only after stop() stops this runloop.
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFMachPortInvalidate(tap)
            self.tap = nil
            self.runLoopSource = nil
            self.tapRunLoop = nil
        }
        thread.name = "M560Mapper.event-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.tapThread = thread

        ready.wait()
        isRunning = created
        return created
    }

    func stop() {
        guard isRunning, let tapRunLoop, let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopStop(tapRunLoop)
        tapThread = nil
        isRunning = false
    }

    /// macOS disables a tap that takes too long; put it straight back.
    func reenableTap() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}
