import AppKit
import Foundation

/// `NSPasteboard` behind the `Pasteboard` seam.
///
/// The only subtlety is that `setString` returns `false` without raising when
/// the pasteboard server is busy — just after another app or a Finder
/// right-click+Copy touched it. `TextInserter` relies on that Bool being
/// truthful, so it is returned rather than discarded.
public struct SystemPasteboard: Pasteboard {

    public init() {}

    public func read() -> String {
        NSPasteboard.general.string(forType: .string) ?? ""
    }

    @discardableResult
    public func write(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    public var changeCount: Int {
        NSPasteboard.general.changeCount
    }
}
