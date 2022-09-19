# swiftsql

> 🇺🇸 [English version below](#english)

Um banco de dados relacional pequeno em Swift: storage por páginas com B+tree, linhas de tamanho fixo, lexer e parser de SQL, executor e um shell interativo. Só Foundation.

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
sql> .stats users
rows: 2  tree height: 1  pages: 1 (4096 bytes)
```

SQL suportado: `CREATE TABLE` (`INT PRIMARY KEY`, `TEXT(n)`), `DROP TABLE`, `INSERT` com várias linhas, `SELECT` com `*`/colunas/`COUNT(*)`, `WHERE` (`= != < > <= >=`, `AND`, `OR`, parênteses, `NULL`), `ORDER BY`, `LIMIT`, `UPDATE`, `DELETE`, e no shell `.tables`, `.schema`, `.stats`, `.exit`. A chave primária tem que ser `INT` e é a chave da B+tree.

## Como os bytes ficam no disco

- **Pager** (`Pager.swift`): o arquivo da tabela é um array de páginas de 4 KB, com cache em memória, marcadas como sujas na escrita e descarregadas no fim de cada statement.
- **B+tree** (`BTree.swift`): folhas guardam `chave + linha` ordenadas e são ligadas da esquerda pra direita pra scan; nós internos guardam pares `filho, maiorChave` mais um filho à direita. Inserir numa folha cheia divide ela e empurra um separador pra cima; nó interno cheio divide também, e a raiz cresce a árvore em um nível. Busca é binária descendo a árvore. Delete só remove a célula, sem rebalancear (foi uma escolha, não preguiça... tá, um pouco de preguiça).
- **Linhas** (`Schema.swift`): o schema define um tamanho fixo (8 bytes por INT, 2 + n por TEXT(n)), então célula nunca se move dentro da página.
- **SQL** (`SQL.swift`): lexer e parser recursivo à mão gerando uma AST pequena.
- **Executor** (`Database.swift`): `schema.json` é o catálogo; cada tabela é sua própria B+tree num arquivo. SELECT varre as folhas, filtra, ordena e limita em memória.

O que aprendi de Swift aqui: `Data` com `withUnsafeBytes` pra ler inteiros big-endian de uma página é feio mas rápido, e os enums com valores associados são perfeitos pra AST.

Testes: `swift test` (B+tree com inserções aleatórias e sequenciais com muitas divisões, deletes, updates, reabrir o arquivo; lexer e parser; e o banco de ponta a ponta com uma tabela de 5000 linhas escrita, reaberta do disco e consultada).

---

## English

A small relational database in Swift: page-based storage with a B+tree, fixed-size rows, SQL lexer and parser, executor and an interactive shell. Foundation only.

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
sql> .stats users
rows: 2  tree height: 1  pages: 1 (4096 bytes)
```

Supported SQL: `CREATE TABLE` (`INT PRIMARY KEY`, `TEXT(n)`), `DROP TABLE`, multi-row `INSERT`, `SELECT` with `*`/columns/`COUNT(*)`, `WHERE` (`= != < > <= >=`, `AND`, `OR`, parentheses, `NULL`), `ORDER BY`, `LIMIT`, `UPDATE`, `DELETE`, and in the shell `.tables`, `.schema`, `.stats`, `.exit`. The primary key has to be `INT` and is the B+tree key.

## How the bytes sit on disk

- **Pager** (`Pager.swift`): the table file is an array of 4 KB pages, cached in memory, marked dirty on write and flushed at the end of each statement.
- **B+tree** (`BTree.swift`): leaves store `key + row` in order and are linked left to right for scans; internal nodes store `child, largestKey` pairs plus a rightmost child. Inserting into a full leaf splits it and pushes a separator up; a full internal node splits too, and the root grows the tree by one level. Search is binary going down the tree. Delete just removes the cell, no rebalancing (it was a choice, not laziness... ok, a bit of laziness).
- **Rows** (`Schema.swift`): the schema defines a fixed size (8 bytes per INT, 2 + n per TEXT(n)), so a cell never moves inside the page.
- **SQL** (`SQL.swift`): hand-written lexer and recursive parser producing a small AST.
- **Executor** (`Database.swift`): `schema.json` is the catalog; every table is its own B+tree in a file. SELECT scans the leaves, filters, sorts and limits in memory.

What I learned about Swift here: `Data` with `withUnsafeBytes` to read big-endian integers from a page is ugly but fast, and enums with associated values are perfect for the AST.

Tests: `swift test` (B+tree with random and sequential inserts with lots of splits, deletes, updates, reopening the file; lexer and parser; and the database end to end with a 5000-row table written, reopened from disk and queried).

MIT.
