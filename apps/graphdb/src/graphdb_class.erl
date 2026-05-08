%%---------------------------------------------------------------------
%% Copyright (c) 2008 SeerStone, Inc.
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: Dallas Noyes
%% Created: *** 2008
%% Description: graphdb_class manages the taxonomic ("is a") hierarchy.
%%				Creates class nodes, manages qualifying characteristics,
%%				and provides class-level attribute inheritance.  Class
%%				nodes live in the Mnesia `nodes` table with kind=class.
%%				Top-level classes are direct children of the Classes
%%				category (nref 3); subclasses are children of other
%%				class nodes.
%%
%%				On first startup, graphdb_class seeds a
%%				"qualifying_characteristic" literal attribute under the
%%				Literals subtree (nref 7).  This attribute is used to
%%				mark which attributes are qualifying characteristics of
%%				a class.  Subsequent startups detect the existing seed
%%				by name and cache its nref in the gen_server state.
%%---------------------------------------------------------------------
%% Revision History
%%---------------------------------------------------------------------
%% Rev PA1 Date: *** 2008 Author: Dallas Noyes (dallas.noyes@gmail.com)
%% Stub implementation.
%%---------------------------------------------------------------------
%% Rev A Date: April 2026 Author: (completion of Dallas Noyes's design)
%% Initial implementation: taxonomic hierarchy over Mnesia.  Provides
%% create_class/2, add_qualifying_characteristic/2, get_class/1,
%% subclasses/1, ancestors/1, inherited_attributes/1.
%% Seeds qualifying_characteristic at init.
%%---------------------------------------------------------------------
-module(graphdb_class).
-behaviour(gen_server).


%%---------------------------------------------------------------------
%% Module Attributes
%%---------------------------------------------------------------------
-revision('Revision: A ').
-created('Date: *** 2008').
-created_by('dallas.noyes@gmail.com').
%%-modified('Date: April 2026').


%%---------------------------------------------------------------------
%% Include files
%%---------------------------------------------------------------------

%%---------------------------------------------------------------------
%% Macro Functions
%%---------------------------------------------------------------------
%% NYI - Not Yet Implemented
%%	F = {fun,{Arg1,Arg2,...}}
%%
%% UEM - UnExpected Message
%%	F = {fun,{Arg1,Arg2,...}}
%%	X = Message
%%---------------------------------------------------------------------
-define(NYI(F), (begin
					io:format("*** NYI ~p ~p ~p~n",[?MODULE, ?LINE, F]),
					exit(nyi)
				 end)).
-define(UEM(F, X), (begin
					io:format("*** UEM ~p:~p ~p ~p~n",[?MODULE, F, ?LINE, X]),
					exit(uem)
				 end)).


%%---------------------------------------------------------------------
%% Bootstrap nref constants
%%---------------------------------------------------------------------
%% Classes category — top-level organisational anchor for all classes.
-define(CLASSES_CATEGORY, 3).

%% NameAttrNref for class-kind nodes.
-define(NAME_ATTR_FOR_CLASS, 19).

%% Compositional arc labels for class children of class parents.
-define(CLASS_CHILD_ARC,  26).  %% Child/ClassRel  -- parent -> child
-define(CLASS_PARENT_ARC, 25).  %% Parent/ClassRel -- child  -> parent

%% Literals subtree — parent for seeded literal attributes.
-define(PARENT_LITERALS, 7).

%% NameAttrNref for attribute-kind nodes (used when seeding).
-define(NAME_ATTR_FOR_ATTRIBUTE, 18).

%% Compositional arc labels for attribute children (used when seeding).
-define(ATTR_CHILD_ARC,  24).
-define(ATTR_PARENT_ARC, 23).

%% Default template name auto-attached to every newly created class.
%% Class authors may delete the default template to force explicit
%% disambiguation on subsequent Connection arcs.
-define(DEFAULT_TEMPLATE_NAME, "default").


%%---------------------------------------------------------------------
%% Record Definitions
%%---------------------------------------------------------------------
-record(node, {
	nref,					%% integer() -- primary key
	kind,					%% category | attribute | class | instance | template
	parents = [],			%% [integer()] -- cache of parent arcs (composition/taxonomy)
	classes = [],			%% [integer()] -- cache of instantiation arcs (instances only)
	attribute_value_pairs	%% [#{attribute => Nref, value => term()}]
}).

-record(relationship, {
	id,						%% integer() -- primary key
	kind,					%% taxonomy | composition | connection | instantiation
	source_nref,			%% integer() -- arc origin
	characterization,		%% integer() -- arc label (an attribute nref)
	target_nref,			%% integer() -- arc target
	reciprocal,				%% integer() -- arc label as seen from target back
	avps					%% [#{attribute => Nref, value => term()}]
}).

-record(state, {
	qc_attr_nref			%% integer() -- seeded qualifying_characteristic attribute
}).


%%---------------------------------------------------------------------
%% Exported Functions
%%---------------------------------------------------------------------
%%---------------------------------------------------------------------
%% Exports External API
%%---------------------------------------------------------------------
-export([
		start_link/0,
		%% Creators
		create_class/2,
		add_superclass/2,
		add_qualifying_characteristic/2,
		add_template/2,
		%% Lookups
		get_class/1,
		subclasses/1,
		ancestors/1,
		get_template/1,
		templates_for_class/1,
		default_template/1,
		%% Class-of resolution helper (used by graphdb_instance to validate
		%% Template AVP class scope on Connection arcs)
		class_in_ancestry/2,
		%% Inheritance
		inherited_attributes/1,
		%% Seeded nref accessor
		qc_attr_nref/0
		]).

%%---------------------------------------------------------------------
%% Exports Behaviour Callback for -behaviour(gen_server).
%%---------------------------------------------------------------------
-export([
		init/1,
		handle_call/3,
		handle_cast/2,
		handle_info/2,
		terminate/2,
		code_change/3
		]).

%%---------------------------------------------------------------------
%% Test-only exports
%%---------------------------------------------------------------------
-ifdef(TEST).
-export([
		is_valid_parent_kind/1,
		collect_qc_nrefs/2
		]).
-endif.


%%=============================================================================
%% Exported External API Functions
%%=============================================================================

start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


%%-----------------------------------------------------------------------------
%% create_class(Name, ParentClassNref) -> {ok, Nref} | {error, term()}
%%
%% Creates a new class node in the ontology.  ParentClassNref
%% is either the Classes category (nref 3) for top-level classes or
%% another class node's nref for subclasses.  Atomically writes the
%% class node, the taxonomic parent/child arc pair, the default
%% template node (kind=template, parent=ClassNref, name "default"),
%% and the compositional class -> template arc pair.
%%
%% Class authors may later delete the default template to force
%% explicit Template specification on subsequent Connection arcs
%% involving instances of this class, or call add_template/2 to
%% attach additional named templates as compositional children.
%%-----------------------------------------------------------------------------
create_class(Name, ParentClassNref) ->
	gen_server:call(?MODULE, {create_class, Name, ParentClassNref}).


%%-----------------------------------------------------------------------------
%% add_superclass(ClassNref, AdditionalParentNref) -> ok | {error, term()}
%%
%% Adds an additional taxonomic parent to an existing class, supporting
%% multiple inheritance (spec §5: "A concept may have any number of
%% generalizations simultaneously").  Atomically writes a taxonomy arc
%% pair (kind=taxonomy, char 25/26) and appends AdditionalParentNref to
%% the class's parents cache.  Idempotent: adding the same parent twice
%% is a no-op.  Rejects self-references; the caller is responsible for
%% avoiding cycles introduced via longer paths.
%%-----------------------------------------------------------------------------
add_superclass(ClassNref, AdditionalParentNref) ->
	gen_server:call(?MODULE,
		{add_superclass, ClassNref, AdditionalParentNref}).


%%-----------------------------------------------------------------------------
%% add_template(ClassNref, Name) -> {ok, TemplateNref} | {error, term()}
%%
%% Adds a new named template as a compositional child of ClassNref.
%% Validates that ClassNref is a class node and that no template with
%% the same name already exists under it.  Compositional arcs use the
%% class-child arc labels (26/25), kind = composition.
%%-----------------------------------------------------------------------------
add_template(ClassNref, Name) ->
	gen_server:call(?MODULE, {add_template, ClassNref, Name}).


%%-----------------------------------------------------------------------------
%% add_qualifying_characteristic(ClassNref, AttrNref) -> ok | {error, term()}
%%
%% Adds an attribute as a qualifying characteristic of the class.
%% Validates that ClassNref is a class node and AttrNref is an attribute
%% node.  Idempotent: adding the same QC twice is a no-op.
%%-----------------------------------------------------------------------------
add_qualifying_characteristic(ClassNref, AttrNref) ->
	gen_server:call(?MODULE, {add_qualifying_characteristic, ClassNref, AttrNref}).


%%-----------------------------------------------------------------------------
%% get_class(Nref) -> {ok, #node{}} | {error, not_found | not_a_class | term()}
%%
%% Returns the class node identified by Nref.  Only nodes of
%% kind=class are returned; any other kind yields {error, not_a_class}.
%%-----------------------------------------------------------------------------
get_class(Nref) ->
	gen_server:call(?MODULE, {get_class, Nref}).


%%-----------------------------------------------------------------------------
%% subclasses(ClassNref) -> {ok, [#node{}]} | {error, term()}
%%
%% Returns all direct subclasses (class-kind children) of the given
%% class node.
%%-----------------------------------------------------------------------------
subclasses(ClassNref) ->
	gen_server:call(?MODULE, {subclasses, ClassNref}).


%%-----------------------------------------------------------------------------
%% ancestors(ClassNref) -> {ok, [#node{}]} | {error, term()}
%%
%% Returns the ancestor chain of the given class, starting from its
%% immediate parent class up to (but not including) the Classes
%% category.  Returns an empty list for top-level classes.
%%-----------------------------------------------------------------------------
ancestors(ClassNref) ->
	gen_server:call(?MODULE, {ancestors, ClassNref}).


%%-----------------------------------------------------------------------------
%% get_template(Nref) ->
%%     {ok, #node{}} | {error, not_found | not_a_template | term()}
%%-----------------------------------------------------------------------------
get_template(Nref) ->
	gen_server:call(?MODULE, {get_template, Nref}).


%%-----------------------------------------------------------------------------
%% templates_for_class(ClassNref) -> {ok, [#node{}]} | {error, term()}
%%
%% Returns all template-kind compositional children of the class.
%%-----------------------------------------------------------------------------
templates_for_class(ClassNref) ->
	gen_server:call(?MODULE, {templates_for_class, ClassNref}).


%%-----------------------------------------------------------------------------
%% default_template(ClassNref) ->
%%     {ok, TemplateNref} | not_found | {error, term()}
%%
%% Returns the nref of the template named "default" attached to the
%% class, or `not_found` if the class author has deleted the default.
%%-----------------------------------------------------------------------------
default_template(ClassNref) ->
	gen_server:call(?MODULE, {default_template, ClassNref}).


%%-----------------------------------------------------------------------------
%% class_in_ancestry(CandidateClassNref, ClassNref) -> boolean()
%%
%% Returns true if CandidateClassNref equals ClassNref or is an ancestor
%% of ClassNref in the taxonomic hierarchy.  Used by graphdb_instance to
%% validate that a Template AVP's class is in scope for a Connection arc.
%%-----------------------------------------------------------------------------
class_in_ancestry(CandidateClassNref, ClassNref) ->
	gen_server:call(?MODULE, {class_in_ancestry, CandidateClassNref, ClassNref}).


%%-----------------------------------------------------------------------------
%% inherited_attributes(ClassNref) -> {ok, [integer()]} | {error, term()}
%%
%% Returns the list of qualifying-characteristic attribute nrefs that
%% apply to this class, including those inherited from ancestor classes.
%% Local QCs appear first; ancestor QCs are appended in nearest-first
%% order with duplicates removed (local takes priority).
%%-----------------------------------------------------------------------------
inherited_attributes(ClassNref) ->
	gen_server:call(?MODULE, {inherited_attributes, ClassNref}).


%%-----------------------------------------------------------------------------
%% qc_attr_nref() -> {ok, integer()}
%%
%% Returns the nref of the seeded qualifying_characteristic attribute.
%% Primarily intended for other graphdb workers and integration tests.
%%-----------------------------------------------------------------------------
qc_attr_nref() ->
	gen_server:call(?MODULE, qc_attr_nref).


%%=============================================================================
%% gen_server Behaviour Callbacks
%%=============================================================================

%%-----------------------------------------------------------------------------
%% init/1
%%
%% Seeds the qualifying_characteristic literal attribute under the
%% Literals subtree (nref 7) and caches its nref in state.  Idempotent:
%% on restart, detects the existing seed by name and reuses its nref.
%%-----------------------------------------------------------------------------
init([]) ->
	try
		QcNref = ensure_seed("qualifying_characteristic"),
		logger:info("graphdb_class: started (qc_attr=~p)", [QcNref]),
		{ok, #state{qc_attr_nref = QcNref}}
	catch
		throw:{error, Reason} ->
			logger:error("graphdb_class: seeding failed: ~p", [Reason]),
			{stop, {seed_failed, Reason}}
	end.


%%-----------------------------------------------------------------------------
%% handle_call/3 -- Creators
%%-----------------------------------------------------------------------------
handle_call({create_class, Name, ParentClassNref}, _From, State) ->
	{reply, do_create_class(Name, ParentClassNref), State};

handle_call({add_superclass, ClassNref, AdditionalParentNref}, _From, State) ->
	{reply, do_add_superclass(ClassNref, AdditionalParentNref), State};

handle_call({add_qualifying_characteristic, ClassNref, AttrNref}, _From,
		#state{qc_attr_nref = QcAttr} = State) ->
	{reply, do_add_qc(ClassNref, AttrNref, QcAttr), State};

handle_call({add_template, ClassNref, Name}, _From, State) ->
	{reply, do_add_template(ClassNref, Name), State};

%%-----------------------------------------------------------------------------
%% handle_call/3 -- Lookups
%%-----------------------------------------------------------------------------
handle_call({get_class, Nref}, _From, State) ->
	{reply, do_get_class(Nref), State};

handle_call({subclasses, ClassNref}, _From, State) ->
	{reply, do_subclasses(ClassNref), State};

handle_call({ancestors, ClassNref}, _From, State) ->
	{reply, do_ancestors(ClassNref), State};

handle_call({get_template, Nref}, _From, State) ->
	{reply, do_get_template(Nref), State};

handle_call({templates_for_class, ClassNref}, _From, State) ->
	{reply, do_templates_for_class(ClassNref), State};

handle_call({default_template, ClassNref}, _From, State) ->
	{reply, do_default_template(ClassNref), State};

handle_call({class_in_ancestry, CandidateNref, ClassNref}, _From, State) ->
	{reply, do_class_in_ancestry(CandidateNref, ClassNref), State};

%%-----------------------------------------------------------------------------
%% handle_call/3 -- Inheritance
%%-----------------------------------------------------------------------------
handle_call({inherited_attributes, ClassNref}, _From,
		#state{qc_attr_nref = QcAttr} = State) ->
	{reply, do_inherited_attributes(ClassNref, QcAttr), State};

handle_call(qc_attr_nref, _From, #state{qc_attr_nref = QcAttr} = State) ->
	{reply, {ok, QcAttr}, State};

handle_call(Request, From, State) ->
	?UEM(handle_call, {Request, From, State}),
	{noreply, State}.

handle_cast(Message, State) ->
	?UEM(handle_cast, {Message, State}),
	{noreply, State}.

handle_info(Info, State) ->
	?UEM(handle_info, {Info, State}),
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	?NYI(code_change),
	{ok, State}.


%%=============================================================================
%% Internal Functions
%%=============================================================================

%%-----------------------------------------------------------------------------
%% is_valid_parent_kind(Kind) -> boolean()
%%
%% Returns true if Kind is acceptable as a class node's parent.
%% Category (the Classes anchor) and class (superclass) are valid.
%%-----------------------------------------------------------------------------
is_valid_parent_kind(category) -> true;
is_valid_parent_kind(class)    -> true;
is_valid_parent_kind(_)        -> false.


%%-----------------------------------------------------------------------------
%% collect_qc_nrefs(AVPs, QcAttrNref) -> [integer()]
%%
%% Extracts qualifying-characteristic attribute nrefs from an AVP list.
%%-----------------------------------------------------------------------------
collect_qc_nrefs(AVPs, QcAttr) ->
	[V || #{attribute := A, value := V} <- AVPs, A =:= QcAttr].


%%-----------------------------------------------------------------------------
%% ensure_seed(Name) -> Nref
%%
%% Looks up an existing literal attribute by name under the Literals
%% subtree; if not found, creates it (node + compositional arc pair).
%% Throws {error, Reason} on failure.
%%-----------------------------------------------------------------------------
ensure_seed(Name) ->
	case find_attribute_by_name(?PARENT_LITERALS, Name) of
		{ok, Nref} ->
			Nref;
		not_found ->
			case do_create_seed_attribute(Name) of
				{ok, Nref}       -> Nref;
				{error, Reason}  -> throw({error, Reason})
			end
	end.


%%-----------------------------------------------------------------------------
%% find_attribute_by_name(ParentNref, Name) -> {ok, Nref} | not_found
%%
%% Finds an attribute-kind child of ParentNref whose name AVP matches
%% Name.  Uses the parent index for O(1) lookup.
%%-----------------------------------------------------------------------------
find_attribute_by_name(ParentNref, Name) ->
	F = fun() ->
		Children = downward_children_by_arc(ParentNref, ?ATTR_CHILD_ARC,
			composition),
		lists:search(fun(N) -> node_has_name(N, Name) end, Children)
	end,
	case mnesia:transaction(F) of
		{atomic, {value, #node{nref = Nref}}} -> {ok, Nref};
		{atomic, false}                       -> not_found;
		{aborted, Reason}                     -> throw({error, Reason})
	end.


%%-----------------------------------------------------------------------------
%% node_has_name(Node, Name) -> boolean()
%%-----------------------------------------------------------------------------
node_has_name(#node{attribute_value_pairs = AVPs}, Name) ->
	lists:any(fun
		(#{attribute := ?NAME_ATTR_FOR_ATTRIBUTE, value := V}) -> V =:= Name;
		(_) -> false
	end, AVPs).


%%-----------------------------------------------------------------------------
%% do_create_seed_attribute(Name) -> {ok, Nref} | {error, term()}
%%
%% Creates a literal attribute node under the Literals subtree (nref 7)
%% with only the name AVP.  Used for seeding the qualifying_characteristic
%% attribute.  Writes node + compositional arc pair atomically.
%%
%% All nref_server:get_nref/0 calls are issued OUTSIDE the Mnesia
%% transaction to avoid side-effects on transaction retry.
%%-----------------------------------------------------------------------------
do_create_seed_attribute(Name) ->
	Nref = nref_server:get_nref(),
	NameAVP = #{attribute => ?NAME_ATTR_FOR_ATTRIBUTE, value => Name},
	Node = #node{
		nref = Nref,
		kind = attribute,
		parents = [?PARENT_LITERALS],
		attribute_value_pairs = [NameAVP]
	},
	Id1 = nref_server:get_nref(),
	Id2 = nref_server:get_nref(),
	P2C = #relationship{
		id = Id1,
		kind = composition,
		source_nref = ?PARENT_LITERALS,
		characterization = ?ATTR_CHILD_ARC,
		target_nref = Nref,
		reciprocal = ?ATTR_PARENT_ARC,
		avps = []
	},
	C2P = #relationship{
		id = Id2,
		kind = composition,
		source_nref = Nref,
		characterization = ?ATTR_PARENT_ARC,
		target_nref = ?PARENT_LITERALS,
		reciprocal = ?ATTR_CHILD_ARC,
		avps = []
	},
	Txn = fun() ->
		ok = mnesia:write(nodes, Node, write),
		ok = mnesia:write(relationships, P2C, write),
		ok = mnesia:write(relationships, C2P, write)
	end,
	case mnesia:transaction(Txn) of
		{atomic, ok}      -> {ok, Nref};
		{aborted, Reason} -> {error, Reason}
	end.


%%-----------------------------------------------------------------------------
%% do_create_class(Name, ParentClassNref) ->
%%     {ok, Nref} | {error, term()}
%%
%% Validates the parent, allocates nrefs OUTSIDE the Mnesia transaction
%% (to avoid side-effects on retry), then atomically writes:
%%   - the class node (kind=class)
%%   - taxonomic parent/child arc pair  (kind=taxonomy, char 26/25)
%%   - the default template node (kind=template, parent=class)
%%   - compositional class -> template arc pair (kind=composition, char 26/25)
%%-----------------------------------------------------------------------------
do_create_class(Name, ParentClassNref) ->
	case do_validate_parent(ParentClassNref) of
		ok ->
			ClassNref      = nref_server:get_nref(),
			TaxId1         = nref_server:get_nref(),
			TaxId2         = nref_server:get_nref(),
			TemplateNref   = nref_server:get_nref(),
			TmplCompId1    = nref_server:get_nref(),
			TmplCompId2    = nref_server:get_nref(),
			ClassNameAVP    = #{attribute => ?NAME_ATTR_FOR_CLASS, value => Name},
			TemplateNameAVP = #{attribute => ?NAME_ATTR_FOR_CLASS,
				value => ?DEFAULT_TEMPLATE_NAME},
			ClassNode = #node{
				nref = ClassNref,
				kind = class,
				parents = [ParentClassNref],
				attribute_value_pairs = [ClassNameAVP]
			},
			TemplateNode = #node{
				nref = TemplateNref,
				kind = template,
				parents = [ClassNref],
				attribute_value_pairs = [TemplateNameAVP]
			},
			TaxP2C = #relationship{
				id = TaxId1, kind = taxonomy,
				source_nref = ParentClassNref,
				characterization = ?CLASS_CHILD_ARC,
				target_nref = ClassNref,
				reciprocal = ?CLASS_PARENT_ARC,
				avps = []
			},
			TaxC2P = #relationship{
				id = TaxId2, kind = taxonomy,
				source_nref = ClassNref,
				characterization = ?CLASS_PARENT_ARC,
				target_nref = ParentClassNref,
				reciprocal = ?CLASS_CHILD_ARC,
				avps = []
			},
			TmplP2C = #relationship{
				id = TmplCompId1, kind = composition,
				source_nref = ClassNref,
				characterization = ?CLASS_CHILD_ARC,
				target_nref = TemplateNref,
				reciprocal = ?CLASS_PARENT_ARC,
				avps = []
			},
			TmplC2P = #relationship{
				id = TmplCompId2, kind = composition,
				source_nref = TemplateNref,
				characterization = ?CLASS_PARENT_ARC,
				target_nref = ClassNref,
				reciprocal = ?CLASS_CHILD_ARC,
				avps = []
			},
			Txn = fun() ->
				ok = mnesia:write(nodes, ClassNode, write),
				ok = mnesia:write(nodes, TemplateNode, write),
				ok = mnesia:write(relationships, TaxP2C, write),
				ok = mnesia:write(relationships, TaxC2P, write),
				ok = mnesia:write(relationships, TmplP2C, write),
				ok = mnesia:write(relationships, TmplC2P, write)
			end,
			case mnesia:transaction(Txn) of
				{atomic, ok}      -> {ok, ClassNref};
				{aborted, Reason} -> {error, Reason}
			end;
		{error, _} = Err ->
			Err
	end.


%%-----------------------------------------------------------------------------
%% do_add_superclass(ClassNref, AdditionalParentNref) -> ok | {error, term()}
%%
%% Validates the subject (must be a class) and the additional parent
%% (class or category 3), rejects self-references, then atomically
%% writes the taxonomy arc pair AND appends AdditionalParentNref to the
%% subject's parents cache.  Idempotent: if AdditionalParentNref is
%% already in the parents list, returns ok without writing.
%%-----------------------------------------------------------------------------
do_add_superclass(ClassNref, ClassNref) ->
	{error, cyclic_self_reference};
do_add_superclass(ClassNref, AdditionalParentNref) ->
	case do_get_class(ClassNref) of
		{ok, _} ->
			case do_validate_parent(AdditionalParentNref) of
				ok               -> do_write_superclass(ClassNref,
									AdditionalParentNref);
				{error, _} = Err -> Err
			end;
		{error, _} = Err ->
			Err
	end.

do_write_superclass(ClassNref, AdditionalParentNref) ->
	Id1 = nref_server:get_nref(),
	Id2 = nref_server:get_nref(),
	Txn = fun() ->
		[#node{kind = class, parents = Parents} = Node] =
			mnesia:read(nodes, ClassNref),
		case lists:member(AdditionalParentNref, Parents) of
			true ->
				already_exists;
			false ->
				C2P = #relationship{
					id = Id1, kind = taxonomy,
					source_nref = ClassNref,
					characterization = ?CLASS_PARENT_ARC,
					target_nref = AdditionalParentNref,
					reciprocal = ?CLASS_CHILD_ARC,
					avps = []
				},
				P2C = #relationship{
					id = Id2, kind = taxonomy,
					source_nref = AdditionalParentNref,
					characterization = ?CLASS_CHILD_ARC,
					target_nref = ClassNref,
					reciprocal = ?CLASS_PARENT_ARC,
					avps = []
				},
				Updated = Node#node{
					parents = Parents ++ [AdditionalParentNref]
				},
				ok = mnesia:write(nodes, Updated, write),
				ok = mnesia:write(relationships, C2P, write),
				ok = mnesia:write(relationships, P2C, write),
				ok
		end
	end,
	case mnesia:transaction(Txn) of
		{atomic, ok}             -> ok;
		{atomic, already_exists} -> ok;
		{aborted, Reason}        -> {error, Reason}
	end.


%%-----------------------------------------------------------------------------
%% do_add_template(ClassNref, Name) -> {ok, TemplateNref} | {error, term()}
%%
%% Validates that ClassNref is a class and that no existing template
%% under it has the same name, then atomically writes the new template
%% node and its compositional arc pair (class-child arc labels 26/25).
%%-----------------------------------------------------------------------------
do_add_template(ClassNref, Name) ->
	case do_get_class(ClassNref) of
		{ok, _} ->
			case do_find_template_by_name(ClassNref, Name) of
				{ok, _Existing} ->
					{error, {template_already_exists, Name}};
				not_found ->
					do_write_template(ClassNref, Name)
			end;
		{error, _} = Err ->
			Err
	end.

do_write_template(ClassNref, Name) ->
	TemplateNref = nref_server:get_nref(),
	Id1 = nref_server:get_nref(),
	Id2 = nref_server:get_nref(),
	NameAVP = #{attribute => ?NAME_ATTR_FOR_CLASS, value => Name},
	Node = #node{
		nref = TemplateNref,
		kind = template,
		parents = [ClassNref],
		attribute_value_pairs = [NameAVP]
	},
	P2C = #relationship{
		id = Id1, kind = composition,
		source_nref = ClassNref,
		characterization = ?CLASS_CHILD_ARC,
		target_nref = TemplateNref,
		reciprocal = ?CLASS_PARENT_ARC,
		avps = []
	},
	C2P = #relationship{
		id = Id2, kind = composition,
		source_nref = TemplateNref,
		characterization = ?CLASS_PARENT_ARC,
		target_nref = ClassNref,
		reciprocal = ?CLASS_CHILD_ARC,
		avps = []
	},
	Txn = fun() ->
		ok = mnesia:write(nodes, Node, write),
		ok = mnesia:write(relationships, P2C, write),
		ok = mnesia:write(relationships, C2P, write)
	end,
	case mnesia:transaction(Txn) of
		{atomic, ok}      -> {ok, TemplateNref};
		{aborted, Reason} -> {error, Reason}
	end.


%%-----------------------------------------------------------------------------
%% do_find_template_by_name(ClassNref, Name) -> {ok, Nref} | not_found
%%
%% Looks up a template-kind child of ClassNref whose name AVP matches.
%% Templates and classes share the class NameAttrNref (19); the kind
%% filter ensures we only return templates.
%%-----------------------------------------------------------------------------
do_find_template_by_name(ClassNref, Name) ->
	F = fun() ->
		Children = downward_children_by_arc(ClassNref, ?CLASS_CHILD_ARC,
			composition),
		lists:search(fun
			(#node{kind = template} = N) -> template_has_name(N, Name);
			(_)                           -> false
		end, Children)
	end,
	case mnesia:transaction(F) of
		{atomic, {value, #node{nref = Nref}}} -> {ok, Nref};
		{atomic, false}                       -> not_found;
		{aborted, _}                          -> not_found
	end.

template_has_name(#node{attribute_value_pairs = AVPs}, Name) ->
	lists:any(fun
		(#{attribute := ?NAME_ATTR_FOR_CLASS, value := V}) -> V =:= Name;
		(_) -> false
	end, AVPs).


%%-----------------------------------------------------------------------------
%% do_get_template(Nref) ->
%%     {ok, #node{}} | {error, not_found | not_a_template | term()}
%%-----------------------------------------------------------------------------
do_get_template(Nref) ->
	case mnesia:transaction(fun() -> mnesia:read(nodes, Nref) end) of
		{atomic, [#node{kind = template} = Node]} -> {ok, Node};
		{atomic, [_Other]}                        -> {error, not_a_template};
		{atomic, []}                              -> {error, not_found};
		{aborted, Reason}                         -> {error, Reason}
	end.


%%-----------------------------------------------------------------------------
%% do_templates_for_class(ClassNref) -> {ok, [#node{}]} | {error, term()}
%%-----------------------------------------------------------------------------
do_templates_for_class(ClassNref) ->
	F = fun() ->
		Children = downward_children_by_arc(ClassNref, ?CLASS_CHILD_ARC,
			composition),
		[N || N <- Children, N#node.kind =:= template]
	end,
	case mnesia:transaction(F) of
		{atomic, Nodes}   -> {ok, Nodes};
		{aborted, Reason} -> {error, Reason}
	end.


%%-----------------------------------------------------------------------------
%% do_default_template(ClassNref) ->
%%     {ok, TemplateNref} | not_found | {error, term()}
%%-----------------------------------------------------------------------------
do_default_template(ClassNref) ->
	case do_find_template_by_name(ClassNref, ?DEFAULT_TEMPLATE_NAME) of
		{ok, Nref} -> {ok, Nref};
		not_found  -> not_found
	end.


%%-----------------------------------------------------------------------------
%% do_class_in_ancestry(CandidateNref, ClassNref) -> boolean()
%%
%% True when CandidateNref equals ClassNref or appears in ClassNref's
%% taxonomic ancestor chain.  Returns false on any lookup error.
%%-----------------------------------------------------------------------------
do_class_in_ancestry(CandidateNref, CandidateNref) ->
	true;
do_class_in_ancestry(CandidateNref, ClassNref) ->
	case do_ancestors(ClassNref) of
		{ok, Ancestors} ->
			lists:any(fun(#node{nref = N}) -> N =:= CandidateNref end, Ancestors);
		_ ->
			false
	end.


%%-----------------------------------------------------------------------------
%% do_validate_parent(ParentNref) -> ok | {error, term()}
%%
%% Validates that ParentNref is either the Classes category (nref 3) or
%% an existing class node.
%%-----------------------------------------------------------------------------
do_validate_parent(?CLASSES_CATEGORY) ->
	ok;
do_validate_parent(Nref) ->
	case mnesia:transaction(fun() -> mnesia:read(nodes, Nref) end) of
		{atomic, [#node{kind = Kind}]} ->
			case is_valid_parent_kind(Kind) of
				true  -> ok;
				false -> {error, {invalid_parent_kind, Kind}}
			end;
		{atomic, []}                     -> {error, parent_not_found};
		{aborted, Reason}                -> {error, Reason}
	end.


%%-----------------------------------------------------------------------------
%% do_add_qc(ClassNref, AttrNref, QcAttr) -> ok | {error, term()}
%%
%% Adds the qualifying-characteristic AVP to the class node.  Validates
%% both ClassNref (must be class) and AttrNref (must be attribute).
%% Idempotent: if the QC already exists, returns ok.
%%-----------------------------------------------------------------------------
do_add_qc(ClassNref, AttrNref, QcAttr) ->
	Txn = fun() ->
		case mnesia:read(nodes, ClassNref) of
			[#node{kind = class, attribute_value_pairs = AVPs} = Node] ->
				case mnesia:read(nodes, AttrNref) of
					[#node{kind = attribute}] ->
						Already = lists:any(fun
							(#{attribute := A, value := V}) ->
								A =:= QcAttr andalso V =:= AttrNref;
							(_) -> false
						end, AVPs),
						case Already of
							true ->
								already_exists;
							false ->
								NewAVP = #{attribute => QcAttr, value => AttrNref},
								Updated = Node#node{
									attribute_value_pairs = AVPs ++ [NewAVP]
								},
								ok = mnesia:write(nodes, Updated, write),
								ok
						end;
					[#node{}] ->
						{error, {not_an_attribute, AttrNref}};
					[] ->
						{error, {attribute_not_found, AttrNref}}
				end;
			[#node{kind = Kind}] ->
				{error, {not_a_class, Kind}};
			[] ->
				{error, not_found}
		end
	end,
	case mnesia:transaction(Txn) of
		{atomic, ok}             -> ok;
		{atomic, already_exists} -> ok;
		{atomic, {error, _} = E} -> E;
		{aborted, Reason}        -> {error, Reason}
	end.


%%-----------------------------------------------------------------------------
%% do_get_class(Nref) ->
%%     {ok, #node{}} | {error, not_found | not_a_class | term()}
%%-----------------------------------------------------------------------------
do_get_class(Nref) ->
	case mnesia:transaction(fun() -> mnesia:read(nodes, Nref) end) of
		{atomic, [#node{kind = class} = Node]} -> {ok, Node};
		{atomic, [_Other]}                     -> {error, not_a_class};
		{atomic, []}                           -> {error, not_found};
		{aborted, Reason}                      -> {error, Reason}
	end.


%%-----------------------------------------------------------------------------
%% do_subclasses(ClassNref) -> {ok, [#node{}]} | {error, term()}
%%
%% Returns all direct child nodes of kind=class under ClassNref.
%%-----------------------------------------------------------------------------
do_subclasses(ClassNref) ->
	F = fun() ->
		Children = downward_children_by_arc(ClassNref, ?CLASS_CHILD_ARC,
			taxonomy),
		[N || N <- Children, N#node.kind =:= class]
	end,
	case mnesia:transaction(F) of
		{atomic, Nodes}   -> {ok, Nodes};
		{aborted, Reason} -> {error, Reason}
	end.


%%-----------------------------------------------------------------------------
%% do_ancestors(ClassNref) -> {ok, [#node{}]} | {error, term()}
%%
%% Walks the multi-parent taxonomic DAG starting from ClassNref's
%% parents.  Performs a breadth-first traversal: nearest parents first,
%% then their parents, etc.  Each ancestor is visited at most once
%% (diamond inheritance returns the shared ancestor exactly once).
%% The Classes category (nref 3) is filtered out of the walk; non-class
%% nodes are skipped silently.  Returns the visited class nodes in BFS
%% (nearest-first) order.
%%-----------------------------------------------------------------------------
do_ancestors(ClassNref) ->
	case mnesia:transaction(fun() -> mnesia:read(nodes, ClassNref) end) of
		{atomic, [#node{kind = class, parents = Parents}]} ->
			Initial = [P || P <- Parents, P =/= ?CLASSES_CATEGORY],
			do_walk_ancestors(Initial, sets:from_list(Initial), []);
		{atomic, [_]} ->
			{error, not_a_class};
		{atomic, []} ->
			{error, not_found};
		{aborted, Reason} ->
			{error, Reason}
	end.

%% BFS over the parent DAG.  Queue is the FIFO of nrefs to visit;
%% Visited is the set of all already-enqueued nrefs (so we never
%% enqueue the same nref twice); Acc accumulates emitted nodes in
%% reverse order.
do_walk_ancestors([], _Visited, Acc) ->
	{ok, lists:reverse(Acc)};
do_walk_ancestors([Nref | Rest], Visited, Acc) ->
	case mnesia:transaction(fun() -> mnesia:read(nodes, Nref) end) of
		{atomic, [#node{kind = class, parents = Parents} = Node]} ->
			New = [P || P <- Parents,
				P =/= ?CLASSES_CATEGORY,
				not sets:is_element(P, Visited)],
			NewVisited = lists:foldl(fun sets:add_element/2, Visited, New),
			do_walk_ancestors(Rest ++ New, NewVisited, [Node | Acc]);
		_ ->
			do_walk_ancestors(Rest, Visited, Acc)
	end.


%%-----------------------------------------------------------------------------
%% downward_children_by_arc(ParentNref, ChildArc, RelKind) -> [#node{}]
%%
%% Replaces the retired #node.parent secondary index.  Reads outgoing
%% arcs from ParentNref of the given Kind/characterization and
%% dereferences each target nref to a node record.  Must run inside an
%% active mnesia transaction.
%%-----------------------------------------------------------------------------
downward_children_by_arc(ParentNref, ChildArc, RelKind) ->
	Arcs = mnesia:index_read(relationships, ParentNref,
		#relationship.source_nref),
	Nrefs = [A#relationship.target_nref || A <- Arcs,
		A#relationship.kind =:= RelKind,
		A#relationship.characterization =:= ChildArc],
	lists:flatmap(fun(N) -> mnesia:read(nodes, N) end, Nrefs).


%%-----------------------------------------------------------------------------
%% do_inherited_attributes(ClassNref, QcAttr) ->
%%     {ok, [integer()]} | {error, term()}
%%
%% Collects qualifying-characteristic attribute nrefs from the class
%% and all its ancestors.  Local QCs appear first; ancestor QCs are
%% appended in nearest-first order with duplicates removed.
%%-----------------------------------------------------------------------------
do_inherited_attributes(ClassNref, QcAttr) ->
	case do_get_class(ClassNref) of
		{ok, Node} ->
			case do_ancestors(ClassNref) of
				{ok, Ancestors} ->
					AllNodes = [Node | Ancestors],
					QcNrefs = collect_all_qcs(AllNodes, QcAttr),
					{ok, QcNrefs};
				{error, _} = Err ->
					Err
			end;
		{error, _} = Err ->
			Err
	end.


%%-----------------------------------------------------------------------------
%% collect_all_qcs(Nodes, QcAttr) -> [integer()]
%%
%% Collects QC nrefs from a list of nodes, deduplicating in list order
%% (earlier entries take priority).
%%-----------------------------------------------------------------------------
collect_all_qcs(Nodes, QcAttr) ->
	lists:foldl(fun(#node{attribute_value_pairs = AVPs}, Acc) ->
		Qcs = collect_qc_nrefs(AVPs, QcAttr),
		lists:foldl(fun(Q, A) ->
			case lists:member(Q, A) of
				true  -> A;
				false -> A ++ [Q]
			end
		end, Acc, Qcs)
	end, [], Nodes).
