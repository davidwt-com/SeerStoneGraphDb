# Project/Environment Separation — SP1: Reference & Namespace Model

**Status:** Design (approved for planning)
**Date:** 2026-06-29
**Scope:** Sub-project 1 of the project/environment separation program.

## 1. Context — why this exists

The codebase documents a two-database architecture (a shared **environment**
/ ontology, and per-project **instance spaces**) but implements a single
physical Mnesia store: one `nodes` table, one `relationships` table, one
allocator (`graphdb_nref`, runtime tier ≥ `?NREF_START`). Instances allocate
from the same environment runtime tier as everything else. The "project
database, allocator from 1" and "`target_kind` routes `target_nref` to
environment-or-project" descriptions were never implemented — `target_kind`
today is *validation* (`check_target_kind` confirms a target's `kind` matches
the arc label), not *routing*.

Consequence: a bare integer nref carries no database identity. This is
harmless while there is one store, but it is a latent correctness defect —
the moment a project namespace begins at 1, project-5 and environment-5
collide as the same primary key, and `check_target_kind` reads the wrong
node.

### Driving reasons for real separation

1. **Isolation** of instance knowledge-bases — commercial, private,
   restricted-access groups, domains, privacy.
2. **Scale** — the universal volume of instances precludes one database for
   all; projects partition by domain.
3. **Physical location / residency** — a project's physical home is governed
   by (1) and (2): a company's own data center isolated from the world, a
   family project isolated for privacy, etc.

These point at **hard physical separation**: each project is its own database,
on its own node, potentially in its own data center, isolated from every
other project and from the public world. The only shared artifact is the
global **environment** ontology (categories, attributes, classes,
arc-labels).

### Program decomposition

This is a distributed, multi-tenant, data-residency architecture — too large
for one spec. It decomposes into four sub-projects, each its own
spec → plan → build cycle:

| #   | Sub-project                     | Establishes                                                                                                                            |
| --- | ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | **Reference & namespace model** | Every nref field has a declared namespace; resolution is total and explicit; a project-session surfaces in the API. *(this spec)*      |
| 2   | **Physical project store**      | Separate Mnesia table set / schema per project; per-project allocator from 1; session binds to a project.                              |
| 3   | **Distribution & residency**    | Projects on separate nodes / locations; environment reachability or replication at each location; air-gap and access-control boundary. |
| 4   | **Migration**                   | Move existing instances out of the shared environment tables into project storage; reassign their nrefs.                               |

This spec covers **SP1 only**.

## 2. Goal and guiding constraint

Establish, **at the API/code layer only**, that every nref reference has a
well-defined namespace and is resolved correctly — so the codebase stops
assuming a single global nref space.

**Guiding constraint: no `node` / `relationship` record changes.** The
namespace of every reference is derivable from context (field role, plus the
arc-label's `target_kind` for the one polymorphic field). A reference whose
namespace is *not* derivable from context would be the only "valid reason" to
revisit the records — none has surfaced.

SP1 is **behavior-preserving against today's single store**: it installs the
resolution seam and the project-session that SP2+ give physical teeth.
"Project-local" resolves to today's tables until SP2 exists; the *contract* is
correct from day one.

## 3. Namespace is a binary, derived not stored

Every structural (graph-traversable) nref field resolves to exactly one of
`{environment, current-project}`. The namespace is determined by the field's
**role**, plus the arc-label's `target_kind` for the single polymorphic field
(`target_nref`).

### Field-role namespace map

| Field                                                        | Namespace                                                                                                             |
| ------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------- |
| `node.nref`                                                  | the node's own DB — environment node → environment; instance → project-local                                          |
| `node.classes`                                               | environment (instances point at environment class nodes)                                                              |
| `node.parents` — compositional                               | project-local (instance part-of instance)                                                                             |
| `node.parents` — taxonomy                                    | environment (class / attribute is-a)                                                                                  |
| `relationship.characterization`                              | environment (arc label) — always                                                                                      |
| `relationship.reciprocal`                                    | environment (arc label) — always                                                                                      |
| `relationship.target_nref`                                   | **routed** by the arc-label's `target_kind`: `instance` → project-local; `category`/`attribute`/`class` → environment |
| `relationship.source_nref`                                   | the row's home DB                                                                                                     |
| AVP `attribute` keys                                         | environment — always                                                                                                  |
| AVP values that are nrefs (e.g. template, `reciprocal_nref`) | environment, per the attribute's definition                                                                           |

This table is authoritative. The resolution seam (§7) is the code expression
of it.

## 4. Cross-project links are indirected, never structural

Projects *can* relate to other projects, but **never via a direct structural
reference**. A cross-project link is an ordinary in-project arc to a **local
proxy node**. The proxy carries the remote coordinates as **AVP payload**, not
as a traversable reference:

| AVP              | Meaning                                                                                         |
| ---------------- | ----------------------------------------------------------------------------------------------- |
| `remote_project` | environment nref of the target project's registry node under nref 5                             |
| `remote_nref`    | the target node's integer **in that project's space** — payload, meaningful only on dereference |

Because the remote coordinates are *data* (AVP values already accept arbitrary
terms), no structural field ever crosses a project boundary and the
`{environment, current-project}` binary holds. The "tree rooted at a
remote-project node with proxy descendants" is an organizational pattern
layered on this one primitive — not a separate mechanism.

### Proxy representation

A proxy is a regular **instance** node that is a member of a new
environment-seeded class **"Remote Reference"** (under Classes, nref 3).
**No new `kind` atom; no record change.**

### Proxy — SP1 scope boundary

SP1 defines the proxy **representation contract** only — what a proxy node is
and what AVPs it carries. **Proxy-creation API and dereference are deferred**:
they are meaningless without remote access (SP2/SP3). See §9.

## 5. Project identity

A project is identified by a **registry node under the environment `Projects`
category (bootstrap nref 5)**. Project identity *is* that environment nref.

For SP1, registration under nref 5 is **mandatory and public**. Private
*environment overlays* that hide a project's registry node (the overlay
mechanism already used for languages, applied to project privacy) are a
deferred future direction.

