import Foundation
import HeadroomCore

enum Tag {
    static func run(text: String, paths: Paths, now: Date, out: (String) -> Void, err: (String) -> Void) -> Int32 {
        let record = SpoolRecord.tag(ts: now.timeIntervalSince1970, text: text)
        guard Spool(url: paths.spool).append(record) else {
            err("could not write tag")
            return 1
        }
        out("tagged")
        return 0
    }
}
