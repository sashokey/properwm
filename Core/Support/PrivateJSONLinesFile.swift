import Darwin
import Foundation

final class BoundedDiagnosticQueue: @unchecked Sendable {
    private let queue: DispatchQueue
    private let slots = DispatchSemaphore(value: 256)
    private let key = DispatchSpecificKey<UInt8>()

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .utility)
        queue.setSpecific(key: key, value: 1)
    }

    func submit(_ operation: @escaping @Sendable () -> Void) {
        guard slots.wait(timeout: .now()) == .success else { return }
        queue.async { [self] in
            defer { slots.signal() }
            operation()
        }
    }

    func flush() {
        if DispatchQueue.getSpecific(key: key) == nil { queue.sync {} }
    }
}

struct PrivateJSONLinesFile: Sendable {
    static let maximumRecordBytes = 65_536
    private static let processLock = NSLock()
    let directory: URL
    let name: String
    var maximumFileBytes = 1_048_576
    var archiveCount = 4

    static var liveDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/io.github.sashokey.properwm", isDirectory: true)
    }

    func append(_ data: Data) throws {
        guard data.count <= Self.maximumRecordBytes else { return }
        guard !name.contains("/"), name.hasSuffix(".jsonl") else { throw failure(EINVAL) }
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        let directoryFD = try openDirectory()
        defer { close(directoryFD) }
        var metadata = stat()
        guard fstat(directoryFD, &metadata) == 0, metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFDIR else { throw failure(EPERM) }
        guard fchmod(directoryFD, 0o700) == 0 else { throw failure(errno) }
        let stem = String(name.dropLast(6))
        let lockFD = try openFile(stem + ".lock", in: directoryFD)
        defer { close(lockFD) }
        guard lockf(lockFD, F_LOCK, 0) == 0 else { throw failure(errno) }
        defer { _ = lockf(lockFD, F_ULOCK, 0) }
        var fileFD = try openFile(name, in: directoryFD)
        defer { if fileFD >= 0 { close(fileFD) } }
        let length = try repairTail(fileFD)
        if length > 0, length > off_t(max(1, maximumFileBytes)) - off_t(data.count) {
            close(fileFD)
            fileFD = -1
            try rotate(in: directoryFD, stem: stem)
            fileFD = try openFile(name, in: directoryFD)
        }
        try data.withUnsafeBytes { buffer in
            guard let address = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = write(fileFD, address.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw failure(errno) }
                offset += count
            }
        }
    }

    private func openDirectory() throws -> Int32 {
        var directoryPath = directory.standardizedFileURL.path
        let roots = [FileManager.default.temporaryDirectory, FileManager.default.homeDirectoryForCurrentUser]
            .sorted { $0.path.count > $1.path.count }
        for root in roots {
            let path = root.standardizedFileURL.path
            let prefix = path.hasSuffix("/") ? path : path + "/"
            if directoryPath.hasPrefix(prefix) {
                guard let resolved = realpath(root.path, nil) else { throw failure(errno) }
                defer { free(resolved) }
                directoryPath = String(cString: resolved) + "/" + directoryPath.dropFirst(prefix.count)
                break
            }
        }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure(errno) }
        do {
            for rawComponent in directoryPath.split(separator: "/") {
                let component = String(rawComponent)
                guard component != ".", component != ".." else { throw failure(EINVAL) }
                if mkdirat(fd, component, 0o700) != 0, errno != EEXIST { throw failure(errno) }
                let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw failure(errno) }
                close(fd)
                fd = next
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private func openFile(_ leaf: String, in directoryFD: Int32) throws -> Int32 {
        let fd = openat(directoryFD, leaf, O_CREAT | O_RDWR | O_APPEND | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure(errno) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_nlink == 1, metadata.st_uid == getuid() else {
            close(fd)
            throw failure(EPERM)
        }
        guard fchmod(fd, 0o600) == 0 else {
            let code = errno
            close(fd)
            throw failure(code)
        }
        return fd
    }

    private func repairTail(_ fd: Int32) throws -> off_t {
        let end = lseek(fd, 0, SEEK_END)
        guard end >= 0 else { throw failure(errno) }
        if end > off_t(max(Self.maximumRecordBytes, maximumFileBytes)) {
            guard ftruncate(fd, 0) == 0 else { throw failure(errno) }
            return 0
        }
        let minimumOffset = max(0, end - off_t(Self.maximumRecordBytes))
        var cursor = end
        while cursor > minimumOffset {
            let count = Int(min(cursor - minimumOffset, 4096))
            cursor -= off_t(count)
            var bytes = [UInt8](repeating: 0, count: count)
            var offset = 0
            while offset < count {
                let readCount = bytes.withUnsafeMutableBytes {
                    pread(fd, $0.baseAddress!.advanced(by: offset), count - offset, cursor + off_t(offset))
                }
                if readCount < 0, errno == EINTR { continue }
                guard readCount > 0 else { throw failure(errno) }
                offset += readCount
            }
            if let index = bytes.lastIndex(of: 0x0A) {
                let length = cursor + off_t(index + 1)
                if length != end, ftruncate(fd, length) != 0 { throw failure(errno) }
                return length
            }
        }
        if end > 0, ftruncate(fd, 0) != 0 { throw failure(errno) }
        return 0
    }

    private func rotate(in fd: Int32, stem: String) throws {
        func remove(_ leaf: String) throws {
            if unlinkat(fd, leaf, 0) != 0, errno != ENOENT { throw failure(errno) }
        }
        guard archiveCount > 0 else { try remove(name); return }
        try remove("\(stem).\(archiveCount).jsonl")
        for index in stride(from: archiveCount - 1, through: 0, by: -1) {
            let source = index == 0 ? name : "\(stem).\(index).jsonl"
            if renameat(fd, source, fd, "\(stem).\(index + 1).jsonl") != 0, errno != ENOENT { throw failure(errno) }
        }
    }

    private func failure(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}

enum DiagnosticErrorSummary {
    static func describe(_ error: Error) -> String {
        let value = error as NSError
        if value.domain == NSPOSIXErrorDomain { return "POSIX error \(value.code)" }
        if value.domain == NSCocoaErrorDomain { return "Cocoa error \(value.code)" }
        if error is EncodingError { return "Encoding error" }
        return "Diagnostic operation failed"
    }
}

enum DiagnosticValue: Encodable, Sendable {
    case text(String), number(Double), flag(Bool), list([DiagnosticValue]), null

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value):
            try container.encode(BoundedText.utf8(value))
        case .number(let value):
            if value.isFinite { try container.encode(value) } else { try container.encodeNil() }
        case .flag(let value): try container.encode(value)
        case .list(let values): try container.encode(Array(values.prefix(256)))
        case .null: try container.encodeNil()
        }
    }
}

enum DiagnosticJSON {
    static func line(_ fields: [String: DiagnosticValue]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(fields), data.count < PrivateJSONLinesFile.maximumRecordBytes else { return nil }
        data.append(0x0A)
        return data
    }
}
