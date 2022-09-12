import Foundation

// MARK: - Lexer

public enum Token: Equatable {
    case keyword(String)     // upper-cased
    case identifier(String)
    case number(Int64)
    case string(String)
    case symbol(String)      // ( ) , * = < > <= >= != ;
    case end
}

private let keywords: Set<String> = [
    "CREATE", "TABLE", "DROP", "INSERT", "INTO", "VALUES", "SELECT", "FROM", "WHERE", "AND", "OR",
    "ORDER", "BY", "ASC", "DESC", "LIMIT", "DELETE", "UPDATE", "SET", "INT", "INTEGER", "TEXT",
    "PRIMARY", "KEY", "NOT", "COUNT", "NULL",
]

public struct Lexer {
    public static func tokenize(_ sql: String) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(sql)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isLetter || c == "_" {
                var word = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" { word.append(chars[i]); i += 1 }
                let upper = word.uppercased()
                tokens.append(keywords.contains(upper) ? .keyword(upper) : .identifier(word))
                continue
            }
            if c.isNumber || (c == "-" && i + 1 < chars.count && chars[i + 1].isNumber) {
                var text = String(c)
                i += 1
                while i < chars.count, chars[i].isNumber { text.append(chars[i]); i += 1 }
                guard let n = Int64(text) else { throw DatabaseError.syntax("bad number \(text)") }
                tokens.append(.number(n))
                continue
            }
            if c == "'" {
                var text = ""
                i += 1
                var closed = false
                while i < chars.count {
                    if chars[i] == "'" {
                        if i + 1 < chars.count, chars[i + 1] == "'" { text.append("'"); i += 2; continue }
                        closed = true
                        i += 1
                        break
                    }
                    text.append(chars[i])
                    i += 1
                }
                guard closed else { throw DatabaseError.syntax("unterminated string") }
                tokens.append(.string(text))
                continue
            }
            let two = i + 1 < chars.count ? String(chars[i...i + 1]) : ""
            if ["<=", ">=", "!=", "<>"].contains(two) {
                tokens.append(.symbol(two == "<>" ? "!=" : two))
                i += 2
                continue
            }
            if "(),*=<>;".contains(c) {
                tokens.append(.symbol(String(c)))
                i += 1
                continue
            }
            throw DatabaseError.syntax("unexpected character '\(c)'")
        }
        tokens.append(.end)
        return tokens
    }
}

// MARK: - AST

public indirect enum Expr: Equatable {
    case column(String)
    case literal(Value)
    case binary(op: String, Expr, Expr)   // = != < > <= >= AND OR
}

public enum Statement: Equatable {
    case createTable(TableSchema)
    case dropTable(String)
    case insert(table: String, columns: [String]?, values: [Row])
    case select(columns: [String], table: String, filter: Expr?, orderBy: (String, Bool)?, limit: Int?)
    case update(table: String, assignments: [(String, Expr)], filter: Expr?)
    case delete(table: String, filter: Expr?)

    public static func == (a: Statement, b: Statement) -> Bool {
        switch (a, b) {
        case (.createTable(let x), .createTable(let y)): return x == y
        case (.dropTable(let x), .dropTable(let y)): return x == y
        case (.insert(let t1, let c1, let v1), .insert(let t2, let c2, let v2)): return t1 == t2 && c1 == c2 && v1 == v2
        case (.select(let c1, let t1, let f1, let o1, let l1), .select(let c2, let t2, let f2, let o2, let l2)):
            return c1 == c2 && t1 == t2 && f1 == f2 && o1?.0 == o2?.0 && o1?.1 == o2?.1 && l1 == l2
        case (.update(let t1, let a1, let f1), .update(let t2, let a2, let f2)):
            return t1 == t2 && f1 == f2 && a1.map { $0.0 } == a2.map { $0.0 } && a1.map { $0.1 } == a2.map { $0.1 }
        case (.delete(let t1, let f1), .delete(let t2, let f2)): return t1 == t2 && f1 == f2
        default: return false
        }
    }
}

