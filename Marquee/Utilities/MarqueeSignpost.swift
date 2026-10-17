import Foundation
import os

// MARK: - Performance Signposts

/// os_signpost seams for the hot paths tracked by the performance plan:
/// profile-select, route switches, search publication, detail opens, and
/// playback startup. Record with `scripts/perf-trace.sh` and filter the
/// os_signpost instrument on subsystem `com.marquee.app`, category `perf`.
enum MarqueeSignpost {

    static let perf = OSLog(subsystem: "com.marquee.app", category: "perf")

    static func begin(_ name: StaticString) -> OSSignpostID {
        let id = OSSignpostID(log: perf)
        os_signpost(.begin, log: perf, name: name, signpostID: id)
        return id
    }

    static func end(_ name: StaticString, _ id: OSSignpostID) {
        os_signpost(.end, log: perf, name: name, signpostID: id)
    }

    static func event(_ name: StaticString, _ message: String = "") {
        os_signpost(.event, log: perf, name: name, "%{public}@", message)
    }
}
