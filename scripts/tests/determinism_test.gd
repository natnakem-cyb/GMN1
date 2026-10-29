extends SceneTree

const SimulationScript = preload("res://scripts/simulation/match_simulation.gd")

func _initialize() -> void:
	call_deferred("_run_test")

func _run_test() -> void:
	if not _run_restart_contract_tests() or not _run_state_contract_tests():
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

func _run_restart_contract_tests() -> bool:
	var kickoff := _new_restart_test_simulation("4-4-2")
	if kickoff == null:
		return false
	var center := Vector2(
		float(kickoff.config["field"]["width"]) * 0.5,
		float(kickoff.config["field"]["height"]) * 0.5
	)
	var kickoff_taker := kickoff._find_player_by_id(kickoff.restart_taker_id)
	var kickoff_receiver := kickoff._find_player_by_id(kickoff.restart_receiver_id)
	if kickoff.next_kickoff_team != 0 or not kickoff.restart_pending \
	or kickoff.restart_kind != "kickoff" or kickoff_taker == null or kickoff_receiver == null \
	or not _restart_has_valid_receiver(kickoff) \
	or kickoff_taker.tactical_role != "ST" or kickoff_receiver.tactical_role != "CF" \
	or kickoff_taker.position.distance_to(center) > 0.01:
		push_error("Restart test failed: 4-4-2 kickoff did not select a central striker pair.")
		kickoff.free()
		return false
	var kickoff_snapshot := kickoff.create_snapshot()
	var kickoff_peer := _new_restart_test_simulation("4-4-2")
	if kickoff_peer == null or not kickoff_peer.restore_snapshot(kickoff_snapshot) \
	or kickoff_peer.get_state_hash() != kickoff.get_state_hash():
		push_error("Restart test failed: pending kickoff snapshot did not round-trip to an identical hash.")
		kickoff.free()
		if kickoff_peer != null:
			kickoff_peer.free()
		return false
	var invalid_snapshot: Dictionary = kickoff_snapshot.duplicate(true)
	invalid_snapshot["state"]["restart_awarded_team"] = 9
	var before_invalid_hash := kickoff_peer.get_state_hash()
	if kickoff_peer.restore_snapshot(invalid_snapshot) \
	or kickoff_peer.get_state_hash() != before_invalid_hash:
		push_error("Restart test failed: malformed pending restart partially mutated state.")
		kickoff.free()
		kickoff_peer.free()
		return false
	kickoff_peer.free()
	kickoff.start_match()
	if kickoff.restart_pending or kickoff.restart_kind != "in_play" \
	or kickoff.ball_owner != null or kickoff.ball_target != kickoff_receiver \
	or kickoff.last_touch_team_index != 0 or kickoff.last_touch_player_id != kickoff_taker.id:
		push_error("Restart test failed: kickoff did not immediately start a guaranteed pass.")
		kickoff.free()
		return false
	for _step in range(10):
		kickoff._advance_ball(float(kickoff.config["match"]["tick_seconds"]))
		if kickoff.ball_owner == kickoff_receiver:
			break
	if kickoff.ball_owner != kickoff_receiver or kickoff.last_touch_player_id != kickoff_receiver.id:
		push_error("Restart test failed: kickoff receiver did not actually receive the ball.")
		kickoff.free()
		return false

	var single_striker := _new_restart_test_simulation("4-3-3")
	if single_striker == null:
		kickoff.free()
		return false
	var single_taker := single_striker._find_player_by_id(single_striker.restart_taker_id)
	var single_receiver := single_striker._find_player_by_id(single_striker.restart_receiver_id)
	if single_taker == null or single_receiver == null or single_taker.tactical_role != "ST" \
	or not _restart_has_valid_receiver(single_striker) \
	or not ["CM", "LCM", "RCM", "CDM", "LDM", "RDM", "CAM"].has(single_receiver.tactical_role):
		push_error("Restart test failed: single-striker kickoff did not select a central midfielder.")
		kickoff.free()
		single_striker.free()
		return false
	single_striker.start_match()
	single_striker._start_second_half()
	var halftime_taker := single_striker._find_player_by_id(single_striker.last_touch_player_id)
	if single_striker.half_index != 1 or single_striker.next_kickoff_team != 1 \
	or single_striker.teams[0].attacks_right or not single_striker.teams[1].attacks_right \
	or single_striker.restart_pending or single_striker.last_touch_team_index != 1 \
	or halftime_taker == null or halftime_taker.team_index != 1 \
	or single_striker.ball_target == null or single_striker.ball_target.team_index != 1:
		push_error("Restart test failed: halftime kickoff team or end switch was incorrect.")
		kickoff.free()
		single_striker.free()
		return false
	kickoff.free()
	single_striker.free()

	var top_throw := _run_ball_out_test(Vector2(500.0, 300.0), Vector2(0.0, -5000.0), 0)
	if top_throw == null or top_throw.restart_kind != "throw_in" or top_throw.restart_awarded_team != 1 \
	or not _restart_has_valid_receiver(top_throw) \
	or not ["LB", "RB", "LWB", "RWB"].has(top_throw._find_player_by_id(top_throw.restart_taker_id).tactical_role):
		push_error("Restart test failed: top touchline last-touch ownership or thrower role.")
		if top_throw != null:
			top_throw.free()
		return false
	var top_count := _count_restart_awards(top_throw, "throw-in")
	var frozen_position: Vector2 = top_throw.teams[0].players[0].position
	var frozen_score := top_throw.teams[0].score
	var pending_state := JSON.stringify(top_throw.create_snapshot())
	top_throw._resolve_pass(top_throw.teams[0].players[0], top_throw.teams[0])
	top_throw._resolve_shot(top_throw.teams[0].players[0], top_throw.teams[0])
	if top_throw._resolve_tackle(top_throw.teams[1].players[0]) \
	or JSON.stringify(top_throw.create_snapshot()) != pending_state:
		push_error("Restart test failed: pass, shot, or tackle changed state during a dead ball.")
		top_throw.free()
		return false
	top_throw._set_possession(top_throw.teams[0].players[0])
	top_throw._advance_ball(0.1)
	top_throw.step_tick()
	if not top_throw.restart_pending or top_throw.ball_owner != null \
	or top_throw.teams[0].score != frozen_score \
	or top_throw.teams[0].players[0].position != frozen_position \
	or _count_restart_awards(top_throw, "throw-in") != top_count:
		push_error("Restart test failed: dead-ball freeze or duplicate restart protection.")
		top_throw.free()
		return false
	top_throw.free()

	var bottom_throw := _run_ball_out_test(Vector2(500.0, 300.0), Vector2(0.0, 5000.0), 1)
	if bottom_throw == null or bottom_throw.restart_kind != "throw_in" \
	or bottom_throw.restart_awarded_team != 0 or not _restart_has_valid_receiver(bottom_throw):
		push_error("Restart test failed: opposite last-touch team did not receive bottom throw-in.")
		if bottom_throw != null:
			bottom_throw.free()
		return false
	bottom_throw.free()

	var corner := _run_ball_out_test(Vector2(200.0, 300.0), Vector2(-5000.0, 0.0), 0)
	if corner == null or corner.restart_kind != "corner_kick" or corner.restart_awarded_team != 1 \
	or not _restart_has_valid_receiver(corner) \
	or not is_equal_approx(corner.restart_position.x, float(corner.config["field"]["ball_radius"])):
		push_error("Restart test failed: defending last touch did not produce the correct corner.")
		if corner != null:
			corner.free()
		return false
	var corner_hash := corner.get_state_hash()
	var corner_snapshot := corner.create_snapshot()
	var repeated_corner := _run_ball_out_test(
		Vector2(200.0, 300.0), Vector2(-5000.0, 0.0), 0
	)
	var corner_peer := _new_restart_test_simulation("4-3-3")
	if repeated_corner == null or repeated_corner.get_state_hash() != corner_hash \
	or repeated_corner.event_log != corner.event_log \
	or corner_peer == null or not corner_peer.restore_snapshot(corner_snapshot) \
	or corner_peer.get_state_hash() != corner_hash \
	or corner_peer.restart_taker_id == corner_peer.restart_receiver_id:
		push_error("Restart test failed: pending corner was not snapshot/network hash compatible.")
		corner.free()
		if repeated_corner != null:
			repeated_corner.free()
		if corner_peer != null:
			corner_peer.free()
		return false
	for _tick in range(7):
		corner.step_tick()
		repeated_corner.step_tick()
		corner_peer.step_tick()
	if corner.restart_pending or repeated_corner.get_state_hash() != corner.get_state_hash() \
	or corner_peer.get_state_hash() != corner.get_state_hash():
		push_error("Restart test failed: post-restart delivery did not produce identical peer hashes.")
		corner.free()
		repeated_corner.free()
		corner_peer.free()
		return false
	repeated_corner.free()
	corner_peer.free()
	corner.free()

	var goal_kick := _run_ball_out_test(Vector2(200.0, 300.0), Vector2(-5000.0, 0.0), 1)
	if goal_kick == null or goal_kick.restart_kind != "goal_kick" \
	or goal_kick.restart_awarded_team != 0 \
	or not _restart_has_valid_receiver(goal_kick) \
	or goal_kick._find_player_by_id(goal_kick.restart_taker_id).tactical_role != "GK":
		push_error("Restart test failed: attacking last touch did not produce a goalkeeper goal kick.")
		if goal_kick != null:
			goal_kick.free()
		return false
	goal_kick.free()

	var fallback_throw := _run_ball_out_test(
		Vector2(500.0, 300.0), Vector2(0.0, -5000.0), 0, true
	)
	var logged_fallback := false
	if fallback_throw != null:
		for event in fallback_throw.event_log:
			if str(event).contains("Throw-in fallback"):
				logged_fallback = true
	if fallback_throw == null or fallback_throw.restart_kind != "throw_in" \
	or not logged_fallback or not _restart_has_valid_receiver(fallback_throw):
		push_error("Restart test failed: missing-fullback throw-in fallback was not logged.")
		if fallback_throw != null:
			fallback_throw.free()
		return false
	fallback_throw.free()

	if not _run_goal_restart_test() \
	or not _run_missed_shot_restart_test() \
	or not _run_saved_shot_corner_test():
		return false
	print("PASS: kickoff roles/pass, halftime ends/team, touchline ownership, corner/goal kick, dead-ball freeze, and restart snapshots.")
	return true

