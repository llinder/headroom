import Foundation
import Testing
@testable import HeadroomCore

@Suite struct DockerClientTests {
    private func serve(_ text: String?, _ body: (FakeUnixHTTPServer) throws -> Void) throws {
        let server = try FakeUnixHTTPServer(response: text.map { Array($0.utf8) })
        defer { server.stop() }
        try body(server)
    }

    @Test func contentLengthBody() throws {
        try serve("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello") { s in
            let data = try DockerClient(socketPath: s.socketPath).get("/x")
            #expect(data == Data("hello".utf8))
        }
    }

    @Test func chunkedBody() throws {
        try serve("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n") { s in
            let data = try DockerClient(socketPath: s.socketPath).get("/x")
            #expect(data == Data("abcde".utf8))
        }
    }

    @Test func chunkedWithExtensionsTrailersAndUppercaseHex() throws {
        let text = "HTTP/1.0 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nA;ext=1\r\n0123456789\r\n0\r\nX-T: 1\r\n\r\n"
        try serve(text) { s in
            let data = try DockerClient(socketPath: s.socketPath).get("/x")
            #expect(data == Data("0123456789".utf8))
        }
    }

    @Test func bodyWithoutFramingReadsToEOF() throws {
        try serve("HTTP/1.1 200 OK\r\n\r\nuntil-eof") { s in
            let data = try DockerClient(socketPath: s.socketPath).get("/x")
            #expect(data == Data("until-eof".utf8))
        }
    }

    @Test func non2xxThrowsStatus() throws {
        try serve("HTTP/1.1 404 Not Found\r\nContent-Length: 2\r\n\r\nno") { s in
            #expect(throws: DockerError.status(404)) { try DockerClient(socketPath: s.socketPath).get("/x") }
        }
    }

    @Test func missingSocketIsRefused() {
        #expect(throws: DockerError.refused) {
            try DockerClient(socketPath: "/tmp/hr-nonexistent/s").get("/x")
        }
    }

    @Test func overlongPathIsRefused() {
        let path = "/tmp/" + String(repeating: "a", count: 120)
        #expect(throws: DockerError.refused) { try DockerClient(socketPath: path).get("/x") }
    }

    @Test func serverThatNeverRespondsTimesOut() throws {
        try serve(nil) { s in
            let start = ContinuousClock.now
            #expect(throws: DockerError.timeout) {
                try DockerClient(socketPath: s.socketPath, timeout: 0.3).get("/x")
            }
            #expect(ContinuousClock.now - start < .seconds(1))
        }
    }

    @Test func serverClosingMidBodyIsMalformed() throws {
        try serve("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc") { s in
            #expect(throws: DockerError.malformed) { try DockerClient(socketPath: s.socketPath).get("/x") }
        }
    }

    @Test func serverClosingMidChunkIsMalformed() throws {
        try serve("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nab") { s in
            #expect(throws: DockerError.malformed) { try DockerClient(socketPath: s.socketPath).get("/x") }
        }
    }

    @Test func hugeChunkSizeIsMalformedNotACrash() throws {
        try serve("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n7fffffffffffffff\r\nab") { s in
            #expect(throws: DockerError.malformed) { try DockerClient(socketPath: s.socketPath).get("/x") }
        }
    }

    @Test func serverAcceptingAndClosingIsAnErrorNotASignal() throws {
        try serve("") { s in
            #expect(throws: DockerError.malformed) { try DockerClient(socketPath: s.socketPath).get("/x") }
        }
    }

    @Test func declaredContentLengthOverCapIsMalformed() throws {
        try serve("HTTP/1.1 200 OK\r\nContent-Length: 99999999999\r\n\r\nabc") { s in
            #expect(throws: DockerError.malformed) { try DockerClient(socketPath: s.socketPath).get("/x") }
        }
    }

    @Test func responseOverCapIsMalformed() throws {
        let big = "HTTP/1.1 200 OK\r\n\r\n" + String(repeating: "a", count: HTTPResponseParser.maxBody + 1)
        try serve(big) { s in
            #expect(throws: DockerError.malformed) { try DockerClient(socketPath: s.socketPath, timeout: 10).get("/x") }
        }
    }

    @Test func slowDripRespectsDeadline() throws {
        let server = try FakeUnixHTTPServer(response: Array(("HTTP/1.1 200 OK\r\n\r\n" + String(repeating: "a", count: 100)).utf8), dripInterval: 0.2)
        defer { server.stop() }
        let start = ContinuousClock.now
        #expect(throws: DockerError.timeout) {
            try DockerClient(socketPath: server.socketPath, timeout: 0.5).get("/x")
        }
        #expect(ContinuousClock.now - start < .seconds(1.5))
    }

    @Test func malformedStatusLine() throws {
        try serve("NOTHTTP 200\r\n\r\n") { s in
            #expect(throws: DockerError.malformed) { try DockerClient(socketPath: s.socketPath).get("/x") }
        }
    }

    @Test func chunkSizeLineWithoutCRLFThenEOF() throws {
        try serve("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5") { s in
            #expect(throws: DockerError.malformed) { try DockerClient(socketPath: s.socketPath).get("/x") }
        }
    }
}
