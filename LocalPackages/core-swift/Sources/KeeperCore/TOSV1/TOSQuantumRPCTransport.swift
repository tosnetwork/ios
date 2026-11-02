import Foundation
import CoreComponents

/// Bounded untrusted transaction relay. A successful JSON-RPC response is never
/// a payment receipt; raw transaction cells still need proof-anchored hashes.
internal final class TOSQuantumRPCTransport {
    private let endpoint: URL
    private let configuration: URLSessionConfiguration
    private let timeout: TimeInterval

    init(endpoint: URL, configuration: URLSessionConfiguration = .ephemeral, timeout: TimeInterval = 20) throws {
        guard ["https", "http"].contains(endpoint.scheme), endpoint.host != nil,
              endpoint.user == nil, endpoint.password == nil, endpoint.fragment == nil,
              (0...20).contains(timeout), timeout > 0 else { throw TOSPQError.invalidInput }
        self.endpoint = endpoint
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.timeout = timeout
    }

    func call(method: String, params: [String: Any], maximumBytes: Int = 2_097_152,
              isCancelled: () -> Bool = { Thread.current.isCancelled }) throws -> Any {
        guard !Thread.isMainThread, ["getTransactions", "sendBocReturnHash", "estimateFee"].contains(method),
              (1...2_097_152).contains(maximumBytes), !isCancelled() else { throw TOSPQError.invalidInput }
        let id = UUID().uuidString
        let bytes = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        guard bytes.count <= 131_072 else { throw TOSPQError.invalidInput }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bytes
        request.timeoutInterval = timeout
        let receiver = Receiver(limit: maximumBytes)
        let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: nil)
        let task = session.dataTask(with: request)
        defer { task.cancel(); session.invalidateAndCancel() }
        task.resume()
        let deadline = DispatchTime.now() + timeout
        while receiver.completed.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            guard DispatchTime.now() < deadline, !isCancelled() else { throw TOSPQError.invalidInput }
        }
        guard !isCancelled(), receiver.failure == nil else { throw TOSPQError.invalidInput }
        try Self.checkJSON(receiver.bytes)
        guard let object = try JSONSerialization.jsonObject(with: receiver.bytes) as? [String: Any],
              object["jsonrpc"] as? String == "2.0", object["id"] as? String == id,
              object["error"] == nil, let result = object["result"], !(result is NSNull) else {
            throw TOSPQError.invalidInput
        }
        return result
    }

    private static func checkJSON(_ bytes: Data) throws {
        var stack = [UInt8](), quoted = false, escaped = false, started = false, finished = false
        for byte in bytes {
            if !quoted && stack.isEmpty {
                if [9, 10, 13, 32].contains(byte) { continue }
                guard !started, !finished, byte == 123 else { throw TOSPQError.invalidInput }
                started = true
            }
            if quoted {
                if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { quoted = false }
            } else {
                switch byte {
                case 34: quoted = true
                case 123, 91:
                    stack.append(byte)
                    guard stack.count <= 64 else { throw TOSPQError.invalidInput }
                case 125, 93:
                    guard stack.popLast() == (byte == 125 ? 123 : 91) else { throw TOSPQError.invalidInput }
                    if stack.isEmpty { finished = true }
                default: break
                }
            }
        }
        guard started, finished, !quoted, stack.isEmpty else { throw TOSPQError.invalidInput }
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
