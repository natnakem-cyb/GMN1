extends Node
class_name NetworkSession

signal status_changed(message: String)
signal session_changed
signal match_forfeited(winner_team: int)

const CONFIG_PATH := "res://data/match_config.json"
const HOST_PEER_ID := 1
const PROTOCOL_VERSION := "gmn1-lockstep-2"

var simulation: MatchSimulation
var offline_ai_enabled := true
var mode := "offline"
var local_team_index := 0
var client_peer_id := 0
var reconnect_token := ""
var guest_reconnect_token := ""
var peer_teams: Dictionary = {}
var scheduled_commands: Dictionary = {}
var command_history: Array[Dictionary] = []
var latest_snapshot: Dictionary = {}
var latest_snapshot_tick := 0
var latest_snapshot_sequence := 0
var latest_snapshot_pending_commands: Array[Dictionary] = []
var expected_hashes: Dictionary = {}
var expected_hash_sequences: Dictionary = {}
var local_hashes: Dictionary = {}
var next_sequence := 1
var last_received_sequence := 0
var last_received_command_tick := 0
var last_applied_sequence := 0
var last_applied_command := "none"
var sync_state := "offline"
var hash_status := "not checked"
var last_hash_tick := -1
var hash_mismatch_count := 0
var out_of_order_count := 0
var ping_milliseconds := -1
var host_tick_watermark := 0
var command_lead_ticks := 45
var beacon_interval_ticks := 15
var hash_interval_ticks := 30
var snapshot_interval_ticks := 300
var reconnect_enabled := true
var ping_interval_seconds := 1.0
var disconnect_timeout_seconds := 10.0
var catchup_limit := 120
var accumulator := 0.0
var beacon_tick_clock := 0
var ping_clock := 0.0
var disconnect_clock := -1.0
var disconnect_message := ""
var match_started := false
var reconnecting := false
var awaiting_reconnect_ack := false
var reconnect_pending_peer_id := 0
var reconnect_target_tick := -1
var reconnect_target_sequence := -1
var reconnect_target_hash := ""
var scheduled_command_log: Array[Dictionary] = []
var pending_ping_nonce := 0
var pending_ping_started_msec := 0
var host_applied_sequence := 0
var last_received_hash_tick := -1
var last_client_hash_tick := -1
var last_beacon_applied_sequence := 0

func _ready() -> void:
	var config := _read_config()
	if config.is_empty():
		return
	var network_data: Dictionary = config["network"]
	command_lead_ticks = int(network_data["command_lead_ticks"])
	beacon_interval_ticks = int(network_data["tick_beacon_interval"])
	hash_interval_ticks = int(network_data["state_hash_interval_ticks"])
	snapshot_interval_ticks = int(network_data["snapshot_interval_ticks"])
	reconnect_enabled = bool(network_data["reconnect_enabled"])
	ping_interval_seconds = float(network_data["ping_interval_seconds"])
	disconnect_timeout_seconds = float(network_data.get("reconnect_timeout_seconds", network_data["disconnect_timeout_seconds"]))
	catchup_limit = int(network_data["maximum_client_catchup_ticks_per_frame"])
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

func configure(match_simulation: MatchSimulation) -> void:
	simulation = match_simulation
	offline_ai_enabled = bool(simulation.config["probability"]["ai"]["enabled"])

func _process(real_delta: float) -> void:
	if disconnect_clock >= 0.0 and (not reconnecting or reconnect_target_tick < 0):
		disconnect_clock += real_delta
		if disconnect_clock >= disconnect_timeout_seconds:
			_forfeit_disconnected_opponent()
			return
		if not reconnecting or reconnect_target_tick < 0:
			return
	if reconnecting and reconnect_target_tick < 0:
		return
	if mode == "host" and match_started and simulation.active:
		var tick_seconds := float(simulation.config["match"]["tick_seconds"])
		accumulator += real_delta * float(simulation.config["match"]["simulation_seconds_per_real_second"])
		while accumulator >= tick_seconds and simulation.active and disconnect_clock < 0.0:
			accumulator -= tick_seconds
			_step_host_tick()
	if mode == "client" and match_started and simulation.active and disconnect_clock < 0.0:
		var stepped := 0
		while simulation.tick_count < host_tick_watermark and stepped < catchup_limit and simulation.active:
			_step_peer_tick()
			stepped += 1
		_check_pending_hashes()
		if reconnecting and simulation.tick_count == reconnect_target_tick:
			_finish_reconnect_catchup()
		elif simulation.tick_count == host_tick_watermark:
			if last_applied_sequence != host_applied_sequence:
				_mark_desynchronized("applied command sequence does not match host beacon")
				return
			sync_state = "in sync"
		elif simulation.tick_count < host_tick_watermark:
			sync_state = "catching up"
		else:
			_mark_desynchronized("local simulation passed the host tick watermark")
	if mode != "offline" and match_started and not reconnecting:
		ping_clock += real_delta
		if ping_clock >= ping_interval_seconds:
			ping_clock = 0.0
			_send_ping()

func host_game(port: int, versus_ai: bool) -> Error:
	if simulation == null:
		return ERR_UNCONFIGURED
	disconnect_session()
	if versus_ai:
		mode = "offline"
		simulation.config["probability"]["ai"]["enabled"] = true
		simulation.externally_ticked = false
		_emit_status("VS AI selected. Start a local match to play against the AI.")
		return OK
	var network_peer := ENetMultiplayerPeer.new()
	var result := network_peer.create_server(port, 1)
	if result != OK:
		_emit_status("Host failed: %s" % error_string(result))
		return result
	multiplayer.multiplayer_peer = network_peer
	mode = "host"
	local_team_index = 0
	peer_teams = {HOST_PEER_ID: 0}
	client_peer_id = 0
	match_started = false
	simulation.config["probability"]["ai"]["enabled"] = false
	_emit_status("Hosting on UDP port %d. Waiting for one manager to join." % port)
	session_changed.emit()
	return OK

func join_game(address: String, port: int) -> Error:
	if simulation == null or address.is_empty():
		return ERR_INVALID_PARAMETER
	if mode == "client" and match_started and disconnect_clock >= 0.0 and not reconnect_token.is_empty():
		return reconnect_to_host(address, port)
	disconnect_session()
	return _connect_to_host(address, port)

