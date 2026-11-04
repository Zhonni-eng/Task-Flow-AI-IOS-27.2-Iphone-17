// A versioned JSON document in a folder - the port of electron/storage.cjs's file handling. On
// iPhone it keeps the backup copy of the data next to the SwiftData store (and is the format used
// for import and export), with the same guarantees as on Windows:
//
//   taskflow-data.json        current data
//   taskflow-data.json.bak    previous successful save
//   taskflow-data.<reason>-<timestamp>.json   preserved copies of unreadable/repaired/imported data
//
// Writes are atomic (temp file + rename); unreadable data is preserved, never discarded; a file
// written by a newer Taskflow is never overwritten.
import Foundation

public enum LoadStatus: String, Sendable, Equatable {
    case new, loaded, recovered, unreadable, repaired, migrated
    case newerVersion = "newer-version"
    case readError = "read-error"
}

public struct LoadResult: Sendable {
    public var status: LoadStatus
    public var writable: Bool
    /// nil on a first launch (the app seeds sample tasks then).
    public var document: TaskflowDocument?
    public var preservedCopy: URL?
    public var preservedBackup: URL?
    public var dropped: Int

    public init(status: LoadStatus, writable: Bool, document: TaskflowDocument?, preservedCopy: URL?, preservedBackup: URL?, dropped: Int) {
        self.status = status
        self.writable = writable
        self.document = document
        self.preservedCopy = preservedCopy
        self.preservedBackup = preservedBackup
        self.dropped = dropped
    }
}

public final class DocumentFileStore: @unchecked Sendable {
    public let directory: URL
    public var file: URL { directory.appendingPathComponent(DocumentCodec.fileName) }
    public var backupFile: URL { directory.appendingPathComponent(DocumentCodec.fileName + ".bak") }

    private let fileManager = FileManager.default
    private let lock = NSLock()
    private(set) public var writable = false
    /// False while the current file is known to be unreadable: it must not become the backup.
    private var currentFileTrusted = true
    private let now: () -> Date

    public init(directory: URL, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.now = now
    }

    public enum WriteError: Error, Equatable { case readOnly, writeFailed }

    private func read(_ url: URL) throws -> DocumentCodec.Result {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ReadFailure.io
        }
        return try DocumentCodec.decode(data)
    }

    enum ReadFailure: Error { case io }

    private func stamp() -> String {
        ISOTime.string(now()).replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ".", with: "-")
    }

    /// Keeps a copy of a file next to the data; never deletes the original.
    @discardableResult
    public func preserveCopy(of source: URL, reason: String) throws -> URL {
        let target = directory.appendingPathComponent("taskflow-data.\(reason)-\(stamp()).json")
        try? fileManager.removeItem(at: target)
        try fileManager.copyItem(at: source, to: target)
        return target
    }

    /// Writes data as a preserved copy (e.g. an imported file or the data replaced by an import).
    @discardableResult
    public func preserve(data: Data, reason: String) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("taskflow-data.\(reason)-\(stamp()).json")
        try data.write(to: target, options: .atomic)
        return target
    }

    private func tryBackup() -> (parsed: DocumentCodec.Result?, preserved: URL?) {
        guard fileManager.fileExists(atPath: backupFile.path) else { return (nil, nil) }
        if let parsed = try? read(backupFile) { return (parsed, nil) }
        // Copied first, because the next saves rotate the backup and would otherwise overwrite what
        // may be the only remaining copy of the data.
        return (nil, try? preserveCopy(of: backupFile, reason: "unusable-backup"))
    }

    public func load() -> LoadResult {
        lock.lock()
        defer { lock.unlock() }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        guard fileManager.fileExists(atPath: file.path) else {
            let backup = tryBackup()
            writable = true
            if let parsed = backup.parsed {
                return LoadResult(status: .recovered, writable: true, document: parsed.document, preservedCopy: nil, preservedBackup: nil, dropped: parsed.dropped)
            }
            // A backup without a data file is not a first launch: report it instead of seeding samples.
            if let preserved = backup.preserved {
                return LoadResult(status: .unreadable, writable: true, document: .empty(), preservedCopy: preserved, preservedBackup: nil, dropped: 0)
            }
            return LoadResult(status: .new, writable: true, document: nil, preservedCopy: nil, preservedBackup: nil, dropped: 0)
        }

        let parsed: DocumentCodec.Result
        do {
            parsed = try read(file)
        } catch DocumentCodec.Failure.newerVersion {
            writable = false
            return LoadResult(status: .newerVersion, writable: false, document: .empty(), preservedCopy: nil, preservedBackup: nil, dropped: 0)
        } catch ReadFailure.io {
            // I/O failure: the data may be fine, so do not write.
            writable = false
            return LoadResult(status: .readError, writable: false, document: .empty(), preservedCopy: nil, preservedBackup: nil, dropped: 0)
        } catch {
            let preserved = try? preserveCopy(of: file, reason: "unreadable")
            let backup = tryBackup()
            writable = true
            currentFileTrusted = false
            if let parsed = backup.parsed {
                return LoadResult(status: .recovered, writable: true, document: parsed.document, preservedCopy: preserved, preservedBackup: nil, dropped: parsed.dropped)
            }
            return LoadResult(status: .unreadable, writable: true, document: .empty(), preservedCopy: preserved, preservedBackup: backup.preserved, dropped: 0)
        }

        writable = true
        if parsed.repaired {
            let preserved = try? preserveCopy(of: file, reason: "before-repair")
            return LoadResult(status: .repaired, writable: true, document: parsed.document, preservedCopy: preserved, preservedBackup: nil, dropped: parsed.dropped)
        }
        if parsed.migrated {
            let preserved = try? preserveCopy(of: file, reason: "before-migration")
            return LoadResult(status: .migrated, writable: true, document: parsed.document, preservedCopy: preserved, preservedBackup: nil, dropped: 0)
        }
        return LoadResult(status: .loaded, writable: true, document: parsed.document, preservedCopy: nil, preservedBackup: nil, dropped: 0)
    }

    /// Saves the document atomically, rotating the previous file into the backup. `normalized`:
    /// the caller already applied DocumentCodec.normalizedForSave (it is not repeated).
    public func save(_ document: TaskflowDocument, normalized: Bool = false) throws {
        lock.lock()
        defer { lock.unlock() }
        guard writable else { throw WriteError.readOnly }
        let data = (normalized ? document : DocumentCodec.normalizedForSave(document)).fileData(savedAt: now())
        let temp = directory.appendingPathComponent(DocumentCodec.fileName + ".tmp")
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: temp, options: [])
            if currentFileTrusted, fileManager.fileExists(atPath: file.path) {
                try? fileManager.removeItem(at: backupFile)
                try fileManager.copyItem(at: file, to: backupFile)
            }
            if fileManager.fileExists(atPath: file.path) {
                _ = try fileManager.replaceItemAt(file, withItemAt: temp)
            } else {
                try fileManager.moveItem(at: temp, to: file)
            }
            currentFileTrusted = true
        } catch {
            try? fileManager.removeItem(at: temp)
            throw WriteError.writeFailed
        }
    }

    /// Allows writing after the app chose to start fresh (e.g. after an import replaced the data).
    public func markWritable() {
        lock.lock()
        writable = true
        lock.unlock()
    }
}
