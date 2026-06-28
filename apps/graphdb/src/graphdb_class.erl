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
%%				Qualifying characteristics (QCs) are stored directly
%%				as AVPs on the class node using the attribute nref as
%%				key: #{attribute => AttrNref, value => undefined} for a
%%				declared-but-unbound QC, or #{attribute => AttrNref,
%%				value => V} for a class-level bound value.  No sentinel
%%				attribute is needed.
%%---------------------------------------------------------------------
%% Revision History
%%---------------------------------------------------------------------
%% Rev PA1 Date: *** 2008 Author: Dallas Noyes (dallas.noyes@gmail.com)
%% Stub implementation.
%%---------------------------------------------------------------------
%% Rev A Date: April 2026 Author: (completion of Dallas Noyes's design)
%% Initial implementation: taxonomic hierarchy over Mnesia.  Provides
%% create_class/2, add_qualifying_characteristic/2, get_class/1,
%% subclasses/1, ancestors/1, inherited_qcs/1.
%% Unified QC AVP shape — value=>undefined for declarations.
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
-include_lib("graphdb/include/graphdb_nrefs.hrl").

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
	instantiable_nref				%% integer() -- seeded `instantiable` marker, cached
									%% from graphdb_attr at init
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
		create_class/3,
		add_superclass/2,
		add_qualifying_characteristic/2,
		add_qualifying_characteristic/3,
		bind_qc_value/3,
		add_template/2,
		%% Lookups
		get_class/1,
		subclasses/1,
		ancestors/1,
		get_template/1,
		get_template_in_txn/1,
		templates_for_class/1,
		default_template/1,
		default_template_in_txn/1,
		find_template_by_name_in_txn/2,
		is_instantiable/1,
		%% Class-ancestry + template-scope helpers (used by graphdb_instance
		%% to validate Template AVP class scope on Connection arcs)
		class_in_ancestry/2,
		class_in_ancestry_in_txn/2,
		validate_template_scope_in_txn/3,
		%% Inheritance (search_class_taxonomy backs graphdb_instance's
		%% Priority-2 class-bound attribute resolution)
		inherited_qcs/1,
		search_class_taxonomy/2
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
		collect_qc_avps/1,
		is_instance_only/1,
		validate_instance_only_avps/1
		]).
-endif.


%%=============================================================================
%% Exported External API Functions
%%=============================================================================

start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


%%-----------------------------------------------------------------------------
%% create_class(Name, ParentClassNref)       -> {ok, Nref} | {error, term()}
%% create_class(Name, ParentClassNref, AVPs) -> {ok, Nref} | {error, term()}
%%
%% Creates a new class node in the ontology.  ParentClassNref
%% is either the Classes category (nref 3) for top-level classes or
%% another class node's nref for subclasses.  Atomically writes the
%% class node, the taxonomic parent/child arc pair, the default
%% template node (kind=template, parent=ClassNref, name "default"),
%% and the compositional class -> template arc pair.
%%
%% The /3 form prepends AVPs (a list of attribute-value pair maps) to the
%% class node's attribute_value_pairs, after the class-name AVP; /2 is the
%% same with an empty AVP list.
%%
%% Class authors may later delete the default template to force
%% explicit Template specification on subsequent Connection arcs
%% involving instances of this class, or call add_template/2 to
%% attach additional named templates as compositional children.
%%-----------------------------------------------------------------------------
create_class(Name, ParentClassNref) ->
	create_class(Name, ParentClassNref, []).

create_class(Name, ParentClassNref, AVPs) when is_list(AVPs) ->
	gen_server:call(?MODULE, {create_class, Name, ParentClassNref, AVPs}).


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

add_qualifying_characteristic(ClassNref, AttrNref, Opts) when is_map(Opts) ->
	gen_server:call(?MODULE,
		{add_qualifying_characteristic, ClassNref, AttrNref, Opts}).


