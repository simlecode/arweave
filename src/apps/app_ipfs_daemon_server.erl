-module(app_ipfs_daemon_server).
-export([start/0, stop/0, handle/3]).
-export([put_key_wallet_address/2, put_key_wallet/2, get_key_q_wallet/1, del_key/1]).
-export([already_reported/2]).
-export([cleaner_upper/0, ipfs_getter/4, sufficient_funds/2]).
-include("ar.hrl").

-ifdef(DEBUG).
-define(CLEANER_WAIT, 6 * 60 * 1000).
-define(MAX_IPFSAR_PENDING, 3).
-define(N_STATS_TO_KEEP, 25).
-else.
-define(CLEANER_WAIT, 6 * 60 * 60 * 1000).
-define(MAX_IPFSAR_PENDING, 100).
-define(N_STATS_TO_KEEP, 250).
-endif.

-type elli_http_method() :: 'GET' | 'POST'.
-type elli_http_request() :: term().
-type elli_http_response() :: {non_neg_integer(), list(), binary()}.
-type path() :: list(binary()).
%	POST [<<"getsend">>] |
%	GET  [<<"balance">>, APIKey] |
%	GET  [<<"status">>, APIKey].
-type ipfs_status() :: pending | queued | nofunds | mined.

-record(ipfsar_key_q_wal, {api_key, queue_pid, wallet}).
-record(ipfsar_ipfs_status, {
	api_key,
	ipfs_hash,
	status :: ipfs_status(),
	timestamp :: non_neg_integer()
	}).
-record(ipfsar_most_recent, {api_key, ipfs_hash, status, timestamp}).

%% @doc Start anything that needs to be started.  So far, just the mnesia table.
start() ->
	%% assume mnesia already started (used in ar_tx_search)
	create_mnesia_table(ipfsar_key_q_wal,   set, record_info(fields, ipfsar_key_q_wal)),
	create_mnesia_table(ipfsar_ipfs_status, bag, record_info(fields, ipfsar_ipfs_status)),
	create_mnesia_table(ipfsar_most_recent, set, record_info(fields, ipfsar_most_recent)),
	spawn(?MODULE, cleaner_upper, []).