func reconnect_to_host(address: String, port: int) -> Error:
	if not reconnect_enabled or mode != "client" or not match_started or reconnect_token.is_empty():
		return ERR_UNCONFIGURED
	if address.is_empty():
		return ERR_INVALID_PARAMETER
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	return _connect_to_host(address, port, true)

func simulate_connection_drop() -> void:
	if mode != "client" or not match_started or reconnecting:
		return
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	_on_server_disconnected()

func _connect_to_host(address: String, port: int, is_reconnect: bool = false) -> Error:
	var network_peer := ENetMultiplayerPeer.new()
	var result := network_peer.create_client(address, port)
	if result != OK:
		_emit_status("Join failed: %s" % error_string(result))
		return result
	multiplayer.multiplayer_peer = network_peer
	mode = "client"
	if not is_reconnect:
		local_team_index = -1
		match_started = false
		reconnect_token = ""
	reconnecting = is_reconnect
	sync_state = "reconnecting" if is_reconnect else "connecting"
	var connection_message := "Connecting to %s:%d..." % [address, port]
	if is_reconnect:
		connection_message = "Reconnecting to %s:%d..." % [address, port]
	_emit_status(connection_message)
	session_changed.emit()
	return OK

func start_pvp_match(formation: String) -> bool:
	if mode != "host" or client_peer_id == 0 or match_started:
		return false
	var digest := _config_digest()
	var home_mentality := simulation.teams[0].mentality
	var home_game_plan := simulation.teams[0].game_plan
	var away_mentality := simulation.teams[1].mentality
	var away_game_plan := simulation.teams[1].game_plan
	simulation.config["probability"]["ai"]["enabled"] = false
	if not simulation.setup_match(formation):
		return false
	simulation.teams[0].mentality = home_mentality
	simulation.teams[0].game_plan = home_game_plan
	simulation.teams[1].mentality = away_mentality
	simulation.teams[1].game_plan = away_game_plan
	simulation.externally_ticked = true
	_initialize_lockstep()
	match_started = true
	simulation.start_match()
	_cache_snapshot()
	rpc(
		"_rpc_begin_match", formation, digest, int(simulation.config["seed"]),
		home_mentality, home_game_plan, away_mentality, away_game_plan
	)
	sync_state = "hosting"
	_emit_status("PVP match started. You manage %s." % simulation.teams[0].team_name)
	session_changed.emit()
	return true

func start_local_match(formation: String) -> bool:
	if mode != "offline" or match_started:
		return false
	if simulation.teams.is_empty() and not simulation.setup_match(formation):
		return false
	simulation.externally_ticked = false
	match_started = true
	simulation.start_match()
	session_changed.emit()
	return true

func submit_command(team_index: int, kind: String, value: String = "", player_id: int = -1) -> bool:
	if simulation == null:
		return false
	if mode == "offline":
		if match_started and not simulation.active:
			return false
		return simulation.apply_manager_command(team_index, kind, value, player_id)
	if team_index != local_team_index or sync_state == "desynchronized":
		return false
	if not match_started:
		if kind != "mentality" and kind != "game_plan":
			return false
		if mode == "host":
			return simulation.apply_manager_command(team_index, kind, value, player_id)
		if mode == "client":
			rpc_id(HOST_PEER_ID, "_rpc_lobby_tactic_request", kind, value)
			return true
		return false
	if mode == "host":
		var accepted := _host_accept_command(HOST_PEER_ID, kind, value, player_id, simulation.tick_count)
		if accepted:
			_emit_status("Command scheduled provisionally for tick %d." % (simulation.tick_count + command_lead_ticks + 1))
		else:
			_emit_status("Command rejected by host validation.")
		return accepted
	if mode == "client":
		rpc_id(HOST_PEER_ID, "_rpc_command_request", kind, value, player_id, simulation.tick_count)
		_emit_status("Command sent to host for validation.")
		return true
	return false

func can_host_start() -> bool:
	return mode == "host" and client_peer_id != 0 and not match_started

func get_lobby_status() -> String:
	if mode == "host":
		var home := str(simulation.config["teams"][0]["name"])
		var away := str(simulation.config["teams"][1]["name"])
		if disconnect_clock >= 0.0:
			return "HOST | %s manager | %s reconnecting" % [home, away]
		return "HOST | %s manager | " % home + ("%s ready" % away if client_peer_id != 0 else "waiting for opponent")
	if mode == "client":
		if reconnecting:
			return "CLIENT | %s manager | reconnecting" % str(simulation.config["teams"][1]["name"])
		if disconnect_clock >= 0.0:
			return "CLIENT | disconnected; reconnect available"
		if local_team_index >= 0:
			return "CLIENT | %s manager | ready" % str(simulation.config["teams"][1]["name"])
		return "CLIENT | connecting"
	return "LOCAL | vs AI"

func get_network_debug_text() -> String:
	var role_text := mode.to_upper()
	var tick_text := "tick %d" % (simulation.tick_count if simulation != null else 0)
	if mode == "client":
		tick_text += " / host %d" % host_tick_watermark
	var ping_text := "ping n/a" if ping_milliseconds < 0 else "ping %dms" % ping_milliseconds
	return "%s | %s | %s | seq rx/applied %d/%d | last %s | sync %s | hash %s @%d | OOO %d" % [
		role_text, tick_text, ping_text, last_received_sequence, last_applied_sequence, last_applied_command,
		sync_state, hash_status, last_hash_tick, out_of_order_count
	]

