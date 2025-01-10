-module(ar_repack).

-export([read_cursor/3, store_cursor/3, repack/5]).

-include("../include/ar.hrl").
-include("../include/ar_consensus.hrl").
-include("../include/ar_config.hrl").

-moduledoc """
	This module handles the repack-in-place logic. This logic is orchestrated by the
	ar_chunk_storage gen_servers.
""".

read_cursor(StoreID, TargetPacking, RangeStart) ->
	Filepath = ar_chunk_storage:get_filepath("repack_in_place_cursor2", StoreID),
	case file:read_file(Filepath) of
		{ok, Bin} ->
			case catch binary_to_term(Bin) of
				{Cursor, TargetPacking} when is_integer(Cursor) ->
					Cursor;
				_ ->
					ar_chunk_storage:get_chunk_bucket_start(RangeStart + 1)
			end;
		_ ->
			ar_chunk_storage:get_chunk_bucket_start(RangeStart + 1)
	end.

store_cursor(none, _StoreID, _TargetPacking) ->
	ok;
store_cursor(Cursor, StoreID, TargetPacking) ->
	Filepath = ar_chunk_storage:get_filepath("repack_in_place_cursor2", StoreID),
	file:write_file(Filepath, term_to_binary({Cursor, TargetPacking})).

advance_cursor(Cursor, RangeStart, RangeEnd) ->
	RepackIntervalSize = get_repack_interval_size(),
	SectorSize = ar_replica_2_9:get_sector_size(),
	Cursor2 = ar_chunk_storage:get_chunk_bucket_start(Cursor + SectorSize + ?DATA_CHUNK_SIZE),
	case Cursor2 > ar_chunk_storage:get_chunk_bucket_start(RangeEnd) of
		true ->
			RangeStart2 = ar_chunk_storage:get_chunk_bucket_start(RangeStart + 1),
			RelativeSectorOffset = (Cursor - RangeStart2) rem SectorSize,
			Cursor3 = RangeStart2
				+ RelativeSectorOffset
				+ min(RepackIntervalSize, SectorSize - RelativeSectorOffset),
			case Cursor3 > RangeStart2 + SectorSize of
				true ->
					none;
				false ->
					Cursor3
			end;
		false ->
			Cursor2
	end.

repack(none, _RangeStart, _RangeEnd, Packing, StoreID) ->
	ar:console("~n~nRepacking of ~s is complete! "
			"We suggest you stop the node, rename "
			"the storage module folder to reflect "
			"the new packing, and start the "
			"node with the new storage module.~n", [StoreID]),
	?LOG_INFO([{event, repacking_complete},
			{storage_module, StoreID},
			{target_packing, ar_serialize:encode_packing(Packing, true)}]),
	Server = ar_chunk_storage:name(StoreID),
	gen_server:cast(Server, repacking_complete);
repack(Cursor, RangeStart, RangeEnd, Packing, StoreID) ->
	RightBound = Cursor + get_repack_interval_size(),
	?LOG_DEBUG([{event, repacking_in_place},
			{tags, [repack_in_place]},
			{s, Cursor},
			{e, RightBound},
			{range_start, RangeStart},
			{range_end, RangeEnd},
			{packing, ar_serialize:encode_packing(Packing, true)},
			{store_id, StoreID}]),
	case ar_sync_record:get_next_synced_interval(Cursor, RightBound,
			ar_data_sync, StoreID) of
		not_found ->
			?LOG_DEBUG([{event, repack_in_place_no_synced_interval},
					{tags, [repack_in_place]},
					{storage_module, StoreID},
					{s, Cursor},
					{e, RightBound},
					{range_start, RangeStart},
					{range_end, RangeEnd}]),
			Server = ar_chunk_storage:name(StoreID),
			Cursor2 = advance_cursor(Cursor, RangeStart, RangeEnd),
			gen_server:cast(Server, {repack, Cursor2, RangeStart, RangeEnd, Packing});
		{_End, _Start} ->
			repack_batch(Cursor, RangeStart, RangeEnd, Packing, StoreID)
	end.

