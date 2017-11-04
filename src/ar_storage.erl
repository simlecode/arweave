-module(ar_storage).
-export([write_block/1, read_block/1]).
-include("ar.hrl").
-include_lib("eunit/include/eunit.hrl").

%%% Reads and writes blocks from disk.

%% Where should the blocks be stored?
-define(BLOCK_DIR, "blocks").

%% @doc Write a block (with the hash.json as the filename) to disk.
write_block(B) ->
	file:write_file(
		Name = lists:flatten(
			io_lib:format(
				"~s/~w_~s.json",
				[?BLOCK_DIR, B#block.height, ar_util:encode(B#block.indep_hash)]
			)
		),
		ar_serialize:jsonify(ar_serialize:block_to_json_struct(B))
	),
	Name.

%% @doc Read a block from disk, given a hash.
read_block(B) when is_record(B, block) -> B;
read_block(ID) ->
	case filelib:wildcard(name(ID)) of
		[] -> unavailable;
		[Filename] -> do_read_block(Filename);
		Filenames -> lists:map(fun do_read_block/1, Filenames)
	end.

do_read_block(Filename) ->
	{ok, Binary} = file:read_file(Filename),
	ar_serialize:json_struct_to_block(binary_to_list(Binary)).

%% @doc Generate a wildcard search string for a block,
%% given a block, binary hash, or list.
name(Height) when is_integer(Height) ->
	?BLOCK_DIR ++ "/" ++ integer_to_list(Height) ++ "_*.json";
name(B) when is_record(B, block) ->
	?BLOCK_DIR
		++ "/"
		++ integer_to_list(B#block.height)
		++ "_"
		++ ar_util:encode(B#block.indep_hash)
		++ ".json";
name(BinHash) when is_binary(BinHash) ->
	?BLOCK_DIR ++ "/*_" ++ ar_util:encode(BinHash) ++ ".json".

%% @doc Test block storage.
store_and_retrieve_block_test() ->
	[B0] = ar_weave:init(),
	write_block(B0),
	B0 = read_block(B0),
	file:delete(name(B0)).