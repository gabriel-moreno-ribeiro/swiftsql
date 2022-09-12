import Foundation

/// Size of every page in a table file.
public let pageSize = 4096

public enum DatabaseError: Error, CustomStringConvertible, Equatable {
    case io(String)
    case syntax(String)
    case schema(String)
    case constraint(String)
    case type(String)

    public var description: String {
        switch self {
        case .io(let m): return "io error: \(m)"
        case .syntax(let m): return "syntax error: \(m)"
        case .schema(let m): return "schema error: \(m)"
        case .constraint(let m): return "constraint violation: \(m)"
        case .type(let m): return "type error: \(m)"
        }
    }
}

/// Reads and writes fixed-size pages of a file, caching them in memory.
/// Pages are only written back on `flush()`, which the executor calls at
/// the end of every statement.
public final class Pager {
    private let handle: FileHandle
    private var cache: [Int: Data] = [:]
    private var dirty: Set<Int> = []
    public private(set) var pageCount: Int

    public init(path: String) throws {
        if !FileManager.default.fileExists(atPath: path) {
            guard FileManager.default.createFile(atPath: path, contents: nil) else {
                throw DatabaseError.io("cannot create \(path)")
            }
        }
        guard let h = FileHandle(forUpdatingAtPath: path) else { throw DatabaseError.io("cannot open \(path)") }
        handle = h
        let length = Int(h.seekToEndOfFile())
        if length % pageSize != 0 { throw DatabaseError.io("\(path) is corrupt: not a whole number of pages") }
        pageCount = length / pageSize
    }

    deinit { try? handle.close() }

    public func page(_ number: Int) throws -> Data {
        if let p = cache[number] { return p }
        if number >= pageCount { throw DatabaseError.io("page \(number) out of range") }
        handle.seek(toFileOffset: UInt64(number * pageSize))
        var data = handle.readData(ofLength: pageSize)
        if data.count < pageSize { data.append(Data(count: pageSize - data.count)) }
        cache[number] = data
        return data
    }

    public func write(_ number: Int, _ data: Data) {
        precondition(data.count == pageSize)
        cache[number] = data
        dirty.insert(number)
    }

    /// Appends a blank page and returns its number.
    public func allocate() -> Int {
        let number = pageCount
        pageCount += 1
        cache[number] = Data(count: pageSize)
        dirty.insert(number)
        return number
    }

    public func flush() throws {
        for number in dirty.sorted() {
            guard let data = cache[number] else { continue }
            handle.seek(toFileOffset: UInt64(number * pageSize))
            handle.write(data)
        }
        dirty.removeAll()
        handle.synchronizeFile()
    }
}

// MARK: - little helpers for reading/writing integers inside pages

extension Data {
    func readUInt32(at offset: Int) -> UInt32 {
        var v: UInt32 = 0
        _ = Swift.withUnsafeMutableBytes(of: &v) { copyBytes(to: $0, from: (startIndex + offset)..<(startIndex + offset + 4)) }
        return UInt32(littleEndian: v)
    }

    mutating func writeUInt32(_ value: UInt32, at offset: Int) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { replaceSubrange((startIndex + offset)..<(startIndex + offset + 4), with: $0) }
    }

    func readInt64(at offset: Int) -> Int64 {
        var v: Int64 = 0
        _ = Swift.withUnsafeMutableBytes(of: &v) { copyBytes(to: $0, from: (startIndex + offset)..<(startIndex + offset + 8)) }
        return Int64(littleEndian: v)
    }

    mutating func writeInt64(_ value: Int64, at offset: Int) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { replaceSubrange((startIndex + offset)..<(startIndex + offset + 8), with: $0) }
    }

    func slice(_ offset: Int, _ length: Int) -> Data {
        return Data(self[(startIndex + offset)..<(startIndex + offset + length)])
    }

    mutating func replace(at offset: Int, with bytes: Data) {
        replaceSubrange((startIndex + offset)..<(startIndex + offset + bytes.count), with: bytes)
    }
}
