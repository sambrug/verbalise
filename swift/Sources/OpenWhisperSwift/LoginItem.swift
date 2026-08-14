import Foundation
import OpenWhisperCore
import ServiceManagement

/// Launch at Login, wrapped so both the failure path and the "did it actually
/// take" question have one answer.
///
/// `SMAppService.register()` can throw, and the state afterwards is whatever the
/// service says rather than whatever was asked for -- so callers read `isEnabled`
/// back instead of assuming the toggle they flipped is the truth.
enum LoginItem {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log("login item: \(error.localizedDescription)")
        }
    }
}
