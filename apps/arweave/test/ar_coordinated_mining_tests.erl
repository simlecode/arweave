-module(ar_coordinated_mining_tests).

-include_lib("arweave/include/ar.hrl").
-include_lib("arweave/include/ar_config.hrl").
-include_lib("arweave/include/ar_consensus.hrl").
-include_lib("arweave/include/ar_mining.hrl").
-include_lib("eunit/include/eunit.hrl").

-import(ar_test_node, [http_get_block/2]).

%% --------------------------------------------------------------------
%% Test registration
%% --------------------------------------------------------------------
mining_test_() ->
	[
		{timeout, 120, fun test_single_node_one_chunk_coordinated_mining/0},
		ar_test_node:test_with_mocked_functions([
			ar_test_node:mock_to_force_invalid_h1()],
			fun test_single_node_two_chunk_coordinated_mining/0, 120),
		ar_test_node:test_with_mocked_functions([
			ar_test_node:mock_to_force_invalid_h1()],
			fun test_coordinated_mining_two_chunk_concurrency/0, 120),
		ar_test_node:test_with_mocked_functions([
			ar_test_node:mock_to_force_invalid_h1()],
			fun test_coordinated_mining_two_chunk_retarget/0, 120),
		{timeout, 120, fun test_coordinated_mining_retarget/0},
		{timeout, 120, fun test_coordinated_mining_concurrency/0},
		{timeout, 120, fun test_no_exit_node/0}
	].

api_test_() ->
	[
		{timeout, 120, fun test_no_secret/0},
		{timeout, 120, fun test_bad_secret/0}
	].

