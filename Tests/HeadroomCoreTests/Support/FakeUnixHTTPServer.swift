import Foundation
import Synchronization

/// Serves one canned raw response per connection on a background thread.
/// A nil response means "accept, read the request, then stay silent until stop()".
final class FakeUnixHTTPServer: Sendable {
    let socketPath: String
    private let directory: String
    private let listenFD: Int32
    private let stopRead: Int32
    private let stopWrite: Int32
    private let finished = DispatchSemaphore(value: 0)
    private let stopped = Mutex(false)

    init(response: [UInt8]?) throws {
        // sun_path is 104 bytes on macOS, so the default temp dir is too long.
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let dir = "/tmp/hr-\(suffix)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/s"

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            for (i, b) in bytes.enumerated() { dst[i] = b }
            dst[bytes.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard fd >= 0, bound == 0, listen(fd, 8) == 0 else {
            if fd >= 0 { close(fd) }
            throw CocoaError(.fileWriteUnknown)
        }
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { close(fd); throw CocoaError(.fileWriteUnknown) }

        socketPath = path
        directory = dir
        listenFD = fd
        stopRead = fds[0]
        stopWrite = fds[1]

        let done = finished
        let stopFD = fds[0]
        let thread = Thread {
            Self.serve(listenFD: fd, stopFD: stopFD, response: response)
            done.signal()
        }
        thread.start()
    }

    func stop() {
        let first = stopped.withLock { state -> Bool in
            defer { state = true }
            return !state
        }
        guard first else { return }
        var byte: UInt8 = 1
        _ = write(stopWrite, &byte, 1)
        _ = finished.wait(timeout: .now() + 5)
        close(listenFD)
        close(stopRead)
        close(stopWrite)
        try? FileManager.default.removeItem(atPath: directory)
    }

    private static func serve(listenFD: Int32, stopFD: Int32, response: [UInt8]?) {
        while true {
            var fds = [pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: stopFD, events: Int16(POLLIN), revents: 0)]
            guard poll(&fds, 2, -1) >= 0 || errno == EINTR else { return }
            if fds[1].revents != 0 { return }
            guard fds[0].revents & Int16(POLLIN) != 0 else { continue }

            let conn = accept(listenFD, nil, nil)
            guard conn >= 0 else { continue }
            var one: Int32 = 1
            setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            drainRequest(conn)

            if let response {
                response.withUnsafeBytes { _ = send(conn, $0.baseAddress, $0.count, 0) }
                close(conn)
            } else {
                var wait = [pollfd(fd: stopFD, events: Int16(POLLIN), revents: 0)]
                _ = poll(&wait, 1, 10_000)
                close(conn)
                return
            }
        }
    }

    private static func drainRequest(_ conn: Int32) {
        var data: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 4096)
        let terminator: [UInt8] = [13, 10, 13, 10]
        while !data.suffix(4).elementsEqual(terminator) {
            var fds = [pollfd(fd: conn, events: Int16(POLLIN), revents: 0)]
            guard poll(&fds, 1, 2_000) > 0 else { return }
            let n = buf.withUnsafeMutableBytes { recv(conn, $0.baseAddress, $0.count, 0) }
            if n <= 0 { return }
            data.append(contentsOf: buf[0..<n])
        }
    }
}
