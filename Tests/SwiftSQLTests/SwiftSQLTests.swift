import XCTest
@testable import SwiftSQL

final class TempDir {
    let path: String
    init() {
        path = NSTemporaryDirectory() + "swiftsql-" + UUID().uuidString
    }
    deinit { try? FileManager.default.removeItem(atPath: path) }
}

final class BTreeTests: XCTestCase {
    private func makeTree(rowSize: Int = 64) throws -> (BTree, TempDir) {
        let dir = TempDir()
        try FileManager.default.createDirectory(atPath: dir.path, withIntermediateDirectories: true)
        let tree = try BTree(pager: try Pager(path: dir.path + "/t.tbl"), rowSize: rowSize)
        return (tree, dir)
    }

    private func row(_ i: Int64, size: Int = 64) -> Data {
        var d = Data(count: size)
        d.writeInt64(i * 7, at: 0)
        return d
    }

    func testInsertAndGet() throws {
        let (tree, _) = try makeTree()
        try tree.insert(key: 5, row: row(5))
        try tree.insert(key: 1, row: row(1))
        try tree.insert(key: 9, row: row(9))
        XCTAssertEqual(try tree.get(5)?.readInt64(at: 0), 35)
        XCTAssertNil(try tree.get(4))
        XCTAssertEqual(try tree.count(), 3)
        XCTAssertThrowsError(try tree.insert(key: 5, row: row(5)))
        var keys: [Int64] = []
        try tree.scan { k, _ in keys.append(k); return true }
        XCTAssertEqual(keys, [1, 5, 9])
    }

    func testSplitsKeepOrderAndGrowHeight() throws {
        let (tree, _) = try makeTree(rowSize: 500)   // ~8 rows per leaf so splits happen early
        var inserted: [Int64] = []
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<600 {
            var k = Int64.random(in: 0..<100_000, using: &rng)
            while inserted.contains(k) { k = Int64.random(in: 0..<100_000, using: &rng) }
            inserted.append(k)
            try tree.insert(key: k, row: row(k, size: 500))
        }
        var scanned: [Int64] = []
        try tree.scan { k, data in
            XCTAssertEqual(data.readInt64(at: 0), k * 7, "row payload stays with its key")
            scanned.append(k)
            return true
        }
        XCTAssertEqual(scanned, inserted.sorted())
        XCTAssertGreaterThanOrEqual(try tree.height(), 2, "600 rows of 500 bytes do not fit in one leaf")
        XCTAssertGreaterThan(tree.pager.pageCount, 75, "at most 8 rows per leaf")
        for k in inserted { XCTAssertEqual(try tree.get(k)?.readInt64(at: 0), k * 7) }
    }

    func testSequentialInsertsThenDeleteAndUpdate() throws {
        let (tree, _) = try makeTree(rowSize: 200)
        for k in 1...2000 { try tree.insert(key: Int64(k), row: row(Int64(k), size: 200)) }
        XCTAssertEqual(try tree.count(), 2000)
        XCTAssertTrue(try tree.delete(key: 1000))
        XCTAssertFalse(try tree.delete(key: 1000))
        XCTAssertNil(try tree.get(1000))
        XCTAssertEqual(try tree.count(), 1999)
        var updated = row(1, size: 200)
        updated.writeInt64(-1, at: 0)
        XCTAssertTrue(try tree.update(key: 1, row: updated))
        XCTAssertEqual(try tree.get(1)?.readInt64(at: 0), -1)
        XCTAssertFalse(try tree.update(key: 99999, row: updated))
        // delete everything, the tree must still be scannable and insertable
        for k in 1...2000 where k != 1000 { XCTAssertTrue(try tree.delete(key: Int64(k))) }
        XCTAssertEqual(try tree.count(), 0)
        try tree.insert(key: 42, row: row(42, size: 200))
        XCTAssertEqual(try tree.count(), 1)
    }

    func testPersistenceAcrossReopen() throws {
        let dir = TempDir()
        try FileManager.default.createDirectory(atPath: dir.path, withIntermediateDirectories: true)
        let path = dir.path + "/p.tbl"
        do {
            let tree = try BTree(pager: try Pager(path: path), rowSize: 300)
            for k in 1...300 { try tree.insert(key: Int64(k), row: row(Int64(k), size: 300)) }
            try tree.pager.flush()
        }
        let reopened = try BTree(pager: try Pager(path: path), rowSize: 300)
        XCTAssertEqual(try reopened.count(), 300)
        XCTAssertEqual(try reopened.get(150)?.readInt64(at: 0), 150 * 7)
        XCTAssertGreaterThan(reopened.pager.pageCount, 10)
    }
}