func disconnect_session() -> void:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	mode = "offline"
	local_team_index = 0
	client_peer_id = 0
	guest_reconnect_token = ""
	peer_teams.clear()
	scheduled_commands.clear()
	next_sequence = 1
	last_received_sequence = 0
	last_received_command_tick = 0
	last_applied_sequence = 0
	last_applied_command = "none"
	sync_state = "offline"
	hash_status = "not checked"
	last_hash_tick = -1
	hash_mismatch_count = 0
	out_of_order_count = 0
	ping_milliseconds = -1
	host_tick_watermark = 0
	host_applied_sequence = 0
	last_received_hash_tick = -1
	last_client_hash_tick = -1
	last_beacon_applied_sequence = 0
	accumulator = 0.0
	beacon_tick_clock = 0
	ping_clock = 0.0
	disconnect_clock = -1.0
	disconnect_message = ""
	match_started = false
	reconnecting = false
	awaiting_reconnect_ack = false
	reconnect_pending_peer_id = 0
	reconnect_target_tick = -1
	reconnect_target_sequence = -1
	reconnect_target_hash = ""
	reconnect_token = ""
	guest_reconnect_token = ""
	scheduled_command_log.clear()
	command_history.clear()
	latest_snapshot.clear()
	latest_snapshot_tick = 0
	latest_snapshot_sequence = 0
	latest_snapshot_pending_commands.clear()
	expected_hashes.clear()
	expected_hash_sequences.clear()
	local_hashes.clear()
	if simulation != null:
		simulation.externally_ticked = false
		simulation.config["probability"]["ai"]["enabled"] = offline_ai_enabled
	session_changed.emit()

func _host_accept_command(peer_id: int, kind: String, value: String, player_id: int, _reported_tick: int) -> bool:
	if not match_started or not simulation.active or disconnect_clock >= 0.0 or not peer_teams.has(peer_id):
		return false
	var team_index := int(peer_teams[peer_id])
	if (
		not _command_payload_valid(kind, value, player_id)
		or not simulation.validate_manager_command(team_index, kind, value, player_id)
	):
		return false
	var max_commands := int(simulation.config["network"]["maximum_pending_commands"])
	if _pending_command_count() >= max_commands or command_history.size() >= max_commands:
		return false
	var target_tick := simulation.tick_count + command_lead_ticks + 1
	var last_match_tick := int(
		float(simulation.config["match"]["half_duration_seconds"]) * 2.0
		/ float(simulation.config["match"]["tick_seconds"])
	)
	if target_tick > last_match_tick:
		return false
	var command := {
		"sequence": next_sequence,
		"tick": target_tick,
		"team": team_index,
		"kind": kind,
		"value": value,
		"player_id": player_id,
		"sender": peer_id
	}
	next_sequence += 1
	_queue_command(command)
	scheduled_command_log.append(command.duplicate(true))
	command_history.append(command.duplicate(true))
	print("[Network] Host scheduled command provisionally: ", command)
	if mode == "host" and client_peer_id != 0:
		rpc("_rpc_command_commit", command)
	if peer_id != HOST_PEER_ID:
		rpc_id(peer_id, "_rpc_command_ack", int(command["sequence"]), target_tick)
	return true

func _cache_snapshot() -> void:
	latest_snapshot = simulation.create_snapshot()
	latest_snapshot_tick = simulation.tick_count
	latest_snapshot_sequence = last_applied_sequence
	latest_snapshot_pending_commands.clear()
	var retained: Array[Dictionary] = []
	for command in command_history:
		if int(command["sequence"]) > latest_snapshot_sequence:
			retained.append(command.duplicate(true))
	command_history = retained

func _broadcast_state_hash() -> void:
	var state_hash := simulation.get_state_hash()
	var tick := simulation.tick_count
	local_hashes[tick] = state_hash
	last_hash_tick = tick
	hash_status = "host computed"
	var oldest_tick := tick - hash_interval_ticks * 8
	for saved_tick in local_hashes.keys():
		if int(saved_tick) < oldest_tick:
			local_hashes.erase(saved_tick)
	if mode == "host" and client_peer_id != 0:
		rpc("_rpc_state_hash", tick, state_hash, last_applied_sequence)

func _check_pending_hashes() -> void:
	var check_ticks: Array = expected_hashes.keys()
	check_ticks.sort()
	for tick_value in check_ticks:
		var tick := int(tick_value)
		if tick > simulation.tick_count:
			continue
		var expected_hash := str(expected_hashes[tick])
		if tick != simulation.tick_count:
			_mark_desynchronized("missed state hash tick %d" % tick)
			return
		if last_applied_sequence != int(expected_hash_sequences[tick]):
			_mark_desynchronized("applied command sequence mismatch at hash tick %d" % tick)
			return
		var actual_hash := simulation.get_state_hash()
		last_hash_tick = tick
		if actual_hash != expected_hash:
			hash_mismatch_count += 1
			hash_status = "FAIL"
			rpc_id(HOST_PEER_ID, "_rpc_client_hash_result", tick, actual_hash)
			_mark_desynchronized("state hash mismatch at tick %d" % tick)
			return
		hash_status = "MATCH"
		rpc_id(HOST_PEER_ID, "_rpc_client_hash_result", tick, actual_hash)
		expected_hashes.erase(tick)
		expected_hash_sequences.erase(tick)
		last_received_hash_tick = tick
		session_changed.emit()

func _finish_reconnect_catchup() -> void:
	if not reconnecting or simulation.tick_count != reconnect_target_tick:
		return
	if sync_state == "reconnected; awaiting host":
		return
	if last_applied_sequence != reconnect_target_sequence:
		_mark_desynchronized("reconnect applied sequence does not match host")
		return
	var actual_hash := simulation.get_state_hash()
	if actual_hash != reconnect_target_hash:
		hash_status = "FAIL"
		hash_mismatch_count += 1
		_mark_desynchronized("reconnect snapshot replay hash mismatch")
		return
	hash_status = "MATCH (reconnect)"
	last_hash_tick = reconnect_target_tick
	sync_state = "reconnected; awaiting host"
	rpc_id(HOST_PEER_ID, "_rpc_reconnect_ack", reconnect_target_tick, last_applied_sequence, actual_hash)
	session_changed.emit()

func _command_payload_valid(kind: String, value: String, player_id: int) -> bool:
	match kind:
		"mentality":
			return player_id == -1 and simulation.config["probability"]["tactical_modifiers"]["mentality"].has(value)
		"game_plan":
			return player_id == -1 and simulation.config["probability"]["tactical_modifiers"]["game_plan"].has(value)
		"instruction":
			return player_id == -1 and simulation.config["probability"]["instructions"].has(value)
		"substitution":
			return value.is_empty() and player_id >= 0
		_:
			return false

