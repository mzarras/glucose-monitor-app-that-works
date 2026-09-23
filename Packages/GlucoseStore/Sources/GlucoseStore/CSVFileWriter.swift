// Writes the CSV export to disk: header, then lines supplied by the caller, buffered in 64 KB
// chunks. Written to a temporary sibling file and moved into place only on success, so a failed
// export never leaves a truncated file at the destination.

import Foundation

enum CSVFileWriter {
    static let chunkSize = 64 * 1024

    /// - Parameter body: receives an `emit` function taking one CSV line (without newline);
    ///   returns the number of data lines it emitted.
    static func write(to destination: URL, body: (_ emit: (String) throws -> Void) throws -> Int) throws -> Int {
        let fileManager = FileManager.default
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent("." + destination.lastPathComponent + ".partial")
        try? fileManager.removeItem(at: partial)
        guard fileManager.createFile(atPath: partial.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: partial.path])
        }

        let count: Int
        do {
            let handle = try FileHandle(forWritingTo: partial)
            defer { try? handle.close() }
            var buffer = Data()
            buffer.reserveCapacity(chunkSize)

            func emit(_ line: String) throws {
                buffer.append(contentsOf: Array(line.utf8))
                buffer.append(0x0A) // LF
                if buffer.count >= chunkSize {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }

            try emit(CSVExport.header)
            count = try body(emit)
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
            }
            try handle.synchronize()
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: partial, to: destination)
        return count
    }
}
