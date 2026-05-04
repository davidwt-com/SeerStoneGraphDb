# The Knowledge Network
*Architecture and Design Principles*

---

## Terminology

| Term                       | Meaning                                                                                                                                                                                                        |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Knowledge model**        | The architecture described in this document                                                                                                                                                                    |
| **Ontology**               | The definitional half of the knowledge model: classes, attributes, templates, rules, and languages. Shared across projects.                                                                                    |
| **Project**                | A domain instantiation of some subset of the ontology. Also called the *instance space* — the collection of all concept instances that exist within a specific deployment.                                     |
| **Template**               | A named semantic context defined on a class. Determines which attributes are relevant, how they are expressed, and what connections made through it mean. Not a static blank — an active node in the ontology. |
| **Ingestion map**          | A visual, codeless configuration for migrating records from an external source into the knowledge graph.                                                                                                       |
| **Concept node**           | The universal unit of identity. Every class, attribute, rule, template, instance, and vocabulary entry is a concept node.                                                                                      |
| **Literal attribute**      | An attribute whose value is raw data — a number, string, measurement, or URL — stored directly on a node. Literal values do not participate in graph traversal.                                                |
| **Relationship attribute** | An attribute that characterizes a connection between two nodes. Both directions of a connection carry their own characterization.                                                                              |

---

## 1. Organizing Principle

The foundational claim of this architecture is an inversion of conventional software design:

> *In a conventional system, documents are primary. Knowledge is inferred from them. In this system, only the knowledge is real. Documents are derived from it on demand.*

A field guide entry, a lab report, a data table, and a research abstract are not stored artifacts — they are projections of the same underlying knowledge, rendered differently for different purposes. They are always consistent with each other because they share one source of truth.

---

## 2. The Knowledge Model

The knowledge model has two bodies:

**The ontology** — the definitional knowledge. All classes of things that can exist, their attributes, the rules governing their behavior, the templates through which they are engaged, and the languages in which they are expressed. The ontology is not infrastructure or configuration — it is knowledge. It is live, queryable, and extensible.

**The project** — the instance space. All specific things that exist within a given deployment: instantiated concepts, their values, their compositions, and their connections. A project instantiates *some* of the ontology — the classes relevant to its domain — not all of it. The same ontology can serve multiple projects across unrelated domains.

---

## 3. Concept Nodes and Identity

Every thing the knowledge model knows about — a class, an attribute type, a rule, a template, a vocabulary term, a project instance — is a **concept node**. Every concept node has a unique identity that is stable across the life of the system.

Identity is uniform: ontology nodes and project nodes share the same identity space. A rule stored in the ontology and a specific observed specimen stored in a project are both concept nodes. This uniformity means any part of the knowledge structure can reference any other part.

**Names are labels, not identifiers.** Two instances may share the same name and be distinguished only by their position in the graph and their relationships. A dog named "Fido" owned by one person is a distinct concept node from a dog named "Fido" owned by another — same label, different identity.

**Make searchable things into nodes.** A value stored as raw text on a node cannot be traversed to. A value expressed as a concept node can. If "blue" is a literal value stored on instances, there is no path to "find everything that is blue." If "Blue" is a concept node connected to instances, the query traverses from that node to all of them. This is a consistent design principle: when a value is likely to be searched, navigated to, or connected from, it should be a concept node rather than a literal.

**Abstraction levels point upward.** The knowledge graph is organized in levels of abstraction. Concrete instances reference the class concepts above them; class concepts reference more general concepts above them; the most abstract concepts have no upward references. References always flow from lower to higher abstraction, never downward. This keeps the graph navigable and prevents circular definitional dependencies.

---

## 4. Three Kinds of Nodes

Not all concept nodes serve the same role. Three kinds are distinguished:

**Class nodes** — defined in the ontology. A class groups all instances that share the same attributes. Each class carries a class name attribute (what distinguishes this class from its siblings) and an instance name attribute (how instances of this class are named). Every attribute that instances may have must be defined at the class level; subclasses and instances inherit from there.

*Test: "X is a [concept]" must be grammatically and semantically valid. "Blue is a color" passes — Blue is a subclass or instance of Color. "Color is a blue" fails — Color is not a subclass of Blue.*

**Instance nodes** — defined in the project. An instance is a concrete member of a class, existing within a specific project. It has a name (via its name attribute), a class membership, a position in the composition tree, and connections to other instances.