// MARK: - Parser (recursive descent)

public struct Parser {
    private var tokens: [Token]
    private var pos = 0

    public static func parse(_ sql: String) throws -> Statement {
        var parser = Parser(tokens: try Lexer.tokenize(sql))
        let statement = try parser.statement()
        if parser.peek == .symbol(";") { parser.pos += 1 }
        guard parser.peek == .end else { throw DatabaseError.syntax("unexpected \(parser.describe(parser.peek)) after statement") }
        return statement
    }

    private init(tokens: [Token]) { self.tokens = tokens }

    private var peek: Token { tokens[pos] }

    private mutating func next() -> Token { let t = tokens[pos]; if t != .end { pos += 1 }; return t }

    private func describe(_ t: Token) -> String {
        switch t {
        case .keyword(let k): return k
        case .identifier(let i): return "'\(i)'"
        case .number(let n): return String(n)
        case .string(let s): return "'\(s)'"
        case .symbol(let s): return "'\(s)'"
        case .end: return "end of input"
        }
    }

    private mutating func expectKeyword(_ k: String) throws {
        guard next() == .keyword(k) else { throw DatabaseError.syntax("expected \(k)") }
    }

    private mutating func expectSymbol(_ s: String) throws {
        guard next() == .symbol(s) else { throw DatabaseError.syntax("expected '\(s)'") }
    }

    private mutating func accept(_ t: Token) -> Bool {
        if peek == t { pos += 1; return true }
        return false
    }

    private mutating func identifier() throws -> String {
        if case .identifier(let name) = next() { return name }
        pos -= 1
        throw DatabaseError.syntax("expected a name, got \(describe(peek))")
    }

    private mutating func statement() throws -> Statement {
        switch next() {
        case .keyword("CREATE"): return try createTable()
        case .keyword("DROP"): try expectKeyword("TABLE"); return .dropTable(try identifier())
        case .keyword("INSERT"): return try insert()
        case .keyword("SELECT"): return try select()
        case .keyword("UPDATE"): return try update()
        case .keyword("DELETE"): return try delete()
        case let t: throw DatabaseError.syntax("unknown statement starting with \(describe(t))")
        }
    }

    private mutating func createTable() throws -> Statement {
        try expectKeyword("TABLE")
        let name = try identifier()
        try expectSymbol("(")
        var columns: [Column] = []
        repeat {
            let colName = try identifier()
            let type: ColumnType
            switch next() {
            case .keyword("INT"), .keyword("INTEGER"): type = .int
            case .keyword("TEXT"):
                if accept(.symbol("(")) {
                    guard case .number(let n) = next(), n > 0, n <= 4000 else { throw DatabaseError.syntax("bad TEXT length") }
                    try expectSymbol(")")
                    type = .text(Int(n))
                } else {
                    type = .text(255)
                }
            case let t: throw DatabaseError.syntax("unknown type \(describe(t))")
            }
            var primary = false
            if accept(.keyword("PRIMARY")) {
                try expectKeyword("KEY")
                primary = true
            }
            columns.append(Column(name: colName, type: type, primaryKey: primary))
        } while accept(.symbol(","))
        try expectSymbol(")")
        let schema = TableSchema(name: name, columns: columns)
        let keys = columns.filter { $0.primaryKey }
        if keys.count > 1 { throw DatabaseError.schema("only one PRIMARY KEY is supported") }
        if let key = keys.first, key.type != .int { throw DatabaseError.schema("PRIMARY KEY must be an INT column") }
        if keys.isEmpty, columns.first?.type != .int { throw DatabaseError.schema("first column must be INT when there is no PRIMARY KEY") }
        if Set(columns.map { $0.name.lowercased() }).count != columns.count { throw DatabaseError.schema("duplicate column name") }
        return .createTable(schema)
    }

