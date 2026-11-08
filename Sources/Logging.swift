import Foundation

/// Appends to ~/Library/Logs/M560Mapper.log. The event tap runs on its own
/// thread and the app has no console when launched from Finder, so this is the
/// only way to see what the callback decided.
final class Trace: @unchecked Sendable {
    static let shared = Trace()

    static let url = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/M560Mapper.log")

    private let lock = NSLock()
    private let handle: FileHandle?
    private let formatter: DateFormatter

    private init() {
        let path = Self.url.path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: Self.url)
        _ = try? handle?.seekToEnd()
        formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
    }

    /// Always recorded: lifecycle and mapping decisions are low rate.
    func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        handle?.write(Data(line.utf8))
    }
}

func trace(_ message: String) {
    Trace.shared.write(message)
}
