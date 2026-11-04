import Foundation
import os

/// `log()` from legacy-python/daemon.py / legacy-python/menubar.py: a timestamped line to a file the user
/// can open, plus an os.Logger line for Console.app.
///
/// The file lives in the sandbox container's Logs directory. Under the sandbox
/// `.libraryDirectory` already resolves inside the container, so this needs no
/// special-casing and never writes outside it.
public final class Log: @unchecked Sendable {
    public static let shared = Log()

    private let logger = Logger(subsystem: "com.sambruggen.verbalise", category: "app")
    private let queue = DispatchQueue(label: "com.sambruggen.verbalise.log")
    private let fileURL: URL?
    private let formatter: DateFormatter

    private init() {
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZZ"

        let fm = FileManager.default
        let logs = try? fm.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Logs", isDirectory: true)
        if let logs {
            try? fm.createDirectory(at: logs, withIntermediateDirectories: true)
            fileURL = logs.appendingPathComponent("verbalise.log")
        } else {
            fileURL = nil
        }
    }

    /// Where the in-app log window tails from, and what "View Logs" opens.
    public var logFileURL: URL? { fileURL }

    public func callAsFunction(_ message: String) {
        logger.log("\(message, privacy: .public)")

        let timestamp = Date()
        queue.async { [self] in
            // Date formatting and file work stay off the recording/model tasks.
            let line = "\(formatter.string(from: timestamp))  \(message)\n"
            guard let fileURL, let data = line.data(using: .utf8) else { return }
            Self.rotateIfNeeded(fileURL, incomingBytes: data.count)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    /// Keep the current file plus three 10 MiB archives. Runs on the log queue.
    /// Rotation failure must never prevent append or affect dictation.
    static func rotateIfNeeded(_ url: URL, incomingBytes: Int,
                               limit: Int = 10 * 1024 * 1024, archives: Int = 3) {
        let fm = FileManager.default
        guard archives > 0,
              let attributes = try? fm.attributesOfItem(atPath: url.path),
              let bytes = attributes[.size] as? NSNumber,
              bytes.intValue > 0, bytes.intValue + incomingBytes > limit else { return }
        func archive(_ index: Int) -> URL { url.appendingPathExtension(String(index)) }
        do {
            if fm.fileExists(atPath: archive(archives).path) { try fm.removeItem(at: archive(archives)) }
            if archives > 1 {
                for index in stride(from: archives - 1, through: 1, by: -1) {
                    if fm.fileExists(atPath: archive(index).path) {
                        try fm.moveItem(at: archive(index), to: archive(index + 1))
                    }
                }
            }
            try fm.moveItem(at: url, to: archive(1))
        } catch { /* Appending the active file remains the fallback. */ }
    }

}

/// Shorthand matching the Python `log("...")` call sites.
public func log(_ message: String) {
    let line = Diagnostics.correlated(message)
    if let sink = Diagnostics.sink { sink(line) }
    else { Log.shared(line) }
}
