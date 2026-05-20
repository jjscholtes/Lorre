import Foundation

enum AtomicFileWriter {
    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let tempURL = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: [])
        var shouldRemoveTemp = true
        defer {
            if shouldRemoveTemp,
               FileManager.default.fileExists(atPath: tempURL.path(percentEncoded: false)) {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        let handle = try FileHandle(forWritingTo: tempURL)
        do {
            if #available(macOS 10.15.4, *) {
                try handle.synchronize()
                try handle.close()
            } else {
                handle.synchronizeFile()
                handle.closeFile()
            }
        } catch {
            try? handle.close()
            throw error
        }

        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: url)
        }
        shouldRemoveTemp = false
    }
}
