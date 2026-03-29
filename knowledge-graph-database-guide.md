# Knowledge Graph Database: Hierarchies and Relations

A reference guide for LLM agents working with knowledge graph databases, synthesized from knowledge representation literature and patent disclosures (US-5379366-A, US-5594837-A, US-5878406-A, Noyes; Cogito Knowledge Center documentation).

---

## Core Principles

### The Fundamental Insight
> "The meaning of a concept is defined by its relationship to other concepts."

Knowledge graphs model reality as a **network of concepts** connected by **relationships**. Unlike traditional databases where data is secondary to structure, knowledge graphs treat the relationships as the essence of the system.

### Basic Components

| Component                | Description                                       |
|--------------------------|---------------------------------------------------|
| **Concepts (Nodes)**     | Atomic data points representing discrete entities |
| **Relationships (Arcs)** | Connections between concepts that provide meaning |
| **Attributes**           | Labels that characterize values or relationships  |
| **Reference Numbers**    | Unique, permanent identifiers for each record     |

---

## Node Types

### 1. Instance Nodes
Concrete, atomic elements representing real-world entities.

**Requirements:**
- Must have a name (via name attribute)
- Must be a member of a class
- Contains relationship connections to other instances

**Structure:**
```
Instance Node
├── Name Attribute (human-readable label; not globally unique)
├── Class Membership (taxonomic parent)
├── Compositional Parent (part-of parent)
└── Relationships (connections to other instances)
└── Attributes with values
```

> Uniqueness is provided by the **Reference Number (Nref)**, not the name. Two instances may share the same name and be distinguished only by their position in the graph.

**Naming Convention:**
- Instance names need not be unique globally
- Position in graph + relationships define uniqueness
- Example: Two "Fido" dogs are distinct by their different owners

### 2. Class Nodes
Groups of instances sharing the same attributes. The primary building block of the model.

**Requirements:**
- Each class requires a **class name attribute** (distinguishes class from siblings)
- Each class requires an **instance name attribute** (for naming instances)
- May have qualifying characteristics (attributes defining the class and defining the instances of the classes)

**Structure:**
```
Class Node (Taxonomic Hierarchy)
├── Class Name Attribute
├── Instance Name Attribute
├── Qualifying Characteristics
  ├── Attributes with class values
  └── Attributes (both relationships and literals) for instances
└── Subclasses (child classes)
```

A class must contain all the attributes that instances may instantiate.  These are inherited by derived classes (subclasses) and by instances of the class or subclasses.

**Class vs Instance Determination:**
> Test: `"X is a [concept]"` must make sense.
> - "Blue is a color" → Blue is a subclass/instance of color
> - "Color is a blue" → Invalid → Color is NOT a subclass of blue

### 3. Attribute Nodes
Provide names, values, and relationship connection points.

**Three Types:**

| Type                        | Purpose                                                                                     |
|-----------------------------|---------------------------------------------------------------------------------------------|
| **Name Attributes**         | Label/value pairs for naming classes and instances                                          |
| **Relationship Attributes** | Characterize connections between instances, or generally between nodes                      |
| **Literal Attributes**      | Attributes whose values are raw data — numbers, strings, URLs, filenames, or other scalar types — stored directly on a node rather than as a reference to another node. Literal attributes are not part of the graph topology; they carry no Reference Numbers and participate in no relationships. Examples: temperature readings, measurements, weighted scores, URLs, filenames. |

**Organization:**
```
Attribute Library
├── Names
│   ├── Class Name Attributes
│   └── Instance Name Attributes
├── Literals
│   └── [Literal Attributes]
│       (e.g. temperature, weight, url, filename)
└── Relationships
    └── [Relationship Types]
        └── [Specific Attributes]
```

---

## Relationship Design

### Reciprocity
All relationships are reciprocal. From viewpoint A→B and B→A, characterizations may differ.