*Test: "X is a part of Y" must make sense. "A nucleus is a part of a cell" passes. "Mammal is a part of a cell" fails — Mammal is a class, not a part.*

**Attribute nodes** — defined in the ontology. Three types:

| Type                       | Role                                                                                                       |
| -------------------------- | ---------------------------------------------------------------------------------------------------------- |
| **Name attribute**         | Provides the human-readable label for a class or instance                                                  |
| **Relationship attribute** | Characterizes a connection between nodes; grouped into relationship types                                  |
| **Literal attribute**      | Carries raw data directly — measurements, numbers, strings, URLs — without participating in graph topology |

The distinction between relationship attributes and literal attributes is architecturally significant. A relationship attribute connects this node to another node, enabling traversal. A literal attribute stores a value that is data about the node, not a path to another concept. Temperature readings, mass measurements, and file paths are literals. "orbits," "is a parent of," and "catalyzes" are relationship attributes.

---

## 5. Four Relationship Types

Relationships between concept nodes are strictly typed. Four types exist:

**Taxonomy (IS-A)** — A concept may be declared a specialization of one or more parent concepts, inheriting all attributes and constraints from every parent. Multiple inheritance is supported natively. A concept may have any number of generalizations simultaneously.

*Example: Golden Retriever IS-A Dog IS-A Mammal IS-A Animal. Golden Retriever inherits every attribute defined at every level above it.*

**Composition (PART-OF)** — Instances are organized into a containment tree. This tree is explicit and queryable, not inferred from attribute values.

*Example: a Nucleus is part of a Cell; the Cell is part of a Tissue; the Tissue is part of an Organ. Creating that hierarchy in the knowledge graph makes every level of it independently queryable.*

> **IS-A and PART-OF are perpendicular.** Taxonomy (IS-A) organizes concept definitions; composition (PART-OF) organizes instances into assemblies. They are independent structures that intersect only at the point where an instance declares its class membership. A common modeling error is mirroring one hierarchy with the other — a class hierarchy does not need to mirror, and should not be confused with, a compositional hierarchy.

**Connection (ASSOCIATE)** — Lateral associations between instances that are not hierarchical. Three properties distinguish connections from both taxonomy and composition:

*Reciprocal* — every connection between two nodes is stored from both directions. The characterization may differ: from one node it reads "orbits"; from the other, "is orbited by." From one it reads "catalyzes"; from the other, "is catalyzed by." Both characterizations are first-class and independently queryable.

*Template-scoped* — every connection is scoped by the template context in which it was made. The template context is recorded as part of the connection's identity permanently. This prevents semantic conflation by design. A Star and a Planet connected through an orbital template (gravitational binding — period, semi-major axis, eccentricity) and connected through a photometric template (illumination — flux, albedo, phase angle) are two distinct relationships between the same two concepts. Querying one does not return the other.

*Metadata-capable* — each direction of a connection may carry per-arc metadata: provenance, confidence scores, weights, validity time frames, and flags such as inferred or verified. This metadata is per-direction and asymmetric — each node stores its own copy of the arc's metadata independently of the other end. Arc metadata does not inherit and does not participate in graph traversal by default.

*Example: a researcher asserts that Compound A inhibits Enzyme B. The connection carries: characterization "inhibits" (from A) and "is inhibited by" (from B), plus metadata: source = "Smith et al. 2019", confidence = 0.87, asserted_by = "automated-pipeline". A second researcher disputes it: confidence is updated; the original provenance is preserved.*

**Instantiation (IS-INSTANCE-OF)** — The link from a project instance to its class or classes in the ontology. A single instance may belong to multiple classes simultaneously.

*Example: a specific observed object may be classified simultaneously as a Dwarf Planet and a Kuiper Belt Object — two classes, one instance.*

---

## 6. Inheritance

When a value is needed for an attribute on an instance, the system resolves it through a defined priority order. Earlier steps take precedence; later steps apply only for attributes not yet resolved:

1. **Local value** — a value set directly on this instance. Highest priority; overrides everything.
2. **Class-bound value** — a value explicitly set at the class level (applies to all instances of that class unless overridden locally).
3. **Compositional ancestor value** — a value inherited up the PART-OF chain, from parent to grandparent, unbroken.
4. **Directly connected node value** — a value inherited from a node connected by a relationship attribute, one level deep. Lowest priority.

This priority order means local specificity always wins. A value set on an instance is never silently overridden by a class definition or an ancestor. A value set at the class level applies uniformly until an instance overrides it.

