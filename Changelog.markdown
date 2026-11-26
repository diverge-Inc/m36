# diverge fork (unreleased, based on upstream v1.2.7)

* build with Nix as a flake (haskell-flake) on nixpkgs-unstable's default GHC (9.10); remove niv, `release.nix`, `default.nix` and `shell.nix`
* export `haskellFlakeProjectModules.output` so haskell-flake projects can depend on project-m36 with its dependency settings
* accept streamly 0.10 and 0.11 (`streamly >= 0.10.1 && < 0.12`, `curryer-rpc >= 0.5.1 && < 0.6`) via a small compatibility module, so nixpkgs' versions can be used
* replace blanket jailbreaks/`allow-newer` with loosening only the third-party upper bounds that are actually too tight
* macOS: read memory statistics with `sysctl` instead of spawning `memory_pressure` on every query; fixes queries failing when `/usr/bin` is not on `PATH` and the free-memory estimate on 16 KiB-page (Apple Silicon) machines
* drop `-fexternal-interpreter` from the library, which made GHC 9.10 panic while running Template Haskell
* run the full test suite in the Nix build (previously disabled)
* make the cost of a commit independent of the size of the database and the length of its history (see [docs/append_benchmark.markdown](docs/append_benchmark.markdown) for measurements against PostgreSQL):
  * **new on-disk format (version 9); databases written by earlier versions cannot be opened** (as with previous format changes, there is no migration)
  * the transaction graph is persisted as one append-only transaction log instead of a directory per transaction; a commit appends the change of the transaction relative to its parent (see [docs/filesystem-persistence.markdown](docs/filesystem-persistence.markdown))
  * the value of a relation variable is kept as a materialized relation in a persistent (structure-sharing) set; `insert`, `delete` and `update` are applied to the value right away instead of piling up as an expression which grows with every statement
  * the Merkle hash of a transaction covers the change of the relation variables relative to the first parent instead of all relation variables, so hashing and validating cost time proportional to the changes; hashes therefore differ from those of earlier versions
  * uniqueness constraints made with `databaseContextExprForUniqueKey`/`inclusionDependencyForKey` (TutorialD `key`) are backed by an index: they are checked without evaluating the constraint, and restrictions which compare the key attributes with constants find their tuples through the index
  * a statement re-checks only the inclusion dependencies which mention the relation variable it changed
  * transactions are found by id in logarithmic time instead of by scanning all transactions; markers for unchanged subschemas no longer form a chain which grows with every commit
  * behaviour change: a `delete` or `update` which changes no tuple no longer marks the session as dirty
  * the properties which the speed depends on are carried by types instead of by convention (see "What keeps it that way" in [docs/append_benchmark.markdown](docs/append_benchmark.markdown)):
    * a relation variable is a `RelVarValue`: either `StoredRelVar` (it holds its tuples in a `TupleStore`) or `DerivedRelVar` (it is defined by an expression). `RelationVariables` maps names to `RelVarValue` instead of to expressions; `relVarExpr` gives the expression which reading a relation variable evaluates
    * `TransactionGraph` keeps its transactions in a `TransactionIndex` keyed by transaction id (`ProjectM36.TransactionGraph.Index`) instead of a `Set`; use `transactionListForGraph` and `transactionIdsForGraph` to enumerate them
    * `NotChangedSinceMarker` can be matched on but not applied; a reference to an earlier transaction is made with `unchangedSince` from the marker of that transaction, so it always names the transaction which holds the value. A session's workspace is based on a transaction with `DisconnectedTransaction.fromTransaction` (which replaces `freshTransaction`)
    * `ptrEquals` (`ProjectM36.PointerEquality`) only accepts evaluated values
    * the indexes of a `TupleStore` are a strict list (`TupleStoreIndexes`), so an index is updated when a tuple changes instead of when the index is next used
    * the materialized constructor of `RelationTupleSet` is now `StoredTuples TupleStore`
  * the optimizations are kept out of the relational logic: `insert`, `update` and `delete` are defined as upstream defines them (the assignment of an expression over the current value, now evaluated right away), and what makes them cheap is in the relational operators (`union`, `restrictByPredicate`), in `ProjectM36.RelVarValue`, and behind the five functions of `ProjectM36.OptimizationHooks`, each of which has a trivial implementation that is always correct. `test-statement-model` checks the statements against a model which knows nothing of these layers (see "How the optimizations are layered" in [docs/append_benchmark.markdown](docs/append_benchmark.markdown))
  * a union of a relation with one which holds its tuples in a store has the order of attributes of the latter, whichever operand it is
  * behaviour change: `insert`, `update` and `delete` on a relation variable which holds its tuples fail right away if their result cannot be evaluated (for example a `delete` whose predicate names a missing attribute); such a statement used to be stored as an expression and fail whenever the relation variable was read
  * behaviour change: a session is not dirty after jumping to a head or a transaction, and after a merge it is based on the merge transaction
  * merging two branches keeps a relation variable which holds the same tuples in both as it is, and merges relation variables which hold their tuples into one which holds their union (instead of defining the merged relation variable by a union expression)
  * drop the `linux-xattr` dependency (extended attributes were only written for the removed per-relation-variable files)

