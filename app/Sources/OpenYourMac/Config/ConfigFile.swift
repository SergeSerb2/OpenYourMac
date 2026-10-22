import Foundation
import Darwin

/// Stages private bytes, then checks both identity and contents under file coordination.
/// Atomic exchange retains the replaced inode. If an uncoordinated editor wrote to it
/// after the final check, those late writes stay recoverable in a dated backup beside
/// the config. Otherwise the replaced file is removed unless the caller keeps a backup.
enum ConfigFile {
    struct Version: Equatable {
        let target: URL
        let data: Data
        let inode: UInt64
        let device: UInt64
        let mode: mode_t
        let modified: Date?

        static func read(_ url: URL) throws -> Version? {
            let target = url.resolvingSymlinksInPath()
            do {
                let before = try FileManager.default.attributesOfItem(atPath: target.path)
                let data = try Data(contentsOf: target)
                let after = try FileManager.default.attributesOfItem(atPath: target.path)
                for key in [FileAttributeKey.systemFileNumber, .systemNumber, .modificationDate, .size, .posixPermissions] {
                    guard (before[key] as? NSObject) == (after[key] as? NSObject) else { throw Changed() }
                }
                guard after[.type] as? FileAttributeType == .typeRegular else {
                    throw ConfigError(message: "The config must be a regular file.", line: nil)
                }
                return Version(target: target, data: data,
                               inode: (after[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                               device: (after[.systemNumber] as? NSNumber)?.uint64Value ?? 0,
                               mode: mode_t((after[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o600),
                               modified: after[.modificationDate] as? Date)
            } catch CocoaError.fileReadNoSuchFile { return nil }
        }
    }

    struct Changed: Error {}
    struct RecoveryError: LocalizedError {
        let path: String
        var errorDescription: String? { "The config was saved, but its previous file remains at \(path). Could not name the backup." }
    }

    static func stage(_ data: Data, beside target: URL) throws -> URL {
        let temp = target.deletingLastPathComponent().appendingPathComponent(".oym-\(UUID().uuidString).tmp")
        let fd = Darwin.open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw posixError() }
        do {
            defer { Darwin.close(fd) }
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw posixError() }
                    offset += count
                }
            }
            guard Darwin.fsync(fd) == 0 else { throw posixError() }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        return temp
    }

    /// The caller owns `staged` until success. Success consumes it and returns the
    /// backup file, if one was kept.
    static func commit(_ staged: URL, to url: URL, expected: Version?, keepBackup: Bool = false) throws -> URL? {
        var coordinationError: NSError?
        var result: Result<URL?, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinated in
            result = Result {
                let target = coordinated.resolvingSymlinksInPath()
                let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
                let backup = target.appendingPathExtension("backup-\(timestamp)-\(UUID().uuidString)")
                let mode = expected?.mode ?? 0o600
                guard Darwin.chmod(staged.path, mode) == 0 else { throw posixError() }
                // Stage and set permissions first; this is the final check before publication.
                guard try Version.read(url) == expected,
                      expected == nil || target == expected?.target else { throw Changed() }
                if expected != nil {
                    // Exchange publishes the candidate and keeps the actual displaced file.
                    guard renamex_np(staged.path, target.path, UInt32(RENAME_SWAP)) == 0 else { throw posixError() }
                    if !keepBackup, let expected, (try? Data(contentsOf: staged)) == expected.data {
                        // Nobody wrote to the old file after the final check: nothing to recover.
                        try? FileManager.default.removeItem(at: staged)
                        return nil
                    }
                    if Darwin.rename(staged.path, backup.path) != 0 {
                        // Never remove the displaced contents, even if naming the backup fails.
                        throw RecoveryError(path: staged.path)
                    }
                    _ = Darwin.chmod(backup.path, 0o600)
                    return backup
                }
                // Exclusive rename also protects first creation from a concurrent creator.
                guard renamex_np(staged.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
                    if errno == EEXIST { throw Changed() }
                    throw posixError()
                }
                return nil
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ConfigError(message: "Could not coordinate the config save.", line: nil) }
        return try result.get()
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