**Multiple inheritance carries risks.** When an instance belongs to more than one class, or sits under more than one compositional parent, conflicts can arise:

- Two parent classes may define the same attribute with different bound values — resolution requires an explicit local value on the instance.
- Multiple class membership often signals a missing superclass or a modeling error; if an instance genuinely belongs to two unrelated classes, examine whether those classes share a common generalization.
- Multiple compositional parents create ambiguity about ownership and make inherited values from ancestors unpredictable.

Multiple inheritance is valid when the domain clearly demands it. When used, the justification should be explicit and the conflict resolution (always a local value) should be deliberate.

---

## 7. Templates

A **template** is a named semantic context defined on a class in the ontology. It is not a blank form waiting to be filled — it is an active node in the ontology that determines:

- Which attributes of the class are relevant in this context
- How those attributes are expressed and constrained
- What connections made through it mean — and permanently record

The same class may have multiple templates. A Star, for example, has a spectroscopic template (spectral class, luminosity, characteristic wavelengths), an astrometric template (position, distance, proper motion, parallax), and a photometric template (apparent magnitude, color index, variability). Each is a different engagement with the same concept. Viewing a star through its spectroscopic template and through its astrometric template produces different projections of the same underlying knowledge — not different data, and never inconsistent with each other.

The connection-scoping role of templates is architecturally load-bearing. When two instances are connected through a template, that template context becomes part of the connection's identity. The connection knows not just *what* is connected to *what*, but *in what context* that connection exists and what it means. This is what makes it possible to have multiple semantically distinct connection types between the same pair of concepts without conflation.

Templates are the mechanism through which the "derive any document" capability works: a different template over the same knowledge produces a different projection — a different document, always consistent with all others because the knowledge underneath is independent of documents and templates.

---

## 8. Rules as Stored Data

Instantiation rules, connection constraints, composition rules, and template rules are stored as typed data in the ontology — not compiled into the system. The rule engine reads and interprets them at runtime.

This is what makes domain configuration possible without modifying the kernel. A new domain is a new ontology. The same underlying system serves any domain that can be expressed as a knowledge network. All domain-specific behavior lives in the ontology; the kernel contains no domain knowledge.

---

## 9. Instantiation Engine

When a new instance is created from a class, the engine executes a rule-driven process to populate its attributes. Two modes:

**Guided** — the engine presents valid options to the user one attribute at a time, using ontology rules to constrain choices at each step.

**Automatic** — values are derived entirely from existing knowledge without user interaction.

The mode is determined by the ontology, not by the kernel.

---

## 10. Composition Rules

Two rule types in the ontology fire automatically at instance creation:

**Component children** — a class definition declares which component types are natural constituents. On creation, the system proposes or automatically creates those components. The kernel knows only that composition rules exist; the domain knowledge lives in the ontology.

*Example: a class definition for Cell declares Nucleus, Cell Membrane, and Mitochondria as natural constituents. Creating a new Cell instance automatically proposes all three. If the definition later adds Ribosome as a required constituent, no code changes — only an ontology update.*

**Mandatory connections** — a class definition can require that a new instance be connected to an instance of a specified class before creation is complete.

Both rule types are data in the ontology. Adding a new required component type to a class requires no code change — only an ontology update.

---

## 11. Reactive Learning

The system observes user behavior and builds rules from it. This is one of the most architecturally significant capabilities: the ontology grows from use, not only from explicit authoring.

**Naming convention learning** — When an attribute value is set on an instance, the system searches all other attribute values on the same instance for substring matches. If the new value contains substrings that correspond to values of other attributes, the system encodes that naming convention as a class-level rule in the ontology. Future instances of the same class have the attribute populated automatically.

*Example: a researcher records a specimen identifier "Canis_lupus_042" on an instance that already has genus "Canis" and species "lupus" as separate attributes. The system detects that the identifier is composed of those two values plus a sequence number and encodes the pattern. The next specimen of the same class is offered the identifier automatically, with only the sequence number to confirm.*

**Connection pattern learning** — When a connection is made between two instances, the system records which classes were connected via which template and connection type. Accumulated observations become connection rules in the ontology that guide or constrain future connections of the same kind.

Rules are not only authored — they are inferred from practice and stored permanently. The ontology is not a static configuration; it is an accumulating body of encoded knowledge.

---

## 12. Views

The knowledge graph supports multiple rendered views simultaneously; the following are representative examples. Switching views changes the rendering; the underlying knowledge is unchanged.

