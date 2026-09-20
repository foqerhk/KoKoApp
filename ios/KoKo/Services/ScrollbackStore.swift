import Foundation

final class ScrollbackStore {
    static let shared = ScrollbackStore()

    /// Cap restored history so opening a chat does not feed megabytes into SwiftTerm.
    static let maxLoadBytes = 1024 * 1024

    private let directoryName = "scrollback"
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.foqerhk.koko.scrollback", qos: .utility)
    private var openHandles: [UUID: FileHandle] = [:]

    private init() {}

    private var directoryURL: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent(directoryName, isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func fileURL(for sessionId: UUID) -> URL {
        directoryURL.appendingPathComponent("\(sessionId.uuidString).log")
    }

    /// Append off the main thread; keeps a single FileHandle per session.
    func append(sessionId: UUID, data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            self?.appendSync(sessionId: sessionId, data: data)
        }
    }

    private func appendSync(sessionId: UUID, data: Data) {
        let url = fileURL(for: sessionId)
        if let handle = openHandles[sessionId] {
            handle.write(data)
            return
        }
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? data.write(to: url, options: .atomic)
            return
        }
        handle.seekToEndOfFile()
        handle.write(data)
        openHandles[sessionId] = handle
    }

    /// Loads at most the trailing `maxLoadBytes` of the log (sync; call once at init).
    func load(sessionId: UUID) -> Data? {
        queue.sync {
            if let handle = openHandles[sessionId] {
                try? handle.synchronize()
            }
            let url = fileURL(for: sessionId)
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            if size == 0 { return nil }
            if size > UInt64(Self.maxLoadBytes) {
                try? handle.seek(toOffset: size - UInt64(Self.maxLoadBytes))
            } else {
                try? handle.seek(toOffset: 0)
            }
            return try? handle.readToEnd()
        }
    }

    func clear(sessionId: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            if let handle = self.openHandles.removeValue(forKey: sessionId) {
                try? handle.close()
            }
            try? self.fileManager.removeItem(at: self.fileURL(for: sessionId))
        }
    }

    func clearAll() {
        queue.async { [weak self] in
            guard let self else { return }
            for (_, handle) in self.openHandles {
                try? handle.close()
            }
            self.openHandles.removeAll()
            guard let files = try? self.fileManager.contentsOfDirectory(
                at: self.directoryURL,
                includingPropertiesForKeys: nil
            ) else { return }
            for file in files {
                try? self.fileManager.removeItem(at: file)
            }
        }
    }
}
