# Append-and-commit benchmark

This benchmark measures the workload of an event-sourced application: a relation variable of facts which grows by one tuple per commit, is reopened, and is read. It exists to keep the cost of a commit independent of the size of the database and the length of its history, and to compare Project:M36 with PostgreSQL on the same workload.

## Workload

One relation variable (one table), with a uniqueness constraint on `id` (primary key in PostgreSQL):

```
event {id Integer, kind Text, payload Text}
```

* append: insert one tuple and commit, 20,000 times
* open: start from the files on disk until the first query can be answered
* scan: read all tuples
* lookup by id: read one tuple by its key
* filter by kind: read the quarter of the tuples with a given `kind` (no index)
* update by id, delete by id: change or remove one tuple by its key and commit

Project:M36 runs in-process (`CrashSafePersistence`, which `fsync`s every commit); PostgreSQL is driven with `pgbench` over a local TCP connection with its default `synchronous_commit=on`.

## Running

```
cabal build bench:append-commit --enable-benchmarks
bin=$(cabal list-bin bench:append-commit --enable-benchmarks)
$bin --datadir /tmp/m36bench --write --count 20000 --key --fsync
$bin --datadir /tmp/m36bench --mutations 1000

scripts/bench-append-postgres.sh 20000
```

`scripts/bench-append-postgres.sh` creates a throwaway PostgreSQL cluster (it needs `initdb`, `pg_ctl`, `psql` and `pgbench` on `PATH`).

With `--reorder`, the appended tuples list their attributes in the reverse order of the relation variable's.

## Results

Apple M-series laptop, macOS, GHC 9.10.3, PostgreSQL 17.11, 20,000 events. Times are per operation.

| operation | before this work | Project:M36 | PostgreSQL |
| --- | --- | --- | --- |
| append and commit | 8.5 ms at 250 events, 26.6 ms at 1,000 events, growing linearly | 0.13 - 0.15 ms | 0.053 ms |
| update by id and commit | - | 0.11 - 0.13 ms | 0.048 ms |
| delete by id and commit | - | 0.08 - 0.10 ms | 0.045 ms |
| open | 3.3 s at 1,000 events | 0.26 - 0.29 s | 0.16 s |
| scan (20,000 tuples) | 468 ms at 1,000 events (first read) | 1.4 - 2.4 ms | 3.6 ms |
| lookup by id | 2.5 ms at 1,000 events | 0.025 ms | 0.034 ms |
| filter by kind (5,000 tuples) | 2.4 ms at 1,000 events | 3.2 - 4.4 ms | 1.5 ms |
| size on disk | 90 MB at 1,000 events, growing quadratically | 7.6 MB | about 4 MB of table, index and WAL |

"Before this work" was measured at 1,000 events because 20,000 were out of reach: every commit wrote and hashed all relation variables, whose defining expressions grew with every insert.

With 100,000 events, an append still takes 0.13 - 0.15 ms per commit and a lookup by id still takes 0.025 ms. The database is 38 MB on disk and opening takes 1.3 - 1.5 s.

The times vary by about a tenth from run to run on this machine.

How the costs grow with the number of events (each event is one commit):

| events | append and commit | transaction log | open |
| --- | --- | --- | --- |
| 1,000 | 0.13 - 0.17 ms | 380 kB (380 bytes per commit) | 0.03 s |
| 2,000 | 0.14 - 0.15 ms | 760 kB (380 bytes per commit) | 0.04 s |
| 4,000 | 0.14 - 0.15 ms | 1.5 MB (380 bytes per commit) | 0.07 s |
| 8,000 | 0.14 - 0.15 ms | 3.0 MB (380 bytes per commit) | 0.11 s |

A commit costs the same whatever came before it, the log grows by the same number of bytes with every commit, and opening (which reads the log once and validates the Merkle hash of every transaction) takes about 13 microseconds per transaction.

## How the optimizations are layered

The relational logic does not know how any of this is made fast. `insert`, `update` and `delete` are still defined in `ProjectM36.RelationalExpression` the way upstream defines them, as the assignment of an expression over the current value (`new union x`, `x where not p`, and the union of the untouched and the updated part); the only addition is that the expression is evaluated right away. That module imports neither the store nor the indexes. What makes the statements cheap sits below and beside it:

| layer | modules | what the logic sees of it |
| --- | --- | --- |
| how tuples are held: a persistent hash set with indexes | `ProjectM36.TupleStore`, `ProjectM36.PointerEquality` | nothing |
| relational operators which keep held tuples shared: a union with, or a restriction of, a relation whose tuples are held adds to or removes from its store, and a restriction on indexed attributes looks at the tuples the index finds | `union`, `restrictByPredicate` in `ProjectM36.Relation`, `tupleSetUnion` in `ProjectM36.TupleSet` | the operators it has always called; a restriction passes its predicate along with its filter |
| the value of a relation variable | `ProjectM36.RelVarValue` | whether a relation variable holds its tuples, and how to make one hold the tuples of a relation |
| shortcuts: indexes for declared keys, keys decided by an index, constraints which a change cannot affect | `ProjectM36.OptimizationHooks` | five functions, each with a trivial implementation (`id`, `Nothing`, "all of them") which is always correct |
| the change between two versions of the relation variables | `ProjectM36.RelationVariablesDelta` | one function, used to define the Merkle hash |
| storage: the transaction log | `ProjectM36.TransactionGraph.Persist`, `ProjectM36.Transaction.Persist`, `ProjectM36.Persist` | nothing; only `ProjectM36.Client` calls it, to load the log and to append to it |
| finding transactions and unchanged parts | `ProjectM36.TransactionGraph.Index`, `ProjectM36.ValueMarker` | lookup by id; markers it can read but not forge |

