import Foundation
import SwiftSQL

// swiftsql <database-directory>
//
// A tiny REPL: type SQL statements ending in ';' (multi-line is fine),
// or one of the meta commands .tables .schema .stats <table> .exit

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: swiftsql <database-directory>\n".data(using: .utf8)!)
    exit(2)
}

let db: Database
do {
    db = try Database(directory: args[1])
} catch {
    FileHandle.standardError.write("cannot open database: \(error)\n".data(using: .utf8)!)
    exit(1)
}

func render(_ result: QueryResult) -> String {
    if let message = result.message { return message }
    let widths = result.columns.indices.map { i in
        max(result.columns[i].count, result.rows.map { $0[i].description.count }.max() ?? 0)
    }
    func line(_ cells: [String]) -> String {
        "| " + zip(cells, widths).map { $0.padding(toLength: $1, withPad: " ", startingAt: 0) }.joined(separator: " | ") + " |"
    }
    var out = [line(result.columns), "|" + widths.map { String(repeating: "-", count: $0 + 2) }.joined(separator: "|") + "|"]
    out += result.rows.map { line($0.map { $0.description }) }
    out.append("(\(result.rows.count) row\(result.rows.count == 1 ? "" : "s"))")
    return out.joined(separator: "\n")
}

let interactive = isatty(STDIN_FILENO) != 0
if interactive { print("swiftsql - database at \(args[1]). End statements with ';', .exit to quit.") }
var buffer = ""
while true {
    if interactive { print(buffer.isEmpty ? "sql> " : "...> ", terminator: "") }
    guard let line = readLine() else { break }
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if buffer.isEmpty, trimmed.hasPrefix(".") {
        let parts = trimmed.split(separator: " ").map(String.init)
        switch parts[0] {
        case ".exit", ".quit": exit(0)
        case ".tables": print(db.tables.map { $0.name }.joined(separator: "\n"))
        case ".schema":
            for t in db.tables {
                let cols = t.columns.map { "\($0.name) \($0.type)\($0.primaryKey ? " PRIMARY KEY" : "")" }
                print("CREATE TABLE \(t.name) (\(cols.joined(separator: ", ")));")
            }
        case ".stats":
            if parts.count > 1, let s = try? db.stats(parts[1]) {
                print("rows: \(s.rows)  tree height: \(s.height)  pages: \(s.pages) (\(s.pages * pageSize) bytes)")
            } else {
                print("usage: .stats <table>")
            }
        default: print("unknown command \(parts[0]); try .tables .schema .stats <table> .exit")
        }
        continue
    }
    buffer += line + "\n"
    guard trimmed.hasSuffix(";") else { continue }
    do {
        print(render(try db.execute(buffer)))
    } catch {
        print("error: \(error)")
    }
    buffer = ""
}