repack_batch(Cursor, RangeStart, RangeEnd, RequiredPacking, StoreID) ->
	{ok, Config} = application:get_env(arweave, config),
	RepackIntervalSize = ?DATA_CHUNK_SIZE * Config#config.repack_batch_size,
	Server = ar_chunk_storage:name(StoreID),
	Cursor2 = advance_cursor(Cursor, RangeStart, RangeEnd),
	RepackFurtherArgs = {repack, Cursor2, RangeStart, RangeEnd, RequiredPacking},
	CheckPackingBuffer =
		case ar_packing_server:is_buffer_full() of
			true ->
				?LOG_DEBUG([{event, repack_in_place_buffer_full},
						{tags, [repack_in_place]},
						{storage_module, StoreID},
						{s, Cursor},
						{range_start, RangeStart},
						{range_end, RangeEnd},
						{required_packing, ar_serialize:encode_packing(RequiredPacking, true)}]),
				ar_util:cast_after(200, Server,
						{repack, Cursor, RangeStart, RangeEnd, RequiredPacking}),
				continue;
			false ->
				ok
		end,
	ReadRange =
		case CheckPackingBuffer of
			continue ->
				continue;
			ok ->
				read_chunk_range(Cursor, RepackIntervalSize,
						StoreID, RepackFurtherArgs)
		end,
	ReadMetadataRange =
		case ReadRange of
			continue ->
				continue;
			{ok, Range2} ->
				read_chunk_metadata_range(Cursor, RepackIntervalSize, RangeEnd,
						Range2, StoreID, RepackFurtherArgs)
		end,
	case ReadMetadataRange of
		continue ->
			ok;
		{ok, Map2, MetadataMap2} ->
			?LOG_DEBUG([{event, repack_further},
						{tags, [repack_in_place]},
						{storage_module, StoreID},
						{s, Cursor2},
						{range_start, RangeStart},
						{range_end, RangeEnd},
						{required_packing, ar_serialize:encode_packing(RequiredPacking, true)}]),
			gen_server:cast(Server, RepackFurtherArgs),
			Args = {StoreID, RequiredPacking, Map2},
			send_chunks_for_repacking(MetadataMap2, Args)
	end.

read_chunk_range(Start, Size, StoreID, RepackFurtherArgs) ->
	Server = ar_chunk_storage:name(StoreID),
	case catch ar_chunk_storage:get_range(Start, Size, StoreID) of
		[] ->
			gen_server:cast(Server, RepackFurtherArgs),
			continue;
		{'EXIT', _Exc} ->
			?LOG_ERROR([{event, failed_to_read_chunk_range},
					{tags, [repack_in_place]},
					{storage_module, StoreID},
					{start, Start},
					{size, Size},
					{store_id, StoreID}]),
			gen_server:cast(Server, RepackFurtherArgs),
			continue;
		Range ->
			{ok, Range}
	end.

read_chunk_metadata_range(Start, Size, End,
		Range, StoreID, RepackFurtherArgs) ->
	Server = ar_chunk_storage:name(StoreID),
	End2 = min(Start + Size, End),
	{_, _, Map} = ar_chunk_storage:chunk_offset_list_to_map(Range),
	case ar_data_sync:get_chunk_metadata_range(Start, End2, StoreID) of
		{ok, MetadataMap} ->
			{ok, Map, MetadataMap};
		{error, Error} ->
			?LOG_ERROR([{event, failed_to_read_chunk_metadata_range},
					{storage_module, StoreID},
					{error, io_lib:format("~p", [Error])}]),
			gen_server:cast(Server, RepackFurtherArgs),
			continue
	end.

send_chunks_for_repacking(MetadataMap, Args) ->
	maps:fold(send_chunks_for_repacking(Args), ok, MetadataMap).

send_chunks_for_repacking(Args) ->
	fun	(AbsoluteOffset, {_, _TXRoot, _, _, _, ChunkSize}, ok)
				when ChunkSize /= ?DATA_CHUNK_SIZE,
						AbsoluteOffset =< ?STRICT_DATA_SPLIT_THRESHOLD ->
			?LOG_DEBUG([{event, skipping_small_chunk},
					{tags, [repack_in_place]},
					{offset, AbsoluteOffset},
					{chunk_size, ChunkSize}]),
			ok;
		(AbsoluteOffset, ChunkMeta, ok) ->
			send_chunk_for_repacking(AbsoluteOffset, ChunkMeta, Args)
	end.

