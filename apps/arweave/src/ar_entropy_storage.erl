-module(ar_entropy_storage).

-behaviour(gen_server).

-export([name/1, is_entropy_packing/1, acquire_semaphore/1, release_semaphore/1, is_ready/1,
	is_recorded/2, is_sub_chunk_recorded/3, delete_record/2, generate_entropies/3,
	generate_missing_entropy/2, generate_entropy_keys/3, shift_entropy_offset/2,
	store_entropy/7, record_chunk/8]).

-export([start_link/2, init/1, handle_cast/2, handle_call/3, handle_info/2, terminate/2]).

-include("../include/ar.hrl").
-include("../include/ar_consensus.hrl").

-include_lib("eunit/include/eunit.hrl").

-record(state, {
	store_id,
	module_ranges
}).

%%%===================================================================
%%% Public interface.
%%%===================================================================

%% @doc Start the server.
start_link(Name, StoreID) ->
	gen_server:start_link({local, Name}, ?MODULE, StoreID, []).

%% @doc Return the name of the server serving the given StoreID.
name(StoreID) ->
	list_to_atom("ar_entropy_storage_" ++ ar_storage_module:label_by_id(StoreID)).

init(StoreID) ->
	?LOG_INFO([{event, ar_entropy_storage_init}, {store_id, StoreID}]),
	ModuleRanges = ar_storage_module:get_all_module_ranges(),
	{ok, #state{ store_id = StoreID, module_ranges = ModuleRanges }}.

store_entropy(
	StoreID, Entropies, BucketEndOffset, SubChunkStartOffset, RangeEnd, Keys, RewardAddr) ->
	gen_server:cast(name(StoreID), {store_entropy,
		Entropies, BucketEndOffset, SubChunkStartOffset, RangeEnd, Keys, RewardAddr}).

is_ready(StoreID) ->
	gen_server:call(name(StoreID), is_ready, infinity).

handle_cast({store_entropy,
		Entropies, BucketEndOffset, SubChunkStartOffset, RangeEnd, Keys, RewardAddr},
		State) ->
	do_store_entropy(
		Entropies, BucketEndOffset, SubChunkStartOffset, RangeEnd, Keys, RewardAddr, State),
	{noreply, State};
handle_cast(Cast, State) ->
	?LOG_WARNING([{event, unhandled_cast}, {module, ?MODULE}, {cast, Cast}]),
	{noreply, State}.

handle_call(is_ready, _From, State) ->
	{reply, true, State};
handle_call(Call, From, State) ->
	?LOG_WARNING([{event, unhandled_call}, {module, ?MODULE}, {call, Call}]),
	{reply, {error, unhandled_call}, State}.

terminate(Reason, State) ->
	?LOG_INFO([{event, ar_entropy_storage_terminate}, {reason, Reason}, {store_id, State#state.store_id}]),
	ok.

handle_info(Info, State) ->
	?LOG_WARNING([{event, unhandled_info}, {module, ?MODULE}, {info, Info}]),
	{noreply, State}.



-spec is_entropy_packing(ar_chunk_storage:packing()) -> boolean().
is_entropy_packing(unpacked_padded) ->
	true;
is_entropy_packing({replica_2_9, _}) ->
	true;
is_entropy_packing(_) ->
	false.

%% @doc Return true if the given sub-chunk bucket contains the 2.9 entropy.
is_sub_chunk_recorded(PaddedEndOffset, SubChunkBucketStartOffset, StoreID) ->
	%% Entropy indexing changed between 2.9.0 and 2.9.1. So we'll use a new
	%% sync_record id (ar_chunk_storage_replica_2_9_1_entropy) going forward.
	%% The old id (ar_chunk_storage_replica_2_9_entropy) should not be used.
	ID = ar_chunk_storage_replica_2_9_1_entropy,
	ChunkBucketStart = ar_chunk_storage:get_chunk_bucket_start(PaddedEndOffset),
	SubChunkBucketStart = ChunkBucketStart + SubChunkBucketStartOffset,
	ar_sync_record:is_recorded(SubChunkBucketStart + 1, ID, StoreID).

%% @doc Return true if the 2.9 entropy for every sub-chunk of the chunk with the
%% given offset (> start offset, =< end offset) is recorded.
%% We check every sub-chunk because the entropy is written on the sub-chunk level.
is_recorded(PaddedEndOffset, StoreID) ->
	ChunkBucketStart = ar_chunk_storage:get_chunk_bucket_start(PaddedEndOffset),
	is_recorded2(ChunkBucketStart,
									 ChunkBucketStart + ?DATA_CHUNK_SIZE,
									 StoreID).

is_recorded2(Cursor, BucketEnd, _StoreID) when Cursor >= BucketEnd ->
	true;
is_recorded2(Cursor, BucketEnd, StoreID) ->
	%% Entropy indexing changed between 2.9.0 and 2.9.1. So we'll use a new
	%% sync_record id (ar_chunk_storage_replica_2_9_1_entropy) going forward.
	%% The old id (ar_chunk_storage_replica_2_9_entropy) should not be used.
	ID = ar_chunk_storage_replica_2_9_1_entropy,
	case ar_sync_record:is_recorded(Cursor + 1, ID, StoreID) of
		false ->
			false;
		true ->
			SubChunkSize = ?COMPOSITE_PACKING_SUB_CHUNK_SIZE,
			is_recorded2(Cursor + SubChunkSize, BucketEnd, StoreID)
	end.

update_sync_records(IsComplete, PaddedEndOffset, StoreID, RewardAddr) ->
	%% Entropy indexing changed between 2.9.0 and 2.9.1. So we'll use a new
	%% sync_record id (ar_chunk_storage_replica_2_9_1_entropy) going forward.
	%% The old id (ar_chunk_storage_replica_2_9_entropy) should not be used.
	ID = ar_chunk_storage_replica_2_9_1_entropy,
	BucketEnd = ar_chunk_storage:get_chunk_bucket_end(PaddedEndOffset),
	BucketStart = ar_chunk_storage:get_chunk_bucket_start(PaddedEndOffset),
	ar_sync_record:add_async(replica_2_9_entropy, BucketEnd, BucketStart, ID, StoreID),
	prometheus_counter:inc(replica_2_9_entropy_stored,
		[ar_storage_module:label_by_id(StoreID)], ?DATA_CHUNK_SIZE),
	case IsComplete of
		true ->
			Packing = {replica_2_9, RewardAddr},
			StartOffset = PaddedEndOffset - ?DATA_CHUNK_SIZE,
			prometheus_counter:inc(chunks_stored, [ar_storage_module:packing_label(Packing), ar_storage_module:label_by_id(StoreID)]),
			ar_sync_record:add_async(replica_2_9_entropy_with_chunk,
										PaddedEndOffset,
										StartOffset,
										ar_chunk_storage,
										StoreID),
			ar_sync_record:add_async(replica_2_9_entropy_with_chunk,
										PaddedEndOffset,
										StartOffset,
										{replica_2_9, RewardAddr},
										ar_data_sync,
										StoreID);
		false ->
			ok
	end.



delete_record(PaddedEndOffset, StoreID) ->
	%% Entropy indexing changed between 2.9.0 and 2.9.1. So we'll use a new
	%% sync_record id (ar_chunk_storage_replica_2_9_1_entropy) going forward.
	%% The old id (ar_chunk_storage_replica_2_9_entropy) should not be used.
	ID = ar_chunk_storage_replica_2_9_1_entropy,
	BucketStart = ar_chunk_storage:get_chunk_bucket_start(PaddedEndOffset),
	ar_sync_record:delete(BucketStart + ?DATA_CHUNK_SIZE, BucketStart, ID, StoreID).

generate_missing_entropy(PaddedEndOffset, RewardAddr) ->
	Entropies = generate_entropies(RewardAddr, PaddedEndOffset, 0),
	case Entropies of
		{error, Reason} ->
			{error, Reason};
		_ ->
			EntropyIndex = ar_replica_2_9:get_slice_index(PaddedEndOffset),
			take_combined_entropy_by_index(Entropies, EntropyIndex)
	end.

%% @doc Returns all the entropies needed to encipher the chunk at PaddedEndOffset.
generate_entropies(_RewardAddr, _PaddedEndOffset, SubChunkStart)
	when SubChunkStart == ?DATA_CHUNK_SIZE ->
	[];
generate_entropies(RewardAddr, PaddedEndOffset, SubChunkStart) ->
	SubChunkSize = ?COMPOSITE_PACKING_SUB_CHUNK_SIZE,
	EntropyTasks = lists:map(
		fun(Offset) ->
			Ref = make_ref(),
			ar_packing_server:request_entropy_generation(
				Ref, self(), {RewardAddr, PaddedEndOffset, Offset}),
			Ref
		end,
		lists:seq(SubChunkStart, ?DATA_CHUNK_SIZE - SubChunkSize, SubChunkSize)
	),
	Entropies = collect_entropies(EntropyTasks, []),
	case Entropies of
		{error, _Reason} ->
			flush_entropy_messages();
		_ ->
			ok
	end,
	Entropies.

generate_entropy_keys(_RewardAddr, _Offset, SubChunkStart)
	when SubChunkStart == ?DATA_CHUNK_SIZE ->
	[];
generate_entropy_keys(RewardAddr, Offset, SubChunkStart) ->
	SubChunkSize = ?COMPOSITE_PACKING_SUB_CHUNK_SIZE,
	[ar_replica_2_9:get_entropy_key(RewardAddr, Offset, SubChunkStart)
	 | generate_entropy_keys(RewardAddr, Offset, SubChunkStart + SubChunkSize)].

collect_entropies([], Acc) ->
	lists:reverse(Acc);
collect_entropies([Ref | Rest], Acc) ->
	receive
		{entropy_generated, Ref, {error, Reason}} ->
			?LOG_ERROR([{event, failed_to_generate_replica_2_9_entropy}, {error, Reason}]),
			{error, Reason};
		{entropy_generated, Ref, Entropy} ->
			collect_entropies(Rest, [Entropy | Acc])
	after 60000 ->
		?LOG_ERROR([{event, entropy_generation_timeout}, {ref, Ref}]),
		{error, timeout}
	end.

flush_entropy_messages() ->
	?LOG_INFO([{event, flush_entropy_messages}]),
	receive
		{entropy_generated, _, _} ->
			flush_entropy_messages()
	after 0 ->
		ok
	end.

do_store_entropy(_Entropies,
			BucketEndOffset,
			_SubChunkStartOffset,
			RangeEnd,
			_Keys,
			_RewardAddr,
			_State)
	when BucketEndOffset > RangeEnd ->
	%% The amount of entropy generated per partition is slightly more than the amount needed.
	%% So at the end of a partition we will have finished processing chunks, but still have
	%% some entropy left. In this case we stop the recursion early and wait for the writes
	%% to complete.
	ok;
do_store_entropy(Entropies,
			BucketEndOffset,
			SubChunkStartOffset,
			RangeEnd,
			Keys,
			RewardAddr,
			State) ->
	case take_and_combine_entropy_slices(Entropies) of
		{<<>>, []} ->
			%% We've finished processing all the entropies, wait for the writes to complete.
			ok;
		{ChunkEntropy, Rest} ->
			%% Sanity checks
			true =
				ar_replica_2_9:get_entropy_partition(BucketEndOffset)
				== ar_replica_2_9:get_entropy_partition(RangeEnd),
			sanity_check_replica_2_9_entropy_keys(BucketEndOffset, RewardAddr,
				SubChunkStartOffset, Keys),
			%% End sanity checks

			FindModules =
				case ar_storage_module:get_all_packed(BucketEndOffset,
						{replica_2_9, RewardAddr}, State#state.module_ranges) of
					[] ->
						?LOG_WARNING([{event, failed_to_find_storage_modules_for_2_9_entropy},
									{padded_end_offset, BucketEndOffset}]),
						not_found;
					StoreIDs ->
						{ok, StoreIDs}
				end,

			case FindModules of
				not_found ->
					BucketEndOffset2 = shift_entropy_offset(BucketEndOffset, 1),
					do_store_entropy(Rest,
								BucketEndOffset2,
								SubChunkStartOffset,
								RangeEnd,
								Keys,
								RewardAddr,
								State);
				{ok, StoreIDs2} ->
					lists:foldl(
						fun(StoreID2, _Acc) ->
							record_entropy(ChunkEntropy,
											BucketEndOffset,
											StoreID2,
											RewardAddr)
						end,
						ok,
						StoreIDs2
					),

					BucketEndOffset2 = shift_entropy_offset(BucketEndOffset, 1),
					do_store_entropy(Rest,
								BucketEndOffset2,
								SubChunkStartOffset,
								RangeEnd,
								Keys,
								RewardAddr,
								State)
			end
	end.

record_chunk(
		PaddedEndOffset, Chunk, RewardAddr, StoreID,
		StoreIDLabel, PackingLabel, FileIndex, IsPrepared) ->
	StartOffset = PaddedEndOffset - ?DATA_CHUNK_SIZE,
	{_ChunkFileStart, Filepath, _Position, _ChunkOffset} =
		ar_chunk_storage:locate_chunk_on_disk(PaddedEndOffset, StoreID),
	acquire_semaphore(Filepath),
	CheckIsStoredAlready =
		ar_sync_record:is_recorded(PaddedEndOffset, ar_chunk_storage, StoreID),
	CheckIsEntropyRecorded =
		case CheckIsStoredAlready of
			true ->
				{error, already_stored};
			false ->
				is_recorded(PaddedEndOffset, StoreID)
		end,
	ReadEntropy =
		case CheckIsEntropyRecorded of
			{error, _} = Error ->
				Error;
			false ->
				case IsPrepared of
					false ->
						no_entropy_yet;
					true ->
						missing_entropy
				end;
			true ->
				ar_chunk_storage:get(StartOffset, StartOffset, StoreID)
		end,
	RecordChunk = case ReadEntropy of
		{error, _} = Error2 ->
			Error2;
		not_found ->
			{error, not_prepared_yet2};
		missing_entropy ->
			Packing = {replica_2_9, RewardAddr},
			Entropy = generate_missing_entropy(PaddedEndOffset, RewardAddr),
			case Entropy of
				{error, Reason} ->
					{error, Reason};
				_ ->
					PackedChunk = ar_packing_server:encipher_replica_2_9_chunk(Chunk, Entropy),
					ar_chunk_storage:record_chunk(
						PaddedEndOffset, PackedChunk, Packing, StoreID,
						StoreIDLabel, PackingLabel, FileIndex)
			end;
		no_entropy_yet ->
			ar_chunk_storage:record_chunk(
				PaddedEndOffset, Chunk, unpacked_padded, StoreID,
				StoreIDLabel, PackingLabel, FileIndex);
		{_EndOffset, Entropy} ->
			Packing = {replica_2_9, RewardAddr},
			PackedChunk = ar_packing_server:encipher_replica_2_9_chunk(Chunk, Entropy),
			ar_chunk_storage:record_chunk(
				PaddedEndOffset, PackedChunk, Packing, StoreID,
				StoreIDLabel, PackingLabel, FileIndex)
	end,
	release_semaphore(Filepath),
	RecordChunk.

%% @doc Return the byte (>= ChunkStartOffset, < ChunkEndOffset)
%% that necessarily belongs to the chunk stored
%% in the bucket with the given bucket end offset.
get_chunk_byte_from_bucket_end(BucketEndOffset) ->
	case BucketEndOffset >= ?STRICT_DATA_SPLIT_THRESHOLD of
		true ->
			?STRICT_DATA_SPLIT_THRESHOLD
			+ ar_util:floor_int(BucketEndOffset - ?STRICT_DATA_SPLIT_THRESHOLD,
					?DATA_CHUNK_SIZE);
		false ->
			BucketEndOffset - 1
	end.

record_entropy(ChunkEntropy, BucketEndOffset, StoreID, RewardAddr) ->
	true = byte_size(ChunkEntropy) == ?DATA_CHUNK_SIZE,

	Byte = get_chunk_byte_from_bucket_end(BucketEndOffset),
	CheckUnpackedChunkRecorded = ar_sync_record:get_interval(
		Byte + 1, ar_chunk_storage:sync_record_id(unpacked_padded), StoreID),

	{IsUnpackedChunkRecorded, EndOffset} =
		case CheckUnpackedChunkRecorded of
			not_found ->
				{false, BucketEndOffset};
			{_IntervalEnd, IntervalStart} ->
				{true, IntervalStart
					+ ar_util:floor_int(Byte - IntervalStart, ?DATA_CHUNK_SIZE)
					+ ?DATA_CHUNK_SIZE}
		end,

	{ChunkFileStart, Filepath, _Position, _ChunkOffset} =
		ar_chunk_storage:locate_chunk_on_disk(EndOffset, StoreID),

	%% We allow generating and filling it the 2.9 entropy and storing unpacked chunks (to
	%% be enciphered later) asynchronously. Whatever comes first, is stored.
	%% If the other counterpart is stored already, we read it, encipher and store the
	%% packed chunk.
	acquire_semaphore(Filepath),

	Chunk = case IsUnpackedChunkRecorded of
		true ->
			case ar_chunk_storage:get(Byte, Byte, StoreID) of
				not_found ->
					{error, not_found};
				{error, _} = Error ->
					Error;
				{_, UnpackedChunk} ->
					ar_sync_record:delete(
						EndOffset, EndOffset - ?DATA_CHUNK_SIZE, ar_data_sync, StoreID),
					ar_packing_server:encipher_replica_2_9_chunk(UnpackedChunk, ChunkEntropy)
			end;
		false ->
			%% The entropy for the first sub-chunk of the chunk.
			%% The zero-offset does not have a real meaning, it is set
			%% to make sure we pass offset validation on read.
			ChunkEntropy
	end,

	Result = case Chunk of
		{error, _} = Error2 ->
			Error2;
		_ ->
			WriteChunkResult = ar_chunk_storage:write_chunk(EndOffset, Chunk, #{}, StoreID),
			case WriteChunkResult of
				{ok, Filepath} ->
					ets:insert(chunk_storage_file_index,
						{{ChunkFileStart, StoreID}, Filepath}),
					update_sync_records(
						IsUnpackedChunkRecorded, EndOffset, StoreID, RewardAddr);
				Error2 ->
					Error2
			end
	end,

	case Result of
		{error, Reason} ->
			?LOG_ERROR([{event, failed_to_store_replica_2_9_chunk_entropy},
							{filepath, Filepath},
							{byte, Byte},
							{padded_end_offset, EndOffset},
							{bucket_end_offset, BucketEndOffset},
							{store_id, StoreID},
							{reason, io_lib:format("~p", [Reason])}]);
		_ ->
			ok
	end,

	release_semaphore(Filepath).
	

%% @doc Take the first slice of each entropy and combine into a single binary. This binary
%% can be used to encipher a single chunk.
-spec take_and_combine_entropy_slices(Entropies :: [binary()]) ->
										 {ChunkEntropy :: binary(),
										  RemainingSlicesOfEachEntropy :: [binary()]}.
take_and_combine_entropy_slices(Entropies) ->
	true = ?COMPOSITE_PACKING_SUB_CHUNK_COUNT == length(Entropies),
	take_and_combine_entropy_slices(Entropies, [], []).

take_and_combine_entropy_slices([], Acc, RestAcc) ->
	{iolist_to_binary(Acc), lists:reverse(RestAcc)};
take_and_combine_entropy_slices([<<>> | Entropies], _Acc, _RestAcc) ->
	true = lists:all(fun(Entropy) -> Entropy == <<>> end, Entropies),
	{<<>>, []};
take_and_combine_entropy_slices([<<EntropySlice:?COMPOSITE_PACKING_SUB_CHUNK_SIZE/binary,
								   Rest/binary>>
								 | Entropies],
								Acc,
								RestAcc) ->
	take_and_combine_entropy_slices(Entropies, [Acc, EntropySlice], [Rest | RestAcc]).

take_combined_entropy_by_index(Entropies, Index) ->
	take_combined_entropy_by_index(Entropies, Index, []).

take_combined_entropy_by_index([], _Index, Acc) ->
	iolist_to_binary(Acc);
take_combined_entropy_by_index([Entropy | Entropies], Index, Acc) ->
	SubChunkSize = ?COMPOSITE_PACKING_SUB_CHUNK_SIZE,
	take_combined_entropy_by_index(Entropies,
								   Index,
								   [Acc, binary:part(Entropy, Index * SubChunkSize, SubChunkSize)]).

sanity_check_replica_2_9_entropy_keys(
		_PaddedEndOffset, _RewardAddr, _SubChunkStartOffset, []) ->
	ok;
sanity_check_replica_2_9_entropy_keys(
		PaddedEndOffset, RewardAddr, SubChunkStartOffset, [Key | Keys]) ->
 	Key = ar_replica_2_9:get_entropy_key(RewardAddr, PaddedEndOffset, SubChunkStartOffset),
	SubChunkSize = ?COMPOSITE_PACKING_SUB_CHUNK_SIZE,
	sanity_check_replica_2_9_entropy_keys(PaddedEndOffset,
										RewardAddr,
										SubChunkStartOffset + SubChunkSize,
										Keys).

shift_entropy_offset(Offset, SectorCount) ->
	SectorSize = ar_replica_2_9:get_sector_size(),
	ar_chunk_storage:get_chunk_bucket_end(ar_block:get_chunk_padded_offset(Offset + SectorSize * SectorCount)).

acquire_semaphore(Filepath) ->
	case ets:insert_new(ar_entropy_storage, {{semaphore, Filepath}}) of
		false ->
			?LOG_DEBUG([
				{event, details_store_chunk}, {section, waiting_on_semaphore}, {filepath, Filepath}]),
			timer:sleep(20),
			acquire_semaphore(Filepath);
		true ->
			ok
	end.

release_semaphore(Filepath) ->
	ets:delete(ar_entropy_storage, {semaphore, Filepath}).
