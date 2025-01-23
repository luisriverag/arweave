-module(ar_sync_pack_mine_tests).

-include_lib("arweave/include/ar.hrl").
-include_lib("arweave/include/ar_config.hrl").
-include_lib("arweave/include/ar_consensus.hrl").
-include_lib("eunit/include/eunit.hrl").

%% --------------------------------------------------------------------------------------------
%% Fixtures
%% --------------------------------------------------------------------------------------------
setup_source_node(PackingType) ->
	SourceNode = peer1,
	SinkNode = peer2,
	ar_test_node:stop(SinkNode),
	{Blocks, _SourceAddr, Chunks} = ar_e2e:start_source_node(SourceNode, PackingType, wallet_a),

	{Blocks, Chunks, PackingType}.

instantiator(GenesisData, SinkPackingType, TestFun) ->
	{timeout, 300, {with, {GenesisData, SinkPackingType}, [TestFun]}}.
	
%% --------------------------------------------------------------------------------------------
%% Test Registration
%% --------------------------------------------------------------------------------------------

replica_2_9_block_sync_test_() ->
	{setup, fun () -> setup_source_node(replica_2_9) end, 
		fun (GenesisData) ->
				[
					instantiator(GenesisData, replica_2_9, fun test_syncing_blocked/1),
					instantiator(GenesisData, spora_2_6, fun test_syncing_blocked/1),
					instantiator(GenesisData, composite_1, fun test_syncing_blocked/1),
					instantiator(GenesisData, unpacked, fun test_syncing_blocked/1)
				]
		end}.

spora_2_6_sync_pack_mine_test_() ->
	{setup, fun () -> setup_source_node(spora_2_6) end, 
		fun (GenesisData) ->
				[
					instantiator(GenesisData, replica_2_9, fun test_sync_pack_mine/1),
					instantiator(GenesisData, spora_2_6, fun test_sync_pack_mine/1),
					instantiator(GenesisData, composite_1, fun test_sync_pack_mine/1),
					instantiator(GenesisData, unpacked, fun test_sync_pack_mine/1)
				]
		end}.

composite_1_sync_pack_mine_test_() ->
	{setup, fun () -> setup_source_node(composite_1) end, 
		fun (GenesisData) ->
				[
					instantiator(GenesisData, replica_2_9, fun test_sync_pack_mine/1),
					instantiator(GenesisData, spora_2_6, fun test_sync_pack_mine/1),
					instantiator(GenesisData, composite_1, fun test_sync_pack_mine/1),
					instantiator(GenesisData, unpacked, fun test_sync_pack_mine/1)
				]
		end}.

unpacked_sync_pack_mine_test_() ->
	{setup, fun () -> setup_source_node(unpacked) end, 
		fun (GenesisData) ->
				[
					instantiator(GenesisData, replica_2_9, fun test_sync_pack_mine/1),
					instantiator(GenesisData, spora_2_6, fun test_sync_pack_mine/1),
					instantiator(GenesisData, composite_1, fun test_sync_pack_mine/1),
					instantiator(GenesisData, unpacked, fun test_sync_pack_mine/1)
				]
		end}.

unpacked_and_packed_sync_pack_mine_test_() ->
	{setup, fun () -> setup_source_node(unpacked) end, 
		fun (GenesisData) ->
				[
					instantiator(GenesisData, replica_2_9, 
						fun test_unpacked_and_packed_sync_pack_mine/1)
				]
		end}.