func _pending_command_count() -> int:
	var count := 0
	for commands_at_tick in scheduled_commands.values():
		count += commands_at_tick.size()
	return count

func _queue_command(command: Dictionary) -> void:
	var tick := int(command["tick"])
	if tick <= simulation.tick_count:
		_mark_desynchronized("received command for an already simulated tick")
		return
	var sequence := int(command["sequence"])
	if sequence != last_received_sequence + 1:
		_mark_desynchronized("command sequence is not contiguous")
		return
	if tick < last_received_command_tick:
		_mark_desynchronized("command target ticks moved backwards")
		return
	if _pending_command_count() >= int(simulation.config["network"]["maximum_pending_commands"]):
		_mark_desynchronized("pending command limit exceeded")
		return
	if not scheduled_commands.has(tick):
		scheduled_commands[tick] = []
	var commands: Array = scheduled_commands[tick]
	commands.append(command.duplicate(true))
	commands.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return int(left["sequence"]) < int(right["sequence"])
	)
	scheduled_commands[tick] = commands
	last_received_sequence = sequence
	last_received_command_tick = tick
	session_changed.emit()

func _step_host_tick() -> void:
	var next_tick := simulation.tick_count + 1
	_apply_commands_at_tick(next_tick)
	if sync_state == "desynchronized":
		return
	simulation.step_tick()
	beacon_tick_clock += 1
	if simulation.tick_count % snapshot_interval_ticks == 0:
		_cache_snapshot()
	if (simulation.tick_count % hash_interval_ticks == 0 or not simulation.active) \
	and last_hash_tick != simulation.tick_count:
		_broadcast_state_hash()
	if beacon_tick_clock >= beacon_interval_ticks or not simulation.active:
		beacon_tick_clock = 0
		rpc("_rpc_tick_beacon", simulation.tick_count, last_applied_sequence)
		if client_peer_id != 0:
			rpc_id(client_peer_id, "_rpc_client_tick_report_request", simulation.tick_count)

func _step_peer_tick() -> void:
	var next_tick := simulation.tick_count + 1
	_apply_commands_at_tick(next_tick)
	if sync_state == "desynchronized":
		return
	simulation.step_tick()
	_check_pending_hashes()

func _apply_commands_at_tick(tick: int) -> void:
	if not scheduled_commands.has(tick):
		return
	var commands: Array = scheduled_commands[tick]
	for command in commands:
		var sequence := int(command["sequence"])
		if sequence != last_applied_sequence + 1:
			_mark_desynchronized("command application sequence is not contiguous")
			return
		var applied := simulation.apply_manager_command(
			int(command["team"]), str(command["kind"]), str(command["value"]), int(command["player_id"])
		)
		last_applied_command = "#%d %s %s" % [
			sequence, str(command["kind"]), "applied" if applied else "rejected"
		]
		last_applied_sequence = sequence
		print("[Network] Command #%d at tick %d: %s" % [
			sequence, tick, "applied" if applied else "rejected at execution"
		])
		if not applied:
			simulation.event_log.append("COMMAND_REJECTED #%d@%d" % [sequence, tick])
			_emit_status("Command #%d rejected at execution; state changed before its scheduled tick." % sequence)
		else:
			simulation.event_log.append("COMMAND_APPLIED #%d@%d" % [sequence, tick])
			_emit_status("Command #%d applied: %s (%s)." % [
				sequence, str(command["kind"]), str(command["value"])
			])
	scheduled_commands.erase(tick)
	session_changed.emit()

func _initialize_lockstep() -> void:
	scheduled_commands.clear()
	next_sequence = 1
	last_received_sequence = 0
	last_received_command_tick = 0
	last_applied_sequence = 0
	last_applied_command = "none"
	host_tick_watermark = 0
	accumulator = 0.0
	beacon_tick_clock = 0
	ping_clock = 0.0
	sync_state = "in sync"
	scheduled_command_log.clear()
	command_history.clear()
	latest_snapshot.clear()
	latest_snapshot_tick = 0
	latest_snapshot_sequence = 0
	latest_snapshot_pending_commands.clear()
	expected_hashes.clear()
	expected_hash_sequences.clear()
	local_hashes.clear()
	hash_status = "waiting for first hash"
	last_hash_tick = -1
	last_received_hash_tick = -1
	last_client_hash_tick = -1
	host_applied_sequence = 0
	last_beacon_applied_sequence = 0
	hash_mismatch_count = 0
	out_of_order_count = 0

func _on_connected_to_server() -> void:
	var config: Dictionary = _read_config()
	rpc_id(HOST_PEER_ID, "_rpc_join_hello", _config_digest(), int(config.get("seed", -1)), reconnect_token)
	sync_state = "handshaking"
	_emit_status("Connected. Checking version and reconnect token with host...")

func _on_connection_failed() -> void:
	if reconnecting:
		reconnecting = false
		sync_state = "reconnect failed"
		_emit_status("Reconnect failed; retry before the host's grace period expires.")
		session_changed.emit()
		return
	_emit_status("Connection failed. Check host address and UDP port.")
	disconnect_session()

func _on_server_disconnected() -> void:
	if not match_started or simulation == null or not simulation.active:
		_emit_status("Host disconnected before a live match.")
		disconnect_session()
		return
	disconnect_clock = 0.0
	disconnect_message = "Host disconnected."
	sync_state = "disconnected"
	_emit_status("Host disconnected. Reconnect before the grace period expires.")
	session_changed.emit()

func _on_peer_connected(peer_id: int) -> void:
	if mode == "host":
		_emit_status("Peer %d connected; checking project/config compatibility." % peer_id)

func _on_peer_disconnected(peer_id: int) -> void:
	if mode == "host" and peer_id == client_peer_id and match_started and simulation.active:
		disconnect_clock = 0.0
		disconnect_message = "Opponent disconnected."
		sync_state = "paused: opponent disconnected"
		_emit_status("Opponent disconnected. Match paused; reconnect within %.0fs." % disconnect_timeout_seconds)
	elif mode == "host" and peer_id == client_peer_id:
		client_peer_id = 0
		peer_teams.erase(peer_id)
		_emit_status("Peer left the lobby.")
	session_changed.emit()