## 6. Project session

A project op travels with a **project-session value**, because the workers
(`graphdb_mgr`, `graphdb_instance`, …) are shared singleton gen_servers
serving every caller: "current project" cannot be ambient worker state, and a
caller-side process dictionary would not reach the worker. The binding **must
travel as data on the call.**

`open_session(ProjectNref)` validates the registry node exists under nref 5
and returns an **opaque project-session value** — a plain value, not a process
(it runs in the caller's process, consistent with the transaction seam).

Today the value wraps essentially `#{project => Nref}`. It is the **single
growth point** where SP2/SP3 attach a connection handle, access context,
snapshot, and residency information **without signature churn**. It rhymes
conceptually with the `graphdb_query` session; unification with that session
is deferred, not assumed.

## 7. Resolution seam

A single resolution primitive expresses the field-role map (§3): given a
session and a field role (plus `target_kind` for `target_nref`), it reads from
the correct store. Against today's single store it always resolves to the one
table set — the seam is **behavior-preserving** but is the **correctness
boundary** SP2 fills in. No structural code outside the seam should assume a
global nref space.

`graphdb_ns` is **intentionally unused by production code in SP1**: it is the
pure *classifier* that the SP2 store-router will consume. Shipping it now fixes
the namespace contract as a testable unit (exhaustive table-driven tests over
§3) before the router exists — it is not dead code.

The per-operation session gate (`graphdb_project:require_session/1`) is
**shape-only**: it accepts any well-formed `#{kind := project_session, …}`
value, including one naming a project that no longer exists. Registry-existence
is validated once by `open_session/1`; re-checking it on every operation would
cost a store read per call for no SP1 benefit (the session is inert). SP2, when
the session binds to physical storage, is the natural point to revisit this.

## 8. Environment-op vs project-op split

The env/project line decides which APIs take a session:

| Operates on                       | Examples                                                                                                                                                                              | Project session?           |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------- |
| **Environment (shared ontology)** | `create_attribute`, `create_class`, `add_qualifying_characteristic`, taxonomy/composition arcs *between classes or attributes* (parent/child), `create_*_rule`, language registration | No — environment context   |
| **Project (instance space)**      | `create_instance`, compositional hierarchy, class membership, **connection** arcs among instances, slice-E `remove_relationship` / `update_relationship` on those connection arcs     | Yes — bound to one project |

A project op reads environment nodes freely; it just cannot *write* the shared
ontology through a project session.

### Relationship-mutation relocation

Relationship mutation currently lives in `graphdb_instance`, but
taxonomy/composition arcs on classes and attributes are relationships too.
Mutation **splits along the env/project line, not under "instance"**:
taxonomy/composition arc mutation is an environment op; connection-arc
mutation (slice E) is a project op.

*Recommended placement:* keep tier-1 in-transaction primitives where they are;
reorganize the **public, session-threaded** surface along the env/project
split. Precise module layout is settled in the implementation plan.

## 9. Scope boundary

**SP1 delivers:**

- the namespace resolution contract + field-role map (§3, §7);
- the project-session value + `open_session` (§6);
- session-threading of project-side APIs (§8);
- the proxy-node representation contract (§4);
- the environment/project API reorganization, including relationship-mutation
  relocation (§8).

**SP1 does *not* deliver** (later sub-projects):

- physical project storage / separate table set per project (SP2);
- per-project allocator from 1 (SP2);
- proxy-node creation API and remote dereference (SP3);
- distribution / residency / environment replication (SP3);
- migration of existing instances out of the shared tables (SP4).

## 10. Deferred open questions

- **Proxy explosion / federation vs materialization** — what happens when a
  significant fraction of a remote project is proxied locally (volume,
  staleness, sync). A dereference/federation concern, SP2–SP3.
- **Private environment overlays** — a private overlay containing a project's
  registry node under nref 5; the language-overlay mechanism applied to
  project privacy.
- **Session unification** — whether the project-session and the
  `graphdb_query` session converge into one concept.
