import CryptoKit
import Foundation

public struct RuntimeArtifactDownload: Sendable {
    public let url: URL
    public let destination: URL
    public let expectedLength: Int64
    public let expectedSHA256: String

    public init(
        url: URL,
        destination: URL,
        expectedLength: Int64,
        expectedSHA256: String
    ) {
        self.url = url
        self.destination = destination
        self.expectedLength = expectedLength
        self.expectedSHA256 = expectedSHA256
    }
}

public protocol RuntimeUpdateTransport {
    func downloadMetadata(
        from url: URL,
        configuration: RuntimeConfiguration
    ) async throws -> Data

    func downloadArtifact(
        _ request: RuntimeArtifactDownload,
        configuration: RuntimeConfiguration,
        progress: (@Sendable (Int64, Int64?) -> Void)?
    ) async throws
}

public final class FoundationUpdateTransport: RuntimeUpdateTransport {
    private let sessionConfiguration: URLSessionConfiguration
    private let maximumRedirects = 5
    private let maximumRetries = 3

    public init(
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) {
        self.sessionConfiguration = sessionConfiguration
    }

    public func downloadMetadata(
        from initialURL: URL,
        configuration: RuntimeConfiguration
    ) async throws -> Data {
        var url = try validateURL(initialURL)
        if url.isFileURL {
            return try readBoundedFile(
                url,
                maximumBytes: configuration.maximumMetadataBytes
            )
        }
        for redirectCount in 0 ... maximumRedirects {
            for attempt in 0 ..< maximumRetries {
                do {
                    let response = try await perform(
                        url: url,
                        configuration: configuration,
                        maximumBytes: configuration.maximumMetadataBytes
                    )
                    if response.isRedirect {
                        guard redirectCount < maximumRedirects else {
                            throw RuntimeError.outcome(
                                .downloadFailure,
                                message: "Update redirect limit exceeded."
                            )
                        }
                        url = try redirectedURL(
                            from: url,
                            response: response.response
                        )
                        break
                    }
                    guard response.isSuccess else {
                        throw HTTPFailure(statusCode: response.statusCode)
                    }
                    return response.data
                } catch {
                    if attempt + 1 == maximumRetries || !isRetryable(error) {
                        throw RuntimeError.outcome(
                            .downloadFailure,
                            message: "Metadata download failed: \(error)"
                        )
                    }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }
        throw RuntimeError.outcome(
            .downloadFailure,
            message: "Update redirect limit exceeded."
        )
    }

    public func downloadArtifact(
        _ request: RuntimeArtifactDownload,
        configuration: RuntimeConfiguration,
        progress: (@Sendable (Int64, Int64?) -> Void)? = nil
    ) async throws {
        guard request.expectedLength >= 0,
              request.expectedSHA256.range(
                  of: "^[0-9a-f]{64}$",
                  options: .regularExpression
              ) != nil
        else {
            throw RuntimeError.invalidConfiguration(
                "Artifact integrity expectations are invalid."
            )
        }
        let partURL = request.destination
            .appendingPathExtension("part") // deterministic .part ownership
        var url = try validateURL(request.url)
        do {
            if url.isFileURL {
                try copyBoundedFile(
                    url,
                    destination: partURL,
                    maximumBytes: request.expectedLength,
                    progress: progress
                )
            } else {
                redirectLoop: for redirectCount in 0 ... maximumRedirects {
                    for attempt in 0 ..< maximumRetries {
                        let resume = fileSize(partURL)
                        if resume > request.expectedLength {
                            try? FileManager.default.removeItem(at: partURL)
                            continue
                        }
                        do {
                            let response = try await perform(
                                url: url,
                                configuration: configuration,
                                maximumBytes: request.expectedLength - resume,
                                destination: partURL,
                                resumeOffset: resume,
                                progress: progress
                            )
                            if response.isRedirect {
                                guard redirectCount < maximumRedirects else {
                                    throw RuntimeError.outcome(
                                        .downloadFailure,
                                        message: "Update redirect limit exceeded."
                                    )
                                }
                                url = try redirectedURL(
                                    from: url,
                                    response: response.response
                                )
                                continue redirectLoop
                            }
                            if resume > 0, response.statusCode == 200 {
                                try? FileManager.default.removeItem(at: partURL)
                                continue
                            }
                            if resume > 0, response.statusCode == 206 {
                                let contentRange = response.response.value(
                                    forHTTPHeaderField: "Content-Range"
                                ) ?? ""
                                guard contentRange.hasPrefix("bytes \(resume)-") else {
                                    throw RuntimeError.outcome(
                                        .downloadFailure,
                                        message: "Content-Range does not match .part file."
                                    )
                                }
                            }
                            guard response.isSuccess else {
                                throw HTTPFailure(statusCode: response.statusCode)
                            }
                            break redirectLoop
                        } catch {
                            if attempt + 1 == maximumRetries ||
                                !isRetryable(error)
                            {
                                throw error
                            }
                            try await Task.sleep(nanoseconds: 100_000_000)
                        }
                    }
                }
            }

            guard fileSize(partURL) == request.expectedLength else {
                throw RuntimeError.outcome(
                    .artifactIntegrityFailure,
                    message: "Artifact length verification failed."
                )
            }
            guard try fileSHA256(partURL) == request.expectedSHA256 else {
                throw RuntimeError.outcome(
                    .artifactIntegrityFailure,
                    message: "Artifact SHA-256 verification failed."
                )
            }
            try? FileManager.default.removeItem(at: request.destination)
            try FileManager.default.moveItem(
                at: partURL,
                to: request.destination
            )
        } catch {
            try? FileManager.default.removeItem(at: partURL)
            throw error
        }
    }

    private func perform(
        url: URL,
        configuration: RuntimeConfiguration,
        maximumBytes: Int64,
        destination: URL? = nil,
        resumeOffset: Int64 = 0,
        progress: (@Sendable (Int64, Int64?) -> Void)? = nil
    ) async throws -> TransportResponse {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: configuration.downloadTimeout
        )
        for (name, value) in configuration.requestHeadersProvider(url) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if resumeOffset > 0 {
            request.setValue(
                "bytes=\(resumeOffset)-",
                forHTTPHeaderField: "Range"
            )
        }
        return try await DataTaskExecutor(
            configuration: sessionConfiguration,
            maximumBytes: maximumBytes,
            destination: destination,
            resumeOffset: resumeOffset,
            progress: progress
        ).execute(request)
    }

    private func validateURL(_ url: URL) throws -> URL {
        guard let scheme = url.scheme?.lowercased(),
              ["https", "http", "file"].contains(scheme)
        else {
            throw RuntimeError.outcome(
                .downloadFailure,
                message: "Unsupported update URL scheme."
            )
        }
        if ["https", "http"].contains(scheme), url.host?.isEmpty != false {
            throw RuntimeError.outcome(
                .downloadFailure,
                message: "HTTP update URL must include a host."
            )
        }
        return url
    }

    private func redirectedURL(
        from source: URL,
        response: HTTPURLResponse
    ) throws -> URL {
        guard let location = response.value(forHTTPHeaderField: "Location"),
              let target = URL(string: location, relativeTo: source)?.absoluteURL
        else {
            throw RuntimeError.outcome(
                .downloadFailure,
                message: "Redirect is missing Location."
            )
        }
        _ = try validateURL(target)
        if source.scheme?.lowercased() == "https",
           target.scheme?.lowercased() != "https"
        {
            throw RuntimeError.outcome(
                .downloadFailure,
                message: "HTTPS redirect downgrade is forbidden."
            )
        }
        return target
    }

    private func isRetryable(_ error: Error) -> Bool {
        if let failure = error as? HTTPFailure {
            return failure.statusCode == 408 || failure.statusCode == 429 ||
                failure.statusCode >= 500
        }
        if let urlError = error as? URLError {
            return [
                .timedOut,
                .cannotConnectToHost,
                .networkConnectionLost,
                .notConnectedToInternet,
            ].contains(urlError.code)
        }
        return false
    }
}

private struct HTTPFailure: Error {
    let statusCode: Int
}

private struct TransportResponse {
    let response: HTTPURLResponse
    let data: Data

