import CryptoKit
import Foundation
import XCTest

@testable import DesktopUpdaterKit

final class UpdateTransportTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testMetadataUsesApplicationAuthorizationHeaders() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer fixture"
            )
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!,
                Data("metadata".utf8)
            )
        }
        let data = try await transport.downloadMetadata(
            from: URL(string: "https://updates.example.test/index.json")!,
            configuration: try configuration { _ in
                ["Authorization": "Bearer fixture"]
            }
        )
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "metadata")
    }

    func testHTTPSRedirectDowngradeIsRejected() async throws {
        StubURLProtocol.handler = { request in
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 302,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "http://updates.example.test/next"]
                )!,
                Data()
            )
        }
        do {
            _ = try await transport.downloadMetadata(
                from: URL(string: "https://updates.example.test/index.json")!,
                configuration: try configuration()
            )
            XCTFail("Expected HTTPS redirect downgrade rejection")
        } catch {
            XCTAssertTrue(String(describing: error).contains("downgrade"))
        }
    }

    func testArtifactResumesWithMatchingContentRange() async throws {
        let full = Data("complete artifact bytes".utf8)
        let prefix = full.prefix(9)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("transport-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("artifact.zip")
        let part = destination.appendingPathExtension("part")
        try Data(prefix).write(to: part)

        StubURLProtocol.handler = { request in
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Range"),
                "bytes=\(prefix.count)-"
            )
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 206,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Range":
                            "bytes \(prefix.count)-\(full.count - 1)/\(full.count)"
                    ]
                )!,
                full.dropFirst(prefix.count)
            )
        }
        try await transport.downloadArtifact(
            RuntimeArtifactDownload(
                url: URL(string: "https://updates.example.test/artifact.zip")!,
                destination: destination,
                expectedLength: Int64(full.count),
                expectedSHA256: SHA256.hash(data: full)
                    .map { String(format: "%02x", $0) }
                    .joined()
            ),
            configuration: try configuration(),
            progress: nil
        )
        XCTAssertEqual(try Data(contentsOf: destination), full)
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
    }

    private var transport: FoundationUpdateTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return FoundationUpdateTransport(sessionConfiguration: configuration)
    }

    private func configuration(
        headers: @escaping RuntimeRequestHeadersProvider = { _ in [:] }
    ) throws -> RuntimeConfiguration {
        return try RuntimeConfiguration(
            appArchiveUrl: URL(
                string: "https://updates.example.test/app-archive.json"
            )!,
            expectedPackageId: "com.example.native-contract",
            currentVersion: "2.7.0",
            currentBuildNumber: 270,
            currentUpdaterVersion: "2.7.0",
            platform: "macos",
            pinnedPublicKeysById: [
                "native-contract-stable": Data(repeating: 1, count: 32)
            ],
            requestHeadersProvider: headers
        )
    }
}

private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
