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
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

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

        let line = "\(formatter.string(from: Date()))  \(message)\n"
        queue.async { [fileURL] in
            guard let fileURL, let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}

/// Shorthand matching the Python `log("...")` call sites.
public func log(_ message: String) {
    Log.shared(message)
}