    var statusCode: Int { response.statusCode }
    var isSuccess: Bool { (200 ... 299).contains(statusCode) }
    var isRedirect: Bool { [301, 302, 303, 307, 308].contains(statusCode) }
}

private final class DataTaskExecutor: NSObject,
    URLSessionDataDelegate,
    URLSessionTaskDelegate
{
    private let configuration: URLSessionConfiguration
    private let maximumBytes: Int64
    private let destination: URL?
    private let resumeOffset: Int64
    private let progress: (@Sendable (Int64, Int64?) -> Void)?
    private var continuation: CheckedContinuation<TransportResponse, Error>?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var received: Int64 = 0
    private var fileHandle: FileHandle?
    private var terminalError: Error?
    private var session: URLSession?

    init(
        configuration: URLSessionConfiguration,
        maximumBytes: Int64,
        destination: URL?,
        resumeOffset: Int64,
        progress: (@Sendable (Int64, Int64?) -> Void)?
    ) {
        self.configuration = configuration
        self.maximumBytes = maximumBytes
        self.destination = destination
        self.resumeOffset = resumeOffset
        self.progress = progress
    }

    func execute(_ request: URLRequest) async throws -> TransportResponse {
        if let destination {
            if !FileManager.default.fileExists(atPath: destination.path) {
                FileManager.default.createFile(
                    atPath: destination.path,
                    contents: nil
                )
            }
            fileHandle = try FileHandle(forWritingTo: destination)
            fileHandle?.seekToEndOfFile()
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(
                configuration: configuration,
                delegate: self,
                delegateQueue: queue
            )
            self.session = session
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        self.response = response as? HTTPURLResponse
        completionHandler(.allow)
    }

    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive body: Data
    ) {
        if let response, [301, 302, 303, 307, 308].contains(response.statusCode) {
            return
        }
        if received > maximumBytes - Int64(body.count) {
            terminalError = RuntimeError.outcome(
                .downloadFailure,
                message: "Download exceeded its byte limit."
            )
            dataTask.cancel()
            return
        }
        if let fileHandle {
            fileHandle.write(body)
        } else {
            data.append(body)
        }
        received += Int64(body.count)
        let total = response?.expectedContentLength ?? -1
        progress?(
            resumeOffset + received,
            total >= 0 ? resumeOffset + total : nil
        )
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        fileHandle?.closeFile()
        session?.finishTasksAndInvalidate()
        guard let continuation else { return }
        self.continuation = nil
        if let terminalError {
            continuation.resume(throwing: terminalError)
        } else if let error {
            continuation.resume(throwing: error)
        } else if let response {
            continuation.resume(returning: TransportResponse(
                response: response,
                data: data
            ))
        } else {
            continuation.resume(throwing: URLError(.badServerResponse))
        }
    }
}

private func fileSize(_ url: URL) -> Int64 {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
}

private func readBoundedFile(_ url: URL, maximumBytes: Int64) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { handle.closeFile() }
    var result = Data()
    while true {
        let chunk = handle.readData(ofLength: 64 * 1024)
        if chunk.isEmpty { break }
        guard Int64(result.count) <= maximumBytes - Int64(chunk.count) else {
            throw RuntimeError.outcome(
                .downloadFailure,
                message: "file URL exceeded its byte limit."
            )
        }
        result.append(chunk)
    }
    return result
}

private func copyBoundedFile(
    _ source: URL,
    destination: URL,
    maximumBytes: Int64,
    progress: (@Sendable (Int64, Int64?) -> Void)?
) throws {
    let data = try readBoundedFile(source, maximumBytes: maximumBytes)
    try data.write(to: destination, options: .atomic)
    progress?(Int64(data.count), Int64(data.count))
}

private func fileSHA256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { handle.closeFile() }
    var hasher = SHA256()
    while true {
        let chunk = handle.readData(ofLength: 64 * 1024)
        if chunk.isEmpty { break }
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}