%% @doc Stop all the queues.
stop() ->
	mnesia:foldl(fun(#ipfsar_key_q_wal{queue_pid=Q}, _) ->
			app_queue:stop(Q)
		end,
		ok,
		ipfsar_key_q_wal).

%% @doc Find the wallet keyfile for the given address, and call put_key_wal/2.
-spec put_key_wallet_address(binary(), binary()) -> ok.
put_key_wallet_address(Key, Addr) ->
	Filename = <<"wallets/arweave_keyfile_", Addr/binary, ".json">>,
	Wallet = ar_wallet:load_keyfile(Filename),
	put_key_wallet(Key, Wallet).

%% @doc Add a new {api_key, queue, wallet} tuple to the db.
put_key_wallet(K, W) ->
	Q = app_queue:start(W),
	F = fun() -> mnesia:write(#ipfsar_key_q_wal{api_key=K, queue_pid=Q, wallet=W}) end,
	mnesia:activity(transaction, F).

%% @doc get queue and wallet for the api key.
get_key_q_wallet(APIKey) ->
	case mnesia:dirty_select(
			ipfsar_key_q_wal,
			[{
				#ipfsar_key_q_wal{api_key=APIKey, queue_pid='$1', wallet='$2'},
				[],
				[['$1', '$2']]
			}]) of
		[[Queue, Wallet]] -> {ok, Queue, Wallet};
		_                 -> {error, not_found}
	end.

%% @doc remove record with api key from the db.
del_key(APIKey) ->
	F = fun() -> mnesia:delete({ipfsar_key_q_wal, APIKey}) end,
	mnesia:activity(transaction, F).

%% @doc Handle /api/ipfs/... calls.
-spec handle(atom(), list(binary()), elli_http_request()) ->
	elli_http_response().
handle(Method, Path, Req) ->
	case is_app_running() of
		true  -> really_handle(Method, Path, Req);
		false -> {503, [], <<"Service not running">>}
	end.

%%% Private functions.

%%% Handlers

-spec really_handle(elli_http_method(), path(), elli_http_request()) ->
	elli_http_response().
really_handle(Method, Path, Req) ->
	case validate_request(Method, Path, Req) of
		{error, Response} ->
			Response;
		{ok, Args} ->
			process_request(Method, Path, Args)
	end.

%%% Validators

%% @doc validate a request and return required info
-spec validate_request(elli_http_method(), path(), elli_http_request()) ->
	{ok, list()} | {error, elli_http_response()}.
validate_request('POST', [<<"getsend">>], Req) ->
	case validate_req_fields_auth(Req, [<<"api_key">>, <<"ipfs_hash">>]) of
		{ok, [APIKey, IPFSHash], Queue, Wallet} ->
			case already_reported(APIKey, IPFSHash) of
				{ok, _} ->
					case current_status(APIKey) of
						[{ok, nofunds}] ->
							{error, {402, [], <<"Insufficient funds in wallet">>}};
						_ ->
							case length(queued_status(APIKey, pending)) > ?MAX_IPFSAR_PENDING of
								true ->
									{error, {429, [], <<"Too many requests pending">>}};
								false ->
									{ok, [APIKey, Queue, Wallet, IPFSHash]}
							end
					end;
				{error, _} ->
					{error, {208, [], <<"Hash already reported by this user">>}}
			end;
		{error, Response} ->
			{error, Response}
	end;
validate_request('GET', [<<"status">>, APIKey], _Req) ->
	case is_authorized(APIKey) of
		{ok, _Queue, _Wallet} ->
			{ok, [APIKey]};
		{error, Response} ->
			{error, Response}
	end;
validate_request('GET', [<<"balance">>, APIKey], _Req) ->
	case is_authorized(APIKey) of
		{ok, _Queue, Wallet} ->
			{ok, [APIKey, Wallet]};
		{error, _} ->
			{error, {401, [], <<"Invalid API Key">>}}
	end;
validate_request(_,_,_) ->
	{error, {400, [], <<"Unrecognised request">>}}.

%%% Processors

%% @doc Process a validated request.
-spec process_request(elli_http_method(), path(), list()) -> elli_http_response().
process_request('POST', [<<"getsend">>], [APIKey, Queue, Wallet, IPFSHash]) ->
	spawn(?MODULE, ipfs_getter, [APIKey, Queue, Wallet, IPFSHash]),
	update_status(APIKey, IPFSHash, pending),
	{200, [], <<"Request sent to queue">>};
process_request('GET', [<<"status">>, APIKey], [APIKey]) ->
	JsonS = lists:reverse(lists:sort(lists:foldl(fun
			([T,H,S], Acc) ->
				Tiso = list_to_binary(calendar:system_time_to_rfc3339(T)),
				[{[{timestamp, Tiso}, {ipfs_hash, H}, {status, S}]}|Acc];
			([], Acc) ->
				Acc
		 end,
		[],
		queued_status(APIKey)))),
	JsonB = ar_serialize:jsonify(JsonS),
	{200, [], JsonB};
process_request('GET', [<<"balance">>, _APIKey], [_APIKey, Wallet]) ->
	Address = ar_wallet:to_address(Wallet),
	Balance = ar_node:get_balance(whereis(http_entrypoint_node), Wallet),
	JsonS = {[
		{address, ar_util:encode(Address)},
		{balance, integer_to_binary(Balance)}]},
	JsonB = ar_serialize:jsonify(JsonS),
	{200, [], JsonB}.

%%% Helpers

%% @doc return values for keys in key-val list - *if* all keys present.
-spec all_fields(list({term(), term()}), list()) -> {ok, binary(), list()} | error.
all_fields(KVs, Keys) ->
	MaybeAPIKey =
		case lists:keyfind(<<"api_key">>, 1, KVs) of
			{<<"api_key">>, V} -> {ok, V};
			false              -> error
		end,
	MaybeValues = lists:foldr(fun
		(_, error) -> error;
		(Key, {ok, Acc}) ->
			case lists:keyfind(Key, 1, KVs) of
				{Key, Val} -> {ok, [Val|Acc]};
				false      -> error
			end
		end,
		{ok, []}, Keys),
	case {MaybeAPIKey, MaybeValues} of
		{{ok, K}, {ok, Vs}} -> {ok, K, Vs};
		_ -> error
	end.

%% @doc Check if this user has already ipfs pinned this hash with us.
%% n.b.: just checks whether the hash has been mined into a tx, likelihood
%% of separate users uploading the same hash is low.
already_reported(APIKey, IPFSHash) ->
	%% case ar_tx_search:get_entries(<<"IPFS-Add">>, IPFSHash) of
	case queued_status_hash(APIKey, IPFSHash) of
		[] -> {ok, new_hash};
		_  -> {error, already_reported}
	end.

%% @doc remove old ipfsar_ipfs_status records.  Only keep newest 250 per key.
cleaner_upper() ->
	Keys = mnesia_get_keys(),
	lists:foreach(fun(APIKey) ->
			THSs = lists:reverse(lists:sort(queued_status(APIKey))),
			{ToKeep, ToDelete} = case length(THSs) > ?N_STATS_TO_KEEP of
				true -> lists:split(?N_STATS_TO_KEEP, THSs);
				false -> {THSs, []}
			end,
			lists:foreach(fun([T,H,S]) ->
					mnesia_del_obj(#ipfsar_ipfs_status{
						api_key=APIKey, timestamp=T, ipfs_hash=H, status=S})
				end,
				ToDelete),
			lists:foreach(fun
					([_, _, mined]) -> pass;
					([T, H, S]) ->
					case hash_mined(H) of
						false -> pass;
						true ->
							mnesia_del_obj(#ipfsar_ipfs_status{
								api_key=APIKey, timestamp=T, ipfs_hash=H, status=S}),
							mnesia_write(#ipfsar_ipfs_status{
								api_key=APIKey, timestamp=timestamp(),
								ipfs_hash=H, status=mined})
					end
				end,
				ToKeep)
		end,
		Keys),
	timer:apply_after(?CLEANER_WAIT, ?MODULE, cleaner_upper, []).

