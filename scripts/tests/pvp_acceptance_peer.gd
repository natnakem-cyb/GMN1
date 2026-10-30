extends SceneTree

const SimulationScript = preload("res://scripts/simulation/match_simulation.gd")
const NetworkScript = preload("res://scripts/network/network_session.gd")

var simulation: MatchSimulation
var network: NetworkSession
var role := ""
var scenario := ""
var port := 24560
var command_submitted := false
var last_logged_hash_tick := -1

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 3:
		push_error("Usage: pvp_acceptance_peer.gd <host|client> <port> <normal|reconnect|forfeit>")
		quit(2)
		return
	role = str(args[0])
	port = int(args[1])
	scenario = str(args[2])
	if not ["host", "client"].has(role) or not ["normal", "reconnect", "forfeit"].has(scenario):
		push_error("Invalid role or scenario.")
		quit(2)
		return

	simulation = SimulationScript.new()
	simulation.name = "MatchSimulation"
	root.add_child(simulation)
	if not simulation.setup_match("4-3-3"):
		push_error("Could not initialize the acceptance match.")
		quit(1)
		return
	network = NetworkScript.new()
	network.name = "NetworkSession"
	root.add_child(network)
	network.configure(simulation)
	network.status_changed.connect(_on_network_status)
	network.session_changed.connect(_on_session_changed)
	print("PVP_BEGIN|role=%s|scenario=%s|port=%d|seed=%d" % [
		role, scenario, port, int(simulation.config["seed"])
	])

	if role == "host":
		await _run_host()
	else:
		await _run_client()

func _run_host() -> void:
	var error := network.host_game(port, false)
	if error != OK:
		push_error("Host startup failed: %s" % error_string(error))
		quit(1)
		return
	if not await _wait_until(func() -> bool: return network.client_peer_id != 0, 10.0):
		push_error("Client did not connect within 10 seconds.")
		quit(1)
		return
	if not network.submit_command(0, "mentality", "Attacking") \
	or not network.submit_command(0, "game_plan", "Direct"):
		push_error("Host could not set starting tactics.")
		quit(1)
		return
	print("PVP_LOBBY|role=host|client_peer=%d|home=Attacking/Direct" % network.client_peer_id)
	if not await _wait_until(func() -> bool:
		return simulation.teams[1].mentality == "Cautious" \
			and simulation.teams[1].game_plan == "Counter"
	, 5.0):
		push_error("Client starting tactics did not arrive.")
		quit(1)
		return
	if not network.start_pvp_match("4-3-3"):
		push_error("Host could not start the PVP match.")
		quit(1)
		return
	print("PVP_MATCH_STARTED|role=host|home=Attacking/Direct|away=Cautious/Counter")

	match scenario:
		"normal":
			await _run_normal_match()
		"reconnect":
			await _run_reconnect_host()
		"forfeit":
			await _run_forfeit_host()

func _run_client() -> void:
	var error := network.join_game("127.0.0.1", port)
	if error != OK:
		push_error("Client startup failed: %s" % error_string(error))
		quit(1)
		return
	if not await _wait_until(func() -> bool:
		return network.local_team_index == 1 and network.sync_state == "lobby ready"
	, 10.0):
		push_error("Client did not become lobby-ready within 10 seconds.")
		quit(1)
		return
	if not network.submit_command(1, "mentality", "Cautious") \
	or not await _wait_until(func() -> bool: return simulation.teams[1].mentality == "Cautious", 5.0):
		push_error("Client mentality request was not applied.")
		quit(1)
		return
	if not network.submit_command(1, "game_plan", "Counter") \
	or not await _wait_until(func() -> bool: return simulation.teams[1].game_plan == "Counter", 5.0):
		push_error("Client game-plan request was not applied.")
		quit(1)
		return
	print("PVP_LOBBY|role=client|team=%d|away=Cautious/Counter" % network.local_team_index)
	if not await _wait_until(func() -> bool: return network.match_started, 10.0):
		push_error("Host did not start the PVP match.")
		quit(1)
		return
	print("PVP_MATCH_STARTED|role=client|team=%d" % network.local_team_index)

	match scenario:
		"normal":
			await _run_normal_match()
		"reconnect":
			await _run_reconnect_client()
		"forfeit":
			await _run_forfeit_client()