%%-----------------------------------------------------------------------------
%% bind_qc_value(ClassNref, AttrNref, Value) -> ok | {error, term()}
%%
%% Sets the bound value for a declared qualifying characteristic on the
%% class.  The QC must already exist on the class node (declared via
%% add_qualifying_characteristic/2); calling bind_qc_value/3 on an
%% undeclared QC returns {error, qc_not_declared}.  Replaces any
%% previously-bound value for the same QC.  This is the Priority-2 input
%% for graphdb_instance:resolve_value/2 inheritance.
%%-----------------------------------------------------------------------------
bind_qc_value(ClassNref, AttrNref, Value) ->
	gen_server:call(?MODULE, {bind_qc_value, ClassNref, AttrNref, Value}).


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
%% is_instantiable(ClassNref) -> boolean() | {error, term()}
%%
%% false iff the class carries an instantiable=>false marker AVP.
%%-----------------------------------------------------------------------------
is_instantiable(ClassNref) ->
	gen_server:call(?MODULE, {is_instantiable, ClassNref}).


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
%% inherited_qcs(ClassNref) ->
%%     {ok, [{integer(), term() | undefined}]} | {error, term()}
%%
%% Returns the list of qualifying-characteristic {AttrNref, Value} pairs
%% that apply to this class, including those inherited from ancestor
%% classes.  Local QCs appear first; ancestor QCs are appended in
%% nearest-first BFS order with duplicates removed (local takes
%% priority).  A Value of `undefined` means the QC is declared but not
%% bound at this level.
%%-----------------------------------------------------------------------------
inherited_qcs(ClassNref) ->
	gen_server:call(?MODULE, {inherited_qcs, ClassNref}).


%%=============================================================================
%% gen_server Behaviour Callbacks
%%=============================================================================

