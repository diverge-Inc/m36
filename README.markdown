# Ξ Project:M36 Relational Algebra Engine

[![CI](https://github.com/diverge-Inc/m36/actions/workflows/ci.yaml/badge.svg)](https://github.com/diverge-Inc/m36/actions/workflows/ci.yaml)

*Software can always be made faster, but rarely can it be made more correct.*

> [!NOTE]
> This is diverge's fork of [agentm/project-m36](https://github.com/agentm/project-m36). It differs from upstream in two ways. Packaging: it is a Nix flake built on nixpkgs' default GHC (currently 9.10), with dependency bounds aligned to the versions in nixpkgs. Storage: commits are appended to a transaction log as changes, relation variables are kept as materialized relations with indexes for their keys, and the cost of a commit no longer grows with the database or its history ([measurements against PostgreSQL](docs/append_benchmark.markdown)). The on-disk format is not compatible with upstream's. See [Changelog](Changelog.markdown) for the fork-specific changes.

## Introduction

Project:M36 implements a relational algebra engine as inspired by the writings of Chris Date. Project:M36 supports both SQL and TutorialD interactive access.

## Quick Start

With [Nix](https://nixos.org/download/) (flakes enabled), run the [TutorialD](docs/tutd_tutorial.markdown) command line interface directly:

```
nix run github:diverge-Inc/m36
```

or the [SQLegacy](docs/sqlegacy.markdown) (SQL dialect) interface:

```
nix run github:diverge-Inc/m36#sqlegacy
```

Upstream also publishes a Docker image (`docker run -it projectm36/project-m36 tutd`) and releases on [Hackage](https://hackage.haskell.org/package/project-m36); those are built from upstream, not from this fork.

## Description

Unlike most database management systems (DBMS), Project:M36 is opinionated software which adheres strictly to the mathematics of the relational algebra. The purpose of this adherence is to prove that software which implements mathematically-sound design principles reaps benefits in the form of code clarity, consistency, performance, and future-proofing.

Project:M36 can be used as an in-process or remote DBMS.

Project:M36 is written entirely in the [Haskell programming language](https://www.haskell.org/).

## Sample Session

```
$ nix run github:diverge-Inc/m36
Project:M36 TutorialD Interpreter 1.2.7
Type ":help" for more information.
TutorialD (master/main): :importexample cjdate
TutorialD (master/main): :showexpr s where gt(@status,15)
┌──────────┬────────┬───────────┬───────────────┐
│city::Text│s#::Text│sname::Text│status::Integer│
├──────────┼────────┼───────────┼───────────────┤
│"London"  │"S4"    │"Clark"    │20             │
│"Paris"   │"S3"    │"Blake"    │30             │
│"Athens"  │"S5"    │"Adams"    │30             │
│"London"  │"S1"    │"Smith"    │20             │
└──────────┴────────┴───────────┴───────────────┘
TutorialD (master/main): :showexpr ((s join sp) where city="London"){sname,p#,qty}
┌────────┬────────────┬───────────┐
│p#::Text│qty::Integer│sname::Text│
├────────┼────────────┼───────────┤
│"P1"    │300         │"Smith"    │
│"P5"    │400         │"Clark"    │
│"P2"    │200         │"Smith"    │
│"P6"    │100         │"Smith"    │
│"P4"    │300         │"Clark"    │
│"P2"    │200         │"Clark"    │
│"P4"    │200         │"Smith"    │
│"P5"    │100         │"Smith"    │
│"P3"    │400         │"Smith"    │
└────────┴────────────┴───────────┘
```

Relations are sets, so tuple order is not significant. The [15 Minute Tutorial](docs/15_minute_tutorial.markdown) walks through more.

## Use-Cases

Project:M36 supports multiple frontends which target different audiences.

* learn about the relational algebra via TutorialD
* use SQLegacy to learn how SQL differs from the relational algebra
* store and manipulate databases
* use Project:M36 as a native Haskell database backend

## Community

These are upstream's community resources.

* [TutorialD for SQL Developers](https://www.udemy.com/course/tutoriald-for-sql-developers/)
  * ask in IRC channel for discount code to get free access
* [Developer's Blog](https://agentm.github.io/project-m36/)
* [Mailing List/Discussion Group](https://groups.google.com/d/forum/project-m36)
* IRC Channel: irc.libera.chat #project-m36 -- [Chat via Web Client](http://kiwiirc.com/nextclient/irc.libera.chat:+6697/#project-m36)
* [Hackage](https://hackage.haskell.org/package/project-m36)
* [Diogo Biazus' Project:M36 Video Tutorial](https://www.youtube.com/watch?v=_GC_lxlVEnE)

## Documentation

### Introductory Materials

1. [Installation and Introduction to Project:M36](docs/introduction_to_projectm36.markdown)
1. [Introduction to the Relational Algebra](docs/introduction_to_the_relational_algebra.markdown)
1. [TutorialD Cheatsheet](docs/tutd_cheatsheet.markdown)
1. [TutorialD via Jupyter Notebook Walkthrough](jupyter/TutorialD%20Notebook%20Walkthrough.ipynb)
1. [TutorialD Tutorial](docs/tutd_tutorial.markdown)
1. [15 Minute Tutorial](docs/15_minute_tutorial.markdown)
1. [Developer's Change Log](Changelog.markdown)
1. [Simple Client API](docs/simple_api.markdown)
1. [CSV Import/Export](docs/import_export_csv.markdown)
1. [Developer Setup](docs/dev_setup.markdown)

### Database Comparisons

1. [ACID Database Properties](docs/acid_assessment.markdown)
1. [On NULL (in SQL)](docs/on_null.markdown)
1. [Reaching "Out of the Tarpit" with Project:M36](docs/reaching_out_of_the_tarpit.markdown)
1. [An Architecture for Data Independence](docs/data_independence.markdown)


### SQL Support

1. [Why SQLegacy?](docs/why_sqlegacy.markdown)
1. [SQLegacy Documentation](docs/sqlegacy.markdown)

### Advanced Features

1. [Role-Based Access Control](docs/role-based_access_control.markdown)
1. [Authentication](docs/authentication.markdown)
1. [Transaction Graph Operators](docs/transaction_graph_operators.markdown)
1. [ProjectM36.Client Library](docs/projectm36_client_library.markdown)
1. [Data Frames for Sorting](docs/dataframes.markdown)
1. [Adding New Data Types](docs/new_datatypes.markdown)
1. [Database-Manipulating Functions](docs/database_context_functions.markdown)
1. [Serving Remote ProjectM36 Databases](docs/server_mode.markdown)
1. [Using Notifications](docs/using_notifications.markdown)
1. [Merge Transactions](docs/merge_transactions.markdown)
1. [Atom (Value) Functions](docs/atomfunctions.markdown)
1. [Trans-Graph Relational Expressions](docs/transgraphrelationalexpr.markdown)
1. [Isomorphic Schemas](docs/isomorphic_schemas.markdown)
1. [Replication](docs/replication.markdown)
1. [Basic Operator Benchmarks](docs/basic_benchmarks.html)
1. [Merkle Transaction Hashes](docs/merkle_transaction_graph.markdown)
1. [Handling DDL Changes](docs/Handling_DDL_Changes.markdown)
1. [Importing a Haskell Module](docs/import_haskell_module.markdown)
1. [TutorialD Inline with Haskell](docs/inline_tutoriald.markdown)

### Integrations

1. [WebSocket Server](docs/websocket_server.markdown)
1. [Jupyter Notebook Kernel](docs/jupyter_kernel.markdown)
1. [Persistent Driver](https://github.com/YuMingLiao/persistent-project-m36)

## Development

Project:M36 is developed in Haskell. Upstream supports GHC 9.4 – 9.10 via cabal or stack (see [Developer Setup](docs/dev_setup.markdown)); this fork is built and tested with Nix on nixpkgs' default GHC.

### Nix flake

This repository is a Nix flake built with [haskell-flake](https://github.com/srid/haskell-flake). It follows the default GHC of nixpkgs-unstable (`pkgs.haskellPackages`, currently GHC 9.10), so most dependencies and `haskell-language-server` come from the public binary cache.

Development environment (GHC with all dependencies, `cabal-install`, `haskell-language-server`, `ghcid`):

```
nix develop            # or `direnv allow` to load it automatically via .envrc
cabal build
```

Run or build without cloning:

```
nix run github:diverge-Inc/m36            # tutd
nix run github:diverge-Inc/m36#project-m36-server
nix build github:diverge-Inc/m36          # library and executables (runs the test suites)
```

Use it from a haskell-flake project. Importing the exported project module brings in `project-m36` together with the dependency overrides it needs:

```nix
# flake.nix
inputs.project-m36.url = "github:diverge-Inc/m36";

# perSystem
haskellProjects.default = {
  imports = [ inputs.project-m36.haskellFlakeProjectModules.output ];
};
```

Without haskell-flake, use `legacyPackages.${system}.haskellPackages` (nixpkgs' `haskellPackages` with `project-m36` and the same overrides) for the library, or `overlays.default`, which adds the executables as `pkgs.project-m36`.

Dependency policy: Haskell dependencies come from nixpkgs as-is, and the bounds in `project-m36.cabal` are written to accept those versions (for example, streamly 0.10 and 0.11 are both supported). `nix/dependencies.nix` only contains what third-party packages need to build on nixpkgs: a few loosened upper bounds (no blanket jailbreaks), one source patch, and a pinned TLS stack that `curryer-rpc` actually requires. `cabal.project` mirrors the same loosened bounds for non-Nix builds. When updating nixpkgs (`nix flake update`), check whether any of these can be dropped.

## Related Projects

* [The Third Manifesto](http://thethirdmanifesto.com/): the philosophical basis for relational algebra engines
* [Rel](http://reldb.org/): a TutorialD implementation against a BerkeleyDB backend
* [Andl](http://andl.org/): a new database language with SQLite and PostgreSQL backends
* [Coddie](https://github.com/scvalencia/Coddie): a python-based relational algebra interpreter

## Suggested Reading

* [Out of the Tarpit](https://github.com/papers-we-love/papers-we-love/blob/2eb8d21/design/out-of-the-tar-pit.pdf): a proposed software architecture which minimizes state and complexity. Project:M36 implements the requirements of this paper.
* [Database Design & Relational Theory: Normal Forms and All That Jazz](http://shop.oreilly.com/product/0636920025276.do): mathematical foundations for the principles of the relational algebra
* [Database Explorations: Essays on the Third Manifesto and Related Topics](http://bookstore.trafford.com/Products/SKU-000177853/Database-Explorations.aspx): additional essays and debates on practical approaches to relational algebra engine design
