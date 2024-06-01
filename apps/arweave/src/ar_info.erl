-module(ar_info).

-export([get_keys/0, get_info/0]).

-include_lib("arweave/include/ar.hrl").

get_keys() ->
    [
        network, version, release, height, current, blocks, peers,
        queue_length, node_state_latency, recent
    ].

get_info() ->
	{Time, Current} =
		timer:tc(fun() -> ar_node:get_current_block_hash() end),
	{Time2, Height} =
		timer:tc(fun() -> ar_node:get_height() end),
	[{_, BlockCount}] = ets:lookup(ar_header_sync, synced_blocks),
    #{
        network => list_to_binary(?NETWORK_NAME),
        version => ?CLIENT_VERSION,
        release => ?RELEASE_NUMBER,
        height =>
            case Height of
                not_joined -> -1;
                H -> H
            end,
        current =>
            case is_atom(Current) of
                true -> atom_to_binary(Current, utf8);
                false -> ar_util:encode(Current)
            end,
        blocks => BlockCount,
        peers => prometheus_gauge:value(arweave_peer_count),
        queue_length =>
            element(
                2,
                erlang:process_info(whereis(ar_node_worker), message_queue_len)
            ),
        node_state_latency => (Time + Time2) div 2,
        %% {
        %%   "id": <indep_hash>,
        %%   "received": <received_timestamp>"
        %% }
        recent => []
    }.