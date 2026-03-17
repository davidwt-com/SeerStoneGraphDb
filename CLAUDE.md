# SeerStoneGraphDb — Project Guide

## Project Background

This is a **distributed graph database** written in Erlang, originally authored by Dallas Noyes (SeerStone, Inc., 2008). Dallas passed away before completing the project. The goal is to finish and extend his work. PRs are welcome. Treat this codebase with care — preserve Dallas's style and conventions wherever possible when completing NYI stubs.

## Language & Runtime

- **Erlang/OTP** — uses the OTP application and supervisor behaviours throughout
- No build system is currently configured (no `rebar.config`, `erlang.mk`, or `Makefile`)
- Compiled `.beam` files are checked in alongside `.erl` source — when making changes, recompile manually: `erlc FileName.erl`
- Compile from the shell: `erl -make` (requires `Emakefile`) or `erlc *.erl`
- Start the top-level application: `application:start(seerstone).`

## Directory Structure

```
SeerStoneGraphDb/
├── seerstone.erl          # Top-level OTP application callback
├── seerstone_sup.erl      # Top-level supervisor (starts database_sup)
├── seerstone.app          # OTP application resource file (binary)
├── dev_lib.erl            # Dev utilities: trace_module/2, dump/2
├── priv/
│   └── default.config     # Runtime config: app_port, data_path, index_path
├── log/                   # Log output directory
├── Database/              # `database` OTP application (includes graphdb + dictionary)
├── graphdb/               # `graphdb` OTP application (the graph database)
├── Dictionary/            # `dictionary` OTP application (ETS/file-backed key-value store)
└── Nref Server/           # `nref` OTP application (globally unique node reference IDs)
```

## OTP Supervision Tree

```
seerstone (application)
  └── seerstone_sup (supervisor, one_for_one, MaxR=5, MaxT=5000)
        └── database_sup (supervisor — child of seerstone_sup)
              └── [graphdb_sup, dictionary_sup]  ← to be confirmed/completed

nref (application — separate, started independently)
  └── nref_sup (supervisor)
        └── nref_allocator  (DETS-backed block allocator)
        └── nref_server     (serves nrefs to callers; client of nref_allocator)
        └── nref_include    (purpose TBD)
```

## Common Coding Conventions

### NYI / UEM Macros (in every module)
```erlang
-define(NYI(X), (begin
    io:format("*** NYI ~p ~p ~p~n",[?MODULE, ?LINE, X]),
    exit(nyi)
end)).
-define(UEM(F, X), (begin
    io:format("*** UEM ~p:~p ~p ~p~n",[?MODULE, F, ?LINE, X]),
    exit(uem)
end)).
```
- `?NYI(X)` — marks **Not Yet Implemented** functions; exits with `nyi`
- `?UEM(F, X)` — marks **UnExpected Message** handlers; exits with `uem`
- These macros are copy-pasted into every module (sourced from Joe Armstrong's *Programming Erlang*, p. 424)

### Module File Header Pattern
Every source file starts with:
1. Copyright block (SeerStone, Inc. 2008)
2. Author, Created date, Description
3. OTP behaviour references
4. Revision history (Rev PA1, Rev A)
5. `-module(name).` and `-behaviour(app|supervisor|gen_server).`
6. Module attributes: `-revision(...)`, `-created(...)`, `-created_by(...)`
7. NYI/UEM macro definitions
8. `-export([...]).`

Maintain this structure when adding new modules.

### Naming Conventions
- Application module: `name.erl` (e.g., `graphdb.erl`)
- Supervisor module: `name_sup.erl` (e.g., `graphdb_sup.erl`)
- Worker/server: `name_server.erl` or `name_worker.erl`
- Implementation module: `name_imp.erl` (e.g., `dictionary_imp.erl`)
- Include/header data: `name_include.erl`

## Known Incomplete Areas (NYI)

- `seerstone:start_phase/3`, `prep_stop/1`, `stop/1`, `config_change/3` — all NYI
- `database:start_phase/3`, `prep_stop/1`, `stop/1`, `config_change/3` — all NYI
- `graphdb:start_phase/3`, `prep_stop/1`, `stop/1`, `config_change/3` — all NYI
- `nref_server:get_another_nref_block/0` — **bug**: line 148 calls `allocate_nrefs` as an atom instead of `nref_allocator:allocate_nrefs()`
- `dictionary_imp:start_dictionary/2` — references `sfiles:file_exists/2` which does not exist; `file_exists/2` is defined locally in the same file
- No `.app` source file (only binary) — an `seerstone.app.src` or equivalent should be created
- No build system — rebar3 should be added

## Configuration

`priv/default.config`:
```erlang
[{seerstone_graph_db, [
  {app_port, 8080},
  {data_path, "data"},
  {index_path, "index"}
]}].
```

## Git Workflow

- Main branch: `main`
- Development branch: `develop`
- `erl_crash.dump` and `priv/` are currently untracked; `erl_crash.dump` should be added to `.gitignore`
- `.beam` files are committed — consider moving to a build output directory and gitignoring them once a build system is added

## Storage Technologies Used

| Technology | Used by | Purpose |
|---|---|---|
| DETS | `nref_allocator`, `nref_server` | Persistent disk-based term storage |
| ETS | `dictionary_imp` | In-memory term storage |
| File (ETS tab2file) | `dictionary_imp` | Persistent serialization of ETS tables |
