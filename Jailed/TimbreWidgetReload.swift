// Lets the Objective-C playback bridge ask WidgetKit to refresh Timbre's widgets.
// Linked only into the Lab bridge dylib; the bridge looks this symbol up at runtime.
import WidgetKit

@_cdecl("TBReloadWidgetTimelines")
public func TBReloadWidgetTimelines(_ kind: UnsafePointer<CChar>?) {
    if let kind {
        WidgetCenter.shared.reloadTimelines(ofKind: String(cString: kind))
    } else {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
