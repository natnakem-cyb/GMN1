extends SceneTree

const SimulationScript = preload("res://scripts/simulation/match_simulation.gd")

func _initialize() -> void:
	call_deferred("_run_test")

func _run_test() -> void:
	if not _run_state_contract_tests():
		quit(1)
		return
	var first := _run_match()
	var second := _run_match()
	if (
		first["home_score"] != second["home_score"]
		or first["away_score"] != second["away_score"]
		or first["events"] != second["events"]
		or first["commands"] != second["commands"]
		or first["hashes"] != second["hashes"]
		or not first["snapshot_roundtrip"]
		or not second["snapshot_roundtrip"]
	):
		push_error("Determinism test failed: identical seed/commands produced different results.")
		quit(1)
		return
	if not first["events"].has("HALFTIME: teams switch ends"):
		push_error("Determinism test failed: halftime switch event was not recorded.")
		quit(1)
		return
	var logged_substitution := false
	var logged_instructions := 0
	for event in first["events"]:
		if " substitutes " in str(event):
			logged_substitution = true
		if " activates " in str(event):
			logged_instructions += 1
	if not logged_substitution:
		push_error("Determinism test failed: scheduled substitution was not recorded.")
		quit(1)
		return
	if logged_instructions < 2:
		push_error("Determinism test failed: scheduled instructions were not recorded.")
		quit(1)
		return
	print("PASS: deterministic score %d-%d; %d key events and %d state hashes match; snapshot replay verified." % [
		int(first["home_score"]), int(first["away_score"]), first["events"].size(), first["hashes"].size()
	])
	quit(0)

func _run_state_contract_tests() -> bool:
	var host := SimulationScript.new()
	var peer := SimulationScript.new()
	root.add_child(host)
	root.add_child(peer)
	if not host.setup_match("4-3-3") or not peer.setup_match("4-3-3"):
		push_error("State contract test could not initialize simulations.")
		host.free()
		peer.free()
		return false
	host.start_match()
	peer.start_match()
	if host.get_state_hash() != peer.get_state_hash():
		push_error("Equivalent initial simulations have different authoritative hashes.")
		host.free()
		peer.free()
		return false
	host.cycle_selected_player(0)
	if host.selected_player_index == peer.selected_player_index \
	or host.get_state_hash() != peer.get_state_hash():
		push_error("Local player selection affected authoritative state or did not change.")
		host.free()
		peer.free()
		return false
	peer.cycle_selected_player(0)
	peer.cycle_selected_player(0)
	var receiver_selection := peer.selected_player_index
	var snapshot := host.create_snapshot()
	if not peer.restore_snapshot(snapshot) or peer.selected_player_index != receiver_selection \
	or peer.get_state_hash() != host.get_state_hash():
		push_error("Snapshot did not preserve receiver selection and restore authoritative state.")
		host.free()
		peer.free()
		return false
	var baseline_hash := host.get_state_hash()
	host.teams[0].score += 1
	if host.get_state_hash() == baseline_hash:
		push_error("Authoritative score changes were omitted from the state hash.")
		host.free()
		peer.free()
		return false
	host.teams[0].score -= 1
	if not host.validate_manager_command(0, "mentality", "Attacking") \
	or not host.validate_manager_command(0, "game_plan", "Direct") \
	or not host.apply_manager_command(0, "mentality", "Attacking") \
	or not peer.apply_manager_command(0, "mentality", "Attacking") \
	or host.apply_manager_command(0, "game_plan", "Direct") \
	or peer.apply_manager_command(0, "game_plan", "Direct") \
	or host.get_state_hash() != peer.get_state_hash() \
	or host.teams[0].game_plan != "Possession":
		push_error("Conflicting tactical commands did not resolve deterministically without partial application.")
		host.free()
		peer.free()
		return false
	var before_stale_command := JSON.stringify(host.create_snapshot())
	if host.validate_manager_command(0, "substitution", "", 999999) \
	or host.apply_manager_command(0, "substitution", "", 999999) \
	or JSON.stringify(host.create_snapshot()) != before_stale_command:
		push_error("Stale substitution identity was accepted or mutated simulation state.")
		host.free()
		peer.free()
		return false
	var outgoing_id := host.teams[0].players[0].id
	if not host.apply_manager_command(0, "substitution", "", outgoing_id) \
	or not peer.apply_manager_command(0, "substitution", "", outgoing_id) \
	or host.get_state_hash() != peer.get_state_hash():
		push_error("Stable outgoing player ID did not produce identical substitutions.")
		host.free()
		peer.free()
		return false
	var valid_snapshot := host.create_snapshot()
	var before_invalid_restore_hash := peer.get_state_hash()
	var before_invalid_restore_selection := peer.selected_player_index
	var before_invalid_restore_snapshot := JSON.stringify(peer.create_snapshot())
	var invalid_snapshots: Array[Dictionary] = []
	var invalid_snapshot := valid_snapshot.duplicate(true)
	invalid_snapshot["state"]["ball_owner_id"] = 999999
	invalid_snapshots.append(invalid_snapshot)
	invalid_snapshot = valid_snapshot.duplicate(true)
	invalid_snapshot["version"] = int(valid_snapshot["version"]) - 1
	invalid_snapshots.append(invalid_snapshot)
	invalid_snapshot = valid_snapshot.duplicate(true)
	invalid_snapshot["state"].erase("rng_state")
	invalid_snapshots.append(invalid_snapshot)
	invalid_snapshot = valid_snapshot.duplicate(true)
	invalid_snapshot["state"]["tick_count"] = "invalid"
	invalid_snapshots.append(invalid_snapshot)
	invalid_snapshot = valid_snapshot.duplicate(true)
	invalid_snapshot["state"]["teams"][0]["players"].pop_back()
	invalid_snapshots.append(invalid_snapshot)
	invalid_snapshot = valid_snapshot.duplicate(true)
	invalid_snapshot["state"]["teams"][0]["players"][1]["id"] = invalid_snapshot["state"]["teams"][0]["players"][0]["id"]
	invalid_snapshots.append(invalid_snapshot)
	for rejected_snapshot in invalid_snapshots:
		if peer.restore_snapshot(rejected_snapshot) \
		or peer.get_state_hash() != before_invalid_restore_hash \
		or JSON.stringify(peer.create_snapshot()) != before_invalid_restore_snapshot \
		or peer.selected_player_index != before_invalid_restore_selection:
			push_error("Rejected snapshot partially mutated the receiving simulation.")
			host.free()
			peer.free()
			return false
	host.free()
	peer.free()
	print("PASS: local selection isolation, authoritative hashing, stable substitution identity, and snapshot rejection.")
	return true