func _forfeit_disconnected_opponent() -> void:
	disconnect_clock = -1.0
	sync_state = "opponent forfeited"
	var winner_team := 0 if mode == "host" else 1
	if simulation != null:
		simulation.active = false
		simulation.finished = true
		simulation.event_log.append("DISCONNECT_FORFEIT: team %d wins" % winner_team)
	_emit_status("%s You win by disconnect forfeit." % disconnect_message)
	match_forfeited.emit(winner_team)

func _mark_desynchronized(reason: String, notify_remote: bool = true) -> void:
	sync_state = "desynchronized"
	hash_status = "FAIL" if reason.contains("hash") else hash_status
	if simulation != null:
		simulation.active = false
	if notify_remote:
		if mode == "host" and client_peer_id != 0:
			rpc("_rpc_session_stopped", reason)
		elif mode == "client" and match_started:
			rpc_id(HOST_PEER_ID, "_rpc_client_desynchronized", reason)
	_emit_status("Simulation stopped: %s. Rejoin; state resync is not supported." % reason)
	session_changed.emit()

func _send_ping() -> void:
	if mode == "host" and client_peer_id != 0:
		pending_ping_nonce += 1
		pending_ping_started_msec = Time.get_ticks_msec()
		rpc_id(client_peer_id, "_rpc_ping", pending_ping_nonce)

func _config_digest() -> String:
	return (FileAccess.get_file_as_string(CONFIG_PATH) + "|" + PROTOCOL_VERSION).sha256_text()

func _is_int_rpc_value(value: Variant) -> bool:
	return typeof(value) == TYPE_INT

func _last_match_tick() -> int:
	return int(
		float(simulation.config["match"]["half_duration_seconds"]) * 2.0
		/ float(simulation.config["match"]["tick_seconds"])
	)

func _read_config() -> Dictionary:
	if not FileAccess.file_exists(CONFIG_PATH):
		push_error("Required network config not found: " + CONFIG_PATH)
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CONFIG_PATH))
	if not parsed is Dictionary:
		push_error("Invalid network config JSON: " + CONFIG_PATH)
		return {}
	return parsed

func _emit_status(message: String) -> void:
	status_changed.emit(message)
	print("[Network] " + message)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_join_hello(config_hash: String, match_seed: int, presented_token: String) -> void:
	if mode != "host":
		return
	var sender := multiplayer.get_remote_sender_id()
	if config_hash != _config_digest() or match_seed != int(simulation.config["seed"]):
		rpc_id(sender, "_rpc_join_rejected", "Project configuration or match seed differs.")
		return
	if match_started:
		if not reconnect_enabled or disconnect_clock < 0.0 or awaiting_reconnect_ack \
		or presented_token.is_empty() or presented_token != guest_reconnect_token:
			rpc_id(sender, "_rpc_join_rejected", "Match is live; reconnect token is invalid or grace period expired.")
			return
		reconnect_pending_peer_id = sender
		awaiting_reconnect_ack = true
		peer_teams.clear()
		peer_teams[HOST_PEER_ID] = 0
		client_peer_id = sender
		peer_teams[sender] = 1
		reconnect_target_tick = simulation.tick_count
		reconnect_target_sequence = last_applied_sequence
		reconnect_target_hash = simulation.get_state_hash()
		var commands_after_snapshot: Array[Dictionary] = []
		for command in command_history:
			if int(command["sequence"]) > latest_snapshot_sequence:
				commands_after_snapshot.append(command.duplicate(true))
		commands_after_snapshot.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
			return int(left["sequence"]) < int(right["sequence"])
		)
		var reconnect_bundle := {
			"config_hash": _config_digest(),
			"seed": int(simulation.config["seed"]),
			"snapshot": latest_snapshot.duplicate(true),
			"snapshot_tick": latest_snapshot_tick,
			"snapshot_sequence": latest_snapshot_sequence,
			"commands": commands_after_snapshot,
			"target_tick": reconnect_target_tick,
			"target_sequence": reconnect_target_sequence,
			"target_hash": reconnect_target_hash,
			"next_sequence": next_sequence
		}
		rpc_id(sender, "_rpc_reconnect_snapshot", reconnect_bundle)
		_emit_status("Returning manager authenticated; sending snapshot and %d pending commands." % commands_after_snapshot.size())
		return
	if client_peer_id != 0:
		rpc_id(sender, "_rpc_join_rejected", "Lobby is full.")
		return
	if not presented_token.is_empty():
		if presented_token != guest_reconnect_token:
			rpc_id(sender, "_rpc_join_rejected", "No resumable lobby or match is available for that token.")
			return
		client_peer_id = sender
		peer_teams[sender] = 1
		rpc_id(sender, "_rpc_lobby_config", _config_digest(), int(simulation.config["seed"]), 1, guest_reconnect_token)
		_emit_status("Manager reconnected to the lobby.")
		session_changed.emit()
		return
	client_peer_id = sender
	peer_teams[sender] = 1
	guest_reconnect_token = Crypto.new().generate_random_bytes(32).hex_encode()
	rpc_id(sender, "_rpc_lobby_config", _config_digest(), int(simulation.config["seed"]), 1, guest_reconnect_token)
	_emit_status("Peer %d joined as %s manager. Start when ready." % [sender, simulation.config["teams"][1]["name"]])
	session_changed.emit()

@rpc("authority", "call_remote", "reliable")
func _rpc_lobby_config(config_hash: String, match_seed: int, assigned_team: int, host_token: String) -> void:
	if config_hash != _config_digest() or match_seed != int(simulation.config["seed"]) or assigned_team != 1:
		_emit_status("Host data mismatch. Disconnecting.")
		disconnect_session()
		return
	local_team_index = assigned_team
	reconnect_token = host_token
	simulation.config["probability"]["ai"]["enabled"] = false
	sync_state = "lobby ready"
	_emit_status("Joined lobby as %s manager. Waiting for host to start." % simulation.config["teams"][assigned_team]["name"])
	session_changed.emit()

