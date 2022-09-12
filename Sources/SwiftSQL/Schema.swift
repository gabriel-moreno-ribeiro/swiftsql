import Foundation

/// Column types. Rows are fixed-size so a table's row layout is decided
/// entirely by its schema: INT is 8 bytes, TEXT(n) is 2 length bytes + n.
public enum ColumnType: Codable, Equatable, CustomStringConvertible {
    case int
    case text(Int)

    public var byteSize: Int {
        switch self {
        case .int: return 8
        case .text(let n): return 2 + n
        }
    }

    public var description: String {
        switch self {
        case .int: return "INT"
        case .text(let n): return "TEXT(\(n))"
        }
    }
}

public struct Column: Codable, Equatable {
    public let name: String
    public let type: ColumnType
    public let primaryKey: Bool
}

public struct TableSchema: Codable, Equatable {
    public let name: String
    public let columns: [Column]

    public var rowSize: Int { columns.reduce(0) { $0 + $1.type.byteSize } }
    public var keyIndex: Int { columns.firstIndex(where: { $0.primaryKey }) ?? 0 }

    public func index(of column: String) -> Int? {
        columns.firstIndex { $0.name.lowercased() == column.lowercased() }
    }
}

/// A single cell value.
public enum Value: Equatable, Hashable, CustomStringConvertible {
    case int(Int64)
    case text(String)
    case null

    public var description: String {
        switch self {
        case .int(let i): return String(i)
        case .text(let s): return s
        case .null: return "NULL"
        }
    }

    /// Ordering used by ORDER BY and comparisons: NULL < numbers < text.
    static func compare(_ a: Value, _ b: Value) -> Int {
        switch (a, b) {
        case (.null, .null): return 0
        case (.null, _): return -1
        case (_, .null): return 1
        case (.int(let x), .int(let y)): return x < y ? -1 : (x == y ? 0 : 1)
        case (.text(let x), .text(let y)): return x < y ? -1 : (x == y ? 0 : 1)
        case (.int, .text): return -1
        case (.text, .int): return 1
        }
    }
}

public typealias Row = [Value]

/// Serialises rows to the fixed-size byte layout described by a schema.
public enum RowCodec {
    public static func encode(_ row: Row, schema: TableSchema) throws -> Data {
        guard row.count == schema.columns.count else {
            throw DatabaseError.constraint("expected \(schema.columns.count) values, got \(row.count)")
        }
        var data = Data(count: schema.rowSize)
        var offset = 0
        for (value, column) in zip(row, schema.columns) {
            switch (column.type, value) {
            case (.int, .int(let i)):
                data.writeInt64(i, at: offset)
            case (.text(let n), .text(let s)):
                let bytes = Data(s.utf8)
                guard bytes.count <= n else { throw DatabaseError.constraint("value too long for \(column.name) (max \(n) bytes)") }
                data[offset] = UInt8(bytes.count & 0xFF)
                data[offset + 1] = UInt8(bytes.count >> 8)
                data.replace(at: offset + 2, with: bytes)
            case (_, .null):
                throw DatabaseError.constraint("column \(column.name) cannot be NULL")
            default:
                throw DatabaseError.type("column \(column.name) is \(column.type), got \(value)")
            }
            offset += column.type.byteSize
        }
        return data
    }

    public static func decode(_ data: Data, schema: TableSchema) -> Row {
        var row: Row = []
        var offset = 0
        for column in schema.columns {
            switch column.type {
            case .int:
                row.append(.int(data.readInt64(at: offset)))
            case .text:
                let length = Int(data[data.startIndex + offset]) | (Int(data[data.startIndex + offset + 1]) << 8)
                row.append(.text(String(decoding: data.slice(offset + 2, length), as: UTF8.self)))
            }
            offset += column.type.byteSize
        }
        return row
    }
}
