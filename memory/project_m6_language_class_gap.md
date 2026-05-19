---
name: project-m6-language-class-gap
description: M6 plan is missing seeding of the Language superclass hierarchy under Classes (nref 3) — ARCHITECTURE §10 specifies it but the plan doesn't implement it
metadata:
  type: project
---

M6 plan gap identified before implementation began. Two items deferred:

**Gap 1 — Language superclass hierarchy (blocks M6 plan completeness)**

`graphdb_language:init/1` in the plan does not seed a `Language` superclass node under Classes (nref 3). ARCHITECTURE §10 specifies: "The abstract concepts — 'Human Language', 'Dialect', 'Grammar Rule', 'Word', 'Token', 'Syntax Rule' — are class nodes in the ontology under a `Language` superclass seeded at runtime under `Classes` (nref 3)."

Currently `lang_human` is a direct child of Classes (3) in bootstrap.terms — there is no `Language` superclass above it. The fix is either:
- Option A: Update bootstrap.terms to add `Language` as a bootstrap node and make `lang_human` a subclass of it (clean but requires bootstrap change).
- Option B: Seed `Language` at M6 init time and call `graphdb_class:add_superclass(lang_human_nref, language_nref)` to place `lang_human` under it.

Decision on which option was deferred before implementation.

**Gap 2 — Connection arcs to subcategory nodes (nrefs 32–35) — deferred**

ARCHITECTURE §10: "Domain membership is recorded by a lateral connection arc from each language class node to the appropriate subcategory (e.g., English → Human Languages, nref 32)." These are template-scoped CONNECTION arcs (char 31). Template infrastructure is not yet implemented. Cannot land in M6. The bootstrap.terms comment on English (10000) confirms this is deferred.

**Why:** Bootstrap.terms carries the note `(b) composition arc to Human Languages category (nref 32) — requires` (cut off, referring to template infrastructure).

**How to apply:** Before starting M6 Task 2 implementation, decide Option A vs B for the Language superclass and update the plan accordingly. Connection arcs remain deferred regardless.