@rpc("authority", "call_remote", "reliable")
func _rpc_join_rejected(reason: String) -> void:
	_emit_status("Join rejected: " + reason)
	if reconnecting:
		reconnecting = false
		sync_state = "reconnect rejected"
		session_changed.emit()
	else:
		disconnect_session()

@rpc("any_peer", "call_remote", "reliable")
func _rpc_lobby_tactic_request(kind: String, value: String) -> void:
	if mode != "host" or match_started:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender != client_peer_id or not peer_teams.has(sender):
		return
	if kind != "mentality" and kind != "game_plan":
		return
	if not _command_payload_valid(kind, value, -1):
		return
	var team_index := int(peer_teams[sender])
	if not simulation.validate_manager_command(team_index, kind, value):
		return
	var applied := simulation.apply_manager_command(team_index, kind, value)
	if applied:
		rpc_id(sender, "_rpc_lobby_tactic_update", kind, value)

@rpc("authority", "call_remote", "reliable")
func _rpc_lobby_tactic_update(kind: String, value: String) -> void:
	if mode != "client" or match_started:
		return
	var applied := simulation.apply_manager_command(local_team_index, kind, value)
	if not applied:
		_mark_desynchronized("host and client lobby tactics diverged")
	else:
		session_changed.emit()

@rpc("authority", "call_remote", "reliable")
func _rpc_begin_match(
	formation: String,
	config_hash: String,
	match_seed: int,
	home_mentality: String,
	home_game_plan: String,
	away_mentality: String,
	away_game_plan: String
) -> void:
	if mode != "client" or config_hash != _config_digest() or match_seed != int(simulation.config["seed"]):
		_mark_desynchronized("host started with incompatible match data")
		return
	simulation.config["probability"]["ai"]["enabled"] = false
	if not simulation.setup_match(formation):
		_mark_desynchronized("could not initialize host match")
		return
	simulation.teams[0].mentality = home_mentality
	simulation.teams[0].game_plan = home_game_plan
	simulation.teams[1].mentality = away_mentality
	simulation.teams[1].game_plan = away_game_plan
	simulation.externally_ticked = true
	_initialize_lockstep()
	match_started = true
	simulation.start_match()
	_emit_status("PVP match started. You manage %s." % simulation.config["teams"][1]["name"])
	session_changed.emit()

@rpc("authority", "call_remote", "reliable")
func _rpc_reconnect_snapshot(bundle: Dictionary) -> void:
	if mode != "client" or not reconnecting:
		return
	for key in [
		"config_hash", "seed", "snapshot", "snapshot_tick", "snapshot_sequence",
		"commands", "target_tick", "target_sequence", "target_hash", "next_sequence"
	]:
		if not bundle.has(key):
			_mark_desynchronized("reconnect bundle is missing '%s'" % key)
			return
	if str(bundle.get("config_hash", "")) != _config_digest() \
	or not _is_int_rpc_value(bundle["seed"]) \
	or int(bundle["seed"]) != int(simulation.config["seed"]):
		_mark_desynchronized("reconnect snapshot configuration mismatch")
		return
	if not bundle["snapshot"] is Dictionary or not bundle["commands"] is Array:
		_mark_desynchronized("reconnect snapshot or command stream has an invalid type")
		return
	for key in ["snapshot_tick", "snapshot_sequence", "target_tick", "target_sequence", "next_sequence"]:
		if not _is_int_rpc_value(bundle[key]):
			_mark_desynchronized("reconnect metadata '%s' has an invalid type" % key)
			return
	if typeof(bundle["target_hash"]) != TYPE_STRING:
		_mark_desynchronized("reconnect target hash has an invalid type")
		return
	var snapshot: Dictionary = bundle["snapshot"]
	if not snapshot.get("state") is Dictionary:
		_mark_desynchronized("reconnect snapshot state has an invalid type")
		return
	var snapshot_state: Dictionary = snapshot["state"]
	var snapshot_tick := int(bundle["snapshot_tick"])
	var snapshot_sequence := int(bundle["snapshot_sequence"])
	var target_tick := int(bundle["target_tick"])
	var target_sequence := int(bundle["target_sequence"])
	var next_sequence_value := int(bundle["next_sequence"])
	if not simulation.validate_snapshot(snapshot):
		_mark_desynchronized("reconnect snapshot is invalid: " + simulation.last_snapshot_error)
		return
	if int(snapshot_state.get("tick_count", -1)) != snapshot_tick:
		_mark_desynchronized("reconnect snapshot tick metadata mismatch")
		return
	if snapshot_tick < 0 or target_tick < snapshot_tick or target_tick > _last_match_tick() \
	or snapshot_sequence < 0 or target_sequence < snapshot_sequence \
	or next_sequence_value <= target_sequence:
		_mark_desynchronized("reconnect sequence or tick metadata is inconsistent")
		return
	var commands: Array = bundle.get("commands", [])
	if commands.size() > int(simulation.config["network"]["maximum_pending_commands"]) \
	or commands.size() != next_sequence_value - snapshot_sequence - 1:
		_mark_desynchronized("reconnect command stream size is inconsistent")
		return
	var expected_sequence := snapshot_sequence + 1
	var previous_command_tick := snapshot_tick
	var expected_target_sequence := snapshot_sequence
	for command in commands:
		if not command is Dictionary:
			_mark_desynchronized("reconnect command stream contains a non-dictionary entry")
			return
		for key in ["sequence", "tick", "team", "kind", "value", "player_id", "sender"]:
			if not command.has(key):
				_mark_desynchronized("reconnect command is missing '%s'" % key)
				return
		if not _is_int_rpc_value(command["sequence"]) or int(command["sequence"]) != expected_sequence \
		or not _is_int_rpc_value(command["tick"]) or int(command["tick"]) <= snapshot_tick \
		or int(command["tick"]) < previous_command_tick \
		or int(command["tick"]) > _last_match_tick() \
		or not _is_int_rpc_value(command["team"]) or int(command["team"]) < 0 \
		or int(command["team"]) >= simulation.teams.size() \
		or typeof(command["kind"]) != TYPE_STRING or typeof(command["value"]) != TYPE_STRING \
		or not _is_int_rpc_value(command["player_id"]) or not _is_int_rpc_value(command["sender"]):
			out_of_order_count += 1
			_mark_desynchronized("reconnect command stream has invalid sequence or payload metadata")
			return
		var command_team := int(command["team"])
		var command_player_id := int(command["player_id"])
		if not _command_payload_valid(
			str(command["kind"]), str(command["value"]), command_player_id
		) or str(command["kind"]) == "substitution" \
		and not simulation.has_player_id_in_team(command_team, command_player_id):
			_mark_desynchronized("reconnect command stream contains an invalid command")
			return
		previous_command_tick = int(command["tick"])
		if previous_command_tick <= target_tick:
			expected_target_sequence = expected_sequence
		expected_sequence += 1
	if expected_sequence != next_sequence_value or expected_target_sequence != target_sequence:
		_mark_desynchronized("reconnect command stream is incomplete")
		return
	if not simulation.restore_snapshot(snapshot):
		_mark_desynchronized("reconnect snapshot could not be restored")
		return
	simulation.externally_ticked = true
	_initialize_lockstep()
	match_started = true
	local_team_index = 1
	last_received_sequence = snapshot_sequence
	last_received_command_tick = snapshot_tick
	last_applied_sequence = snapshot_sequence
	next_sequence = next_sequence_value
	reconnect_target_tick = target_tick
	reconnect_target_sequence = target_sequence
	reconnect_target_hash = str(bundle["target_hash"])
	host_tick_watermark = reconnect_target_tick
	host_applied_sequence = reconnect_target_sequence
	disconnect_clock = -1.0
	for command in commands:
		_queue_command(command)
		scheduled_command_log.append(command.duplicate(true))
	sync_state = "replaying commands to tick %d" % reconnect_target_tick
	_emit_status("Snapshot restored at tick %d; replaying to tick %d." % [
		simulation.tick_count, reconnect_target_tick
	])
	session_changed.emit()
	if simulation.tick_count == reconnect_target_tick:
		_finish_reconnect_catchup()

