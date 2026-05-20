%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: David W. Thomas
%% Created: 2026-05-20
%% Description: Runtime catalog of scaffold nrefs and bootstrap
%%              congruency verification.
%%---------------------------------------------------------------------
%% Revision History
%%---------------------------------------------------------------------
%% Rev PA1 Date: 2026-05-20 Author: David W. Thomas
%% Initial implementation.
%%---------------------------------------------------------------------

-module(graphdb_nrefs).

-include_lib("graphdb/include/graphdb_nrefs.hrl").

-record(node, {
	nref,
	kind,
	parents              = [],
	classes              = [],
	attribute_value_pairs
}).

-export([scaffold_spec/0, verify/0]).


%%---------------------------------------------------------------------
%% scaffold_spec() -> [{atom(), integer(), atom(), string()}]
%%
%% Returns {MacroName, Nref, Kind, ExpectedName} for every immutable
%% scaffold nref.  Used by verify/0 and CT tests.
%%---------------------------------------------------------------------
scaffold_spec() -> [
	{nref_root,           ?NREF_ROOT,           category,  "Root"},
	{nref_attributes,     ?NREF_ATTRIBUTES,      category,  "Attributes"},
	{nref_classes,        ?NREF_CLASSES,         category,  "Classes"},
	{nref_languages,      ?NREF_LANGUAGES,       category,  "Languages"},
	{nref_projects,       ?NREF_PROJECTS,        category,  "Projects"},
	{nref_names,          ?NREF_NAMES,           attribute, "Names"},
	{nref_literals,       ?NREF_LITERALS,        attribute, "Literals"},
	{nref_relationships,  ?NREF_RELATIONSHIPS,   attribute, "Relationships"},
	{nref_cat_name_attrs, ?NREF_CAT_NAME_ATTRS,  attribute, "Category Name Attributes"},
	{nref_attr_name_attrs,?NREF_ATTR_NAME_ATTRS, attribute, "Attribute Name Attributes"},
	{nref_cls_name_attrs, ?NREF_CLS_NAME_ATTRS,  attribute, "Class Name Attributes"},
	{nref_inst_name_attrs,?NREF_INST_NAME_ATTRS, attribute, "Instance Name Attributes"},
	{nref_cat_rel_attrs,  ?NREF_CAT_REL_ATTRS,   attribute, "Category Relationships"},
	{nref_attr_rel_attrs, ?NREF_ATTR_REL_ATTRS,  attribute, "Attribute Relationships"},
	{nref_cls_rel_attrs,  ?NREF_CLS_REL_ATTRS,   attribute, "Class Relationships"},
	{nref_inst_rel_attrs, ?NREF_INST_REL_ATTRS,  attribute, "Instance Relationships"},
	{name_attr_category,  ?NAME_ATTR_CATEGORY,   attribute, "Name"},
	{name_attr_attribute, ?NAME_ATTR_ATTRIBUTE,  attribute, "Name"},
	{name_attr_class,     ?NAME_ATTR_CLASS,      attribute, "Name"},
	{name_attr_instance,  ?NAME_ATTR_INSTANCE,   attribute, "Name"},
	{arc_cat_parent,      ?ARC_CAT_PARENT,       attribute, "Parent"},
	{arc_cat_child,       ?ARC_CAT_CHILD,        attribute, "Child"},
	{arc_attr_parent,     ?ARC_ATTR_PARENT,      attribute, "Parent"},
	{arc_attr_child,      ?ARC_ATTR_CHILD,       attribute, "Child"},
	{arc_cls_parent,      ?ARC_CLS_PARENT,       attribute, "Parent"},
	{arc_cls_child,       ?ARC_CLS_CHILD,        attribute, "Child"},
	{arc_inst_parent,     ?ARC_INST_PARENT,      attribute, "Parent"},
	{arc_inst_child,      ?ARC_INST_CHILD,       attribute, "Child"},
	{arc_inst_to_class,   ?ARC_INST_TO_CLASS,    attribute, "Class"},
	{arc_class_to_inst,   ?ARC_CLASS_TO_INST,    attribute, "Instance"},
	{arc_template,        ?ARC_TEMPLATE,         attribute, "Template"},
	{nref_human_langs,    ?NREF_HUMAN_LANGS,     category,  "Human Languages"},
	{nref_formal_langs,   ?NREF_FORMAL_LANGS,    category,  "Formal Languages"},
	{nref_diagram_langs,  ?NREF_DIAGRAM_LANGS,   category,  "Diagram Languages"},
	{nref_renderers,      ?NREF_RENDERERS,       category,  "Renderers"},
	{nref_english,        ?NREF_ENGLISH,         instance,  "English"}
].


%%---------------------------------------------------------------------
%% verify() -> ok | {error, {scaffold_nref_mismatch, [term()]}}
%%
%% Reads every scaffold nref from Mnesia and confirms it has the
%% expected kind and name AVP.  Called at the end of bootstrap load.
%%---------------------------------------------------------------------
verify() ->
	Mismatches = lists:flatmap(fun verify_one/1, scaffold_spec()),
	case Mismatches of
		[] -> ok;
		_  -> {error, {scaffold_nref_mismatch, Mismatches}}
	end.

verify_one({Name, Nref, ExpKind, ExpNameValue}) ->
	NameAttr = name_attr_for_kind(ExpKind),
	case mnesia:dirty_read(nodes, Nref) of
		[#node{kind = ExpKind, attribute_value_pairs = AVPs}] ->
			HasName = lists:any(
				fun(#{attribute := A, value := V}) ->
					A =:= NameAttr andalso V =:= ExpNameValue
				end, AVPs),
			case HasName of
				true  -> [];
				false -> [{Name, Nref, name_not_found, ExpNameValue}]
			end;
		[#node{kind = ActualKind}] ->
			[{Name, Nref, kind_mismatch, ExpKind, ActualKind}];
		[] ->
			[{Name, Nref, node_not_found}]
	end.

name_attr_for_kind(category)  -> ?NAME_ATTR_CATEGORY;
name_attr_for_kind(attribute) -> ?NAME_ATTR_ATTRIBUTE;
name_attr_for_kind(class)     -> ?NAME_ATTR_CLASS;
name_attr_for_kind(instance)  -> ?NAME_ATTR_INSTANCE.
