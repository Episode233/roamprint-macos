import XCTest
@testable import RoamPrintCore
import Foundation

/// Real URLSession POSTs and real system curl PUTs, with no mocked transport or uploader.
final class SubmissionIntegrationTests: XCTestCase {
    func testNativeConnectionUsesNoCORSHeadersOrPreflight() async throws {
        let done = expectation(description: "native API calls without CORS")
        let replies: [[String: Any]] = [
            ["Code": "0", "data": "native-token"],
            ["Code": "0", "List": [["ID": 1, "StorageType": 2, "IP": "127.0.0.1", "Port": 21,
                "UserName": "storage", "Password": "", "FileEncType": 0]]]
        ]
        let server = try LoopbackHTTPServer(statuses: [200, 200],
            responseBodies: try replies.map { try JSONSerialization.data(withJSONObject: $0) }, done: done)
        let configuration = try ServerConfiguration(baseURL: URL(string: "http://127.0.0.1:\(server.port)/xzentprint/services")!)
        server.start()
        let result = try await V5Platform(configuration: configuration).checkConnection()
        await fulfillment(of: [done], timeout: 10)
        let (requests, error) = server.snapshot()
        XCTAssertNil(error)
        XCTAssertTrue(result.contains("FTP"))
        XCTAssertEqual(requests.map(\.method), ["POST", "POST"])
        XCTAssertTrue(requests.allSatisfy { $0.headers["origin"] == nil })
        XCTAssertEqual(requests.map(\.target), ["/xzentprint/services/getToken", "/xzentprint/services/filestorage"])
    }
    func testRealHTTPAndStorageSubmissionPreservesCardRelease() async throws {
        try await exercise(dropFinalResponse: false)
    }
    func testLostRealFinalizeResponsePreservesJobAndPreventsRecreation() async throws {
        try await exercise(dropFinalResponse: true)
    }
    private func exercise(dropFinalResponse: Bool) async throws {
        let davDone = expectation(description: "storage completed")
        let storageServer = try LoopbackHTTPServer(statuses: [201, 201, 201], done: davDone)
        let apiDone = expectation(description: "enterprise API completed")
        let storagePassword = "storage\"\\password&:!"
        let responses: [[String: Any]] = [
            ["Code": "0", "data": "integration-token"],
            ["Code": "0", "List": [["ID": 9, "StorageType": 6, "IP": "127.0.0.1", "Port": storageServer.port,
                "UserName": "integration-storage", "Password": try LegacyPassword.encrypt(storagePassword), "FileEncType": 0]]],
            ["Code": "0", "SubmitJobId": 731],
            ["Code": "0"]
        ]
        let apiServer = try LoopbackHTTPServer(statuses: [200, 200, 200, 200],
            responseBodies: try responses.map { try JSONSerialization.data(withJSONObject: $0) },
            dropResponses: dropFinalResponse ? [3] : [], done: apiDone)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("%PDF-1.7\nIntegration fixture\n".utf8) + Data(repeating: 0x9a, count: 512 * 1024)
        let source = root.appendingPathComponent("source.pdf")
        try bytes.write(to: source)
        let queue = try JobQueue(root: root.appendingPathComponent("jobs"))
        let job = try await queue.add(source: source,
            info: DocumentInfo(title: "集成测试", pageCount: 3, byteCount: Int64(bytes.count)),
            settings: PrintSettings(copies: 2, color: .color, duplex: .shortEdge, collate: false, landscape: true))
        let configuration = try ServerConfiguration(
            baseURL: URL(string: "http://127.0.0.1:\(apiServer.port)/xzentprint/services")!)
        let client = V5Platform(configuration: configuration,
            identity: ClientIdentity(ip: "127.0.0.1", mac: "00:11:22:33:44:55", host: "integration-mac"))
        let credentials = Credentials(username: "integration-user", password: "fixture-password")
        storageServer.start(); apiServer.start()
        var submitError: Error?
        do { try await client.submit(job: job, credentials: credentials, queue: queue) }
        catch { submitError = error }
        await fulfillment(of: [apiDone, davDone], timeout: 20)
        let (api, apiError) = apiServer.snapshot(), (dav, davError) = storageServer.snapshot()
        XCTAssertNil(apiError); XCTAssertNil(davError)
        XCTAssertEqual(api.map(\.target), ["getToken", "filestorage", "print", "printfile"].map { "/xzentprint/services/" + $0 })
        guard api.count == 4, dav.count == 3 else {
            XCTFail("submission did not complete the expected HTTP/storage request sequence")
            return
        }
        XCTAssertTrue(api.allSatisfy { $0.method == "POST" && $0.headers["content-type"] == "application/json;charset=UTF-8" })
        XCTAssertTrue(api.dropFirst().allSatisfy {
            $0.headers["token"] == "integration-token" && $0.authorization == "Bearer integration-token"
        })
        let create = try JSONSerialization.jsonObject(with: api[2].body) as! [String: Any]
        let password = try XCTUnwrap(create["pwd"] as? String)
        XCTAssertEqual(try LegacyPassword.decrypt(password), credentials.password)
        XCTAssertEqual(create["signature"] as? String,
            V5Wire.signature("type=4&code=\(credentials.username)&pwd=\(password)"))
        XCTAssertEqual(create["directprintid"] as? Int, -1)
        XCTAssertEqual(create["ischeckpwd"] as? Int, 1)
        XCTAssertEqual(create["count"] as? Int, 2)
        XCTAssertEqual(create["direction"] as? Int, 2)
        XCTAssertEqual(create["iscollate"] as? Int, 0)
        XCTAssertEqual(create["doubleprint"] as? Int, 3)
        XCTAssertEqual(create["filesize"] as? Int, bytes.count)
        XCTAssertEqual(dav.map(\.method), ["MKCOL", "MKCOL", "PUT"])
        let storageAuth = "Basic " + Data(("integration-storage:" + storagePassword).utf8).base64EncodedString()
        XCTAssertTrue(dav.allSatisfy { $0.authorization == storageAuth })
        XCTAssertEqual(dav.last?.body, bytes)
        let finish = try JSONSerialization.jsonObject(with: api[3].body) as! [String: Any]
        XCTAssertEqual(finish["state"] as? Int, 1)
        XCTAssertEqual(finish["submitjobid"] as? Int, 731)
        XCTAssertEqual(finish["filestorageid"] as? Int, 9)
        XCTAssertEqual(finish["jobpath"] as? String, dav.last?.target.removingPercentEncoding)
        let saved = try await queue.get(job.id)
        XCTAssertEqual(saved.state, dropFinalResponse ? .uncertain : .submitted)
        XCTAssertEqual(saved.serverJobID, "731")
        let capturedDocument = await queue.documentURL(job.id)
        XCTAssertEqual(try Data(contentsOf: capturedDocument), bytes)
        if dropFinalResponse { XCTAssertNotNil(submitError) } else { XCTAssertNil(submitError) }
        do {
            try await client.submit(job: job, credentials: credentials, queue: queue)
            XCTFail("completed or uncertain job must not be recreated")
        } catch {
            guard case PrintError.queue = error else { return XCTFail("must reject before any network request") }
        }
    }
}
