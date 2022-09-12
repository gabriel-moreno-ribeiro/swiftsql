import Foundation

/// Result of executing a statement.
public struct QueryResult: Equatable {
    public var columns: [String]
    public var rows: [Row]
    public var affected: Int
    public var message: String?

    public static func info(_ text: String, affected: Int = 0) -> QueryResult {
        QueryResult(columns: [], rows: [], affected: affected, message: text)
    }
}

/// A database is a directory: `schema.json` plus one B+tree file per table.
public final class Database {
    public let directory: String
    private var schemas: [String: TableSchema] = [:]   // lower-cased name -> schema
    private var trees: [String: BTree] = [:]

    public init(directory: String) throws {
        self.directory = directory
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let schemaPath = (directory as NSString).appendingPathComponent("schema.json")
        if let data = FileManager.default.contents(atPath: schemaPath) {
            let list = try JSONDecoder().decode([TableSchema].self, from: data)
            for s in list { schemas[s.name.lowercased()] = s }
        }
    }

    public var tables: [TableSchema] { schemas.values.sorted { $0.name < $1.name } }

    private func saveSchemas() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(tables)
        let path = (directory as NSString).appendingPathComponent("schema.json")
        guard FileManager.default.createFile(atPath: path, contents: data) else { throw DatabaseError.io("cannot write schema.json") }
    }

    private func schema(_ name: String) throws -> TableSchema {
        guard let s = schemas[name.lowercased()] else { throw DatabaseError.schema("no such table: \(name)") }
        return s
    }

    private func tree(for schema: TableSchema) throws -> BTree {
        let key = schema.name.lowercased()
        if let t = trees[key] { return t }
        let path = (directory as NSString).appendingPathComponent("\(key).tbl")
        let t = try BTree(pager: try Pager(path: path), rowSize: schema.rowSize)
        trees[key] = t
        return t
    }

    // MARK: - execution

    @discardableResult
    public func execute(_ sql: String) throws -> QueryResult {
        let statement = try Parser.parse(sql)
        let result = try execute(statement)
        for t in trees.values { try t.pager.flush() }
        return result
    }

    public func execute(_ statement: Statement) throws -> QueryResult {
        switch statement {
        case .createTable(let schema):
            if schemas[schema.name.lowercased()] != nil { throw DatabaseError.schema("table \(schema.name) already exists") }
            _ = try BTree(pager: try Pager(path: (directory as NSString).appendingPathComponent("\(schema.name.lowercased()).tbl")), rowSize: schema.rowSize)
            schemas[schema.name.lowercased()] = schema
            try saveSchemas()
            return .info("table \(schema.name) created")

        case .dropTable(let name):
            let s = try schema(name)
            trees[s.name.lowercased()] = nil
            schemas[s.name.lowercased()] = nil
            try? FileManager.default.removeItem(atPath: (directory as NSString).appendingPathComponent("\(s.name.lowercased()).tbl"))
            try saveSchemas()
            return .info("table \(s.name) dropped")

        case .insert(let table, let columns, let values):
            let s = try schema(table)
            let t = try tree(for: s)
            var count = 0
            for provided in values {
                let row = try arrange(provided, columns: columns, schema: s)
                let key = try keyOf(row, schema: s)
                try t.insert(key: key, row: try RowCodec.encode(row, schema: s))
                count += 1
            }
            return .info("\(count) row\(count == 1 ? "" : "s") inserted", affected: count)

        case .select(let columns, let table, let filter, let orderBy, let limit):
            let s = try schema(table)
            let t = try tree(for: s)
            var rows: [Row] = []
            try t.scan { _, data in
                let row = RowCodec.decode(data, schema: s)
                if try filter.map({ try Evaluator.isTrue($0, row: row, schema: s) }) ?? true { rows.append(row) }
                return true
            }
            if let order = orderBy {
                let (column, ascending) = order
                guard let idx = s.index(of: column) else { throw DatabaseError.schema("no such column: \(column)") }
                rows.sort { ascending ? Value.compare($0[idx], $1[idx]) < 0 : Value.compare($0[idx], $1[idx]) > 0 }
            }
            if let limit = limit { rows = Array(rows.prefix(limit)) }
            if columns == ["COUNT(*)"] {
                return QueryResult(columns: ["COUNT(*)"], rows: [[.int(Int64(rows.count))]], affected: 0, message: nil)
            }
            let names = columns == ["*"] ? s.columns.map { $0.name } : columns
            let indexes = try names.map { name -> Int in
                guard let i = s.index(of: name) else { throw DatabaseError.schema("no such column: \(name)") }
                return i
            }
            let projected = rows.map { row in indexes.map { row[$0] } }
            return QueryResult(columns: indexes.map { s.columns[$0].name }, rows: projected, affected: 0, message: nil)

        case .update(let table, let assignments, let filter):
            let s = try schema(table)
            let t = try tree(for: s)
            var targets: [(Int64, Row)] = []
            try t.scan { key, data in
                let row = RowCodec.decode(data, schema: s)
                if try filter.map({ try Evaluator.isTrue($0, row: row, schema: s) }) ?? true { targets.append((key, row)) }
                return true
            }
            var count = 0
            for (key, row) in targets {
                var updated = row
                for (column, expr) in assignments {
                    guard let idx = s.index(of: column) else { throw DatabaseError.schema("no such column: \(column)") }
                    updated[idx] = try Evaluator.evaluate(expr, row: row, schema: s)
                }
                let newKey = try keyOf(updated, schema: s)
                let encoded = try RowCodec.encode(updated, schema: s)
                if newKey == key {
                    _ = try t.update(key: key, row: encoded)
                } else {
                    try t.insert(key: newKey, row: encoded)
                    _ = try t.delete(key: key)
                }
                count += 1
            }
            return .info("\(count) row\(count == 1 ? "" : "s") updated", affected: count)

        case .delete(let table, let filter):
            let s = try schema(table)
            let t = try tree(for: s)
            var keys: [Int64] = []
            try t.scan { key, data in
                if try filter.map({ try Evaluator.isTrue($0, row: RowCodec.decode(data, schema: s), schema: s) }) ?? true { keys.append(key) }
                return true
            }
            for key in keys { _ = try t.delete(key: key) }
            return .info("\(keys.count) row\(keys.count == 1 ? "" : "s") deleted", affected: keys.count)
        }
    }

    /// Reorders values given with an explicit column list into schema order.
    private func arrange(_ values: Row, columns: [String]?, schema: TableSchema) throws -> Row {
        guard let columns = columns else {
            guard values.count == schema.columns.count else {
                throw DatabaseError.constraint("table \(schema.name) has \(schema.columns.count) columns but \(values.count) values were supplied")
            }
            return values
        }
        guard columns.count == values.count else { throw DatabaseError.constraint("column count does not match value count") }
        var row: Row = Array(repeating: .null, count: schema.columns.count)
        for (name, value) in zip(columns, values) {
            guard let idx = schema.index(of: name) else { throw DatabaseError.schema("no such column: \(name)") }
            row[idx] = value
        }
        return row
    }

    private func keyOf(_ row: Row, schema: TableSchema) throws -> Int64 {
        guard case .int(let key) = row[schema.keyIndex] else {
            throw DatabaseError.constraint("primary key \(schema.columns[schema.keyIndex].name) must be an integer")
        }
        return key
    }

    /// Row count and tree height, for the .stats meta command and tests.
    public func stats(_ table: String) throws -> (rows: Int, height: Int, pages: Int) {
        let s = try schema(table)
        let t = try tree(for: s)
        return (try t.count(), try t.height(), t.pager.pageCount)
    }
}

