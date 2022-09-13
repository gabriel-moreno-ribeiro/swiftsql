# swiftsql

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

**EN:** a small relational database in Swift: a 4 KB page cache, a B+tree with leaf and internal splits, fixed-size rows, a hand-written SQL lexer/parser (CREATE/INSERT/SELECT/UPDATE/DELETE with WHERE, ORDER BY, LIMIT) and an interactive shell. XCTest covers the tree, the parser and end-to-end queries over 5000 rows that survive reopening the file. MIT.