**Examples:**
| A's View | Type | B's View |
|----------|------|----------|
| Ford makes Taurus | manufacturing | Taurus is made by Ford |
| Mary is mother of Martha | family | Martha is daughter of Mary |
| Warehouse 10 has forklift A | location | Forklift A is located in Warehouse 10 |

### Relationship Types
Group related attributes that can be used together:
- **Pipe**: inlet, outlet, drain, vent
- **Location**: located in, location of
- **Family**: mother of, daughter of, father of, son of

### Relationship Attributes
- Characterize relationships (not values)
- Grouped into types for consistency
- Used to create connections between instance nodes

**Example:**
```
Relationship Type: Location
├── Attribute: "located in" (for equipment)
└── Attribute: "location of" (for locations)
```

### Relationship Metadata (Per-Arc Attribute/Value Pairs)

Each relationship entry may carry an optional `attribute_value_pairs` list that holds metadata about that specific arc. This list is **per-direction (asymmetric)**: each node stores its own AVPs on its own copy of the arc independently of the AVPs stored on the reciprocal entry at the target node.

**Use cases:**

| Category          | Example attributes                             |
|-------------------|------------------------------------------------|
| Provenance        | `source`, `asserted_by`, `confidence_source`   |
| Weights / scores  | `weight`, `strength`, `probability`            |
| Flags             | `is_inferred`, `is_verified`, `is_deprecated`  |
| Revisions         | `version`, `last_modified_by`, `change_reason` |
| Active time frame | `valid_from`, `valid_to`, `created_at`         |

**Rules:**

- The field is optional. Absent is equivalent to an empty list. No Nref is allocated for the arc itself; the relationship remains a flat structure inside the owning node's record.
- Relationship AVPs do **not** inherit. They are not propagated by any inheritance mechanism.
- Relationship AVPs do not participate in graph traversal by default. However, certain AVPs (e.g., a `valid_to` time frame or an `is_deprecated` flag) are explicitly reserved for a future traversal-condition mechanism that may gate or modify traversal based on their values. This capability is not ruled out by this design.
- Because the relationship has no Nref of its own, attribute nodes referenced in a relationship's AVP list are sourced from the same attribute library as all other attribute nodes.

**Attribute library organization for relationship AVP attributes:**

Relationship AVP attributes are **literal attributes**. They are identified in the library by carrying a `relationship_avp` AVP — value `true` — on their own attribute node record:

```
Attribute node: "relationship_weight"
  attribute_value_pairs:
    #{attribute => NameAttrNref, value => <<"relationship_weight">>}
    #{attribute => RelationshipAvpFlagNref, value => true}
```

This flag is itself a literal attribute (`relationship_avp`) seeded into the attribute library at bootstrap. Its presence (value `true`) marks an attribute as intended for use on relationship arcs rather than on node records directly. Absent means not a relationship AVP attribute.

Relationship AVP attributes may be organized as **children of their nearest general sibling attribute** in the library. For example, a `relationship_weight` attribute (arc-specific) is a sibling or child of a general `weight` literal attribute, distinguished from it by the `relationship_avp` flag.

---

## Hierarchy Systems

### Taxonomic Hierarchy (Class Structure)
Organizes classes by inheritance. Each child has all parent characteristics plus distinguishing features.

```
Animal
└── Mammal (adds: hair, milk production)
    └── Whale (adds: fins, blowhole)
```

**Inheritance Rules:**
- Child inherits all attributes from parent(s)
- Child adds qualifying characteristic(s)
- Different values for qualifying attributes distinguish siblings

### Compositional Hierarchy (Instance Structure)
Organizes instances by "part-of" relationships. Big things made of smaller things.

```
Car
├── Engine
│   └── Cylinder Block
│       └── Pistons
├── Wheels
│   └── Hubs
└── Chassis
```

**Test:** "X is a part of Y" must make sense.
- "Lug nut is a part of car" ✓
- "Taurus is a part of car" ✗

### Critical Design Note
> Class structure and instance structure are **perpendicular**, not parallel.
> - Class structure = "is a" (taxonomic)
> - Instance structure = "part of" (compositional)
> - They intersect at instance-to-class membership

