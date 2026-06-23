<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# Converge Default-Template Name Search — Design

**Status:** Approved (design) — not yet planned/implemented
**Date:** 2026-06-22
**Author:** David W. Thomas (with Claude)
**Slice:** Cleanup — converge the duplicated template name-search walk in
`graphdb_class`

## Background

`graphdb_class` carries the template name-search walk **twice**, verbatim:

- `do_find_template_by_name/2` — the gen-server form. Opens its own
  transaction via `graphdb_mgr:transaction/1`, takes a generic `Name`, and
  swallows a read error as `not_found`. Internal-only; called by
  `do_add_template/2` (duplicate-name guard) and `do_default_template/1`
  (default-template lookup).
- `default_template_in_txn/1` — the tier-1 in-transaction form added in the
  atomic-`add_relationship` PR 1 (`ad030f6`). Runs inside a caller's mnesia
  activity (no own transaction) and hardcodes `?DEFAULT_TEMPLATE_NAME`.
  Exported; called by `graphdb_instance` (line ~1314) and covered by three
  direct CT cases.

Both contain the identical core:

```erlang
Children = downward_children_by_arc(ClassNref, ?ARC_CLS_CHILD, composition),
lists:search(fun
    (#node{kind = template} = N) -> template_has_name(N, Name);
    (_)                          -> false
end, Children)
```

The duplication was sanctioned project precedent at the time (the tier-1
twins were deliberately near-verbatim copies of their gen-server originals,
mirroring the ancestry-walk twins). This slice converges the *name-search*
pair now that both copies have settled, and was tracked as the deferred
"Converge default-template name search" item in `TASKS.md`.

## Goal

Remove the duplicated walk by extracting one shared tier-1 in-transaction
primitive, funnelling both existing functions through it, and exposing the
primitive for future cross-module use (e.g. `mutate/1`). No externally
observable behaviour changes.

## The shared primitive

Extract the core into a new tier-1 in-transaction primitive and **export**
it alongside the other tier-1 primitives:

```erlang
%% find_template_by_name_in_txn(ClassNref, Name) -> {ok, Nref} | not_found
%%
%% Tier-1 in-transaction primitive.  Assumes it runs inside an active mnesia
%% activity; reuses the bare-mnesia downward_children_by_arc/3 and
%% template_has_name/2.  Returns the kind=template child of ClassNref whose
%% class NameAttrNref (19) value equals Name, or not_found.
find_template_by_name_in_txn(ClassNref, Name) ->
    Children = downward_children_by_arc(ClassNref, ?ARC_CLS_CHILD, composition),
    case lists:search(fun
            (#node{kind = template} = N) -> template_has_name(N, Name);
            (_)                          -> false
        end, Children) of
        {value, #node{nref = Nref}} -> {ok, Nref};
        false                       -> not_found
    end.
```

It joins `get_template_in_txn/1`, `class_in_ancestry_in_txn/2`, and
`default_template_in_txn/1` in the exported tier-1 group: bare mnesia ops,
no own transaction, composes into a caller's single transaction.

## The two existing functions funnel through it

```erlang
default_template_in_txn(ClassNref) ->
    find_template_by_name_in_txn(ClassNref, ?DEFAULT_TEMPLATE_NAME).

do_find_template_by_name(ClassNref, Name) ->
    case graphdb_mgr:transaction(fun() ->
            find_template_by_name_in_txn(ClassNref, Name)
        end) of
        {ok, {ok, Nref}} -> {ok, Nref};
        {ok, not_found}  -> not_found;
        {error, _}       -> not_found
    end.
```

`do_default_template/1` and `do_add_template/2` are unchanged callers of
`do_find_template_by_name/2`. There is no double-wrapping:
`default_template_in_txn/1` calls the primitive directly (already in a
caller's txn); `do_find_template_by_name/2` opens exactly one txn around it.

## Behaviour preservation

- `default_template_in_txn/1` returns the identical `{ok, Nref} | not_found`
  and still aborts the enclosing transaction on a mnesia read error — its
  body is simply the extracted primitive with `?DEFAULT_TEMPLATE_NAME`.
- `do_find_template_by_name/2` keeps its own single transaction and its
  `{error, _} -> not_found` swallow. `graphdb_mgr:transaction/1` maps
  `{atomic, R} -> {ok, R}`, so the fun's `{ok, Nref}` / `not_found` surface
  as `{ok, {ok, Nref}}` / `{ok, not_found}` and map back to the same
  `{ok, Nref}` / `not_found` the function returns today.
- Name matching (class NameAttrNref 19 via `template_has_name/2`), the
  `kind = template` filter, and `downward_children_by_arc/3` traversal are
  byte-identical to both originals.

## Out of scope

- `do_templates_for_class/1` — lists *all* template children with no name
  match. A different operation; left alone.
- `do_default_template/1` — a thin identity wrapper over
  `do_find_template_by_name/2`, not part of the duplicated walk. Left alone.
- Any change to `graphdb_instance`, `graphdb_mgr`, or the schema.

## Testing

- **Existing template tests pass unchanged** — the behaviour-preservation
  proof. This includes the three `default_template_in_txn_*` CT cases and the
  gen-server `default_template` / `add_template` cases.
- **Three new CT cases** in `graphdb_class_SUITE` for the newly exported
  primitive, invoked via `graphdb_mgr:transaction/1` (so results read as
  `{ok, {ok, Nref}}` / `{ok, not_found}`):
  1. found-by-name — a named template child (e.g. `"biological"`) resolves to
     its nref, distinct from the auto-created default template;
  2. discriminates-by-name — searching the same class for `"default"` resolves
     to the default template nref, proving the name selects the right template
     rather than returning first-match;
  3. name-not-found — an absent name resolves to `not_found`.

  The `kind = template` guard's reject branch is unreachable through the
  public API (composition children of a class with arc 26 are templates by
  construction; subclasses attach via a taxonomy arc and are filtered out by
  `downward_children_by_arc/3`'s `composition` kind filter before the guard
  runs). The guard stays in the code for behaviour preservation but is not
  exercised by an artificial injected-state test; a reject-branch test would
  be added if a future caller (e.g. `mutate/1`) ever makes non-template
  composition children reachable.

## Docs

- `apps/graphdb/CLAUDE.md` — add `find_template_by_name_in_txn/2` to the
  tier-1 in-transaction primitive bullet for `graphdb_class`.
- `TASKS.md` — flip the "Converge default-template name search" bullet to
  IMPLEMENTED.
- `docs/Architecture.md` — untouched (internal refactor; public contract and
  inheritance algorithm unchanged).
