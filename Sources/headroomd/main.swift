import Foundation
import HeadroomCore
import os

MainActor.assumeIsolated {
    do {
        try Recorder(paths: .standard()).start()
    } catch {
        // Exiting non-zero lets launchd restart the recorder. The error may name a path, so it stays private.
        Logger(subsystem: "io.github.llinder.headroom", category: "recorder")
            .fault("recorder failed to start: \(String(describing: error))")
        exit(1)
    }
}
dispatchMain()