final class ParserTests: XCTestCase {
    func testLexer() throws {
        let tokens = try Lexer.tokenize("SELECT name, age FROM users WHERE age >= 18 AND name != 'O''Brien';")
        XCTAssertEqual(tokens[0], .keyword("SELECT"))
        XCTAssertEqual(tokens[1], .identifier("name"))
        XCTAssertEqual(tokens[8], .symbol(">="))
        XCTAssertEqual(tokens[9], .number(18))
        XCTAssertEqual(tokens[13], .string("O'Brien"))
        XCTAssertEqual(tokens[14], .symbol(";"))
        XCTAssertThrowsError(try Lexer.tokenize("SELECT 'unterminated"))
        XCTAssertThrowsError(try Lexer.tokenize("SELECT #"))
    }

    func testStatements() throws {
        let create = try Parser.parse("CREATE TABLE users (id INT PRIMARY KEY, name TEXT(32), age INT)")
        XCTAssertEqual(create, .createTable(TableSchema(name: "users", columns: [
            Column(name: "id", type: .int, primaryKey: true),
            Column(name: "name", type: .text(32), primaryKey: false),
            Column(name: "age", type: .int, primaryKey: false),
        ])))
        XCTAssertEqual(try Parser.parse("INSERT INTO users VALUES (1, 'ana', 30), (2, 'bo', 25)"),
                       .insert(table: "users", columns: nil, values: [[.int(1), .text("ana"), .int(30)], [.int(2), .text("bo"), .int(25)]]))
        XCTAssertEqual(try Parser.parse("insert into users (name, id) values ('x', 3)"),
                       .insert(table: "users", columns: ["name", "id"], values: [[.text("x"), .int(3)]]))
        XCTAssertEqual(try Parser.parse("SELECT * FROM users WHERE age > 20 AND (name = 'ana' OR id = 2) ORDER BY age DESC LIMIT 5;"),
                       .select(columns: ["*"], table: "users",
                               filter: .binary(op: "AND", .binary(op: ">", .column("age"), .literal(.int(20))),
                                               .binary(op: "OR", .binary(op: "=", .column("name"), .literal(.text("ana"))),
                                                       .binary(op: "=", .column("id"), .literal(.int(2))))),
                               orderBy: ("age", false), limit: 5))
        XCTAssertEqual(try Parser.parse("UPDATE users SET age = 31, name = 'ana b' WHERE id = 1"),
                       .update(table: "users", assignments: [("age", .literal(.int(31))), ("name", .literal(.text("ana b")))],
                               filter: .binary(op: "=", .column("id"), .literal(.int(1)))))
        XCTAssertEqual(try Parser.parse("DELETE FROM users"), .delete(table: "users", filter: nil))
        XCTAssertEqual(try Parser.parse("DROP TABLE users"), .dropTable("users"))
        XCTAssertEqual(try Parser.parse("SELECT COUNT(*) FROM users"), .select(columns: ["COUNT(*)"], table: "users", filter: nil, orderBy: nil, limit: nil))
    }

    func testErrors() {
        XCTAssertThrowsError(try Parser.parse("SELECT FROM"))
        XCTAssertThrowsError(try Parser.parse("CREATE TABLE t (name TEXT)")) // first column must be INT
        XCTAssertThrowsError(try Parser.parse("CREATE TABLE t (a INT PRIMARY KEY, b INT PRIMARY KEY)"))
        XCTAssertThrowsError(try Parser.parse("CREATE TABLE t (a INT, a INT)"))
        XCTAssertThrowsError(try Parser.parse("INSERT INTO t VALUES (1) extra"))
        XCTAssertThrowsError(try Parser.parse("EXPLODE"))
    }
}

final class DatabaseTests: XCTestCase {
    private func makeDatabase() throws -> (Database, TempDir) {
        let dir = TempDir()
        return (try Database(directory: dir.path), dir)
    }

    private func rows(_ db: Database, _ sql: String) throws -> [Row] { try db.execute(sql).rows }