/// Evaluates WHERE clauses and SET expressions against a row.
public enum Evaluator {
    public static func evaluate(_ expr: Expr, row: Row, schema: TableSchema) throws -> Value {
        switch expr {
        case .literal(let v): return v
        case .column(let name):
            guard let idx = schema.index(of: name) else { throw DatabaseError.schema("no such column: \(name)") }
            return row[idx]
        case .binary(let op, let l, let r):
            let a = try evaluate(l, row: row, schema: schema)
            let b = try evaluate(r, row: row, schema: schema)
            switch op {
            case "AND": return .int((truthy(a) && truthy(b)) ? 1 : 0)
            case "OR": return .int((truthy(a) || truthy(b)) ? 1 : 0)
            case "=": return .int(a == b ? 1 : 0)
            case "!=": return .int(a != b ? 1 : 0)
            case "<": return .int(Value.compare(a, b) < 0 ? 1 : 0)
            case ">": return .int(Value.compare(a, b) > 0 ? 1 : 0)
            case "<=": return .int(Value.compare(a, b) <= 0 ? 1 : 0)
            case ">=": return .int(Value.compare(a, b) >= 0 ? 1 : 0)
            default: throw DatabaseError.syntax("unknown operator \(op)")
            }
        }
    }

    public static func isTrue(_ expr: Expr, row: Row, schema: TableSchema) throws -> Bool {
        truthy(try evaluate(expr, row: row, schema: schema))
    }

    private static func truthy(_ v: Value) -> Bool {
        switch v {
        case .int(let i): return i != 0
        case .text(let s): return !s.isEmpty
        case .null: return false
        }
    }
}