---

## Inheritance Mechanisms

### Instance Inheritance Process

Priority order — each step applies only to attributes not yet resolved by a higher-priority step:

1. **Apply local values** (highest priority — values set directly on this node override all else)
2. **Inherit bound values from class(es)** (values explicitly bound at the class level)
3. **Inherit from compositional ancestors** (unbroken chain upward only)
4. **Inherit from directly connected nodes** (one level deep only; lowest priority)

### Class Inheritance Process
- Child inherits all attributes, values, and vocabularies of parent(s)
- Resembles genetic inheritance in nature

### Multiple Inheritance
- Instance may be member of multiple classes
- Instance may have multiple compositional parents
- Both are valid; both carry risks. Use either only when the domain clearly demands it, and document the justification explicitly.

**Pitfalls of multiple class membership:**
- Attribute conflicts: two parent classes may define the same attribute with different bound values — resolution must be explicit
- Semantic ambiguity: if an instance genuinely belongs to two unrelated classes, this often signals a missing superclass or a modelling error
- Query complexity: class-based queries must account for all membership paths

**Pitfalls of multiple compositional parents:**
- Ownership ambiguity: "part of" implies a single owner in most physical domains; multiple parents can make lifecycle and responsibility unclear
- Inheritance fan-out: values propagate from all compositional ancestors; conflicting inherited values require explicit local overrides
- Maintenance burden: moving or restructuring one parent silently affects the instance's inherited context from all other parents

---

## Modeling Guidelines

### The Key Rule
> Define every item of interest as a concept node. Even attributes become nodes.

**Why This Matters:**
```
BAD: "blue" as simple attribute value
GOOD: "blue" as concept node with relationships

Result: Can query "find all blue things"
        by traversing from "blue" node to connected instances
```

### Query Optimization
- Only **node names** (values of name attributes) are indexed
- Maximize indexing by:
  - Using name attributes to name nodes
  - Obtaining values through inheritance where possible
  - Making searchable values into nodes

---

## Database Architecture

### Multi-Layer Structure

```
┌─────────────────────────────────────┐
│         Environment Database        │
│  (Attribute/Component Libraries)    │
│        Common to all Projects       │
└─────────────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────┐
│         Project Databases           │
│  (Specific instances & projects)    │
│  One per project, reference         │
│  common Environment                 │
└─────────────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────┐
│       Descriptive Database          │
│  (Non-permanent working memory)     │
│  Assembles specific views of KR     │
└─────────────────────────────────────┘
```

### Record Structure
```json
{
  "reference_number": "unique_permanent_id",
  "attribute_value_pairs": [
    {
      "attribute": "ref_to_attribute_concept",
      "value": "any data type value or construct"
    }
  ],
  "relationships": [
    {
      "characterization": "ref_to_attribute_concept",
      "value": "ref_to_target_concept",
      "reciprocal": "ref_to_reciprocal_attribute",
      "attribute_value_pairs": []
    }
  ]
}
```

Each attribute value pair, with the attribute nref, the value of any type, from simple native to complex.  The attribute node would have definition(s) of these values.

Each relationship is a flat triple: `characterization` is the arc label (an attribute Nref), `value` is the target concept (an Nref), and `reciprocal` is the arc label as seen from the target back to this node (also an attribute Nref).

The optional `attribute_value_pairs` list on a relationship carries per-arc metadata (provenance, weights, flags, revisions, active time frames, etc.). It is absent or empty when not needed. See **Relationship Metadata** under Relationship Design for the full specification.

### Value Types

| Type         | Description                                              |
|--------------|----------------------------------------------------------|
| **Internal** | Reference to another concept (enables network traversal) |
| **External** | Standard data type (string, number, etc.)                |

---

## Levels of Abstraction (Strata)

Records organized into strata representing different conceptual levels:

```
Higher Abstraction (Abstract Concepts)
    ▲
    │ Referenced by
    │
Middle Level (Domain-specific concepts)
    ▲
    │ Referenced by
    │
Lower Abstraction (Concrete instances)
```

**Rule:** Each record stores a reference to at least one record in a **higher** stratum. References point upward — lower-abstraction records reference higher-abstraction records, not the other way around.

---

## Pattern Recognition & Learning

Knowledge graphs can "learn" by:

1. **Pattern Detection:** Identify recurring relationship patterns
2. **Pattern Storage:** Store patterns as relationships themselves
3. **Pattern Application:** Suggest relationships based on learned patterns

**Example:**
> When creating Tank B, system recognizes: "Tanks typically have temperature sensors, pressure gauges, inlet valves, outlet valves"
> Suggests these as likely subassemblies

---

## View/Document Derivation

Knowledge can be transformed into multiple human-readable formats:

| Component    | Role                               | Analogy            |
|--------------|------------------------------------|--------------------|
| **View**     | Connectivity and interaction       | Layout rules       |
| **Template** | Grammar, format, icon placement    | Document structure |
| **Type**     | Vocabulary, concept identification | Word choice        |

---

## Implementation Guidelines

### Minimum Requirements

| Requirement              | Description                                     |
|--------------------------|-------------------------------------------------|
| Unique Reference Numbers | Permanently associated with each record         |
| Reference Storage        | Ability to store refs in records and indexes    |
| Indexing                 | B-Tree, hashing, or similar for rapid retrieval |
| Flexible Data Types      | No restriction on record data types             |
| Variable Length Records  | Support unbounded relationship lists            |

### Design Principles

1. **Start with instances** - Model concrete elements first
2. **Identify patterns** - Group instances into classes
3. **Define relationships** - How instances connect
4. **Establish hierarchies** - Taxonomic (class) and compositional (instance)
5. **Configure inheritance** - What values propagate where
6. **Consider query patterns** - Make frequently searched items into nodes

### Common Pitfalls

| Pitfall                             | Problem                  | Solution                                        |
|-------------------------------------|--------------------------|-------------------------------------------------|
| Using attributes instead of nodes   | Cannot query effectively | Make searchable values into nodes               |
| Mirrored class/instance hierarchies | Indicates confusion      | Classes = taxonomic, Instances = compositional  |
| Local values override class values  | Breaks consistency       | Prefer class-level values for shared properties |
| Multiple parents (class or part-of) | Ambiguity and conflicts  | Justify explicitly; resolve conflicts with local values |

---

## Quick Reference

### Terminology Mapping

| This Guide       | Alternative Terms            |
|------------------|------------------------------|
| Node             | Record, Entity, Concept      |
| Arc              | Relationship, Edge, Link     |
| Class            | Type, Category, Schema       |
| Instance         | Object, Record Instance      |
| Reference Number | ID, Primary Key              |
| Characterization | Attribute, Relationship Type |
| Stratum          | Abstraction Level, Layer     |

### Key Formulas

**Node Completeness:**
```
Instance = Name + Class Membership + Compositional Parent + Relationships
```

**Class Completeness:**
```
Class = Class Name Attribute + Instance Name Attribute + Qualifying Characteristics
```

**Relationship Completeness:**
```
Relationship = Characterization + Value + [Reciprocal Characterization]
             + [AVP list (optional, per-direction)]
```

---

## Sources

- **Cogito, Inc.** "Defining Models" (2005) - Graph database modeling methodology
- **US Patent 5,379,366** (1995) - Noyes, "Method for representation of knowledge in a computer as a network database system"
- **US Patent 5,594,837** (1997) - Noyes, "Method for representation of knowledge in a computer as a network database system" (continuation-in-part of 5,379,366)
- **US Patent 5,878,406** (1999) - Noyes, "Method for representation of knowledge in a computer as a network database system" (continuation-in-part of 5,594,837)

---

*This document synthesized for LLM agent reference. For detailed implementation, consult the source materials.*