    func testCrudEndToEnd() throws {
        let (db, dir) = try makeDatabase()
        defer { _ = dir } // keep the temporary directory alive for the whole test
        try db.execute("CREATE TABLE users (id INT PRIMARY KEY, name TEXT(32), age INT)")
        try db.execute("INSERT INTO users VALUES (1, 'ana', 30), (2, 'bo', 25), (3, 'cy', 41)")
        try db.execute("INSERT INTO users (age, id, name) VALUES (19, 4, 'di')")

        XCTAssertEqual(try rows(db, "SELECT name FROM users WHERE age > 24 ORDER BY age DESC"), [[.text("cy")], [.text("ana")], [.text("bo")]])
        XCTAssertEqual(try rows(db, "SELECT id, name FROM users WHERE name = 'bo' OR id = 4 ORDER BY id"), [[.int(2), .text("bo")], [.int(4), .text("di")]])
        XCTAssertEqual(try rows(db, "SELECT COUNT(*) FROM users"), [[.int(4)]])
        XCTAssertEqual(try rows(db, "SELECT * FROM users ORDER BY id LIMIT 2").count, 2)
        XCTAssertEqual(try db.execute("SELECT * FROM users").columns, ["id", "name", "age"])

        XCTAssertEqual(try db.execute("UPDATE users SET age = 26 WHERE name = 'bo'").affected, 1)
        XCTAssertEqual(try rows(db, "SELECT age FROM users WHERE id = 2"), [[.int(26)]])
        XCTAssertEqual(try db.execute("UPDATE users SET id = 20 WHERE id = 2").affected, 1, "changing the key moves the row")
        XCTAssertEqual(try rows(db, "SELECT id FROM users ORDER BY id"), [[.int(1)], [.int(3)], [.int(4)], [.int(20)]])

        XCTAssertEqual(try db.execute("DELETE FROM users WHERE age < 30").affected, 2)
        XCTAssertEqual(try rows(db, "SELECT COUNT(*) FROM users"), [[.int(2)]])
        try db.execute("DROP TABLE users")
        XCTAssertThrowsError(try db.execute("SELECT * FROM users"))
    }

    func testConstraintsAndErrors() throws {
        let (db, dir) = try makeDatabase()
        defer { _ = dir } // keep the temporary directory alive for the whole test
        try db.execute("CREATE TABLE t (id INT PRIMARY KEY, label TEXT(4))")
        try db.execute("INSERT INTO t VALUES (1, 'ok')")
        XCTAssertThrowsError(try db.execute("INSERT INTO t VALUES (1, 'dup')")) { XCTAssertEqual($0 as? DatabaseError, .constraint("duplicate key 1")) }
        XCTAssertThrowsError(try db.execute("INSERT INTO t VALUES (2, 'toolong')"))
        XCTAssertThrowsError(try db.execute("INSERT INTO t VALUES (3, 4)")) { XCTAssertEqual($0 as? DatabaseError, .type("column label is TEXT(4), got 4")) }
        XCTAssertThrowsError(try db.execute("INSERT INTO t VALUES (3)"))
        XCTAssertThrowsError(try db.execute("INSERT INTO t (id) VALUES (3)"), "label would be NULL")
        XCTAssertThrowsError(try db.execute("SELECT nope FROM t"))
        XCTAssertThrowsError(try db.execute("CREATE TABLE t (id INT)"))
        XCTAssertEqual(try rows(db, "SELECT COUNT(*) FROM t"), [[.int(1)]], "failed inserts leave no trace")
    }

    func testPersistenceAndLargeTable() throws {
        let dir = TempDir()
        do {
            let db = try Database(directory: dir.path)
            try db.execute("CREATE TABLE log (id INT PRIMARY KEY, msg TEXT(100), level INT)")
            for batch in stride(from: 0, to: 5000, by: 500) {
                let values = (batch..<batch + 500).map { "(\($0), 'message \($0)', \($0 % 3))" }.joined(separator: ", ")
                try db.execute("INSERT INTO log VALUES \(values)")
            }
            let stats = try db.stats("log")
            XCTAssertEqual(stats.rows, 5000)
            XCTAssertGreaterThanOrEqual(stats.height, 2)
        }
        let reopened = try Database(directory: dir.path)
        XCTAssertEqual(reopened.tables.map { $0.name }, ["log"])
        XCTAssertEqual(try reopened.execute("SELECT COUNT(*) FROM log WHERE level = 1").rows, [[.int(1667)]])
        XCTAssertEqual(try reopened.execute("SELECT msg FROM log WHERE id = 4321").rows, [[.text("message 4321")]])
        XCTAssertEqual(try reopened.execute("SELECT id FROM log WHERE id >= 4998 ORDER BY id").rows, [[.int(4998)], [.int(4999)]])
        XCTAssertEqual(try reopened.execute("DELETE FROM log WHERE level = 2").affected, 1666)
        XCTAssertEqual(try reopened.execute("SELECT COUNT(*) FROM log").rows, [[.int(3334)]])
    }

    func testRowCodec() throws {
        let schema = TableSchema(name: "x", columns: [Column(name: "a", type: .int, primaryKey: true), Column(name: "b", type: .text(10), primaryKey: false)])
        let encoded = try RowCodec.encode([.int(-5), .text("héllo")], schema: schema)
        XCTAssertEqual(encoded.count, 8 + 12)
        XCTAssertEqual(RowCodec.decode(encoded, schema: schema), [.int(-5), .text("héllo")])
    }
}