- **Tree view** — hierarchical browser of taxonomy and composition
- **Schematic view** — diagram-style rendering; schematic types are themselves template-driven
- **Template view** — attribute editor for a single instance through a specific template
- **Gallery view** — spatial arrangement of instances as icons
- **Natural language query** — text-based query interface

---

## 13. Query

The query interface accepts natural-language expressions over the knowledge graph. The intent is conversational: ask a question about the knowledge, get an answer — without knowing how the graph is structured or writing a formal query. Examples of what queries can express:

- Navigate to a concept by name or by class membership
- Evaluate expressions involving quantities, with units tracked through the calculation
- Ask multi-criteria questions spanning class membership, attribute values, and connections

These are possibilities, not a complete definition. Any question expressible about the knowledge in the graph should be askable at this interface.

---

## 14. Ingestion

### 14.1 Ingestion Maps

Any flat-file or relational database can be mapped into the knowledge graph without writing code. The user builds an **ingestion map** — a visual configuration of how source records become concept nodes. Each node in the map specifies whether to create a new instance, locate an existing one, add a class to an existing node, or search by value. A pattern language extracts substrings from source field values to populate concept attributes.

Conditional rules govern whether each mapping node fires, allowing selective or differential ingestion. Cross-source relationships are formed during the ingestion process by map nodes that locate instances created from a different source file.

*Example: nine astronomical catalogs, each maintained independently by different observatories and using different identifier schemes for the same objects, were consolidated into a single knowledge network via an ingestion map. Cross-catalog relationships — the same star appearing under different designations in different catalogs — were resolved and connected at ingestion time without writing code.*

### 14.2 External File Learning

Files on disk become first-class concept nodes. Directory trees are walked; file content is analyzed; words are matched to existing knowledge concepts; connections are created. External documents become queryable as part of the knowledge graph.

*Example: research papers, images, and datasets stored as files are ingested and connected to the concepts they discuss. Asking "show all files connected to Jupiter" returns observation logs, spectral data files, and published papers automatically — because the connections were built from content, not from manual tagging.*

### 14.3 Drawing Recognition

Schematic drawings can be imported and their symbols recognized automatically. Patterns defined in the ontology match graphical elements to concept classes, auto-creating corresponding knowledge nodes from the drawing geometry without manual symbol mapping.

---

## 15. Multilingual Support

Concepts are stored language-neutrally in the ontology. Labels, prompts, and vocabulary entries are stored per language and swapped at rendering time without modifying the knowledge. The same knowledge graph produces output in any configured language.

*Example: the concept of water is stored once. In English it is labeled "water"; in German, "Wasser"; in French, "eau". The knowledge — its molecular composition, its physical properties, its relationships to other concepts — is identical across all languages. Changing the output language changes labels only.*

---

## 16. Architectural Differentiators

| Concept                                     | Assessment                                                                                                     |
| ------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| Template-scoped connections                 | **Architecturally novel** — prevents semantic conflation by design; not a standard graph model feature         |
| Reciprocal connection characterization      | **Consistent and principled** — both directions of every connection are named and queryable                    |
| Per-arc relationship metadata               | **Extends expressiveness** — provenance, confidence, and time validity live on the arc, not on a separate node |
| Reactive learning from observed use         | **Novel** — the ontology accumulates rules from practice                                                       |
| Ingestion maps                              | **Practical and novel** — visual, codeless migration from any external source                                  |
| Document derivation from knowledge          | **The organizing principle** — knowledge is the source; documents are derived                                  |
| Language-neutral concept storage            | **Novel** — one knowledge store, any output language                                                           |
| Ontology / project separation               | Sound engineering; consistent with modern ontology practice                                                    |
| Multiple inheritance                        | Conventional in knowledge representation; unusual in databases                                                 |
| Set-operation queries over concept identity | Conventional inverted index applied to a knowledge graph                                                       |
| Rules as stored data                        | Rule engines are conventional; tight integration with a live ontology is the novel part                        |

---

## 17. What a Demanding Domain Provides

Any domain that imposes complex, formally specified data — multiple rendering requirements, strict semantic constraints, and real users demanding correctness — will prove this architecture. The domain is the forcing function; it is not the architecture.

All domain-specific knowledge lives in the ontology. The kernel contains none of it. A deployment tracking exoplanet observations, one cataloging protein interactions, and one managing materials properties would each require only a different ontology — the same kernel, the same mechanisms, the same query interface.

The architecture is proved by the hardest domain available. The harder the domain, the more clearly the separation between kernel and ontology is validated.
