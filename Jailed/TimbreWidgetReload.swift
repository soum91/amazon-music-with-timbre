// Lets the Objective-C playback bridge ask WidgetKit to refresh Timbre's widgets, and reports what
// WidgetKit thinks is installed so reload problems show up in Timbre's Diagnostics page.
// Linked only into the Lab bridge dylib; the bridge looks these symbols up at runtime.
import Foundation
import WidgetKit

private let lock = NSLock()
private var reloadCount = 0
private var lastReport = "Not checked yet"

@_cdecl("TBReloadWidgetTimelines")
public func TBReloadWidgetTimelines(_ kind: UnsafePointer<CChar>?) {
    if let kind {
        WidgetCenter.shared.reloadTimelines(ofKind: String(cString: kind))
    } else {
        WidgetCenter.shared.reloadAllTimelines()
    }
    lock.lock(); reloadCount += 1; lock.unlock()
}

/// Asks WidgetKit which of this app's widgets are installed. Result appears in TBWidgetReport().
@_cdecl("TBRefreshWidgetReport")
public func TBRefreshWidgetReport() {
    WidgetCenter.shared.getCurrentConfigurations { result in
        let text: String
        switch result {
        case .success(let infos):
            let kinds = infos.map { "\($0.kind.split(separator: ".").last ?? "?")/\($0.family)" }
            text = infos.isEmpty ? "WidgetKit sees no installed Timbre widgets for this app"
                                 : "WidgetKit sees \(infos.count): " + kinds.joined(separator: ", ")
        case .failure(let error):
            text = "WidgetKit error: \(error.localizedDescription)"
        }
        lock.lock(); lastReport = text; lock.unlock()
    }
}

/// Caller frees the returned string.
@_cdecl("TBWidgetReport")
public func TBWidgetReport() -> UnsafeMutablePointer<CChar>? {
    lock.lock(); defer { lock.unlock() }
    return strdup("Reload requests sent: \(reloadCount)\n\(lastReport)")
}