# ? (v1.2.7)

* upgrade to streamly 0.11.1 along with curryer-rpc 0.5.2
	
# 2026-03-01 (v1.2.6)

* add support for inlining TutorialD expressions in Haskell using Quasiquoters

# 2026-02-22 (v1.2.5)

* include GHC in docker image so that users can use the new Haskell module functionality

# 2026-02-16 (v1.2.4)

* fix bug resulting in duplicate rows after group operator application

# 2026-02-09 (v1.2.3)

* add support for importing whole Haskell modules for easier application logic programming
	
# 2026-01-15 (v1.2.1)

* fix critical type resolution error in MakeRelationFromExprs
* upgrade to crypton 1.8.0 and friends

# 2026-01-06 (v1.2.0)

* add LRU result caching layer
* add parallel execution engine based on [streamly 0.9.0](https://github.com/composewell/streamly)
* reduce copying of database context fields in persistence layer by enabling references to previous transactions
* require GHC 9.4+
* add TLS encryption including mutual TLS support for client authentication
* add role-based authentication for a variety of database permissions

# 2025-03-30 (v1.1.1)

* upgrade to curryer-rpc 0.4.0 which includes support for IPv6 and Unix domain socket communications

This improvement changes the connectProjectM36 API. When connecting to a database over IPv4 or IPv6, use `RemoteConnectionInfo <dbname> (RemoteServerHostAddress <String ip_addr> <Int port>) <NotificationCallback>`.

# 2024-08-25 (v1.1.0)

* add support for GHC 9.6, GHC 9.8, and GHC 9.10
* clean up compiler warnings

# 2024-07-27 (v1.0.2)

* upgrade to streamly 0.10.1
* refactor websocket API to support request UUIDs (#367)
* refactor websocket API to support `createSessionAtHead` (#367)

# 2024-07-15 (v1.0.1)

* add support for aggregate functions using sub-relation attributes

# 2024-06-06 (v1.0.0)

* add support for relational expression evaluation against sub-relations
* add support for SQL dialect and console called "SQLegacy"

# 2024-01-12 (v0.9.9)

* revert to using streamly 0.9.0 due to over-the-wire corruption bug in 0.10.0
* fixed toAtom/fromAtom for NonEmpty lists (#363)

# 2023-12-30 (v0.9.8)

* fix notification serialization in transaction (#362)
* require minimum GHC 9.2 (dropping GHC 8.10 and GHC 9.0)
* add support for GHC 9.4

# 2023-07-18 (v0.9.7)

* fix critical bug resulting in empty results from cross joins

# 2022-11-05 (v0.9.6)

* fix tuple context passed down to extended expressions
* add ddl hash- useful for validating that the client supports the current schema
* add registered queries- useful for constraining what DDL can be applied to the database so as not to break client applications
* reduce memory usage during Merkle hashing by an order of magnitude by using strict serialization and hashing

# 2022-08-19 (v0.9.5)

* removed necessity for caret "^" when using boolean atom expressions in restriction predicates
* `True` and `False` are now value constructors for `Bool` atom values (previously `t` and `f); changed for better discoverability by Haskell developers
* add `Scientific` data type for arbitrary-precision values (backed by Data.Scientific)
* add support for GHC 9.0 and GHC 9.2
* drop support for GHC < 8.10.7
* fix relational equality when the relation includes a nested relation

# 2021-12-05 (v0.9.4)

* fix bug which [caused tuple storage to be duplicated unnecessarily](https://github.com/agentm/project-m36/pull/328)
* add support for `case` and `if-then-else` expressions
* allow relation variable names and attribute names to be escaped using backticks
* add UUID primitive type
* complete implementation of [object and shared object files at runtime](https://github.com/agentm/project-m36/blob/master/docs/atomfunctions.markdown#pre-compiled-atom-functions) in order to compete with Haskell scripting alternative
* fix constraint checking after undefining a relation variable
* optionally allow TLS and client certificate authentication in Project:M36 server
* require GHC >=8.8

# 2021-04-01 (v0.9.3)

* add new ":importtutd <URI> <SHA256 hash>" feature to import TutorialD from a local file or a HTTP/HTTPS URI

# 2020-12-27 (v0.9.0)

* replace unmaintained distributed-process-client-server RPC package with new curryer RPC package
* drop support for GHC 8.2 and GHC 8.4 due to dependency on DerivingVia extension

# 2020-11-21 (v0.8.2)

* support multiple extend expressions in TutorialD
* fix parsing of Bool atoms in TutorialD
* fix database context expressions which include self-references such as `s:=s union s`
* show constraints as TutorialD when using tutd console
* add `RelationalExprAtom` data type useful for storing `RelationalExpr` within the database

# 2020-10-05 (v0.8.1)

* support GHC 8.10

# 2020-05-25 (v0.8)

* refactor backend to maximize laziness: [An Architecture for Data Independence](docs/data_independence.markdown)

# 2019-09-07 (v0.7)

* fix case sensitivity issue with relation variables in tutd
* fix multibyte escaping in data frames
* fix broken instances of `Atomable [a]`
* fix `TypeConstructor` validation of argument count
* add help option to executables

# 2019-01-08 (v0.6)

* fix atom type parsing to support more complex data types
* add [data frames](docs/dataframes.markdown) to support server-side sort ordering, limits, and offsets

# 2018-10-03 (v0.5.1)

* fix atom function type validation
* add support for GHC 8.4 (now we support GHC 8.0, 8.2, and 8.4)

# 2018-08-10 (v0.5)

* fix critical type bug which allowed unresolved types to be used
* add full support for GHC 8.2 with stack or cabal (delayed for a long time by dependency version boundaries)
* drop support for GHC 7.10
* add support for `with (relexpr as name,...)` syntax for use as tutd macros
* add `NonEmptyList` list data type

# 2018-06-04 (v0.4)

* add contributed feature to allow users to [create arbitrary relations](https://github.com/agentm/project-m36/blob/master/docs/tutd_tutorial.markdown#arbitrary-relation-variables)
* fix type validation bug allowing concrete type with type variables in relations
* improve usability of `Interval a` data type
* allow `Integer` to be parsed as negative in `tutd` console
* support precompiled (Haskell) [`AtomFunction`s](https://github.com/agentm/project-m36/blob/master/docs/atomfunctions.markdown#pre-compiled-atom-functions) and [`DatabaseContextFunction`s](https://github.com/agentm/project-m36/blob/master/docs/database_context_functions.markdown#loading-precompiled-modules)
* make TutorialD scripts read from the filesystem unconditionally read as UTF-8
* improve support for display of multibyte characters in `tutd` console, especially Chinese
* fix file descriptor leak in file sychronization
* improve reliability by allowing fast-forward commits when using `autoMergeToHead`
* add [`semijoin` and `anitjoin`](https://github.com/agentm/project-m36/blob/master/docs/tutd_tutorial.markdown#join) support to `tutd`
* added various new static optimizations

# 2017-11-14

* alter websocket server API to allow for multiple representations (JSON, text, or HTML) to be selected and returned simultaneously
* add jupyter kernel for TutorialD interpreter
* fix warnings suggested by new hlint 2.0.10

# 2017-10-08 (v0.3)

* replaced overuse of `undefined` with `Proxy` in `Tupleable` and `Atomable` typeclasses
* allow notifications to return query results from before *and* after the commit which triggered the notification
* alert users in `tutd` console before a transaction graph expression is evaluated which would throw out their changes
* drastically-improved CSV import/export now supports all possible types except `RelationAtom`
* fix serious file handle leaks when using on-disk persistence
* fix case where invalid number of arguments to `ConstructedAtom` did not result in an error
* add support for `IntegerAtom` (previously, only `IntAtom` was supported)

# 2017-09-16 (v0.2)

* a new [simple client API](https://github.com/agentm/project-m36/blob/master/docs/simple_api.markdown) with a monadic transaction manager
* complete hlint compliance
* the generics-based [Tupleable typeclass](	https://github.com/agentm/project-m36/blob/master/docs/tupleable.markdown
) which makes it easy to marshal Haskell data types to-and-from the database
* timestamps attached to transactions to allow specific point-in-time travel
* autoMergeToHead, a variant of commit which attempts to merge and commit to the latest head transaction to reduce incidents of TransactionNotAHeadErrors
* interval data types
* transaction dirtiness detection which allows the client to determine if an update expression actually changed the database state

# 2017-08-01

## autoMergeToHead

In preparation for the simpler monad client API, ProjectM36.Client now includes a server-side merge for new transactions called "[automerge](https://github.com/agentm/project-m36/issues/33)". This feature should reduce head contention in cases where new transactions can be simply merged to the head without additional processing. The trade-off is reduced ```TransactionIsNotAHeadError```s but an increased chance of merge errors. The feature operates similarly to a server-side git rebase.

## critical bug in merging

Successfully merged transactions did not have their constraints validated. Fixed.

# 2017-06-12

## add file locking

This [feature](#102) allows Project:M36 database directories to be shared amongst multiple Project:M36 processes. This is similar to how SQLite operates except that the remote server mode supports the feature as well. This could allow, for example, multi-master, file-based replication across Windows shares or NFS.

[Documentation](/docs/replication.markdown)

# 2016-11-30

## add functional dependency macro

Date demonstrates two ways to implement functional dependencies as constraints on page 21 in "Database Design and Relational Theory". A similar macros is now implemented in the tutd interpreter.

```funcdep sname_status (sname) -> (status) s```

[Documentation](/docs/tutd_tutorial.markdown#functional-dependencies)

# 2016-09-07

## add TransGraphRelationalExpr

The TransGraphRelationalExpr allows queries against all past states of the database.

The following example executes a query against two different committed transactions using syntax similar to that of git for graph traversal:
```:showtransgraphexpr s@master~ join sp@master```

[Documentation](/docs/transgraphrelationalexpr.markdown)