%%-----------------------------------------------------------------------------
%% init/1
%%-----------------------------------------------------------------------------
init([]) ->
	%% graphdb_attr is started before graphdb_class by graphdb_sup, so
	%% seeded_nrefs/0 is answerable here.
	{ok, #{instantiable := InstAttr}} = graphdb_attr:seeded_nrefs(),
	logger:info("graphdb_class: started (instantiable=~p)", [InstAttr]),
	{ok, #state{instantiable_nref = InstAttr}}.


%%-----------------------------------------------------------------------------
%% handle_call/3 -- Creators
%%-----------------------------------------------------------------------------
handle_call({create_class, Name, ParentClassNref, AVPs}, _From,
		#state{instantiable_nref = InstAttr} = State) ->
	{reply, do_create_class(Name, ParentClassNref, AVPs, InstAttr), State};

handle_call({add_superclass, ClassNref, AdditionalParentNref}, _From, State) ->
	{reply, do_add_superclass(ClassNref, AdditionalParentNref), State};

handle_call({add_qualifying_characteristic, ClassNref, AttrNref}, _From,
		State) ->
	{reply, do_add_qc(ClassNref, AttrNref), State};

handle_call({add_qualifying_characteristic, ClassNref, AttrNref, Opts}, _From,
		State) ->
	{reply, do_add_qc(ClassNref, AttrNref, Opts), State};

handle_call({bind_qc_value, ClassNref, AttrNref, Value}, _From, State) ->
	{reply, do_bind_qc_value(ClassNref, AttrNref, Value), State};

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

handle_call({is_instantiable, ClassNref}, _From,
		#state{instantiable_nref = InstAttr} = State) ->
	Reply = case mnesia:dirty_read(nodes, ClassNref) of
		[#node{kind = class, attribute_value_pairs = AVPs}] ->
			not is_marked_non_instantiable(AVPs, InstAttr);
		[#node{kind = Kind}] -> {error, {not_a_class, Kind}};
		[]                   -> {error, class_not_found}
	end,
	{reply, Reply, State};

%%-----------------------------------------------------------------------------
%% handle_call/3 -- Inheritance
%%-----------------------------------------------------------------------------
handle_call({inherited_qcs, ClassNref}, _From, State) ->
	{reply, do_inherited_qcs(ClassNref), State};

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
%% do_create_class(Name, ParentClassNref, AVPs, InstAttr) ->
%%     {ok, Nref} | {error, term()}
%%
%% Validates the parent, allocates nrefs OUTSIDE the Mnesia transaction
%% (to avoid side-effects on retry), then atomically writes:
%%   - the class node (kind=class)
%%   - taxonomic parent/child arc pair  (kind=taxonomy, char 26/25)
%%   - the default template node (kind=template, parent=class) UNLESS the
%%     class is marked non-instantiable (instantiable=>false in AVPs)
%%   - compositional class -> template arc pair (kind=composition, char 26/25)
%%     (omitted for non-instantiable classes)
%%
%% InstAttr is the cached `instantiable` attribute nref from #state{}.
%% template_rows/3 is evaluated BEFORE the Txn fun is built so that all
%% nref/id allocation stays outside the transaction.
%%-----------------------------------------------------------------------------
do_create_class(Name, ParentClassNref, AVPs, InstAttr) ->
	case validate_instance_only_avps(AVPs) of
		{error, _} = Err ->
			Err;
		ok ->
			case do_validate_parent(ParentClassNref) of
				ok ->
					ClassNref        = graphdb_nref:get_next(),
					{TaxId1, TaxId2} = rel_id_server:get_id_pair(),
					ClassNameAVP = #{attribute => ?NAME_ATTR_CLASS, value => Name},
					ClassNode = #node{
						nref = ClassNref,
						kind = class,
						parents = [ParentClassNref],
						attribute_value_pairs = [ClassNameAVP | AVPs]
					},
					TaxP2C = #relationship{
						id = TaxId1, kind = taxonomy,
						source_nref = ParentClassNref,
						characterization = ?ARC_CLS_CHILD,
						target_nref = ClassNref,
						reciprocal = ?ARC_CLS_PARENT,
						avps = []
					},
					TaxC2P = #relationship{
						id = TaxId2, kind = taxonomy,
						source_nref = ClassNref,
						characterization = ?ARC_CLS_PARENT,
						target_nref = ParentClassNref,
						reciprocal = ?ARC_CLS_CHILD,
						avps = []
					},
					TemplateRows = template_rows(ClassNref, AVPs, InstAttr),
					Txn = fun() ->
						ok = mnesia:write(nodes, ClassNode, write),
						ok = mnesia:write(relationships, TaxP2C, write),
						ok = mnesia:write(relationships, TaxC2P, write),
						[ ok = mnesia:write(T, R, write) || {T, R} <- TemplateRows ]
					end,
					case graphdb_mgr:transaction(Txn) of
						%% Txn value is [] (abstract) or [ok,ok,ok] (template rows)
						{ok, _Writes}    -> {ok, ClassNref};
						{error, _} = Err -> Err
					end;
				{error, _} = Err ->
					Err
			end
	end.


%%-----------------------------------------------------------------------------
%% template_rows(ClassNref, AVPs, InstAttr) -> [{Table, Record}]
%%
%% Returns the default-template node + class<->template composition arc
%% pair, or [] when the class is marked non-instantiable.
%% All nref and relationship-id allocation happens here, OUTSIDE the
%% calling transaction, so retries are side-effect-free.
%%-----------------------------------------------------------------------------
template_rows(ClassNref, AVPs, InstAttr) ->
	case is_marked_non_instantiable(AVPs, InstAttr) of
		true  -> [];
		false ->
			TemplateNref               = graphdb_nref:get_next(),
			{TmplCompId1, TmplCompId2} = rel_id_server:get_id_pair(),
			TemplateNameAVP = #{attribute => ?NAME_ATTR_CLASS,
				value => ?DEFAULT_TEMPLATE_NAME},
			TemplateNode = #node{
				nref = TemplateNref,
				kind = template,
				parents = [ClassNref],
				attribute_value_pairs = [TemplateNameAVP]
			},
			TmplP2C = #relationship{
				id = TmplCompId1, kind = composition,
				source_nref = ClassNref,
				characterization = ?ARC_CLS_CHILD,
				target_nref = TemplateNref,
				reciprocal = ?ARC_CLS_PARENT,
				avps = []
			},
			TmplC2P = #relationship{
				id = TmplCompId2, kind = composition,
				source_nref = TemplateNref,
				characterization = ?ARC_CLS_PARENT,
				target_nref = ClassNref,
				reciprocal = ?ARC_CLS_CHILD,
				avps = []
			},
			[{nodes, TemplateNode},
			 {relationships, TmplP2C},
			 {relationships, TmplC2P}]
	end.


