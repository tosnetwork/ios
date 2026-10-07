import Foundation

/// Untrusted read-only relay. Use on a worker thread; proof verification establishes authenticity.
public final class TOSV5R2ProofHTTPTransport {
    private let endpoint: URL
    private let configuration: URLSessionConfiguration
    private let timeout: TimeInterval
    public convenience init(endpoint: URL) throws {
        try self.init(endpoint: endpoint, configuration: .ephemeral, timeout: 20)
    }
    internal init(endpoint: URL, configuration: URLSessionConfiguration, timeout: TimeInterval) throws {
        guard ["https", "http"].contains(endpoint.scheme), endpoint.host != nil,
              endpoint.user == nil, endpoint.password == nil, endpoint.fragment == nil,
              timeout > 0, timeout <= 20 else { throw TOSPQError.invalidInput }
        self.endpoint = endpoint
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.timeout = timeout
    }
    public func query(_ query: Data, maximumBytes: Int, isCancelled: () -> Bool = { Thread.current.isCancelled }) throws -> Data {
        guard !Thread.isMainThread, (1...16384).contains(query.count), (1...67_108_864).contains(maximumBytes),
              !isCancelled() else { throw TOSPQError.invalidInput }
        let id = UUID().uuidString
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id,
            "method": "getProofQuery", "params": ["query": query.base64EncodedString()]])
        request.timeoutInterval = timeout
        let encodedLimit = (maximumBytes + 2) / 3 * 4
        let receiver = Receiver(limit: encodedLimit + 4096)
        let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: nil)
        let task = session.dataTask(with: request)
        defer { task.cancel(); session.invalidateAndCancel() }
        task.resume()
        let deadline = DispatchTime.now() + timeout
        while receiver.completed.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            guard DispatchTime.now() < deadline, !isCancelled() else { throw TOSPQError.invalidInput }
        }
        guard !isCancelled(), receiver.failure == nil else { throw TOSPQError.invalidInput }
        try Self.checkEnvelope(receiver.bytes)
        guard let object = try JSONSerialization.jsonObject(with: receiver.bytes) as? [String: Any],
              object["jsonrpc"] as? String == "2.0", object["id"] as? String == id, object["error"] == nil,
              let result = object["result"] as? [String: Any], let reply = result["reply"] as? String,
              reply.utf8.count <= encodedLimit, let decoded = Data(base64Encoded: reply),
              !decoded.isEmpty, decoded.count <= maximumBytes else { throw TOSPQError.invalidInput }
        return decoded
    }
    private static func checkEnvelope(_ bytes: Data) throws {
        var depth = 0, quoted = false, escaped = false, started = false, finished = false
        for byte in bytes {
            if !quoted && depth == 0 {
                if [9, 10, 13, 32].contains(byte) { continue }
                guard !started, !finished, byte == 123 else { throw TOSPQError.invalidInput }
                started = true
            }
            if quoted {
                if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { quoted = false }
            } else {
                switch byte {
                case 34: quoted = true
                case 123: depth += 1; guard depth <= 2 else { throw TOSPQError.invalidInput }
                case 125: depth -= 1; guard depth >= 0 else { throw TOSPQError.invalidInput }; if depth == 0 { finished = true }
                case 91, 93: throw TOSPQError.invalidInput
                default: break
                }
            }
        }
        guard started, finished, !quoted, depth == 0 else { throw TOSPQError.invalidInput }
    }
    private final class Receiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let completed = DispatchSemaphore(value: 0)
        let limit: Int
        var bytes = Data()
        var failure: Error?
        init(limit: Int) { self.limit = limit }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  response.expectedContentLength <= Int64(limit) else {
                failure = TOSPQError.invalidInput; completionHandler(.cancel); return
            }
            completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard data.count <= limit - bytes.count else { failure = TOSPQError.invalidInput; dataTask.cancel(); return }
            bytes.append(data)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { failure = error }
            completed.signal()
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            failure = TOSPQError.invalidInput
            completionHandler(nil)
        }
    }
}
