# swiftsql

A small relational database written from scratch in Swift: a page-based
storage engine with a B+tree, fixed-size rows, a SQL lexer and parser, a
query executor and an interactive shell. No dependencies beyond Foundation.

```sh
swift build -c release
.build/release/swiftsql ./mydb
```

```
sql> CREATE TABLE users (id INT PRIMARY KEY, name TEXT(32), age INT);
table users created
sql> INSERT INTO users VALUES (1, 'ana', 30), (2, 'bo', 25), (3, 'cy', 41);
3 rows inserted
sql> SELECT name, age FROM users WHERE age > 24 ORDER BY age DESC LIMIT 2;
| name | age |
|------|-----|
| cy   | 41  |
| ana  | 30  |
(2 rows)
sql> UPDATE users SET age = 26 WHERE name = 'bo';
sql> DELETE FROM users WHERE id = 3;
sql> .stats users
rows: 2  tree height: 1  pages: 1 (4096 bytes)
```

## Supported SQL

- `CREATE TABLE t (col INT PRIMARY KEY, col TEXT(n), ...)`, `DROP TABLE t`
- `INSERT INTO t [(cols)] VALUES (...), (...)`
- `SELECT * | cols | COUNT(*) FROM t [WHERE expr] [ORDER BY col [ASC|DESC]] [LIMIT n]`
- `UPDATE t SET col = value, ... [WHERE expr]`
- `DELETE FROM t [WHERE expr]`
- expressions: `= != < > <= >=`, `AND`, `OR`, parentheses, integer and
  `'string'` literals (with `''` escaping), `NULL`
- meta commands in the shell: `.tables`, `.schema`, `.stats <table>`, `.exit`

Types are `INT` (64-bit) and `TEXT(n)` (up to n UTF-8 bytes, default 255).
The primary key must be an `INT` column and is the B+tree key.

## How it works

- **Pager** (`Pager.swift`): the table file is an array of 4 KB pages. Pages
  are cached in memory, marked dirty on write and flushed at the end of each
  statement.
- **B+tree** (`BTree.swift`): leaf pages hold `key + row` cells sorted by
  key and are linked left to right for scans; internal pages hold
  `child, maxKey` pairs plus a right-most child. Inserting into a full leaf
  splits it and pushes a separator up; a full internal node splits too, and
  the root grows the tree by one level. Lookups are binary searches down the
  tree. Deletes remove the cell without rebalancing.
- **Rows** (`Schema.swift`): a table's schema decides a fixed row size
  (8 bytes per INT, 2 + n per TEXT(n)), so cells never move within a page.
- **SQL** (`SQL.swift`): a hand-written lexer and a recursive-descent parser
  produce a small AST (`Statement`, `Expr`).
- **Executor** (`Database.swift`): `schema.json` is the catalog; each table
  is its own B+tree file. SELECT scans the leaves, filters with the
  expression evaluator, then sorts and limits in memory. UPDATE rewrites
  cells in place (or moves the row when the key changes); DELETE removes
  matching keys.

## Tests

```sh
swift test
```

The XCTest suite covers the B+tree (random and sequential inserts with many
splits, deletes, updates, reopening the file), the lexer and parser (every
statement form and error), and the database end to end, including a 5000-row
table that is written, reopened from disk and queried.

## License

MIT
