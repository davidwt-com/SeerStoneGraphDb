%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% graphdb_nrefs.hrl -- Compile-time names for immutable scaffold nrefs.
%%
%% Scaffold nrefs 1-35 are written once at bootstrap and never reallocated.
%% Changing any value here requires re-bootstrapping the environment.
%% All values correspond directly to bootstrap.terms entries.
%%
%% nref_english (10000) is a permanent seed in the 10000-99999 tier.
%%---------------------------------------------------------------------

%% -- Top-level categories (scaffold 1-5) ------------------------------
-define(NREF_ROOT,             1).
-define(NREF_ATTRIBUTES,       2).
-define(NREF_CLASSES,          3).
-define(NREF_LANGUAGES,        4).
-define(NREF_PROJECTS,         5).

%% -- Attribute family roots (scaffold 6-8) ----------------------------
-define(NREF_NAMES,            6).
-define(NREF_LITERALS,         7).
-define(NREF_RELATIONSHIPS,    8).

%% -- Name-attribute subcategory nodes (scaffold 9-12) -----------------
-define(NREF_CAT_NAME_ATTRS,   9).
-define(NREF_ATTR_NAME_ATTRS, 10).
-define(NREF_CLS_NAME_ATTRS,  11).
-define(NREF_INST_NAME_ATTRS, 12).

%% -- Relationship-attribute subcategory nodes (scaffold 13-16) --------
-define(NREF_CAT_REL_ATTRS,   13).
-define(NREF_ATTR_REL_ATTRS,  14).
-define(NREF_CLS_REL_ATTRS,   15).
-define(NREF_INST_REL_ATTRS,  16).

%% -- Name attributes: used as #{attribute => ?NAME_ATTR_*, value => Name}
-define(NAME_ATTR_CATEGORY,   17).
-define(NAME_ATTR_ATTRIBUTE,  18).
-define(NAME_ATTR_CLASS,      19).
-define(NAME_ATTR_INSTANCE,   20).

%% -- Category hierarchy arc labels (kind = composition) ---------------
-define(ARC_CAT_PARENT,       21).
-define(ARC_CAT_CHILD,        22).

%% -- Attribute hierarchy arc labels (kind = taxonomy) -----------------
-define(ARC_ATTR_PARENT,      23).
-define(ARC_ATTR_CHILD,       24).

%% -- Class hierarchy arc labels (kind = taxonomy or composition) ------
-define(ARC_CLS_PARENT,       25).
-define(ARC_CLS_CHILD,        26).

%% -- Instance hierarchy arc labels (kind = composition) ---------------
-define(ARC_INST_PARENT,      27).
-define(ARC_INST_CHILD,       28).

%% -- Instance-class membership arc labels -----------------------------
-define(ARC_INST_TO_CLASS,    29).  %% instance -> class direction
-define(ARC_CLASS_TO_INST,    30).  %% class -> instance direction

%% -- Template scope AVP marker ----------------------------------------
-define(ARC_TEMPLATE,         31).

%% -- Language subcategories (scaffold 32-35) --------------------------
-define(NREF_HUMAN_LANGS,     32).
-define(NREF_FORMAL_LANGS,    33).
-define(NREF_DIAGRAM_LANGS,   34).
-define(NREF_RENDERERS,       35).

%% -- Permanent named instance nrefs (10000-99999 tier) ----------------
-define(NREF_ENGLISH,      10000).  %% English; first instance in ontology