func _new_restart_test_simulation(formation: String) -> MatchSimulation:
	var simulation: MatchSimulation = SimulationScript.new()
	root.add_child(simulation)
	if not simulation.setup_match(formation):
		push_error("Restart test could not initialize formation %s." % formation)
		simulation.free()
		return null
	return simulation

func _run_ball_out_test(
	position: Vector2, velocity: Vector2, last_touch_team: int, remove_fullbacks: bool = false
) -> MatchSimulation:
	var simulation := _new_restart_test_simulation("4-3-3")
	if simulation == null:
		return null
	simulation.start_match()
	simulation.ball_owner = null
	simulation.ball_target = simulation.teams[last_touch_team].players[1]
	simulation.ball_position = position
	simulation.ball_velocity = velocity
	var last_touch_player: FootballPlayer = simulation.teams[last_touch_team].players[2]
	simulation.last_touch_team_index = last_touch_team
	simulation.last_touch_player_id = last_touch_player.id
	if remove_fullbacks:
		for player in simulation.teams[1].players:
			if player.tactical_role != "GK":
				player.tactical_role = "CM"
	simulation._advance_ball(0.1)
	return simulation

func _count_restart_awards(simulation: MatchSimulation, restart_name: String) -> int:
	var count := 0
	for event in simulation.event_log:
		if str(event).contains("[Restart] %s awarded" % restart_name):
			count += 1
	return count