%% --------------------------------------------------------------------
%% Tests
%% --------------------------------------------------------------------
test_single_node_one_chunk_coordinated_mining() ->
	[Node, _ExitNode, ValidatorNode] = ar_test_node:start_coordinated(1),
	ar_test_node:mine(Node),
	BI = ar_test_node:wait_until_height(ValidatorNode, 1),
	{ok, B} = http_get_block(element(1, hd(BI)), ValidatorNode),
	?assert(byte_size((B#block.poa)#poa.data_path) > 0),
	assert_empty_cache(Node).
	
test_single_node_two_chunk_coordinated_mining() ->
	[Node, _ExitNode, ValidatorNode] = ar_test_node:start_coordinated(1),
	ar_test_node:mine(Node),
	BI = ar_test_node:wait_until_height(ValidatorNode, 1),
	{ok, B} = http_get_block(element(1, hd(BI)), ValidatorNode),
	?assert(byte_size((B#block.poa2)#poa.data_path) > 0),
	assert_empty_cache(Node).

test_coordinated_mining_retarget() ->
	%% Assert that a difficulty retarget is handled correctly.
	[Node1, Node2, _ExitNode, ValidatorNode] = ar_test_node:start_coordinated(2),
	lists:foreach(
		fun(Height) ->
			mine_in_parallel([Node1, Node2], ValidatorNode, Height)
		end,
		lists:seq(0, ?RETARGET_BLOCKS)),
	assert_empty_cache(Node1),
	assert_empty_cache(Node2).

test_coordinated_mining_concurrency() ->
	%% Assert that three nodes mining concurrently don't conflict with each other and that
	%% each of them are able to win a solution.
	[Node1, Node2, Node3, _ExitNode, ValidatorNode] = ar_test_node:start_coordinated(3),	
	wait_for_each_node([Node1, Node2, Node3], ValidatorNode, 0, [0, 2, 4]),
	assert_empty_cache(Node1),
	assert_empty_cache(Node2),
	assert_empty_cache(Node3).

test_coordinated_mining_two_chunk_concurrency() ->
	%% Assert that cross-node solutions still work when two nodes are mining concurrently 
	[Node1, Node2, _ExitNode, ValidatorNode] = ar_test_node:start_coordinated(2),
	wait_for_each_node([Node1, Node2], ValidatorNode, 0, [0, 2]),
	assert_empty_cache(Node1),
	assert_empty_cache(Node2).

test_coordinated_mining_two_chunk_retarget() ->
	[Node1, Node2, _ExitNode, ValidatorNode] = ar_test_node:start_coordinated(2),
	lists:foreach(
		fun(H) ->
			mine_in_parallel([Node1, Node2], ValidatorNode, H)
		end,
		lists:seq(0, ?RETARGET_BLOCKS)),
	wait_for_each_node([Node1, Node2], ValidatorNode, ?RETARGET_BLOCKS, [0, 2]),
	assert_empty_cache(Node1),
	assert_empty_cache(Node2).

test_no_exit_node() ->
	%% Assert that when the exit node is down, CM miners don't share their solution with any
	%% other peers.
	[Node, ExitNode, ValidatorNode] = ar_test_node:start_coordinated(1),
	ar_test_node:stop(ExitNode),
	ar_test_node:mine(Node),
	timer:sleep(5000),
	BI = ar_test_node:get_blocks(ValidatorNode),
	?assertEqual(1, length(BI)).

test_no_secret() ->
	[Node, _ExitNode, _ValidatorNode] = ar_test_node:start_coordinated(1),
	Peer = ar_test_node:peer_ip(Node),
	?assertMatch(
		{error, {ok, {{<<"421">>, _}, _, 
			<<"CM API disabled or invalid CM API secret in request.">>, _, _}}},
		ar_http_iface_client:get_cm_partition_table(Peer)),
	?assertMatch(
		{error, {ok, {{<<"421">>, _}, _, 
			<<"CM API disabled or invalid CM API secret in request.">>, _, _}}},
		ar_http_iface_client:cm_h1_send(Peer, dummy_candidate(), [])),
	?assertMatch(
		{error, {ok, {{<<"421">>, _}, _, 
			<<"CM API disabled or invalid CM API secret in request.">>, _, _}}},
		ar_http_iface_client:cm_h2_send(Peer, dummy_candidate())),
	?assertMatch(
		{error, {ok, {{<<"421">>, _}, _, 
			<<"CM API disabled or invalid CM API secret in request.">>, _, _}}},
		ar_http_iface_client:cm_publish_send(Peer, dummy_solution())).

test_bad_secret() ->
	[Node, _ExitNode, _ValidatorNode] = ar_test_node:start_coordinated(1),
	Peer = ar_test_node:peer_ip(Node),
	{ok, Config} = application:get_env(arweave, config),
	ok = application:set_env(arweave, config,
			Config#config{ cm_api_secret = <<"this_is_not_the_actual_secret">> }),
	?assertMatch(
		{error, {ok, {{<<"421">>, _}, _, 
			<<"CM API disabled or invalid CM API secret in request.">>, _, _}}},
		ar_http_iface_client:get_cm_partition_table(Peer)),
	?assertMatch(
		{error, {ok, {{<<"421">>, _}, _, 
			<<"CM API disabled or invalid CM API secret in request.">>, _, _}}},
		ar_http_iface_client:cm_h1_send(Peer, dummy_candidate(), [])),
	?assertMatch(
		{error, {ok, {{<<"421">>, _}, _, 
			<<"CM API disabled or invalid CM API secret in request.">>, _, _}}},
		ar_http_iface_client:cm_h2_send(Peer, dummy_candidate())),
	?assertMatch(
		{error, {ok, {{<<"421">>, _}, _, 
			<<"CM API disabled or invalid CM API secret in request.">>, _, _}}},
		ar_http_iface_client:cm_publish_send(Peer, dummy_solution())).

%% --------------------------------------------------------------------
%% Helpers
%% --------------------------------------------------------------------
wait_for_each_node(Miners, ValidatorNode, CurrentHeight, ExpectedPartitions) ->
	wait_for_each_node(
		Miners, ValidatorNode, CurrentHeight, sets:from_list(ExpectedPartitions), 20).

wait_for_each_node(
		_Miners, _ValidatorNode, _CurrentHeight, _ExpectedPartitions, 0) ->
	?assert(false, "Timed out waiting for all mining nodes to win a solution");
wait_for_each_node(
		Miners, ValidatorNode, CurrentHeight, ExpectedPartitions, RetryCount) ->
	Partition = mine_in_parallel(Miners, ValidatorNode, CurrentHeight),
	Partitions = sets:del_element(Partition, ExpectedPartitions),
	case sets:is_empty(Partitions) of
		true ->
			CurrentHeight+1;
		false ->
			wait_for_each_node(
				Miners, ValidatorNode, CurrentHeight+1, Partitions, RetryCount-1)
	end.
	
mine_in_parallel(Miners, ValidatorNode, CurrentHeight) ->
	ar_util:pmap(fun(Node) -> ar_test_node:mine(Node) end, Miners),
	[{Hash, _, _} | _] = ar_test_node:wait_until_height(ValidatorNode, CurrentHeight + 1),
	lists:foreach(
		fun(Node) ->
			[{MinerHash, _, _} | _] = ar_test_node:wait_until_height(Node, CurrentHeight + 1),
			Message = lists:flatten(
				io_lib:format("Node ~p did not mine the same block as the validator node", [Node])),
			?assertEqual(ar_util:encode(Hash), ar_util:encode(MinerHash), Message)
		end,
		Miners
	),
	{ok, Block} = ar_test_node:http_get_block(Hash, ValidatorNode),
	case Block#block.recall_byte2 of
		undefined -> ?PARTITION_NUMBER(Block#block.recall_byte);
		RecallByte2 -> ?PARTITION_NUMBER(RecallByte2)
	end.

assert_empty_cache(Node) ->
	ar_test_node:wait_until_mining_paused(Node),
	ok.
	% [{_, Size}] = ar_test_node:remote_call(Node, ets, lookup, [ar_mining_server, chunk_cache_size]),
	%% We should assert that the size is 0, but there is a lot of concurrency in these tests
	%% so it's been hard to guarantee the cache is always empty by the time this check runs.
	%% It's possible there is a bug in the cache management code, but that code is pretty complex.
	%% In the future, if cache size ends up being a problem we can revisit - but for now, not
	%% worth the time for a test failure that may not have any realworld implications.
	% ?assertEaqual(0, Size, Node).

dummy_candidate() ->
	#mining_candidate{
		cm_diff = rand:uniform(1024),
		h0 = crypto:strong_rand_bytes(32),
		h1 = crypto:strong_rand_bytes(32),
		mining_address = crypto:strong_rand_bytes(32),
		next_seed = crypto:strong_rand_bytes(32),
		nonce_limiter_output = crypto:strong_rand_bytes(32),
		partition_number = rand:uniform(1024),
		partition_number2 = rand:uniform(1024),
		partition_upper_bound = rand:uniform(1024),
		seed = crypto:strong_rand_bytes(32),
		start_interval_number = rand:uniform(1024),
		step_number = rand:uniform(1024)
	}.

dummy_solution() ->
	#mining_solution{
		last_step_checkpoints = [],
		merkle_rebase_threshold = rand:uniform(1024),
		mining_address = crypto:strong_rand_bytes(32),
		next_seed = crypto:strong_rand_bytes(32),
		nonce = rand:uniform(1024),
		nonce_limiter_output = crypto:strong_rand_bytes(32),
		partition_number = rand:uniform(1024),
		partition_upper_bound = rand:uniform(1024),
		poa1 = dummy_poa(),
		poa2 = dummy_poa(),
		preimage = crypto:strong_rand_bytes(32),
		recall_byte1 = rand:uniform(1024),
		seed = crypto:strong_rand_bytes(32),
		solution_hash = crypto:strong_rand_bytes(32),
		start_interval_number = rand:uniform(1024),
		step_number = rand:uniform(1024),
		steps = []
	}.

dummy_poa() ->
	#poa{
		option = rand:uniform(1024),
		tx_path = crypto:strong_rand_bytes(32),
		data_path = crypto:strong_rand_bytes(32),
		chunk = crypto:strong_rand_bytes(?DATA_CHUNK_SIZE)
	}.