func _run_normal_match() -> void:
	var deadline := 35.0
	var started := Time.get_ticks_msec()
	while simulation.active \
	and float(Time.get_ticks_msec() - started) / 1000.0 < deadline:
		await create_timer(0.05).timeout
		_submit_competing_command()
	if simulation.active:
		push_error("Match did not reach full time before the deadline.")
		quit(1)
		return
	if role == "client":
		if not await _wait_until(func() -> bool:
			return network.last_hash_tick >= 3600 and network.sync_state == "in sync"
		, 8.0):
			push_error("Client did not verify the full-time hash and watermark.")
			quit(1)
			return
	else:
		if not await _wait_until(func() -> bool: return network.last_client_hash_tick >= 3600, 8.0):
			push_error("Host did not receive the client full-time hash.")
			quit(1)
			return
		if not await _wait_until(func() -> bool: return network.sync_state == "in sync", 8.0):
			push_error("Host did not observe the client caught up to the final tick watermark.")
			quit(1)
			return
	print("PVP_SUMMARY|role=%s|scenario=normal|tick=%d|score=%d-%d|ping_ms=%d|seq=%d/%d|sync=%s|hash=%s@%d|ooo=%d|mismatch=%d" % [
		role, simulation.tick_count, simulation.teams[0].score, simulation.teams[1].score,
		network.ping_milliseconds, network.last_received_sequence, network.last_applied_sequence,
		network.sync_state, network.hash_status, network.last_hash_tick,
		network.out_of_order_count, network.hash_mismatch_count
	])
	_print_restart_evidence()
	await create_timer(1.0).timeout
	quit(0)

func _submit_competing_command() -> void:
	if command_submitted or simulation.tick_count < 20:
		return
	command_submitted = true
	var accepted := false
	if role == "host":
		accepted = network.submit_command(0, "mentality", "Balanced")
	else:
		accepted = network.submit_command(1, "game_plan", "Possession")
	print("PVP_COMMAND|role=%s|accepted=%s|tick=%d|sequence=%d" % [
		role, str(accepted), simulation.tick_count, network.next_sequence - 1
	])
	if not accepted:
		push_error("Competing manager command was not accepted.")

func _run_reconnect_host() -> void:
	if not await _wait_until(func() -> bool: return simulation.tick_count >= 320, 10.0):
		push_error("Host did not reach reconnect test point.")
		quit(1)
		return
	if not network.submit_command(0, "mentality", "Balanced"):
		push_error("Host could not schedule the reconnect catch-up command.")
		quit(1)
		return
	print("PVP_RECONNECT_SETUP|role=host|tick=%d|sequence=%d" % [
		simulation.tick_count, network.next_sequence - 1
	])
	if not await _wait_until(func() -> bool:
		return network.sync_state == "reconnected" or network.sync_state == "desynchronized"
	, 12.0):
		push_error("Reconnect did not complete within 12 seconds.")
		quit(1)
		return
	if network.sync_state != "reconnected":
		push_error("Reconnect ended in state %s." % network.sync_state)
		quit(1)
		return
	if not await _wait_until(func() -> bool: return simulation.tick_count >= 650, 10.0):
		push_error("Host did not resume simulation after reconnect.")
		quit(1)
		return
	print("PVP_SUMMARY|role=host|scenario=reconnect|tick=%d|ping_ms=%d|sync=%s|hash=%s@%d|last_client_hash=%d|ooo=%d|mismatch=%d" % [
		simulation.tick_count, network.ping_milliseconds, network.sync_state,
		network.hash_status, network.last_hash_tick, network.last_client_hash_tick,
		network.out_of_order_count, network.hash_mismatch_count
	])
	await create_timer(0.5).timeout
	quit(0)