func _restart_has_valid_receiver(simulation: MatchSimulation) -> bool:
	var taker := simulation._find_player_by_id(simulation.restart_taker_id)
	var receiver := simulation._find_player_by_id(simulation.restart_receiver_id)
	return taker != null and receiver != null \
		and taker != receiver and taker.on_pitch and receiver.on_pitch \
		and taker.team_index == simulation.restart_awarded_team \
		and receiver.team_index == simulation.restart_awarded_team

func _run_goal_restart_test() -> bool:
	var simulation := _new_restart_test_simulation("4-3-3")
	if simulation == null:
		return false
	simulation.start_match()
	var shooter: FootballPlayer = null
	for player in simulation.teams[0].players:
		if player.tactical_role == "ST":
			shooter = player
			break
	if shooter == null:
		push_error("Restart test could not find a formation striker.")
		simulation.free()
		return false
	shooter.position = Vector2(900.0, 300.0)
	simulation.config["match"]["minimum_probability"] = 0.0
	simulation.config["match"]["maximum_probability"] = 1.0
	simulation.config["probability"]["sigmoid_slope"] = 100.0
	simulation.config["probability"]["goalkeeper_save_slope"] = 100.0
	simulation.config["probability"]["action_weights"]["shot"] = {"finishing": 1.0}
	simulation.config["probability"]["action_weights"]["goalkeeper"] = {"goalkeeping": 1.0}
	simulation._goalkeeper(simulation.teams[1]).attributes["goalkeeping"] = 0
	var score_before := simulation.teams[0].score
	var kickoff_awards_before := _count_restart_awards(simulation, "kick-off")
	simulation._resolve_shot(shooter, simulation.teams[0])
	if simulation.teams[0].score != score_before + 1 or not simulation.restart_pending \
	or simulation.restart_kind != "kickoff" or simulation.restart_awarded_team != 1 \
	or simulation.next_kickoff_team != 1 \
	or _count_restart_awards(simulation, "kick-off") != kickoff_awards_before + 1:
		push_error("Restart test failed: goal did not yield exactly one conceding-team kickoff.")
		simulation.free()
		return false
	var pending_goal_snapshot := simulation.create_snapshot()
	var pending_peer := _new_restart_test_simulation("4-3-3")
	if pending_peer != null:
		pending_peer._goalkeeper(pending_peer.teams[1]).attributes["goalkeeping"] = 0
	if pending_peer == null or not pending_peer.restore_snapshot(pending_goal_snapshot) \
	or pending_peer.get_state_hash() != simulation.get_state_hash():
		push_error("Restart test failed: post-goal pending kickoff snapshot did not round-trip.")
		simulation.free()
		if pending_peer != null:
			pending_peer.free()
		return false
	pending_peer.free()
	for _tick in range(12):
		simulation.step_tick()
	if simulation.restart_pending or simulation.ball_target == null \
	or simulation.ball_target.team_index != 1 or simulation.last_touch_team_index != 1:
		push_error("Restart test failed: post-goal kickoff did not deliver the ball to a teammate.")
		simulation.free()
		return false
	simulation.free()
	return true

