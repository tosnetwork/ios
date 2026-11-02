import Foundation
import Darwin
import CoreComponents

/// Bounded document input only. Authentication and identity validation happen after password entry.
public enum TOSQuantumBackupDocument {
    public static func read(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw TOSPQError.invalidInput }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw TOSPQError.invalidInput }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              (58...262201).contains(info.st_size),
              let bytes = try handle.read(upToCount: 262202), bytes.count == info.st_size else { throw TOSPQError.invalidInput }
        return bytes
    }
}