func _run_reconnect_client() -> void:
	if not await _wait_until(func() -> bool: return simulation.tick_count >= 360, 10.0):
		push_error("Client did not reach reconnect test point.")
		quit(1)
		return
	await create_timer(0.15).timeout
	print("PVP_DROP_LINK|role=client|tick=%d" % simulation.tick_count)
	network.simulate_connection_drop()
	await create_timer(0.35).timeout
	var error := network.reconnect_to_host("127.0.0.1", port)
	if error != OK:
		push_error("Client reconnect call failed: %s" % error_string(error))
		quit(1)
		return
	if not await _wait_until(func() -> bool:
		return network.sync_state == "in sync" and network.hash_status == "MATCH (reconnect)"
	, 12.0):
		push_error("Client failed snapshot/catch-up reconnect: %s" % network.sync_state)
		quit(1)
		return
	if not await _wait_until(func() -> bool: return simulation.tick_count >= 650, 10.0):
		push_error("Client did not continue advancing after reconnect.")
		quit(1)
		return
	print("PVP_SUMMARY|role=client|scenario=reconnect|tick=%d|ping_ms=%d|sync=%s|hash=%s@%d|seq=%d/%d|ooo=%d|mismatch=%d" % [
		simulation.tick_count, network.ping_milliseconds, network.sync_state,
		network.hash_status, network.last_hash_tick, network.last_received_sequence,
		network.last_applied_sequence, network.out_of_order_count, network.hash_mismatch_count
	])
	await create_timer(0.5).timeout
	quit(0)

func _run_forfeit_host() -> void:
	if not await _wait_until(func() -> bool: return not network.match_started or network.simulation.finished, 40.0):
		push_error("Host did not observe disconnect forfeit within 40 seconds.")
		quit(1)
		return
	var forfeit_seen := false
	for event in simulation.event_log:
		if str(event).contains("DISCONNECT_FORFEIT"):
			forfeit_seen = true
			break
	if not forfeit_seen:
		push_error("Host finished without a disconnect-forfeit event.")
		quit(1)
		return
	print("PVP_SUMMARY|role=host|scenario=forfeit|winner=0|tick=%d|sync=%s|event=%s" % [
		simulation.tick_count, network.sync_state, simulation.event_log[-1]
	])
	quit(0)

func _run_forfeit_client() -> void:
	if not await _wait_until(func() -> bool: return simulation.tick_count >= 60, 10.0):
		push_error("Client did not reach disconnect-forfeit test point.")
		quit(1)
		return
	print("PVP_DROP_LINK|role=client|tick=%d|no_reconnect=true" % simulation.tick_count)
	network.simulate_connection_drop()
	await create_timer(0.5).timeout
	print("PVP_CLIENT_EXIT|scenario=forfeit|connected_process_closing=true")
	quit(0)

func _print_restart_evidence() -> void:
	var goal_seen := false
	var post_goal_restart := false
	for event in simulation.event_log:
		if str(event).contains("scores!"):
			goal_seen = true
		elif goal_seen and str(event).contains("[Restart] kick-off taken"):
			post_goal_restart = true
	print("PVP_RESTART_EVIDENCE|role=%s|goal_seen=%s|post_goal_kickoff=%s|score=%d-%d" % [
		role, str(goal_seen), str(post_goal_restart), simulation.teams[0].score, simulation.teams[1].score
	])
	for event in simulation.event_log:
		if str(event).contains("[Restart]") or str(event).contains("scores!"):
			print("PVP_EVENT|role=%s|%s" % [role, str(event)])

func _on_network_status(message: String) -> void:
	print("PVP_STATUS|role=%s|tick=%d|%s" % [role, simulation.tick_count, message])

func _on_session_changed() -> void:
	if network.last_hash_tick <= last_logged_hash_tick \
	or not network.hash_status.begins_with("MATCH"):
		return
	last_logged_hash_tick = network.last_hash_tick
	print("PVP_HASH_OK|role=%s|tick=%d|status=%s|seq=%d/%d|ping_ms=%d" % [
		role, network.last_hash_tick, network.hash_status,
		network.last_received_sequence, network.last_applied_sequence,
		network.ping_milliseconds
	])

func _wait_until(predicate: Callable, timeout_seconds: float) -> bool:
	var started := Time.get_ticks_msec()
	while float(Time.get_ticks_msec() - started) / 1000.0 < timeout_seconds:
		if predicate.call():
			return true
		await create_timer(0.05).timeout
	return predicate.call()