create_mnesia_table(Name, Type, Info) ->
	TabDef = [{attributes, Info}, {disc_copies, [node()]}, {type, Type}],
	mnesia:create_table(Name, TabDef).

current_status(APIKey) ->
	case mnesia:dirty_select(
			ipfsar_most_recent,
			[{
				#ipfsar_most_recent{api_key=APIKey, status='$1', _='_'},
				[],
				['$1']
			}]) of
		[Status] -> {ok, Status};
		_        -> {error, not_found}
	end.

hash_mined(Hash) ->
	case ar_tx_search:get_entries(<<"IPFS-Add">>, Hash) of
		[] -> false;
		_  -> true
	end.

ipfs_getter(APIKey, Queue, Wallet, IPFSHash) ->
	{ok, Data} = ar_ipfs:cat_data_by_hash(IPFSHash),
	UnsignedTX = #tx{tags=[{<<"IPFS-Add">>, IPFSHash}], data=Data},
	Status = case ?MODULE:sufficient_funds(Wallet, byte_size(Data)) of
		ok ->
			app_queue:add(Queue, UnsignedTX),
			%% tx will be added to ar_tx_search db after mined into block.
			queued;
		{error, _} ->
			nofunds
	end,
	update_status(APIKey, IPFSHash, Status).

%% @doc is the ipfs->ar service running?
is_app_running() ->
	try
		mnesia:table_info(ipfsar_key_q_wal, type),
		true
	catch
		exit:_ ->
			false
	end.

%% @doc Check if the API key is on the books. If so, return their wallet.
is_authorized(APIKey) ->
	?MODULE:get_key_q_wallet(APIKey).

queued_status(APIKey) ->
	mnesia:dirty_select(
			ipfsar_ipfs_status,
			[{
				#ipfsar_ipfs_status{api_key=APIKey,
					timestamp='$1', ipfs_hash='$2', status='$3'},
				[],
				[['$1','$2','$3']]
			}]).

queued_status(APIKey, Status) ->
	mnesia:dirty_select(
			ipfsar_ipfs_status,
			[{
				#ipfsar_ipfs_status{
					api_key=APIKey, status=Status,
					timestamp='$1', ipfs_hash='$2'},
				[],
				[['$1','$2']]
			}]).

queued_status_hash(APIKey, IPFSHash) ->
	mnesia:dirty_select(
			ipfsar_ipfs_status,
			[{
				#ipfsar_ipfs_status{
					api_key=APIKey, status='$2',
					timestamp='$1', ipfs_hash=IPFSHash},
				[],
				[['$1','$2']]
			}]).

%% @doc Given a request, returns the json body as a struct (or error).
request_to_struct(Req) ->
	try
		BlockJSON = elli_request:body(Req),
		{Struct} = ar_serialize:dejsonify(BlockJSON),
		{ok, Struct}
	catch
		Exception:Reason ->
			{error, {Exception, Reason}}
	end.

%% @doc Does the wallet have sufficient funds to submit the data.
-ifdef(DEBUG).
sufficient_funds(_, _) -> ok.
-else.
sufficient_funds(Wallet, DataSize) ->
	Diff = ar_node:get_current_diff(whereis(http_entrypoint_node)),
	Cost = ar_tx:calculate_min_tx_cost(DataSize, Diff),
	Balance = ar_node:get_balance(
		whereis(http_entrypoint_node),
		ar_wallet:to_address(Wallet)),
	case Balance > Cost of
		true  -> ok;
		false -> {error, insufficient_funds}
	end.
-endif.

timestamp() ->
	erlang:system_time(second).

update_status(APIKey, IPFSHash, Status) ->
	TS = timestamp(),
	R1 = #ipfsar_ipfs_status{
        api_key=APIKey, ipfs_hash=IPFSHash,
        status=Status, timestamp=TS},
	mnesia_write(R1),
	R2 = #ipfsar_most_recent{
        api_key=APIKey, ipfs_hash=IPFSHash,
        status=Status, timestamp=TS},
	mnesia_write(R2).

validate_req_fields_auth(Req, FieldsRequired) ->
	case request_to_struct(Req) of
		{ok, Struct} ->
			case all_fields(Struct, FieldsRequired) of
				{ok, APIKey, ReqFields} ->
					case is_authorized(APIKey) of
						{ok, Queue, Wallet} ->
								{ok, ReqFields, Queue, Wallet};
						{error, _} ->
							{error, {401, [], <<"Invalid API Key">>}}
					end;
				error ->
					{error, {400, [], <<"Invalid json fields">>}}
			end;
		{error, _} ->
			{error, {400, [], <<"Invalid json">>}}
	end.

mnesia_write(Record) ->
	F = fun() -> mnesia:write(Record) end,
	mnesia:activity(transaction, F).

mnesia_del_obj(Obj) ->
	F = fun() -> mnesia:delete_object(Obj) end,
	mnesia:activity(transaction, F).

mnesia_get_keys() ->
	mnesia:dirty_select(
		ipfsar_key_q_wal,
		[{
			#ipfsar_key_q_wal{api_key='$1', _='_'},
			[],
			['$1']
		}]).