@rpc("any_peer", "call_remote", "reliable")
func _rpc_reconnect_ack(client_tick: int, applied_sequence: int, client_hash: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if mode != "host" or not awaiting_reconnect_ack or sender != reconnect_pending_peer_id:
		return
	if client_tick != reconnect_target_tick or applied_sequence != reconnect_target_sequence \
	or client_hash != reconnect_target_hash:
		hash_mismatch_count += 1
		hash_status = "FAIL (reconnect)"
		_mark_desynchronized("reconnected peer failed snapshot hash verification")
		return
	awaiting_reconnect_ack = false
	disconnect_clock = -1.0
	accumulator = 0.0
	hash_status = "MATCH (reconnect)"
	last_hash_tick = client_tick
	sync_state = "reconnected"
	reconnect_pending_peer_id = 0
	rpc_id(sender, "_rpc_reconnect_resumed", reconnect_target_tick, reconnect_target_sequence, reconnect_target_hash)
	_emit_status("Opponent reconnected and verified at tick %d; match resumed." % reconnect_target_tick)
	session_changed.emit()

@rpc("authority", "call_remote", "reliable")
func _rpc_reconnect_resumed(host_tick: int, applied_sequence: int, host_hash: String) -> void:
	if mode != "client" or not reconnecting:
		return
	if host_tick != simulation.tick_count or applied_sequence != last_applied_sequence \
	or host_hash != simulation.get_state_hash():
		_mark_desynchronized("host reconnect confirmation does not match local state")
		return
	host_tick_watermark = host_tick
	reconnect_target_tick = -1
	reconnect_target_sequence = -1
	reconnect_target_hash = ""
	disconnect_clock = -1.0
	reconnecting = false
	sync_state = "in sync"
	hash_status = "MATCH (reconnect)"
	_emit_status("Reconnected and synchronized; match resumed.")
	session_changed.emit()

@rpc("any_peer", "call_remote", "reliable")
func _rpc_command_request(kind: String, value: String, player_id: int, reported_tick: int) -> void:
	if mode != "host" or not match_started:
		return
	var sender := multiplayer.get_remote_sender_id()
	if not peer_teams.has(sender) or int(peer_teams[sender]) != 1:
		_emit_status("Rejected manager command from unassigned peer %d." % sender)
		return
	if not _host_accept_command(sender, kind, value, player_id, reported_tick):
		rpc_id(sender, "_rpc_command_rejected", "Command rejected by host validation.")

@rpc("authority", "call_remote", "reliable")
func _rpc_command_commit(command: Dictionary) -> void:
	if mode != "client" or not match_started:
		return
	for key in ["sequence", "tick", "team", "kind", "value", "player_id", "sender"]:
		if not command.has(key):
			_mark_desynchronized("committed command is missing '%s'" % key)
			return
	var expected_sequence := last_received_sequence + 1
	if not _is_int_rpc_value(command["sequence"]) or int(command["sequence"]) != expected_sequence:
		out_of_order_count += 1
		_mark_desynchronized("command sequence gap")
		return
	if not _is_int_rpc_value(command["tick"]) or int(command["tick"]) <= simulation.tick_count \
	or int(command["tick"]) > _last_match_tick():
		_mark_desynchronized("committed command target tick is invalid")
		return
	if not _is_int_rpc_value(command["team"]) or not _is_int_rpc_value(command["player_id"]) \
	or not _is_int_rpc_value(command["sender"]):
		_mark_desynchronized("invalid committed command identifiers")
		return
	var command_team := int(command["team"])
	var player_id := int(command["player_id"])
	if command_team < 0 or command_team >= simulation.teams.size() \
	or typeof(command["kind"]) != TYPE_STRING or typeof(command["value"]) != TYPE_STRING \
	or int(command["tick"]) < last_received_command_tick \
	or command_team == 0 and int(command["sender"]) != HOST_PEER_ID \
	or command_team == 1 and int(command["sender"]) != multiplayer.get_unique_id() \
	or not _command_payload_valid(str(command["kind"]), str(command["value"]), player_id) \
	or str(command["kind"]) == "substitution" and not simulation.has_player_id_in_team(command_team, player_id):
		_mark_desynchronized("invalid committed command")
		return
	if _pending_command_count() >= int(simulation.config["network"]["maximum_pending_commands"]):
		_mark_desynchronized("pending command limit exceeded")
		return
	_queue_command(command)
	scheduled_command_log.append(command.duplicate(true))
	print("[Network] Received committed command: ", command)
	session_changed.emit()

@rpc("authority", "call_remote", "reliable")
func _rpc_command_ack(sequence: int, scheduled_tick: int) -> void:
	if mode == "client":
		_emit_status("Command #%d scheduled provisionally for tick %d." % [sequence, scheduled_tick])

@rpc("authority", "call_remote", "reliable")
func _rpc_state_hash(tick: int, host_hash: String, applied_sequence: int) -> void:
	if mode != "client" or not match_started:
		return
	if applied_sequence > last_received_sequence:
		out_of_order_count += 1
		_mark_desynchronized("host hash references an unapplied or unreceived command")
		return
	if tick <= last_received_hash_tick or expected_hashes.has(tick):
		out_of_order_count += 1
		_mark_desynchronized("duplicate or out-of-order state hash for tick %d" % tick)
		return
	if tick < 0 or tick > _last_match_tick():
		_mark_desynchronized("state hash tick is invalid")
		return
	if applied_sequence < last_applied_sequence or applied_sequence > last_received_sequence:
		_mark_desynchronized("state hash applied sequence is invalid")
		return
	if expected_hashes.size() >= 8:
		_mark_desynchronized("too many unverified host state hashes")
		return
	expected_hashes[tick] = host_hash
	expected_hash_sequences[tick] = applied_sequence
	last_received_hash_tick = tick
	if simulation.tick_count > tick:
		_mark_desynchronized("received stale state hash for tick %d" % tick)
		return
	_check_pending_hashes()

@rpc("any_peer", "call_remote", "reliable")
func _rpc_client_hash_result(tick: int, client_hash: String) -> void:
	if mode != "host" or multiplayer.get_remote_sender_id() != client_peer_id:
		return
	if not local_hashes.has(tick):
		out_of_order_count += 1
		_emit_status("Received unexpected client hash for tick %d." % tick)
		return
	if tick <= last_client_hash_tick:
		out_of_order_count += 1
		_emit_status("Received duplicate or stale client hash for tick %d." % tick)
		return
	if client_hash != str(local_hashes[tick]):
		hash_mismatch_count += 1
		hash_status = "FAIL"
		_mark_desynchronized("client state hash mismatch at tick %d" % tick)
		return
	hash_status = "MATCH"
	last_hash_tick = tick
	last_client_hash_tick = tick
	session_changed.emit()

@rpc("authority", "call_remote", "reliable")
func _rpc_tick_beacon(host_tick: int, applied_sequence: int) -> void:
	if mode != "client" or not match_started:
		return
	if applied_sequence > last_received_sequence:
		out_of_order_count += 1
		_mark_desynchronized("host tick beacon references a missing command")
		return
	if host_tick < host_tick_watermark:
		_mark_desynchronized("host tick watermark moved backwards")
		return
	if applied_sequence < last_beacon_applied_sequence:
		_mark_desynchronized("host applied sequence moved backwards")
		return
	if host_tick == host_tick_watermark and host_tick != 0 \
	and applied_sequence != last_beacon_applied_sequence:
		_mark_desynchronized("duplicate host tick beacon has conflicting sequence")
		return
	if host_tick < 0 or host_tick > _last_match_tick():
		_mark_desynchronized("host tick beacon is outside match bounds")
		return
	host_tick_watermark = host_tick
	host_applied_sequence = applied_sequence
	last_beacon_applied_sequence = applied_sequence
	if simulation.tick_count > host_tick:
		_mark_desynchronized("client simulation is ahead of host")
	elif simulation.tick_count == host_tick and last_applied_sequence != applied_sequence:
		_mark_desynchronized("host beacon applied sequence differs from local sequence")
	else:
		sync_state = "in sync" if simulation.tick_count == host_tick else "catching up"
	session_changed.emit()

@rpc("authority", "call_remote", "reliable")
func _rpc_client_tick_report_request(_host_tick: int) -> void:
	if mode == "client":
		rpc_id(HOST_PEER_ID, "_rpc_client_tick_report", simulation.tick_count)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_client_tick_report(client_tick: int) -> void:
	if mode != "host" or multiplayer.get_remote_sender_id() != client_peer_id:
		return
	if client_tick < 0 or client_tick > simulation.tick_count:
		_mark_desynchronized("client reported an invalid tick")
		return
	var tick_difference := simulation.tick_count - client_tick
	sync_state = "in sync" if abs(tick_difference) <= beacon_interval_ticks else "client catching up (%d ticks)" % tick_difference
	session_changed.emit()

@rpc("authority", "call_remote", "reliable")
func _rpc_ping(nonce: int) -> void:
	if mode == "client":
		rpc_id(HOST_PEER_ID, "_rpc_pong", nonce)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_pong(nonce: int) -> void:
	if mode != "host" or multiplayer.get_remote_sender_id() != client_peer_id or nonce != pending_ping_nonce:
		return
	ping_milliseconds = Time.get_ticks_msec() - pending_ping_started_msec
	rpc_id(client_peer_id, "_rpc_ping_result", ping_milliseconds)
	session_changed.emit()

@rpc("authority", "call_remote", "reliable")
func _rpc_ping_result(milliseconds: int) -> void:
	if mode == "client":
		ping_milliseconds = milliseconds
		session_changed.emit()

@rpc("authority", "call_remote", "reliable")
func _rpc_command_rejected(reason: String) -> void:
	if mode == "client":
		_emit_status(reason)

@rpc("authority", "call_remote", "reliable")
func _rpc_session_stopped(reason: String) -> void:
	_mark_desynchronized(reason, false)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_client_desynchronized(reason: String) -> void:
	if mode == "host" and multiplayer.get_remote_sender_id() == client_peer_id:
		_mark_desynchronized("client reported desync: " + reason)