One consequence is visible outside: the union of a relation with one whose tuples are held has the order of attributes of the latter, whichever operand it is, where upstream takes the order of the first operand. The order of attributes means nothing in the relational model ("the relation header is a set of attributes, so the attributes also have no ordering", [introduction to the relational algebra](introduction_to_the_relational_algebra.markdown)), and equality of attributes, tuples and relations ignores it. It matters here because `insert` is the union of the inserted relation and the relation variable, in that order, and the tuples are held in the order of the relation variable. If the union took the order of the inserted relation, an insert which lists its attributes in another order would rebuild the relation variable: measured with `--reorder`, an append then takes 2.4 ms at 2,000 events and 25.5 ms at 8,000 instead of 0.14 ms throughout. The alternative, keeping upstream's union and writing `insert` with the relation variable first, is just as fast but leaves a line in the relational logic whose only reason is speed.

Two things check that the layers change how fast a statement is and not what it means. `test-statement-model` runs 600 pseudo-random statements (inserts, updates and deletes which hit existing keys and missing foreign keys, commits, rollbacks) against a database on disk and against a model which is a plain set of rows with constraints checked by looking at every row; both have to agree after every statement, and the database has to come back from disk in the state of the model. And with the five functions of `ProjectM36.OptimizationHooks` replaced by their trivial implementations, the same test still passes.

## What keeps it that way

Each of the slowdowns removed by this work came from something which the types allowed and only a convention forbade. The conventions are now types, so that a later change cannot bring the slowdown back without the compiler objecting.

| what must stay true | how it is enforced |
| --- | --- |
| A transaction is found by its id without scanning the graph. | `TransactionGraph` holds a `TransactionIndex` (`ProjectM36.TransactionGraph.Index`), whose only way to find a transaction is the lookup by id. Listing all transactions is a separate, explicitly linear function. |
| The value of an unchanged part of a transaction is one lookup away, however long the history. | A reference to an earlier transaction (`NotChangedSinceMarker`) can be matched on but not applied. The only way to make one is `unchangedSince`, which takes the marker of the transaction referred to and passes an existing reference on as it is. A reference therefore always names the transaction which holds the value; references cannot form a chain. Sessions get their workspace from `DisconnectedTransaction.fromTransaction`, and a log whose references do not name holders is refused when it is read. |
| Inserting, updating or deleting tuples costs time proportional to those tuples, and never makes later reads or writes more expensive. | A relation variable is a `RelVarValue`: `StoredRelVar` holds a `TupleStore`, `DerivedRelVar` holds an expression. A statement on a relation variable which holds its tuples evaluates its expression right away and holds the result (`changeTuples`); it has no way to leave the expression behind. The store is only changed by functions of type store -> tuples -> store (`ProjectM36.TupleStore`). A relation variable is only defined by an expression where the code says `DerivedRelVar`: an assignment of a non-constant expression, or a merge. |
| Two versions of a relation variable are compared in time proportional to their difference. | The comparison skips shared parts by pointer equality, which is only meaningful for evaluated values. `ptrEquals` takes `Forced` arguments, an unlifted type with a strict field: it cannot be handed an unevaluated value. |
| The work of a statement is done by that statement, not left for a later one. | The fields of `TupleStore`, `TupleStoreIndex` and `RelVarValue` are strict, and the indexes of a store are a strict list (`TupleStoreIndexes`). An index is therefore updated when a tuple changes. (With a lazy map the updates piled up unevaluated, one per tuple, and the first statement to use the index paid for all of them: opening looked faster and the first lookups slower than they were.) |
| A commit writes and hashes what it changed. | `transactionToRecord` and `hashTransaction` are given the relation variables of the parent and turn them into a `RelVarsDelta` before anything is written or hashed. |

Types do not state the complexity itself (that a function is logarithmic or proportional to its input), so the bounds are also checked by tests: `test-transactiongraph-persist` commits several hundred single-tuple inserts and fails if the log grows by more than a fixed number of bytes per commit, if a relation variable stops holding its tuples, or if a reference does not name the transaction holding the value.

## What is left

* A commit spends about a fifth of its time looking up the roles of the connection in the login roles database (three SQLite queries per insert and commit).
* Restrictions on attributes without an index examine every tuple, like a sequential scan in PostgreSQL, but at roughly twice the cost per tuple.
* Only uniqueness constraints are backed by an index. Other inclusion dependencies (such as foreign keys) are evaluated in full whenever one of the relation variables they mention changes.
* Opening replays the whole transaction log; there are no checkpoints yet, so the time to open grows with the length of the history (about 12 microseconds per transaction).
* Joins, grouping and the other relational operators are untouched by this work.
