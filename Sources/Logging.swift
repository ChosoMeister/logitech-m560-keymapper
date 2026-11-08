import Foundation

/// Appends to ~/Library/Logs/M560Mapper.log. The event tap runs on its own
/// thread and the app has no console when launched from Finder, so this is the
/// only way to see what the callback decided.
///
/// The tap sees every key the machine types, so this file is treated as
/// sensitive: it is created 0600, it is truncated once it passes a size cap,
/// and per-event detail is written only when tracing is explicitly switched on.
/// Mapping decisions and lifecycle lines carry no key information and are
/// always recorded.
final class Trace: @unchecked Sendable {
    static let shared = Trace()

    static let url = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/M560Mapper.log")

    private static let sizeCap = 256 * 1024

    private let lock = NSLock()
    private var handle: FileHandle?
    private let formatter: DateFormatter

    private init() {
        formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        handle = Self.openLog()
    }

    private static func openLog() -> FileHandle? {
        let path = url.path
        let manager = FileManager.default
        if !manager.fileExists(atPath: path) {
            manager.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        } else {
            // An earlier build created this file world-readable.
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }

    /// Carries no key information; always recorded.
    func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        rotateIfNeededLocked()
        handle?.write(Data(line.utf8))
    }

    /// Per-event detail, which can include key codes. Written only while
    /// tracing is on, so the log is not a keystroke record by default.
    func writeVerbose(_ message: @autoclosure () -> String) {
        guard MapperOptions.shared.trace else { return }
        write(message())
    }

    private func rotateIfNeededLocked() {
        guard let handle, (try? handle.offset()).map({ $0 > UInt64(Self.sizeCap) }) == true else { return }
        try? handle.close()
        self.handle = nil
        try? FileManager.default.removeItem(at: Self.url)
        self.handle = Self.openLog()
    }
}

func trace(_ message: String) {
    Trace.shared.write(message)
}

/// Use for anything derived from raw event contents.
func traceVerbose(_ message: @autoclosure () -> String) {
    Trace.shared.writeVerbose(message())
}
