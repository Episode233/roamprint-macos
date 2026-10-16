import XCTest
@testable import RoamPrintCore

final class HTTPFramingTests: XCTestCase {
    func testFragmentedContentLengthAndExpectContinue() throws {
        var parser = HTTPFramer()
        XCTAssertNil(try parser.append(Data("POST /ipp/print HTTP/1.1\r\nHost: 127.0.0.1:19963\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\n".utf8)))
        XCTAssertTrue(parser.expectsContinue)
        XCTAssertNil(try parser.append(Data("abc".utf8)))
        XCTAssertEqual(try parser.append(Data("de".utf8)), Data("abcde".utf8))
        XCTAssertTrue(parser.complete)
    }
    func testChunkedRequestFragmentedOneByteAtATime() throws {
        var parser = HTTPFramer()
        let request = Data("POST /ipp/print HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3;foo=bar\r\nabc\r\n2\r\nde\r\n0\r\nX-Receipt: done\r\n\r\n".utf8)
        var result: Data?
        for byte in request { result = try parser.append(Data([byte])) }
        XCTAssertEqual(result, Data("abcde".utf8))
    }
    func testMalformedAndAmbiguousHTTPNeverTrapsOrAccepts() {
        let requests = [
            "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n\r\n",
            "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 1\r\n\r\n",
            "POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\na",
            "POST / HTTP/1.1\r\nContent-Length: +1\r\n\r\na",
            "POST / HTTP/1.1\r\nContent-Length: 1\r\n\r\nab",
            "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\nextra",
            "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nContent-Length: 1\r\n\r\n",
            "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n8000001\r\n",
            "POST / HTTP/1.1\r\nBad Header: 1\r\nContent-Length: 0\r\n\r\n"
        ]
        for request in requests {
            var parser = HTTPFramer()
            XCTAssertThrowsError(try parser.append(Data(request.utf8)), request)
        }
    }
}