%%-----------------------------------------------------------------------------
%% is_marked_non_instantiable(AVPs, InstAttr) -> boolean()
%%
%% Returns true when AVPs contains #{attribute => InstAttr, value => false}.
%% Deliberately duplicated in graphdb_instance (the two workers share no
%% module); this avoids a shared util for one predicate (YAGNI).
%%-----------------------------------------------------------------------------
is_marked_non_instantiable(AVPs, InstAttr) ->
	lists:any(fun
		(#{attribute := A, value := false}) when A =:= InstAttr -> true;
		(_) -> false
	end, AVPs).


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
	{Id1, Id2} = rel_id_server:get_id_pair(),
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
					characterization = ?ARC_CLS_PARENT,
					target_nref = AdditionalParentNref,
					reciprocal = ?ARC_CLS_CHILD,
					avps = []
				},
				P2C = #relationship{
					id = Id2, kind = taxonomy,
					source_nref = AdditionalParentNref,
					characterization = ?ARC_CLS_CHILD,
					target_nref = ClassNref,
					reciprocal = ?ARC_CLS_PARENT,
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
	case graphdb_mgr:transaction(Txn) of
		{ok, ok}             -> ok;
		{ok, already_exists} -> ok;
		{error, _} = Err     -> Err
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
	TemplateNref = graphdb_nref:get_next(),
	{Id1, Id2} = rel_id_server:get_id_pair(),
	NameAVP = #{attribute => ?NAME_ATTR_CLASS, value => Name},
	Node = #node{
		nref = TemplateNref,
		kind = template,
		parents = [ClassNref],
		attribute_value_pairs = [NameAVP]
	},
	P2C = #relationship{
		id = Id1, kind = composition,
		source_nref = ClassNref,
		characterization = ?ARC_CLS_CHILD,
		target_nref = TemplateNref,
		reciprocal = ?ARC_CLS_PARENT,
		avps = []
	},
	C2P = #relationship{
		id = Id2, kind = composition,
		source_nref = TemplateNref,
		characterization = ?ARC_CLS_PARENT,
		target_nref = ClassNref,
		reciprocal = ?ARC_CLS_CHILD,
		avps = []
	},
	Txn = fun() ->
		ok = mnesia:write(nodes, Node, write),
		ok = mnesia:write(relationships, P2C, write),
		ok = mnesia:write(relationships, C2P, write)
	end,
	case graphdb_mgr:transaction(Txn) of
		{ok, ok}         -> {ok, TemplateNref};
		{error, _} = Err -> Err
	end.


%%-----------------------------------------------------------------------------
%% do_find_template_by_name(ClassNref, Name) -> {ok, Nref} | not_found
%%
%% Looks up a template-kind child of ClassNref whose name AVP matches.
%% Templates and classes share the class NameAttrNref (19); the kind
%% filter ensures we only return templates.
%%-----------------------------------------------------------------------------
do_find_template_by_name(ClassNref, Name) ->
	case graphdb_mgr:transaction(fun() ->
			find_template_by_name_in_txn(ClassNref, Name)
		end) of
		{ok, {ok, Nref}} -> {ok, Nref};
		{ok, not_found}  -> not_found;
		{error, _}       -> not_found
	end.