func _run_missed_shot_restart_test() -> bool:
	var simulation := _new_restart_test_simulation("4-3-3")
	if simulation == null:
		return false
	simulation.start_match()
	var shooter: FootballPlayer = null
	for player in simulation.teams[0].players:
		if player.tactical_role == "ST":
			shooter = player
			break
	if shooter == null:
		simulation.free()
		return false
	shooter.position = Vector2(900.0, 300.0)
	simulation.config["match"]["minimum_probability"] = 0.0
	simulation.config["match"]["maximum_probability"] = 0.0
	simulation.config["probability"]["action_weights"]["shot"] = {"finishing": 1.0}
	simulation._resolve_shot(shooter, simulation.teams[0])
	var passed := simulation.restart_pending and simulation.restart_kind == "goal_kick" \
		and simulation.restart_awarded_team == 1 \
		and simulation.ball_owner == null and simulation.ball_target == null
	if not passed:
		push_error("Restart test failed: wide attacking shot did not produce a goal kick.")
	simulation.free()
	return passed

func _run_saved_shot_corner_test() -> bool:
	var simulation := _new_restart_test_simulation("4-3-3")
	if simulation == null:
		return false
	simulation.start_match()
	var shooter: FootballPlayer = null
	for player in simulation.teams[0].players:
		if player.tactical_role == "ST":
			shooter = player
			break
	if shooter == null:
		simulation.free()
		return false
	shooter.position = Vector2(900.0, 200.0)
	simulation.config["match"]["minimum_probability"] = 0.0
	simulation.config["match"]["maximum_probability"] = 1.0
	simulation.config["probability"]["sigmoid_slope"] = 100.0
	simulation.config["probability"]["goalkeeper_save_slope"] = 100.0
	simulation.config["probability"]["action_weights"]["shot"] = {"finishing": 1.0}
	simulation.config["probability"]["action_weights"]["goalkeeper"] = {"goalkeeping": 1.0}
	simulation.config["match"]["restarts"]["saved_shot_corner_probability"] = 1.0
	simulation._goalkeeper(simulation.teams[1]).attributes["goalkeeping"] = 100
	simulation._resolve_shot(shooter, simulation.teams[0])
	var passed := simulation.restart_pending and simulation.restart_kind == "corner_kick" \
		and simulation.restart_awarded_team == 0 \
		and simulation.last_touch_team_index == 1
	if not passed:
		push_error("Restart test failed: configured keeper deflection did not produce a corner.")
	simulation.free()
	return passed

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
	var replay_simulation: MatchSimulation = null
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
		if tick == int(total_ticks / 3.0):
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
