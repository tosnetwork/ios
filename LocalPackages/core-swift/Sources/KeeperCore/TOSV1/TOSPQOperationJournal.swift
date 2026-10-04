import Foundation

/// Public operation metadata is written atomically before network submission.
public actor TOSPQOperationJournal {
    private let directory: URL
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TOSPQOperations", isDirectory: true)
    }
    private func file(_ address: String) -> URL {
        directory.appendingPathComponent(Data(address.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_") + ".json")
    }
    public func read(address: String) throws -> TOSPQPendingOperation? {
        let path = file(address)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return try JSONDecoder().decode(TOSPQPendingOperation.self, from: Data(contentsOf: path))
    }
    public func write(_ operation: TOSPQPendingOperation) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = file(operation.walletAddress)
        try JSONEncoder().encode(operation).write(to: path, options: [.atomic, .completeFileProtection])
        let handle = try FileHandle(forWritingTo: path);defer { try? handle.close() };try handle.synchronize()
    }
}