template_has_name(#node{attribute_value_pairs = AVPs}, Name) ->
	lists:any(fun
		(#{attribute := ?NAME_ATTR_CLASS, value := V}) -> V =:= Name;
		(_) -> false
	end, AVPs).

%%-----------------------------------------------------------------------------
%% find_template_by_name_in_txn(ClassNref, Name) -> {ok, Nref} | not_found
%%
%% Tier-1 in-transaction primitive.  Assumes it runs inside an active mnesia
%% activity; reuses the bare-mnesia downward_children_by_arc/3 and
%% template_has_name/2.  Returns the kind=template child of ClassNref whose
%% class NameAttrNref (19) value equals Name, or not_found.
%%-----------------------------------------------------------------------------
find_template_by_name_in_txn(ClassNref, Name) ->
	Children = downward_children_by_arc(ClassNref, ?ARC_CLS_CHILD, composition),
	case lists:search(fun
			(#node{kind = template} = N) -> template_has_name(N, Name);
			(_)                           -> false
		end, Children) of
		{value, #node{nref = Nref}} -> {ok, Nref};
		false                       -> not_found
	end.

%%-----------------------------------------------------------------------------
%% default_template_in_txn(ClassNref) -> {ok, Nref} | not_found
%%
%% Tier-1 in-transaction twin of default_template/1.  Delegates to
%% find_template_by_name_in_txn/2 with ?DEFAULT_TEMPLATE_NAME.  Returns
%% not_found when ClassNref has no default template (e.g. an abstract class).
%%-----------------------------------------------------------------------------
default_template_in_txn(ClassNref) ->
	find_template_by_name_in_txn(ClassNref, ?DEFAULT_TEMPLATE_NAME).


%%-----------------------------------------------------------------------------
%% do_get_template(Nref) ->
%%     {ok, #node{}} | {error, not_found | not_a_template | term()}
%%-----------------------------------------------------------------------------
do_get_template(Nref) ->
	case mnesia:dirty_read(nodes, Nref) of
		[#node{kind = template} = Node] -> {ok, Node};
		[_Other]                        -> {error, not_a_template};
		[]                              -> {error, not_found}
	end.

%%-----------------------------------------------------------------------------
%% get_template_in_txn(Nref) ->
%%     {ok, #node{}} | {error, not_a_template | not_found}
%%
%% Tier-1 in-transaction twin of do_get_template/1.  Assumes it runs inside an
%% active mnesia activity; uses a bare mnesia:read.  See
%% docs/designs/atomic-add-relationship-primitives-design.md.
%%-----------------------------------------------------------------------------
get_template_in_txn(Nref) ->
	case mnesia:read(nodes, Nref) of
		[#node{kind = template} = Node] -> {ok, Node};
		[_Other]                        -> {error, not_a_template};
		[]                              -> {error, not_found}
	end.


%%-----------------------------------------------------------------------------
%% do_templates_for_class(ClassNref) -> {ok, [#node{}]} | {error, term()}
%%-----------------------------------------------------------------------------
do_templates_for_class(ClassNref) ->
	F = fun() ->
		Children = downward_children_by_arc(ClassNref, ?ARC_CLS_CHILD,
			composition),
		[N || N <- Children, N#node.kind =:= template]
	end,
	graphdb_mgr:transaction(F).


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
%% class_in_ancestry_in_txn(CandidateNref, ClassNref) -> boolean()
%%
%% Tier-1 in-transaction twin of do_class_in_ancestry/2.  Assumes it runs
%% inside an active mnesia activity; walks the taxonomic ancestry with bare
%% mnesia:read.  Returns false on any lookup error.
%%-----------------------------------------------------------------------------
class_in_ancestry_in_txn(CandidateNref, CandidateNref) ->
	true;
class_in_ancestry_in_txn(CandidateNref, ClassNref) ->
	case ancestors_in_txn(ClassNref) of
		{ok, Ancestors} ->
			lists:any(fun(#node{nref = N}) -> N =:= CandidateNref end, Ancestors);
		_ ->
			false
	end.

%%-----------------------------------------------------------------------------
%% ancestors_in_txn(ClassNref) -> {ok, [#node{}]} | {error, term()}
%%
%% Tier-1 in-transaction twin of do_ancestors/1: BFS over the multi-parent
%% taxonomic DAG with bare mnesia:read, nearest-first, each ancestor once,
%% the Classes category (nref 3) filtered out.
%%-----------------------------------------------------------------------------
ancestors_in_txn(ClassNref) ->
	case mnesia:read(nodes, ClassNref) of
		[#node{kind = class, parents = Parents}] ->
			Initial = [P || P <- Parents, P =/= ?NREF_CLASSES],
			walk_ancestors_in_txn(Initial, sets:from_list(Initial), []);
		[_] ->
			{error, not_a_class};
		[] ->
			{error, not_found}
	end.

walk_ancestors_in_txn([], _Visited, Acc) ->
	{ok, lists:reverse(Acc)};
walk_ancestors_in_txn([Nref | Rest], Visited, Acc) ->
	case mnesia:read(nodes, Nref) of
		[#node{kind = class, parents = Parents} = Node] ->
			New = [P || P <- Parents,
				P =/= ?NREF_CLASSES,
				not sets:is_element(P, Visited)],
			NewVisited = lists:foldl(fun sets:add_element/2, Visited, New),
			walk_ancestors_in_txn(Rest ++ New, NewVisited, [Node | Acc]);
		_ ->
			walk_ancestors_in_txn(Rest, Visited, Acc)
	end.


%%-----------------------------------------------------------------------------
%% validate_template_scope_in_txn(TemplateNref, SourceClass, TargetClass) -> ok
%%     (aborts invalid_template / template_class_not_in_ancestry)
%%
%% Confirms TemplateNref resolves to a kind=template node whose parent class is
%% in SourceClass's or TargetClass's taxonomic ancestry.  Tier-1 in-transaction
%% helper: assumes it runs inside an active mnesia activity and signals failure
%% via mnesia:abort/1.  Used by graphdb_instance to validate the Template AVP
%% class scope on Connection arcs.
%%-----------------------------------------------------------------------------
validate_template_scope_in_txn(TemplateNref, SourceClass, TargetClass) ->
	case get_template_in_txn(TemplateNref) of
		{ok, #node{parents = TmplParents}} ->
			TmplClass = head_parent(TmplParents),
			InSource = class_in_ancestry_in_txn(TmplClass, SourceClass),
			InTarget = class_in_ancestry_in_txn(TmplClass, TargetClass),
			case InSource orelse InTarget of
				true  -> ok;
				false -> mnesia:abort({template_class_not_in_ancestry,
					TemplateNref, TmplClass, SourceClass, TargetClass})
			end;
		{error, Reason} ->
			mnesia:abort({invalid_template, TemplateNref, Reason})
	end.

%% head_parent(Parents) -> integer() | undefined
%%
%% First element of a node's parents cache, or undefined when empty.
head_parent([])      -> undefined;
head_parent([P | _]) -> P.


%%-----------------------------------------------------------------------------
%% search_class_taxonomy(ClassNref, AttrNref) ->
%%     {ok, FoundClassNref, Value} | not_found
%%
%% Walks ClassNref and its taxonomy ancestors (nearest-first), returning the
%% first bound-AVP match together with the class nref where it was found.  Used
%% by graphdb_instance's attribute-inheritance resolution (Priority 2: class-
%% level bound values).  Runs in the caller's process and reads via the public
%% get_class/1 + ancestors/1 reads (behaviour-identical to its prior home in
%% graphdb_instance).
%%-----------------------------------------------------------------------------
search_class_taxonomy(ClassNref, AttrNref) ->
	case get_class(ClassNref) of
		{ok, #node{attribute_value_pairs = AVPs}} ->
			case find_avp_value(AVPs, AttrNref) of
				{ok, V} ->
					{ok, ClassNref, V};
				not_found ->
					case ancestors(ClassNref) of
						{ok, Ancestors} ->
							search_first_in_ancestors(Ancestors, AttrNref);
						_ ->
							not_found
					end
			end;
		_ ->
			not_found
	end.

search_first_in_ancestors([], _AttrNref) ->
	not_found;
search_first_in_ancestors(
		[#node{nref = N, attribute_value_pairs = AVPs} | Rest], AttrNref) ->
	case find_avp_value(AVPs, AttrNref) of
		{ok, V}   -> {ok, N, V};
		not_found -> search_first_in_ancestors(Rest, AttrNref)
	end.

%% find_avp_value(AVPs, AttrNref) -> {ok, Value} | not_found
%%
%% First AVP entry matching AttrNref with a bound (non-undefined) value.  An
%% entry with value => undefined is a QC declaration, not a resolved value, and
%% reads as not_found.  (Duplicated from graphdb_instance per the codebase's
%% deliberate per-worker micro-helper convention — no shared util module.)
find_avp_value([], _AttrNref) ->
	not_found;
find_avp_value([#{attribute := A, value := V} | _], A) when V =/= undefined ->
	{ok, V};
find_avp_value([#{attribute := A} | _], A) ->
	not_found;
find_avp_value([_ | Rest], AttrNref) ->
	find_avp_value(Rest, AttrNref).


%%-----------------------------------------------------------------------------
%% do_validate_parent(ParentNref) -> ok | {error, term()}
%%
%% Validates that ParentNref is either the Classes category (nref 3) or
%% an existing class node.
%%-----------------------------------------------------------------------------
do_validate_parent(?NREF_CLASSES) ->
	ok;
do_validate_parent(Nref) ->
	case mnesia:dirty_read(nodes, Nref) of
		[#node{kind = Kind}] ->
			case is_valid_parent_kind(Kind) of
				true  -> ok;
				false -> {error, {invalid_parent_kind, Kind}}
			end;
		[] -> {error, parent_not_found}
	end.


%%-----------------------------------------------------------------------------
%% do_add_qc(ClassNref, AttrNref) -> ok | {error, term()}
%% do_add_qc(ClassNref, AttrNref, Opts) -> ok | {error, term()}
%%
%% Adds the qualifying-characteristic AVP to the class node.  /2 is the
%% plain declared-unbound form (delegates to /3 with empty Opts).  /3
%% accepts Opts = #{instance_only => true} to stamp the instance-only
%% marker onto the canonical declared-unbound shape.
%%
%% Validates both ClassNref (must be class) and AttrNref (must be
%% attribute).  Idempotent: if any entry for AttrNref already exists
%% (regardless of value or flags), leaves it alone and returns ok.
%%-----------------------------------------------------------------------------
do_add_qc(ClassNref, AttrNref) ->
	do_add_qc(ClassNref, AttrNref, #{}).

do_add_qc(ClassNref, AttrNref, Opts) ->
	Txn = fun() ->
		case mnesia:read(nodes, ClassNref) of
			[#node{kind = class, attribute_value_pairs = AVPs} = Node] ->
				case mnesia:read(nodes, AttrNref) of
					[#node{kind = attribute}] ->
						Already = lists:any(fun(#{attribute := A}) -> A =:= AttrNref;
									   (_)              -> false
									end, AVPs),
						case Already of
							true ->
								already_exists;
							false ->
								NewAVP = new_qc_avp(AttrNref, Opts),
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
	case graphdb_mgr:transaction(Txn) of
		{ok, ok}             -> ok;
		{ok, already_exists} -> ok;
		{ok, {error, _} = E} -> E;
		{error, Reason}      -> {error, Reason}
	end.

%%-----------------------------------------------------------------------------
%% new_qc_avp(AttrNref, Opts) -> map()
%%
%% Builds the QC AVP for a fresh declaration.  `instance_only => true` in
%% Opts stamps the marker onto the canonical declared-unbound shape;
%% otherwise the plain declared-unbound shape is returned.
%%-----------------------------------------------------------------------------
new_qc_avp(AttrNref, Opts) ->
	Base = #{attribute => AttrNref, value => undefined},
	case maps:get(instance_only, Opts, false) of
		true  -> Base#{instance_only => true};
		false -> Base
	end.


%%-----------------------------------------------------------------------------
%% do_bind_qc_value(ClassNref, AttrNref, Value) -> ok | {error, term()}
%%
%% Updates the class node's AVP for the matching QC AttrNref in place.
%% Aborts with `qc_not_declared` when the QC was never added via
%% add_qualifying_characteristic/2.  Aborts with `not_a_class` for nodes
%% of any other kind, and `not_found` when the nref doesn't exist.
%%-----------------------------------------------------------------------------
do_bind_qc_value(ClassNref, AttrNref, Value) ->
	F = fun() ->
		case mnesia:read(nodes, ClassNref) of
			[#node{kind = class, attribute_value_pairs = AVPs} = N] ->
				Declared = lists:any(
					fun(#{attribute := A}) -> A =:= AttrNref;
					   (_)                 -> false
					end, AVPs),
				case Declared of
					false ->
						mnesia:abort(qc_not_declared);
					true ->
						case is_qc_instance_only(AVPs, AttrNref) of
							true ->
								mnesia:abort(
									{instance_only_attribute, AttrNref});
							false ->
								NewAVPs = update_qc_value(AVPs, AttrNref,
									Value),
								mnesia:write(nodes,
									N#node{attribute_value_pairs = NewAVPs},
									write)
						end
				end;
			[_] -> mnesia:abort(not_a_class);
			[]  -> mnesia:abort(not_found)
		end
	end,
	case graphdb_mgr:transaction(F) of
		{ok, ok}         -> ok;
		{error, _} = Err -> Err
	end.

%%-----------------------------------------------------------------------------
%% update_qc_value(AVPs, AttrNref, Value) -> NewAVPs
%%
%% Returns a copy of the AVP list with the entry matching AttrNref
%% updated to carry Value.  Non-matching entries are preserved in
%% place.  Caller has already verified that AttrNref is present in AVPs.
%%-----------------------------------------------------------------------------
update_qc_value(AVPs, AttrNref, Value) ->
	[case A of
		#{attribute := AttrNref} -> A#{value => Value};
		_                        -> A
	 end || A <- AVPs].

%%-----------------------------------------------------------------------------
%% is_qc_instance_only(AVPs, AttrNref) -> boolean()
%%
%% True iff the QC entry for AttrNref in AVPs carries the instance_only
%% marker. Caller has already verified AttrNref is present.
%%-----------------------------------------------------------------------------
is_qc_instance_only(AVPs, AttrNref) ->
	lists:any(fun(#{attribute := A} = E) when A =:= AttrNref ->
				 is_instance_only(E);
			 (_) -> false
		  end, AVPs).


%%-----------------------------------------------------------------------------
%% do_get_class(Nref) ->
%%     {ok, #node{}} | {error, not_found | not_a_class | term()}
%%-----------------------------------------------------------------------------
do_get_class(Nref) ->
	case mnesia:dirty_read(nodes, Nref) of
		[#node{kind = class} = Node] -> {ok, Node};
		[_Other]                     -> {error, not_a_class};
		[]                           -> {error, not_found}
	end.


%%-----------------------------------------------------------------------------
%% do_subclasses(ClassNref) -> {ok, [#node{}]} | {error, term()}
%%
%% Returns all direct child nodes of kind=class under ClassNref.
%%-----------------------------------------------------------------------------
do_subclasses(ClassNref) ->
	F = fun() ->
		Children = downward_children_by_arc(ClassNref, ?ARC_CLS_CHILD,
			taxonomy),
		[N || N <- Children, N#node.kind =:= class]
	end,
	graphdb_mgr:transaction(F).


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
	case mnesia:dirty_read(nodes, ClassNref) of
		[#node{kind = class, parents = Parents}] ->
			Initial = [P || P <- Parents, P =/= ?NREF_CLASSES],
			do_walk_ancestors(Initial, sets:from_list(Initial), []);
		[_] ->
			{error, not_a_class};
		[] ->
			{error, not_found}
	end.

%% BFS over the parent DAG.  Queue is the FIFO of nrefs to visit;
%% Visited is the set of all already-enqueued nrefs (so we never
%% enqueue the same nref twice); Acc accumulates emitted nodes in
%% reverse order.
do_walk_ancestors([], _Visited, Acc) ->
	{ok, lists:reverse(Acc)};
do_walk_ancestors([Nref | Rest], Visited, Acc) ->
	case mnesia:dirty_read(nodes, Nref) of
		[#node{kind = class, parents = Parents} = Node] ->
			New = [P || P <- Parents,
				P =/= ?NREF_CLASSES,
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
%% do_inherited_qcs(ClassNref) ->
%%     {ok, [{integer(), term() | undefined}]} | {error, term()}
%%
%% Collects {AttrNref, Value} pairs from the class and all its ancestors.
%% Local QCs appear first; ancestor QCs are appended in nearest-first
%% BFS order.  Deduplication is by AttrNref — first occurrence wins,
%% so a local binding takes priority over any ancestor binding for the
%% same attribute.
%%-----------------------------------------------------------------------------
do_inherited_qcs(ClassNref) ->
	case do_get_class(ClassNref) of
		{ok, Node} ->
			case do_ancestors(ClassNref) of
				{ok, Ancestors} ->
					AllNodes = [Node | Ancestors],
					{ok, collect_qc_avps(AllNodes)};
				{error, _} = Err ->
					Err
			end;
		{error, _} = Err ->
			Err
	end.


%%-----------------------------------------------------------------------------
%% collect_qc_avps(Nodes) -> [{integer(), term() | undefined}]
%%
%% Collects qualifying-characteristic {AttrNref, Value} pairs from a
%% list of nodes.  The class name AVP (attribute = ?NAME_ATTR_CLASS)
%% is excluded — it is not a QC.  Deduplicates by AttrNref in list order
%% (first occurrence wins).
%%-----------------------------------------------------------------------------
collect_qc_avps(Nodes) ->
	lists:foldl(fun(#node{attribute_value_pairs = AVPs}, Acc) ->
		lists:foldl(fun
			(#{attribute := ?NAME_ATTR_CLASS}, A) ->
				A;  % skip class name AVP
			(#{attribute := Attr, value := V}, A) ->
				case lists:keymember(Attr, 1, A) of
					true  -> A;
					false -> A ++ [{Attr, V}]
				end
		end, Acc, AVPs)
	end, [], Nodes).


%%-----------------------------------------------------------------------------
%% is_instance_only(QcMap) -> boolean()
%%
%% True iff a qualifying-characteristic AVP map carries the
%% `instance_only => true` marker. Pure; consumed by the bind_qc_value
%% and create_class enforcement gates.
%%-----------------------------------------------------------------------------
is_instance_only(#{instance_only := true}) -> true;
is_instance_only(_)                        -> false.


%%-----------------------------------------------------------------------------
%% validate_instance_only_avps(AVPs) ->
%%     ok | {error, {instance_only_attribute, integer()}}
%%
%% Rejects an initial create_class AVP list in which any entry is both
%% marked `instance_only => true` AND carries a concrete (non-undefined)
%% value. An instance-only QC declared unbound (value => undefined) is
%% accepted. Pure; returns the first offending attribute nref.
%%-----------------------------------------------------------------------------
validate_instance_only_avps(AVPs) ->
	case [A || #{attribute := A, value := V} = E <- AVPs,
		V =/= undefined, is_instance_only(E)] of
		[]      -> ok;
		[A | _] -> {error, {instance_only_attribute, A}}
	end.