%% --------------------------------------------------------------------------------------------
%% test_sync_pack_mine
%% --------------------------------------------------------------------------------------------
test_sync_pack_mine({{Blocks, Chunks, SourcePackingType}, SinkPackingType}) ->
	ar_e2e:delayed_print(<<" ~p -> ~p ">>, [SourcePackingType, SinkPackingType]),
	[B0 | _] = Blocks,
	SourceNode = peer1,
	SinkNode = peer2,

	SinkPacking = start_sink_node(SinkNode, SourceNode, B0, SinkPackingType),
	ar_e2e:assert_syncs_range(
		SinkNode,
		?PARTITION_SIZE,
		2*?PARTITION_SIZE + ar_storage_module:get_overlap(SinkPacking)),
	ar_e2e:assert_chunks(SinkNode, SinkPacking, Chunks),

	case SinkPackingType of
		unpacked ->
			ok;
		_ ->
			CurrentHeight = max(
				ar_test_node:remote_call(SourceNode, ar_node, get_height, []),
				ar_test_node:remote_call(SinkNode, ar_node, get_height, [])
			),
			ar_test_node:wait_until_height(SourceNode, CurrentHeight),
			ar_test_node:wait_until_height(SinkNode, CurrentHeight),
			ar_test_node:mine(SinkNode),

			SinkBI = ar_test_node:wait_until_height(SinkNode, CurrentHeight + 1),
			{ok, SinkBlock} = ar_test_node:http_get_block(element(1, hd(SinkBI)), SinkNode),
			ar_e2e:assert_block(SinkPacking, SinkBlock),

			SourceBI = ar_test_node:wait_until_height(SourceNode, SinkBlock#block.height),
			{ok, SourceBlock} = ar_test_node:http_get_block(element(1, hd(SourceBI)), SourceNode),
			?assertEqual(SinkBlock, SourceBlock),
			ok
	end.

test_syncing_blocked({{Blocks, Chunks, SourcePackingType}, SinkPackingType}) ->
	ar_e2e:delayed_print(<<" ~p -> ~p ">>, [SourcePackingType, SinkPackingType]),
	[B0 | _] = Blocks,
	SourceNode = peer1,
	SinkNode = peer2,

	start_sink_node(SinkNode, SourceNode, B0, SinkPackingType),
	ar_e2e:assert_does_not_sync_range(SinkNode, ?PARTITION_SIZE, 2*?PARTITION_SIZE),
	ar_e2e:assert_no_chunks(SinkNode, Chunks).

test_unpacked_and_packed_sync_pack_mine({{Blocks, Chunks, SourcePackingType}, PackingType}) ->
	ar_e2e:delayed_print(<<" ~p -> {~p, ~p} ">>, [SourcePackingType, PackingType, unpacked]),
	[B0 | _] = Blocks,
	SourceNode = peer1,
	SinkNode = peer2,

	{SinkPacking, unpacked} = start_sink_node(SinkNode, SourceNode, B0, PackingType, unpacked),
	ar_e2e:assert_syncs_range(
		SinkNode,
		?PARTITION_SIZE,
		2*?PARTITION_SIZE + ar_storage_module:get_overlap(SinkPacking)),
	ar_e2e:assert_partition_size(SinkNode, 1, SinkPacking),
	ar_e2e:assert_partition_size(SinkNode, 1, unpacked),

	CurrentHeight = ar_test_node:remote_call(SinkNode, ar_node, get_height, []),
	ar_test_node:mine(SinkNode),

	SinkBI = ar_test_node:wait_until_height(SinkNode, CurrentHeight + 1),
	{ok, SinkBlock} = ar_test_node:http_get_block(element(1, hd(SinkBI)), SinkNode),
	ar_e2e:assert_block(SinkPacking, SinkBlock),

	SourceBI = ar_test_node:wait_until_height(SourceNode, SinkBlock#block.height),
	{ok, SourceBlock} = ar_test_node:http_get_block(element(1, hd(SourceBI)), SourceNode),
	?assertEqual(SinkBlock, SourceBlock),
	ok.
	

start_sink_node(Node, SourceNode, B0, PackingType) ->
	Wallet = ar_test_node:remote_call(Node, ar_e2e, load_wallet_fixture, [wallet_b]),
	SinkAddr = ar_wallet:to_address(Wallet),
	SinkPacking = ar_e2e:packing_type_to_packing(PackingType, SinkAddr),
	{ok, Config} = ar_test_node:get_config(Node),
	
	StorageModules = [
		{?PARTITION_SIZE, 1, SinkPacking}
	],
	?assertEqual(ar_test_node:peer_name(Node),
		ar_test_node:start_other_node(Node, B0, Config#config{
			peers = [ar_test_node:peer_ip(SourceNode)],
			start_from_latest_state = true,
			storage_modules = StorageModules,
			auto_join = true,
			mining_addr = SinkAddr
		}, true)
	),

	SinkPacking.

start_sink_node(Node, SourceNode, B0, PackingType1, PackingType2) ->
	Wallet = ar_test_node:remote_call(Node, ar_e2e, load_wallet_fixture, [wallet_b]),
	SinkAddr = ar_wallet:to_address(Wallet),
	SinkPacking1 = ar_e2e:packing_type_to_packing(PackingType1, SinkAddr),
	SinkPacking2 = ar_e2e:packing_type_to_packing(PackingType2, SinkAddr),
	{ok, Config} = ar_test_node:get_config(Node),
	
	StorageModules = [
		{?PARTITION_SIZE, 1, SinkPacking1},
		{?PARTITION_SIZE, 1, SinkPacking2}
	],

	?assertEqual(ar_test_node:peer_name(Node),
		ar_test_node:start_other_node(Node, B0, Config#config{
			peers = [ar_test_node:peer_ip(SourceNode)],
			start_from_latest_state = true,
			storage_modules = StorageModules,
			auto_join = true,
			mining_addr = SinkAddr
		}, true)
	),
	{SinkPacking1, SinkPacking2}.