    private mutating func insert() throws -> Statement {
        try expectKeyword("INTO")
        let table = try identifier()
        var columns: [String]? = nil
        if accept(.symbol("(")) {
            var names: [String] = []
            repeat { names.append(try identifier()) } while accept(.symbol(","))
            try expectSymbol(")")
            columns = names
        }
        try expectKeyword("VALUES")
        var rows: [Row] = []
        repeat {
            try expectSymbol("(")
            var row: Row = []
            repeat {
                switch next() {
                case .number(let n): row.append(.int(n))
                case .string(let s): row.append(.text(s))
                case .keyword("NULL"): row.append(.null)
                case let t: throw DatabaseError.syntax("expected a value, got \(describe(t))")
                }
            } while accept(.symbol(","))
            try expectSymbol(")")
            rows.append(row)
        } while accept(.symbol(","))
        return .insert(table: table, columns: columns, values: rows)
    }

    private mutating func select() throws -> Statement {
        var columns: [String] = []
        if accept(.symbol("*")) {
            columns = ["*"]
        } else if accept(.keyword("COUNT")) {
            try expectSymbol("(")
            try expectSymbol("*")
            try expectSymbol(")")
            columns = ["COUNT(*)"]
        } else {
            repeat { columns.append(try identifier()) } while accept(.symbol(","))
        }
        try expectKeyword("FROM")
        let table = try identifier()
        let filter: Expr? = try accept(.keyword("WHERE")) ? expression() : nil
        var order: (String, Bool)? = nil
        if accept(.keyword("ORDER")) {
            try expectKeyword("BY")
            let column = try identifier()
            var ascending = true
            if accept(.keyword("DESC")) { ascending = false } else { _ = accept(.keyword("ASC")) }
            order = (column, ascending)
        }
        var limit: Int? = nil
        if accept(.keyword("LIMIT")) {
            guard case .number(let n) = next(), n >= 0 else { throw DatabaseError.syntax("LIMIT needs a number") }
            limit = Int(n)
        }
        return .select(columns: columns, table: table, filter: filter, orderBy: order, limit: limit)
    }

    private mutating func update() throws -> Statement {
        let table = try identifier()
        try expectKeyword("SET")
        var assignments: [(String, Expr)] = []
        repeat {
            let column = try identifier()
            try expectSymbol("=")
            assignments.append((column, try expression()))
        } while accept(.symbol(","))
        let filter: Expr? = try accept(.keyword("WHERE")) ? expression() : nil
        return .update(table: table, assignments: assignments, filter: filter)
    }

    private mutating func delete() throws -> Statement {
        try expectKeyword("FROM")
        let table = try identifier()
        let filter: Expr? = try accept(.keyword("WHERE")) ? expression() : nil
        return .delete(table: table, filter: filter)
    }

    // expression := and ("OR" and)*
    private mutating func expression() throws -> Expr {
        var left = try andExpr()
        while accept(.keyword("OR")) { left = .binary(op: "OR", left, try andExpr()) }
        return left
    }

    private mutating func andExpr() throws -> Expr {
        var left = try comparison()
        while accept(.keyword("AND")) { left = .binary(op: "AND", left, try comparison()) }
        return left
    }

    private mutating func comparison() throws -> Expr {
        let left = try primary()
        if case .symbol(let s) = peek, ["=", "!=", "<", ">", "<=", ">="].contains(s) {
            pos += 1
            return .binary(op: s, left, try primary())
        }
        return left
    }

    private mutating func primary() throws -> Expr {
        switch next() {
        case .number(let n): return .literal(.int(n))
        case .string(let s): return .literal(.text(s))
        case .keyword("NULL"): return .literal(.null)
        case .identifier(let name): return .column(name)
        case .symbol("("):
            let e = try expression()
            try expectSymbol(")")
            return e
        case let t: throw DatabaseError.syntax("unexpected \(describe(t)) in expression")
        }
    }
}