func _run_match() -> Dictionary:
	var simulation: MatchSimulation = SimulationScript.new()
	root.add_child(simulation)
	var test_config: Dictionary = simulation.config["determinism_test"]
	simulation.config["match"]["half_duration_seconds"] = float(test_config["half_duration_seconds"])
	if not simulation.setup_match("4-3-3"):
		push_error("Determinism test could not initialize a match.")
		simulation.free()
		return {"home_score": -1, "away_score": -1, "events": [], "commands": [], "hashes": [], "snapshot_roundtrip": false}
	var commands := _recorded_command_stream(test_config["command_ticks"], simulation.teams[0].players[7].id)
	var hash_history: Array[Dictionary] = []
	var snapshot_roundtrip := false
	var replay_simulation: MatchSimulation
	for command in commands:
		if int(command["tick"]) == 0:
			if not simulation.apply_manager_command(
				int(command["team"]), str(command["kind"]), str(command["value"]), int(command["player_id"])
			):
				push_error("Determinism test rejected setup command: " + str(command))
				simulation.free()
				return {"home_score": -1, "away_score": -1, "events": [], "commands": [], "hashes": [], "snapshot_roundtrip": false}
	simulation.externally_ticked = true
	simulation.start_match()
	var total_ticks := int(float(test_config["half_duration_seconds"]) * 2.0 / float(simulation.config["match"]["tick_seconds"]))
	for tick in range(1, total_ticks + 1):
		for command in commands:
			if int(command["tick"]) != tick:
				continue
			if not simulation.apply_manager_command(
				int(command["team"]), str(command["kind"]), str(command["value"]), int(command["player_id"])
			):
				push_error("Determinism test rejected recorded command: " + str(command))
				simulation.free()
				return {"home_score": -1, "away_score": -1, "events": [], "commands": [], "hashes": [], "snapshot_roundtrip": false}
			if replay_simulation != null and not replay_simulation.apply_manager_command(
				int(command["team"]), str(command["kind"]), str(command["value"]), int(command["player_id"])
			):
				push_error("Determinism test replay rejected command: " + str(command))
				simulation.free()
				replay_simulation.free()
				return {"home_score": -1, "away_score": -1, "events": [], "commands": [], "hashes": [], "snapshot_roundtrip": false}
		simulation.step_tick()
		if replay_simulation != null:
			replay_simulation.step_tick()
		if tick == int(total_ticks / 3):
			var snapshot := simulation.create_snapshot()
			replay_simulation = SimulationScript.new()
			root.add_child(replay_simulation)
			replay_simulation.config["match"]["half_duration_seconds"] = float(test_config["half_duration_seconds"])
			if replay_simulation.setup_match("4-3-3"):
				replay_simulation.externally_ticked = true
				snapshot_roundtrip = replay_simulation.restore_snapshot(snapshot) \
					and replay_simulation.get_state_hash() == simulation.get_state_hash()
			else:
				replay_simulation.free()
				replay_simulation = null
		var hash_interval := int(simulation.config["network"]["state_hash_interval_ticks"])
		if tick % hash_interval == 0:
			hash_history.append({"tick": tick, "hash": simulation.get_state_hash()})
	var result := {
		"home_score": simulation.teams[0].score,
		"away_score": simulation.teams[1].score,
		"events": simulation.event_log.duplicate(),
		"commands": commands.duplicate(true),
		"hashes": hash_history,
		"snapshot_roundtrip": snapshot_roundtrip and replay_simulation != null \
			and replay_simulation.get_state_hash() == simulation.get_state_hash()
	}
	simulation.free()
	if replay_simulation != null:
		replay_simulation.free()
	return result

func _recorded_command_stream(command_ticks: Dictionary, outgoing_player_id: int) -> Array[Dictionary]:
	var commands: Array[Dictionary] = [
		{"tick": 0, "team": 0, "kind": "mentality", "value": "Attacking", "player_id": -1},
		{"tick": 0, "team": 0, "kind": "game_plan", "value": "Direct", "player_id": -1},
		{"tick": int(command_ticks["first_instruction"]) + 1, "team": 0, "kind": "instruction", "value": "push_fullbacks", "player_id": -1},
		{"tick": int(command_ticks["second_instruction"]) + 1, "team": 0, "kind": "instruction", "value": "direct_long_balls", "player_id": -1},
		{"tick": int(command_ticks["mentality_change"]) + 1, "team": 0, "kind": "mentality", "value": "Balanced", "player_id": -1},
		{"tick": int(command_ticks["substitution"]) + 1, "team": 0, "kind": "substitution", "value": "", "player_id": outgoing_player_id}
	]
	return commands
