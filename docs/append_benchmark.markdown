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

## Results

Apple M-series laptop, macOS, GHC 9.10.3, PostgreSQL 17.11, 20,000 events. Times are per operation.

| operation | before this work | Project:M36 | PostgreSQL |
| --- | --- | --- | --- |
| append and commit | 8.5 ms at 250 events, 26.6 ms at 1,000 events, growing linearly | 0.13 ms | 0.053 ms |
| update by id and commit | - | 0.11 ms | 0.048 ms |
| delete by id and commit | - | 0.08 ms | 0.045 ms |
| open | 3.3 s at 1,000 events | 0.23 s | 0.16 s |
| scan (20,000 tuples) | 468 ms at 1,000 events (first read) | 1.4 - 2.5 ms | 3.6 ms |
| lookup by id | 2.5 ms at 1,000 events | 0.050 ms | 0.034 ms |
| filter by kind (5,000 tuples) | 2.4 ms at 1,000 events | 3.1 - 4.6 ms | 1.5 ms |
| size on disk | 90 MB at 1,000 events, growing quadratically | 7.6 MB | about 4 MB of table, index and WAL |

"Before this work" was measured at 1,000 events because 20,000 were out of reach: every commit wrote and hashed all relation variables, whose defining expressions grew with every insert.

With 100,000 events, appending still takes 0.13 ms per commit and the database is 37 MB on disk. Opening takes 1.2 s, and a lookup by id takes 0.13 ms instead of 0.05 ms; the cause of the latter has not been found yet.

## What is left

* A commit spends about a fifth of its time looking up the roles of the connection in the login roles database (three SQLite queries per insert and commit).
* Restrictions on attributes without an index examine every tuple, like a sequential scan in PostgreSQL, but at roughly twice the cost per tuple.
* Only uniqueness constraints are backed by an index. Other inclusion dependencies (such as foreign keys) are evaluated in full whenever one of the relation variables they mention changes.
* Opening replays the whole transaction log; there are no checkpoints yet, so the time to open grows with the length of the history (about 12 microseconds per transaction).
* Joins, grouping and the other relational operators are untouched by this work.
