import Foundation

/// Task-local correlation follows child tasks without mixing concurrent recordings.
/// Metadata only: never put transcript, vocabulary or clipboard contents here.
public enum Diagnostics {
    public struct Context: Sendable, Equatable {
        public var dictation: String
        public var chunk: String
        public init(dictation: String = UUID().uuidString, chunk: String = "session") {
            self.dictation = dictation
            self.chunk = chunk
        }
    }
    @TaskLocal public static var context: Context?
    // Tests can collect diagnostics without touching the user's log file.
    @TaskLocal public static var sink: (@Sendable (String) -> Void)?

    public static func correlated(_ message: String) -> String {
        guard let context else { return message }
        return "[dictation=\(context.dictation) chunk=\(context.chunk)] \(message)"
    }

    public static var now: Double { SystemClock().now }

    public static var systemState: String {
        let process = ProcessInfo.processInfo
        return "thermal=\(process.thermalState.rawValue) low_power=\(process.isLowPowerModeEnabled)"
    }
}