send_chunk_for_repacking(AbsoluteOffset, ChunkMeta, Args) ->
	{StoreID, RequiredPacking, ChunkMap} = Args,
	Server = ar_chunk_storage:name(StoreID),
	PaddedOffset = ar_block:get_chunk_padded_offset(AbsoluteOffset),
	{ChunkDataKey, TXRoot, DataRoot, TXPath,
			RelativeOffset, ChunkSize} = ChunkMeta,
	case ar_sync_record:is_recorded(PaddedOffset, ar_data_sync, StoreID) of
		{true, unpacked_padded} ->
			%% unpacked_padded is a special internal packing used
			%% for temporary storage of unpacked and padded chunks
			%% before they are enciphered with the 2.9 entropy.
			?LOG_WARNING([
				{event, repack_in_place_found_unpacked_padded},
				{tags, [repack_in_place]},
				{storage_module, StoreID},
				{packing,
					ar_serialize:encode_packing(RequiredPacking,true)},
				{offset, AbsoluteOffset}]),
			ok;
		{true, RequiredPacking} ->
			?LOG_WARNING([{event, repack_in_place_found_already_repacked},
					{tags, [repack_in_place]},
					{storage_module, StoreID},
					{packing,
						ar_serialize:encode_packing(RequiredPacking, true)},
					{offset, AbsoluteOffset}]),
			ok;
		{true, Packing} ->
			ChunkMaybeDataPath =
				case maps:get(PaddedOffset, ChunkMap, not_found) of
					not_found ->
						read_chunk_and_data_path(StoreID,
								ChunkDataKey, AbsoluteOffset, no_chunk);
					Chunk3 ->
						case ar_chunk_storage:is_storage_supported(AbsoluteOffset,
								ChunkSize, RequiredPacking) of
							false ->
								%% We are going to move this chunk to
								%% RocksDB after repacking so we read
								%% its DataPath here to pass it later on
								%% to store_chunk.
								read_chunk_and_data_path(StoreID,
										ChunkDataKey, AbsoluteOffset, Chunk3);
							true ->
								%% We are going to repack the chunk and keep it
								%% in the chunk storage - no need to make an
								%% extra disk access to read the data path.
								{Chunk3, none}
						end
				end,
			case ChunkMaybeDataPath of
				not_found ->
					ok;
				{Chunk, MaybeDataPath} ->
					RequiredPacking2 =
						case RequiredPacking of
							{replica_2_9, _} ->
								unpacked_padded;
							Packing2 ->
								Packing2
						end,
					?LOG_DEBUG([{event, request_repack},
							{tags, [repack_in_place]},
							{storage_module, StoreID},
							{offset, PaddedOffset},
							{absolute_offset, AbsoluteOffset},
							{chunk_size, ChunkSize},
							{required_packing, ar_serialize:encode_packing(RequiredPacking2, true)},
							{packing, ar_serialize:encode_packing(Packing, true)}]),
					Ref = make_ref(),
					RepackArgs = {Packing, MaybeDataPath, RelativeOffset,
							DataRoot, TXPath, none, none},
					gen_server:cast(Server,
							{register_packing_ref, Ref, RepackArgs}),
					ar_util:cast_after(300000, Server,
							{expire_repack_request, Ref}),
					ar_packing_server:request_repack(Ref, whereis(Server),
							{RequiredPacking2, Packing, Chunk,
									AbsoluteOffset, TXRoot, ChunkSize})
			end;
		true ->
			?LOG_WARNING([{event, repack_in_place_found_no_packing_information},
					{tags, [repack_in_place]},
					{storage_module, StoreID},
					{offset, PaddedOffset}]),
			ok;
		false ->
			?LOG_WARNING([{event, repack_in_place_chunk_not_found},
					{tags, [repack_in_place]},
					{storage_module, StoreID},
					{offset, PaddedOffset}]),
			ok
	end.

read_chunk_and_data_path(StoreID, ChunkDataKey, AbsoluteOffset, MaybeChunk) ->
	case ar_kv:get({chunk_data_db, StoreID}, ChunkDataKey) of
		not_found ->
			?LOG_WARNING([{event, chunk_not_found_in_chunk_data_db},
					{tags, [repack_in_place]},
					{storage_module, StoreID},
					{offset, AbsoluteOffset}]),
			not_found;
		{ok, V} ->
			case binary_to_term(V) of
				{Chunk, DataPath} ->
					{Chunk, DataPath};
				DataPath when MaybeChunk /= no_chunk ->
					{MaybeChunk, DataPath};
				_ ->
					?LOG_WARNING([{event, chunk_not_found2},
						{tags, [repack_in_place]},
						{storage_module, StoreID},
						{offset, AbsoluteOffset}]),
					not_found
			end
	end.

get_repack_interval_size() ->
	{ok, Config} = application:get_env(arweave, config),
	?DATA_CHUNK_SIZE * Config#config.repack_batch_size.
	