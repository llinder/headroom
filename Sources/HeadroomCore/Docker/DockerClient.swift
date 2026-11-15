import Foundation

public enum DockerError: Error, Equatable {
    case refused, timeout, status(Int), malformed
}

/// Minimal HTTP/1.1 GET over a Unix-domain socket, enough for the Docker Engine API.
public struct DockerClient: Sendable {
    private let socketPath: String
    private let timeout: Double

    public init(socketPath: String, timeout: Double = 2) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    public func get(_ path: String) throws(DockerError) -> Data {
        let deadline = ContinuousClock.now + .seconds(timeout)
        let fd = try connectSocket()
        defer { close(fd) }

        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        try setTimeouts(fd, remaining: timeout)
        let request = Array("GET \(path) HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n".utf8)
        try sendAll(fd, request, deadline: deadline)

        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { throw .timeout }
            // Best effort: macOS rejects setsockopt with EINVAL once the peer has closed.
            _ = try? setTimeouts(fd, remaining: max(0.001, remaining.seconds))

            let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n < 0 {
                switch errno {
                case EINTR: continue
                case EAGAIN, EWOULDBLOCK: throw .timeout
                default: throw .malformed
                }
            }
            buffer.append(contentsOf: chunk[0..<n])
            switch HTTPResponseParser.parse(buffer, eof: n == 0) {
            case .incomplete: continue
            case .complete(let status, let body):
                guard (200..<300).contains(status) else { throw .status(status) }
                return Data(body)
            case .failed(let error): throw error
            }
        }
    }

    private func connectSocket() throws(DockerError) -> Int32 {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw .refused }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            for (i, b) in bytes.enumerated() { dst[i] = b }
            dst[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .refused }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let err = errno
            close(fd)
            throw err == EAGAIN || err == ETIMEDOUT ? .timeout : .refused
        }
        return fd
    }

    private func setTimeouts(_ fd: Int32, remaining: Double) throws(DockerError) {
        var tv = timeval(tv_sec: Int(remaining), tv_usec: Int32((remaining - Double(Int(remaining))) * 1_000_000))
        let size = socklen_t(MemoryLayout<timeval>.size)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, size) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, size) == 0
        else { throw .malformed }
    }

    private func sendAll(_ fd: Int32, _ bytes: [UInt8], deadline: ContinuousClock.Instant) throws(DockerError) {
        var sent = 0
        while sent < bytes.count {
            guard ContinuousClock.now < deadline else { throw .timeout }
            let n = bytes[sent...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            if n < 0 {
                switch errno {
                case EINTR: continue
                case EAGAIN, EWOULDBLOCK: throw .timeout
                default: throw .malformed
                }
            }
            sent += n
        }
    }
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

enum HTTPResponseParser {
    enum Result {
        case incomplete
        case complete(status: Int, body: [UInt8])
        case failed(DockerError)
    }

    private static let crlf: [UInt8] = [13, 10]
    private static let headerEnd: [UInt8] = [13, 10, 13, 10]

    static func parse(_ buf: [UInt8], eof: Bool) -> Result {
        guard let headEnd = find(headerEnd, in: buf, from: 0) else {
            return eof ? .failed(.malformed) : .incomplete
        }
        guard let head = String(bytes: buf[0..<headEnd], encoding: .utf8) else { return .failed(.malformed) }
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard statusLine.count >= 2, statusLine[0].hasPrefix("HTTP/1."),
              statusLine[1].count == 3, let status = Int(statusLine[1])
        else { return .failed(.malformed) }

        guard (200..<300).contains(status) else { return .complete(status: status, body: []) }

        var contentLength: Int?
        var chunked = false
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .failed(.malformed) }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch name {
            case "content-length":
                guard let n = Int(value), n >= 0 else { return .failed(.malformed) }
                contentLength = n
            case "transfer-encoding":
                if value.lowercased().contains("chunked") { chunked = true }
            default: break
            }
        }

        let bodyStart = headEnd + 4
        if chunked { return decodeChunked(buf, from: bodyStart, status: status, eof: eof) }
        let available = buf.count - bodyStart
        if let length = contentLength {
            if available >= length { return .complete(status: status, body: Array(buf[bodyStart..<(bodyStart + length)])) }
            return eof ? .failed(.malformed) : .incomplete
        }
        return eof ? .complete(status: status, body: Array(buf[bodyStart...])) : .incomplete
    }

    private static func decodeChunked(_ buf: [UInt8], from start: Int, status: Int, eof: Bool) -> Result {
        let pending: Result = eof ? .failed(.malformed) : .incomplete
        var body: [UInt8] = []
        var pos = start
        while true {
            guard let lineEnd = find(crlf, in: buf, from: pos) else { return pending }
            guard let line = String(bytes: buf[pos..<lineEnd], encoding: .utf8) else { return .failed(.malformed) }
            let sizeText = (line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
                .trimmingCharacters(in: .whitespaces)
            guard !sizeText.isEmpty, let size = Int(sizeText, radix: 16), size >= 0 else {
                return .failed(.malformed)
            }
            pos = lineEnd + 2

            if size == 0 {
                // Trailer section: header lines up to a blank line.
                while true {
                    guard let trailerEnd = find(crlf, in: buf, from: pos) else { return pending }
                    let empty = trailerEnd == pos
                    pos = trailerEnd + 2
                    if empty { return .complete(status: status, body: body) }
                }
            }

            guard buf.count >= pos + size + 2 else { return pending }
            guard buf[pos + size] == 13, buf[pos + size + 1] == 10 else { return .failed(.malformed) }
            body.append(contentsOf: buf[pos..<(pos + size)])
            pos += size + 2
        }
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8], from: Int) -> Int? {
        guard hay.count >= needle.count, from <= hay.count - needle.count else { return nil }
        for i in from...(hay.count - needle.count) where hay[i] == needle[0] {
            if hay[i..<(i + needle.count)].elementsEqual(needle) { return i }
        }
        return nil
    }
}
