# Dictionary — Dictionary OTP Application

## Purpose

The `dictionary` application manages **in-memory, file-backed key-value dictionaries** as part of the SeerStone database system. It uses Erlang **ETS** for in-memory storage with **ETS tab2file/file2tab** for persistence. Multiple named dictionary instances can be run concurrently as separate registered processes.

## Files

| File                    | Description                                              |
| ----------------------- | -------------------------------------------------------- |
| `dictionary.erl`        | OTP `application` behaviour callback module              |
| `dictionary_sup.erl`    | OTP `supervisor` callback module                         |
| `dictionary_imp.erl`    | Core implementation: ETS-backed CRUD + process lifecycle |
| `dictionary_server.erl` | gen_server worker stub                                   |
| `term_server.erl`       | gen_server worker stub                                   |

## dictionary_imp — Key API

All dictionary operations are **asynchronous RPC** sent to a named registered process (`Proc_Name`). The process runs a simple `receive` loop (`loop/0`) and dispatches closures.

```erlang
%% Lifecycle
dictionary_imp:start_dictionary(File, Proc_Name) -> ok
dictionary_imp:stop_dictionary(File, Proc_Name)  -> ok
dictionary_imp:delete_dictionary(Type, File)     -> ok

%% CRUD
dictionary_imp:create(Proc_Name, Key)           -> true | false
dictionary_imp:read(Proc_Name, Key)             -> [{Key, Value}] | []
dictionary_imp:update(Proc_Name, Key, Value)    -> true
dictionary_imp:delete(Proc_Name, Key)           -> true

%% Inspection
dictionary_imp:all(Proc_Name)   -> [{Key, Value}]
dictionary_imp:size(Proc_Name)  -> integer()
```

Keys are stored as **binaries** (`list_to_binary(Key)` is applied internally).

## NYI Status

**`dictionary_server.erl` and `term_server.erl`** — both are gen_server stubs not yet
wired to `dictionary_imp`. No `dictionary_imp` functions are called from either server.
Implementing delegation from each gen_server to the relevant `dictionary_imp` functions
is Task 7 in `TASKS-LOW.md`.

**`dictionary.erl` callbacks** — `start_phase/3`, `prep_stop/1`, `stop/1`,
`config_change/3` return `ok` (no-op stubs; correct for current deployment model).

## Process Model

```
start_dictionary(File, Proc_Name)
  → file_exists(File, InitFun)   %% creates ETS file if not present
  → spawn(LoadFun)               %% loads ETS from file, starts loop()
  → register(Proc_Name, Pid)

loop() receives {From, Fun} → Fun(From) → loop()
```

Each dictionary runs as an **independent registered process**. The process name is the atom used as `Proc_Name` in all CRUD calls.

## Shutdown Behaviour

`stop_dictionary/2` flushes ETS to disk via `ets:tab2file/2`, deletes the in-memory table, and exits the dictionary process. This is a clean shutdown that persists state.

`delete_dictionary/2` calls `stop_dictionary/2` if the process is alive, then deletes the file from disk.

## Compile

```sh
# with rebar3 (from project root — preferred):
./rebar3 compile

# manually (from project root):
erlc apps/dictionary/src/dictionary_sup.erl apps/dictionary/src/dictionary_imp.erl apps/dictionary/src/dictionary.erl
```


