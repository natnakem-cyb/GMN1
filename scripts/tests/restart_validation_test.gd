extends SceneTree

const SimulationScript = preload("res://scripts/simulation/match_simulation.gd")
const KICKOFF_SHORT_PASS_MAX_DISTANCE_RATIO := 0.30

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	for formation in ["4-3-3", "4-2-3-1"]:
		var layout_result := _run_kickoff_layout(formation)
		if layout_result.is_empty():
			quit(1)
			return
		print("[Validation PASS] kickoff layout: %s" % JSON.stringify(layout_result))

	var kickoff_first := _run_kickoff("4-4-2")
	var kickoff_replay := _run_kickoff("4-4-2")
	if not _same_result("initial kickoff", kickoff_first, kickoff_replay):
		quit(1)
		return
	print("[Validation PASS] initial kickoff: %s" % _result_text(kickoff_first))

	var single_striker := _run_kickoff("4-3-3")
	var single_striker_replay := _run_kickoff("4-3-3")
	if single_striker.is_empty() or str(single_striker["receiver_role"]) not in [
		"CM", "LCM", "RCM", "CDM", "LDM", "RDM", "CAM"
	] or not _same_result("single-striker kickoff", single_striker, single_striker_replay):
		push_error("Initial kickoff failed the single-striker midfield-receiver fallback.")
		quit(1)
		return
	print("[Validation PASS] single-striker kickoff: %s" % _result_text(single_striker))

	var scenarios: Array[Dictionary] = [
		{
			"name": "throw-in top / team 0 last touch",
			"kind": "throw_in",
			"boundary": "top_touchline",
			"last_touch_team": 0,
			"awarded_team": 1,
			"start": Vector2(500.0, 300.0),
			"velocity": Vector2(0.0, -5000.0)
		},
		{
			"name": "throw-in bottom / team 1 last touch",
			"kind": "throw_in",
			"boundary": "bottom_touchline",
			"last_touch_team": 1,
			"awarded_team": 0,
			"start": Vector2(500.0, 300.0),
			"velocity": Vector2(0.0, 5000.0)
		},
		{
			"name": "corner left goal line",
			"kind": "corner_kick",
			"boundary": "left_goal_line",
			"last_touch_team": 0,
			"awarded_team": 1,
			"start": Vector2(200.0, 150.0),
			"velocity": Vector2(-3000.0, 0.0)
		},
		{
			"name": "corner right goal line",
			"kind": "corner_kick",
			"boundary": "right_goal_line",
			"last_touch_team": 1,
			"awarded_team": 0,
			"start": Vector2(800.0, 450.0),
			"velocity": Vector2(3000.0, 0.0)
		},
		{
			"name": "goal kick left goal line",
			"kind": "goal_kick",
			"boundary": "left_goal_line",
			"last_touch_team": 1,
			"awarded_team": 0,
			"start": Vector2(200.0, 150.0),
			"velocity": Vector2(-3000.0, 0.0)
		},
		{
			"name": "goal kick right goal line",
			"kind": "goal_kick",
			"boundary": "right_goal_line",
			"last_touch_team": 0,
			"awarded_team": 1,
			"start": Vector2(800.0, 450.0),
			"velocity": Vector2(3000.0, 0.0)
		}
	]
	for scenario in scenarios:
		var first := _run_boundary_scenario(scenario)
		var replay := _run_boundary_scenario(scenario)
		if not _same_result(str(scenario["name"]), first, replay):
			quit(1)
			return
		print("[Validation PASS] %s: %s" % [scenario["name"], _result_text(first)])

	var goal_first := _run_post_goal_kickoff()
	var goal_replay := _run_post_goal_kickoff()
	if not _same_result("post-goal kickoff", goal_first, goal_replay):
		quit(1)
		return
	print("[Validation PASS] post-goal kickoff: %s" % _result_text(goal_first))
	print("PASS: all restart validation scenarios replayed with matching states and hashes.")
	quit(0)

func _same_result(label: String, first: Dictionary, replay: Dictionary) -> bool:
	if first.is_empty() or replay.is_empty():
		push_error("Restart validation failed: %s did not complete." % label)
		return false
	if JSON.stringify(first) != JSON.stringify(replay):
		push_error("Restart validation failed: %s replay differed.\nFirst: %s\nReplay: %s" % [
			label, JSON.stringify(first), JSON.stringify(replay)
		])
		return false
	return true

func _result_text(result: Dictionary) -> String:
	var summary := result.duplicate(true)
	summary.erase("hash_history")
	return JSON.stringify(summary)

func _run_kickoff_layout(formation: String) -> Dictionary:
	var simulation := _new_simulation(formation)
	if simulation == null:
		return {}
	var kickoff_team_index := int(simulation.config["match"]["initial_kickoff_team_index"])
	var initial_layout := _verify_kickoff_layout(simulation, kickoff_team_index)
	if initial_layout.is_empty():
		simulation.free()
		return {}

	simulation.elapsed_seconds = float(simulation.config["match"]["half_duration_seconds"]) \
		- float(simulation.config["match"]["tick_seconds"])
	simulation.step_tick()
	if not _require(
		simulation.half_index == 1
		and simulation.teams[0].attacks_right == false
		and simulation.teams[1].attacks_right == true
		and simulation.restart_kind == "in_play"
		and not simulation.restart_pending,
		"%s halftime did not switch ends and execute its kickoff." % formation
	):
		simulation.free()
		return {}
	var halftime_kickoff_team := int(simulation.config["match"]["halftime_restart_team_index"])
	var halftime_layout := _verify_kickoff_layout(simulation, halftime_kickoff_team)
	if halftime_layout.is_empty():
		simulation.free()
		return {}
	var result := {
		"formation": formation,
		"initial": initial_layout,
		"halftime": halftime_layout
	}
	simulation.free()
	return result

func _verify_kickoff_layout(simulation: MatchSimulation, kickoff_team_index: int) -> Dictionary:
	var field_data: Dictionary = simulation.config["field"]
	var match_data: Dictionary = simulation.config["match"]
	var field_width := float(field_data["width"])
	var field_height := float(field_data["height"])
	var center := Vector2(field_width * 0.5, field_height * 0.5)
	var taker := simulation._find_player_by_id(simulation.last_touch_player_id)
	if not _require(
		taker != null
		and taker.team_index == kickoff_team_index
		and taker.position.is_equal_approx(center)
		and simulation.ball_position.is_equal_approx(center)
		and simulation.ball_target != null
		and simulation.ball_target.team_index == kickoff_team_index
		and simulation.ball_velocity.length() > 0.0,
		"kickoff layout must keep the ball/taker at centre and select a live teammate receiver."
	):
		return {}
	var layout_log_count := 0
	var latest_layout_log := ""
	for event in simulation.event_log:
		if str(event).begins_with("[Match] [Kickoff layout]"):
			layout_log_count += 1
			latest_layout_log = str(event)
	var expected_layout_log_count := simulation.half_index + 1
	var expected_directions := [
		"attacks right" if simulation.teams[0].attacks_right else "attacks left",
		"attacks right" if simulation.teams[1].attacks_right else "attacks left"
	]
	if not _require(
		layout_log_count == expected_layout_log_count
		and latest_layout_log.contains(simulation.teams[0].formation)
		and latest_layout_log.contains(simulation.teams[1].formation)
		and latest_layout_log.contains(expected_directions[0])
		and latest_layout_log.contains(expected_directions[1])
		and latest_layout_log.contains(taker.player_name)
		and latest_layout_log.contains(simulation.ball_target.player_name),
		"kickoff placement log is missing a formation, direction, taker, or receiver."
	):
		return {}

	var depth_ratio := clampf(float(match_data["kickoff_own_half_depth_ratio"]), 0.0, 0.5)
	var boundary_margin := float(match_data["player_boundary_margin"])
	var team_positions: Array[Dictionary] = []
	for team in simulation.teams:
		var formation: Array = simulation.config["formations"][team.formation]
		var team_positions_for_dump: Array[Dictionary] = []
		for player in team.players:
			var slot: Dictionary = {}
			for candidate in formation:
				if str(candidate["role"]) == player.tactical_role:
					slot = candidate
					break
			if not _require(not slot.is_empty(), "kickoff player has no matching formation slot."):
				return {}
			var expected_position := center
			if player.id != taker.id:
				var normalized_x := float(slot["x"]) * depth_ratio
				if not team.attacks_right:
					normalized_x = 1.0 - normalized_x
				expected_position = Vector2(
					clampf(field_width * normalized_x, boundary_margin, field_width - boundary_margin),
					clampf(
						field_height * float(slot["y"]),
						boundary_margin,
						field_height - boundary_margin
					)
				)
				if not _require(
					player.position.is_equal_approx(expected_position)
					and player.tactical_position.is_equal_approx(expected_position),
					"%s #%d is not placed on its %s kickoff slot." % [
						team.team_name, player.number, player.tactical_role
					]
				):
					return {}
				var on_own_half := player.position.x <= center.x if team.attacks_right \
					else player.position.x >= center.x
				if not _require(on_own_half, "%s has a kickoff player outside its own half." % team.team_name):
					return {}
			team_positions_for_dump.append({
				"name": player.player_name,
				"role": player.tactical_role,
				"position": [player.position.x, player.position.y]
			})
		team_positions.append({
			"name": team.team_name,
			"formation": team.formation,
			"attacks": "right" if team.attacks_right else "left",
			"players": team_positions_for_dump
		})
	return {
		"kickoff_team": simulation.teams[kickoff_team_index].team_name,
		"taker": taker.player_name,
		"receiver": simulation.ball_target.player_name,
		"teams": team_positions
	}

func _new_simulation(formation: String = "4-3-3") -> MatchSimulation:
	var simulation: MatchSimulation = SimulationScript.new()
	root.add_child(simulation)
	if not simulation.setup_match(formation):
		push_error("Restart validation could not initialize formation %s." % formation)
		simulation.free()
		return null
	simulation.externally_ticked = true
	simulation.start_match()
	return simulation

func _require(condition: bool, message: String) -> bool:
	if condition:
		return true
	push_error("Restart validation failed: " + message)
	return false

func _run_kickoff(formation: String) -> Dictionary:
	var simulation := _new_simulation(formation)
	if simulation == null:
		return {}
	var kickoff_team := int(simulation.config["match"]["initial_kickoff_team_index"])
	var taker := simulation._find_player_by_id(simulation.last_touch_player_id)
	var receiver: FootballPlayer = simulation.ball_target
	var initial_velocity := simulation.ball_velocity
	var center := Vector2(
		float(simulation.config["field"]["width"]) * 0.5,
		float(simulation.config["field"]["height"]) * 0.5
	)
	var kickoff_pass_vector := receiver.position - center if receiver != null else Vector2.ZERO
	var attack_direction := 1.0 if simulation.teams[kickoff_team].attacks_right else -1.0
	var short_pass_limit := (
		float(simulation.config["field"]["width"]) * KICKOFF_SHORT_PASS_MAX_DISTANCE_RATIO
	)
	var attacking_team_faces_right := simulation.teams[kickoff_team].attacks_right
	if not _require(
		kickoff_team == 0 and not simulation.restart_pending
		and simulation.restart_kind == "in_play"
		and taker != null and taker.team_index == kickoff_team
		and taker.position.is_equal_approx(center)
		and receiver != null and receiver.on_pitch
		and receiver.team_index == kickoff_team and receiver != taker
		and simulation.ball_owner == null
		and simulation.ball_velocity.length() > 0.0
		and kickoff_pass_vector.x * attack_direction < 0.0
		and kickoff_pass_vector.length() < short_pass_limit
		and simulation.last_touch_team_index == kickoff_team
		and simulation.last_action.contains("kick-off taken")
		and simulation.last_formula.contains("Guaranteed deterministic restart delivery"),
		"initial kickoff pass must be backward and shorter than %.1fpx; got vector %s (%.1fpx)." % [
			short_pass_limit, str(kickoff_pass_vector), kickoff_pass_vector.length()
		]
	):
		simulation.free()
		return {}
	if formation == "4-4-2" and not _require(
		taker.tactical_role in ["ST", "CF"] and receiver.tactical_role in ["ST", "CF"],
		"two-forward kickoff did not choose a forward receiver."
	):
		simulation.free()
		return {}
	if formation == "4-3-3" and not _require(
		receiver.tactical_role in ["CM", "LCM", "RCM", "CDM", "LDM", "RDM", "CAM"],
		"single-striker kickoff did not choose a central midfielder."
	):
		simulation.free()
		return {}
	var hash_history: Array[String] = [simulation.get_state_hash()]
	var received_tick := _advance_to_receiver(simulation, receiver, null, hash_history)
	if received_tick < 0:
		simulation.free()
		return {}
	var kickoff_awards := _count_awards(simulation, "kick-off")
	if not _require(
		simulation.ball_owner == receiver and simulation.ball_target == null
		and simulation.last_touch_player_id == receiver.id
		and kickoff_awards == 1
		and _resumed_state_is_live(simulation, receiver),
		"kickoff did not enter normal play exactly once at the receiver."
	):
		simulation.free()
		return {}
	if not _verify_restart_events(
		simulation, "kickoff", "", Vector2.ZERO, "none recorded",
		taker.player_name, receiver.player_name
	):
		simulation.free()
		return {}
	if not _verify_no_duplicate_after_resume(
		simulation, receiver, "kick-off", kickoff_awards, hash_history
	):
		simulation.free()
		return {}
	var result := {
		"formation": formation,
		"team": kickoff_team,
		"team_attacks_right": attacking_team_faces_right,
		"taker_id": taker.id,
		"receiver_id": receiver.id,
		"receiver_role": receiver.tactical_role,
		"pass_vector": _vector_data(kickoff_pass_vector),
		"pass_distance": kickoff_pass_vector.length(),
		"short_pass_limit": short_pass_limit,
		"attack_direction": attack_direction,
		"start_velocity": _vector_data(initial_velocity),
		"received_tick": received_tick,
		"restart_awards": kickoff_awards,
		"hash_history": hash_history,
		"hash": simulation.get_state_hash()
	}
	simulation.free()
	return result

func _run_boundary_scenario(scenario: Dictionary) -> Dictionary:
	var simulation := _new_simulation()
	if simulation == null:
		return {}
	var last_touch_team := int(scenario["last_touch_team"])
	var awarded_team := int(scenario["awarded_team"])
	var last_toucher: FootballPlayer = simulation.teams[last_touch_team].players[1]
	var scores_before := [simulation.teams[0].score, simulation.teams[1].score]
	for defender in simulation.teams[1 - last_touch_team].players:
		defender.position = Vector2(-500.0, -500.0)
	simulation._set_possession(last_toucher)
	var last_touch_was_recorded := simulation.last_touch_team_index == last_touch_team \
		and simulation.last_touch_player_id == last_toucher.id \
		and simulation.ball_owner == last_toucher
	if not _require(last_touch_was_recorded, "could not establish a production last-touch state before crossing."):
		simulation.free()
		return {}
	simulation.ball_owner = null
	simulation.ball_target = last_toucher
	simulation.ball_position = scenario["start"]
	simulation.ball_velocity = scenario["velocity"]
	simulation.ball_position_3d = Vector3(simulation.ball_position.x, simulation.ball_position.y, float(simulation.config["match"]["ball_flight"]["ball_radius_px"]))
	simulation.ball_velocity_3d = Vector3(simulation.ball_velocity.x, simulation.ball_velocity.y, 0.0)
	simulation.ball_in_flight = true
	simulation.ball_on_ground = true
	simulation.ball_flight_phase = "ground_pass"
	simulation.ball_pass_probability = 1.0
	simulation.ball_shooter_id = last_toucher.id
	simulation.last_touch_team_index = last_touch_team
	simulation.last_touch_player_id = last_toucher.id
	simulation.step_tick()
	for player in simulation.teams[1 - last_touch_team].players:
		if player.id != simulation.restart_taker_id:
			player.position = player.tactical_position

	var kind := str(scenario["kind"])
	var expected_boundary := str(scenario["boundary"])
	var taker := simulation._find_player_by_id(simulation.restart_taker_id)
	var receiver := simulation._find_player_by_id(simulation.restart_receiver_id)
	var crossing: Vector2 = simulation.restart_crossing_position
	var expected_position := _expected_restart_position(simulation, scenario, crossing)
	var field: Dictionary = simulation.config["field"]
	var crossing_is_expected := _crossing_matches_boundary(
		crossing, expected_boundary, float(field["width"]), float(field["height"]),
		float(field["ball_radius"])
	)
	if not _require(
		crossing_is_expected
		and simulation.restart_pending and simulation.restart_kind == kind
		and simulation.restart_awarded_team == awarded_team
		and simulation.last_touch_team_index == last_touch_team
		and simulation.last_touch_player_id == last_toucher.id
		and taker != null and taker.on_pitch and taker.team_index == awarded_team
		and receiver != null and receiver.on_pitch and receiver.team_index == awarded_team
		and receiver != taker
		and simulation.restart_position.is_equal_approx(expected_position)
		and simulation.last_action.contains(_restart_name(kind) + " awarded")
		and simulation.last_action.contains(last_toucher.player_name),
		"%s classification, ownership, restart geometry, or player selection was incorrect." % scenario["name"]
	):
		simulation.free()
		return {}
	if kind == "corner_kick":
		var defending_team := _defending_team_for_boundary(simulation, expected_boundary)
		var attacking_team := 1 - defending_team
		var outside_goal_mouth := absf(crossing.y - float(field["height"]) * 0.5) \
			> float(field["goal_width"]) * 0.5 + float(field["ball_radius"])
		if not _require(
			last_touch_team == defending_team and awarded_team == attacking_team
			and outside_goal_mouth
			and not simulation.last_action.contains("scores!")
			and simulation.restart_kind != "goal_kick",
			"corner did not follow defensive last touch outside the goal mouth."
		):
			simulation.free()
			return {}
	if not _require(
		simulation.teams[0].score == scores_before[0]
		and simulation.teams[1].score == scores_before[1],
		"out-of-bounds crossing incorrectly changed the score."
	):
		simulation.free()
		return {}
	if kind == "throw_in" and not _require(
		taker.on_pitch and taker.team_index == awarded_team
		and taker.tactical_role in ["LB", "RB", "LWB", "RWB"]
		and _has_available_thrower(simulation.teams[awarded_team]),
		"throw-in did not choose an eligible fullback."
	):
		simulation.free()
		return {}
	if kind == "goal_kick" and not _require(
		taker.tactical_role == "GK",
		"goal kick did not choose the goalkeeper."
	):
		simulation.free()
		return {}
	if not simulation.validate_snapshot(simulation.create_snapshot()):
		push_error("Restart validation failed: pending restart snapshot did not validate.")
		simulation.free()
		return {}
	var hash_history: Array[String] = [simulation.get_state_hash()]
	var restart_awards_before := _count_awards(simulation, _restart_name(kind))
	if restart_awards_before != 1:
		push_error("Restart validation failed: expected exactly one %s award." % kind)
		simulation.free()
		return {}

	var pending_snapshot := simulation.create_snapshot()
	var peer := _new_simulation()
	if peer == null or not peer.restore_snapshot(pending_snapshot):
		push_error("Restart validation failed: pending %s snapshot did not restore." % kind)
		simulation.free()
		if peer != null:
			peer.free()
		return {}
	peer.externally_ticked = true
	if not _require(
		peer.get_state_hash() == simulation.get_state_hash()
		and peer.restart_crossing_position.is_equal_approx(crossing)
		and peer.restart_taker_id == taker.id
		and peer.restart_receiver_id == receiver.id,
		"pending %s snapshot state/hash did not round-trip." % kind
	):
		simulation.free()
		peer.free()
		return {}
	var malformed := pending_snapshot.duplicate(true)
	malformed["state"]["restart_awarded_team"] = 9
	var peer_before := JSON.stringify(peer.create_snapshot())
	if peer.restore_snapshot(malformed) or JSON.stringify(peer.create_snapshot()) != peer_before:
		push_error("Restart validation failed: malformed pending snapshot mutated the receiver.")
		simulation.free()
		peer.free()
		return {}

	var frozen_position: Vector2 = simulation.teams[0].players[0].position
	var frozen_score := simulation.teams[0].score + simulation.teams[1].score
	simulation._advance_ball(1.0)
	simulation.step_tick()
	peer._advance_ball(1.0)
	peer.step_tick()
	hash_history.append(simulation.get_state_hash())
	if not _require(
		simulation.restart_pending and simulation.get_state_hash() == peer.get_state_hash()
		and simulation.teams[0].players[0].position.is_equal_approx(frozen_position)
		and simulation.teams[0].score + simulation.teams[1].score == frozen_score
		and _count_awards(simulation, _restart_name(kind)) == restart_awards_before,
		"pending %s did not freeze play or generated a duplicate restart." % kind
	):
		simulation.free()
		peer.free()
		return {}

	var execution_ticks := 0
	while simulation.restart_pending and execution_ticks < 20:
		simulation.step_tick()
		peer.step_tick()
		execution_ticks += 1
		hash_history.append(simulation.get_state_hash())
		if simulation.get_state_hash() != peer.get_state_hash():
			push_error("Restart validation failed: peers diverged executing pending %s." % kind)
			simulation.free()
			peer.free()
			return {}
	var execution_tick := simulation.tick_count
	if not _require(
		not simulation.restart_pending and simulation.restart_kind == "in_play"
		and simulation.ball_owner == null and simulation.ball_target == receiver
		and simulation.last_touch_player_id == taker.id
		and simulation.last_touch_team_index == awarded_team
		and simulation.restart_awarded_team == -1
		and simulation.restart_taker_id == -1
		and simulation.restart_receiver_id == -1
		and simulation.restart_delay_remaining == 0.0
		and simulation.restart_crossing_position == Vector2.ZERO
		and simulation.ball_velocity.length() > 0.0
		and simulation.active and not simulation.finished
		and simulation.get_state_hash() == peer.get_state_hash()
		and _count_awards(simulation, _restart_name(kind)) == restart_awards_before,
		"%s did not execute once into normal play." % kind
	):
		simulation.free()
		peer.free()
		return {}

	var toward_field := _inward_direction(expected_boundary)
	if not _require(
		simulation.ball_velocity.normalized().dot(toward_field) > 0.2,
		"%s delivery was not directed into the pitch." % kind
	):
		simulation.free()
		peer.free()
		return {}
	var received_tick := _advance_to_receiver(simulation, receiver, peer, hash_history)
	if received_tick < 0 or not _require(
		simulation.ball_owner == receiver and simulation.ball_target == null
		and simulation.last_touch_player_id == receiver.id
		and _resumed_state_is_live(simulation, receiver)
		and _count_awards(simulation, _restart_name(kind)) == restart_awards_before,
		"%s pass failed to reach its receiver or created a duplicate restart." % kind
	):
		simulation.free()
		peer.free()
		return {}
	if not _verify_restart_events(
		simulation, kind, expected_boundary, crossing, last_toucher.player_name,
		taker.player_name, receiver.player_name
	):
		simulation.free()
		peer.free()
		return {}
	if not _verify_no_duplicate_after_resume(
		simulation, receiver, _restart_name(kind), restart_awards_before, hash_history
	):
		simulation.free()
		peer.free()
		return {}
	var ball_travel_distance := simulation.ball_position.distance_to(expected_position)
	if not _require(ball_travel_distance > 0.0, "%s delivery did not move the ball from the restart spot." % kind):
		simulation.free()
		peer.free()
		return {}

	var result := {
		"kind": kind,
		"boundary": expected_boundary,
		"crossing": _vector_data(crossing),
		"position": _vector_data(expected_position),
		"last_touch_team": last_touch_team,
		"last_touch_player_id": last_toucher.id,
		"awarded_team": awarded_team,
		"taker_id": taker.id,
		"receiver_id": receiver.id,
		"restart_awards": restart_awards_before,
		"ball_travel_distance": ball_travel_distance,
		"execution_tick": execution_tick,
		"received_tick": received_tick,
		"hash_history": hash_history,
		"hash": simulation.get_state_hash(),
		"restart_events": _restart_events(simulation)
	}
	simulation.free()
	peer.free()
	return result

func _run_post_goal_kickoff() -> Dictionary:
	var simulation := _new_simulation()
	if simulation == null:
		return {}
	var shooter: FootballPlayer = null
	for player in simulation.teams[0].players:
		if player.tactical_role == "ST":
			shooter = player
			break
	if shooter == null:
		push_error("Restart validation could not find a striker for the scoring scenario.")
		simulation.free()
		return {}
	shooter.position = Vector2(900.0, 300.0)
	simulation.config["match"]["minimum_probability"] = 0.0
	simulation.config["match"]["maximum_probability"] = 1.0
	simulation.config["probability"]["sigmoid_slope"] = 100.0
	simulation.config["probability"]["goalkeeper_save_slope"] = 100.0
	simulation.config["probability"]["action_weights"]["shot"] = {"finishing": 1.0}
	simulation.config["probability"]["action_weights"]["goalkeeper"] = {"goalkeeping": 1.0}
	var goalkeeper := simulation._goalkeeper(simulation.teams[1])
	goalkeeper.attributes["goalkeeping"] = 0
	goalkeeper.position = Vector2(950.0, 0.0)
	goalkeeper.tactical_position = goalkeeper.position
	var starting_score := [simulation.teams[0].score, simulation.teams[1].score]
	var awards_before := _count_awards(simulation, "kick-off")
	simulation._set_possession(shooter)
	simulation._resolve_shot(shooter, simulation.teams[0])
	for _flight_tick in range(40):
		if simulation.restart_pending:
			break
		simulation._advance_ball(float(simulation.config["match"]["tick_seconds"]))
	var scoring_event := ""
	for event in simulation.event_log:
		if str(event).contains(" scores!"):
			scoring_event = str(event)
	var taker := simulation._find_player_by_id(simulation.restart_taker_id)
	var receiver := simulation._find_player_by_id(simulation.restart_receiver_id)
	if not _require(
		simulation.teams[0].score == starting_score[0] + 1
		and simulation.teams[1].score == starting_score[1]
		and not scoring_event.is_empty()
		and simulation.restart_pending and simulation.restart_kind == "kickoff"
		and simulation.restart_awarded_team == 1 and simulation.next_kickoff_team == 1
		and simulation.ball_owner == null and simulation.ball_target == null
		and taker != null and receiver != null and taker.team_index == 1
		and receiver.team_index == 1 and taker != receiver
		and _count_awards(simulation, "kick-off") == awards_before + 1,
		"production scoring did not award exactly one kickoff to the conceding side."
	):
		simulation.free()
		return {}
	var peer := _new_simulation()
	if peer == null:
		simulation.free()
		return {}
	peer._goalkeeper(peer.teams[1]).attributes["goalkeeping"] = 0
	var post_goal_snapshot := simulation.create_snapshot()
	if not peer.restore_snapshot(post_goal_snapshot):
		push_error("Restart validation failed: post-goal pending kickoff snapshot did not restore.")
		simulation.free()
		peer.free()
		return {}
	peer.externally_ticked = true
	var post_goal_center := Vector2(500.0, 300.0)
	var kickoff_pass_vector := receiver.position - post_goal_center
	var kickoff_attack_direction := 1.0 if simulation.teams[1].attacks_right else -1.0
	var kickoff_short_pass_limit := (
		float(simulation.config["field"]["width"]) * KICKOFF_SHORT_PASS_MAX_DISTANCE_RATIO
	)
	var kickoff_assertion_message := (
		"post-goal kickoff receiver %s (#%d, %s) at %s produced vector %s (%.1fpx); "
		+ "expected a backward midfielder pass shorter than %.1fpx (attacks_right=%s)."
	) % [
		receiver.player_name, receiver.id, receiver.tactical_role,
		str(receiver.position), str(kickoff_pass_vector), kickoff_pass_vector.length(),
		kickoff_short_pass_limit, str(simulation.teams[1].attacks_right)
	]
	if not _require(
		receiver.tactical_role in ["CM", "LCM", "RCM", "CDM", "LDM", "RDM", "CAM"]
		and kickoff_pass_vector.x * kickoff_attack_direction < 0.0
		and kickoff_pass_vector.length() < kickoff_short_pass_limit,
		kickoff_assertion_message
	):
		simulation.free()
		peer.free()
		return {}
	var hash_history: Array[String] = [simulation.get_state_hash()]
	var execution_ticks := 0
	while simulation.restart_pending and execution_ticks < 20:
		simulation.step_tick()
		peer.step_tick()
		execution_ticks += 1
		hash_history.append(simulation.get_state_hash())
		if simulation.get_state_hash() != peer.get_state_hash():
			push_error("Restart validation failed: post-goal kickoff snapshot replay diverged.")
			simulation.free()
			peer.free()
			return {}
	if not _require(
		not simulation.restart_pending and simulation.restart_kind == "in_play"
		and simulation.restart_awarded_team == -1
		and simulation.restart_taker_id == -1
		and simulation.restart_receiver_id == -1
		and simulation.restart_delay_remaining == 0.0
		and simulation.restart_crossing_position == Vector2.ZERO
		and simulation.ball_position.is_equal_approx(Vector2(500.0, 300.0))
		and simulation.ball_target == receiver and simulation.ball_owner == null
		and simulation.last_touch_team_index == 1
		and simulation.last_touch_player_id == taker.id
		and simulation.active and not simulation.finished
		and simulation.teams[0].score == starting_score[0] + 1
		and _count_awards(simulation, "kick-off") == awards_before + 1
		and simulation.get_state_hash() == peer.get_state_hash(),
		"post-goal kickoff did not execute with a clean centre restart."
	):
		simulation.free()
		peer.free()
		return {}
	var received_tick := _advance_to_receiver(simulation, receiver, peer, hash_history)
	if received_tick < 0 or not _require(
		simulation.ball_owner == receiver and simulation.ball_target == null
		and _resumed_state_is_live(simulation, receiver)
		and _count_awards(simulation, "kick-off") == awards_before + 1,
		"post-goal kickoff pass did not reach its receiver exactly once."
	):
		simulation.free()
		peer.free()
		return {}
	if not _verify_post_goal_kickoff_events(
		simulation, simulation.teams[1].team_name,
		simulation.teams[0].team_name, shooter.player_name, shooter.number,
		taker.player_name, taker.id, receiver.player_name, receiver.id
	):
		simulation.free()
		peer.free()
		return {}
	if not _verify_no_duplicate_after_resume(
		simulation, receiver, "kick-off", awards_before + 1, hash_history
	):
		simulation.free()
		peer.free()
		return {}
	var result := {
		"score": [simulation.teams[0].score, simulation.teams[1].score],
		"scoring_event": scoring_event,
		"awarded_team": 1,
		"taker_id": taker.id,
		"receiver_id": receiver.id,
		"receiver_role": receiver.tactical_role,
		"pass_vector": _vector_data(kickoff_pass_vector),
		"pass_distance": kickoff_pass_vector.length(),
		"short_pass_limit": kickoff_short_pass_limit,
		"execution_ticks": execution_ticks,
		"received_tick": received_tick,
		"hash_history": hash_history,
		"restart_awards": _count_awards(simulation, "kick-off"),
		"hash": simulation.get_state_hash(),
		"restart_events": _restart_events(simulation)
	}
	simulation.free()
	peer.free()
	return result

func _advance_to_receiver(
	simulation: MatchSimulation,
	receiver: FootballPlayer,
	peer: MatchSimulation,
	hash_history: Array[String]
) -> int:
	var starting_position := simulation.ball_position
	var moved := false
	for _step in range(120):
		if simulation.ball_owner == receiver:
			if not moved:
				push_error("Restart validation failed: ball did not move during its delivery.")
				return -1
			return simulation.tick_count
		simulation.step_tick()
		if peer != null:
			peer.step_tick()
			if simulation.get_state_hash() != peer.get_state_hash():
				push_error("Restart validation failed: snapshot peer diverged during ball delivery.")
				return -1
		hash_history.append(simulation.get_state_hash())
		if not moved:
			moved = simulation.ball_position.distance_to(starting_position) > 0.001
			if not simulation.active or simulation.finished:
				push_error("Restart validation failed: match remained stopped after restart execution.")
				return -1
	push_error("Restart validation timed out waiting for player #%d to receive the ball." % receiver.id)
	return -1

func _resumed_state_is_live(simulation: MatchSimulation, receiver: FootballPlayer) -> bool:
	return simulation.active and not simulation.finished \
		and not simulation.restart_pending and simulation.restart_kind == "in_play" \
		and simulation.restart_awarded_team == -1 \
		and simulation.restart_taker_id == -1 \
		and simulation.restart_receiver_id == -1 \
		and simulation.restart_delay_remaining == 0.0 \
		and simulation.restart_crossing_position == Vector2.ZERO \
		and simulation.ball_owner == receiver and simulation.ball_target == null

func _verify_no_duplicate_after_resume(
	simulation: MatchSimulation,
	receiver: FootballPlayer,
	display_name: String,
	expected_awards: int,
	hash_history: Array[String]
) -> bool:
	simulation.step_tick()
	hash_history.append(simulation.get_state_hash())
	return _require(
		_resumed_state_is_live(simulation, receiver)
		and _count_awards(simulation, display_name) == expected_awards,
		"%s left normal play stopped or generated a duplicate restart on the next tick." % display_name
	)

func _verify_restart_events(
	simulation: MatchSimulation,
	kind: String,
	boundary: String,
	crossing: Vector2,
	last_touch_name: String,
	taker_name: String,
	receiver_name: String
) -> bool:
	var award_count := 0
	var execution_count := 0
	var crossing_text := "" if boundary.is_empty() else (
		"from crossing (%.1f, %.1f)" % [crossing.x, crossing.y]
	)
	var expected_last_touch := "last touch:"
	for event in _restart_events(simulation):
		if event.contains("[Restart] %s awarded" % _restart_name(kind)):
			award_count += 1
			if not crossing_text.is_empty() and not event.contains(crossing_text) \
			or not event.contains(expected_last_touch) \
			or not event.contains(last_touch_name):
				return _require(false, "%s award log omitted crossing or last-touch evidence." % kind)
		if event.contains("[Restart] %s taken" % _restart_name(kind)):
			execution_count += 1
			if not event.contains(taker_name) or not event.contains(receiver_name) \
			or not event.contains("the ball is live"):
				return _require(false, "%s execution log omitted taker, receiver, or live state." % kind)
	return _require(
		award_count == 1 and execution_count == 1,
		"%s event log did not contain exactly one crossing award and one execution." % kind
	)

func _verify_post_goal_kickoff_events(
	simulation: MatchSimulation,
	awarded_team_name: String,
	scoring_team_name: String,
	scorer_name: String,
	scorer_number: int,
	taker_name: String,
	taker_id: int,
	receiver_name: String,
	receiver_id: int
) -> bool:
	var award_count := 0
	var execution_count := 0
	var expected_last_touch := "last touch: %s, %s (#%d)" % [
		scoring_team_name, scorer_name, scorer_number
	]
	for event in _restart_events(simulation):
		if event.contains("[Restart] kick-off awarded to %s" % awarded_team_name) \
		and event.contains(expected_last_touch):
			award_count += 1
		if event.contains("[Restart] kick-off taken by %s (#%d) for %s (#%d)" % [
			taker_name, taker_id, receiver_name, receiver_id
		]):
			execution_count += 1
	return _require(
		award_count == 1 and execution_count == 1,
		"post-goal kickoff event log did not identify one conceding-team award and delivery."
	)

func _crossing_matches_boundary(
	crossing: Vector2,
	boundary: String,
	width: float,
	height: float,
	radius: float
) -> bool:
	match boundary:
		"top_touchline":
			return is_equal_approx(crossing.y, -radius) \
				and crossing.x >= -radius and crossing.x <= width + radius
		"bottom_touchline":
			return is_equal_approx(crossing.y, height + radius) \
				and crossing.x >= -radius and crossing.x <= width + radius
		"left_goal_line":
			return is_equal_approx(crossing.x, -radius) \
				and crossing.y >= -radius and crossing.y <= height + radius
		"right_goal_line":
			return is_equal_approx(crossing.x, width + radius) \
				and crossing.y >= -radius and crossing.y <= height + radius
	return false

func _defending_team_for_boundary(simulation: MatchSimulation, boundary: String) -> int:
	var left_goal := boundary == "left_goal_line"
	for team_index in range(simulation.teams.size()):
		if simulation.teams[team_index].attacks_right == left_goal:
			return team_index
	return -1

func _has_available_thrower(team: FootballTeam) -> bool:
	for player in team.players:
		if player.on_pitch and player.tactical_role in ["LB", "RB", "LWB", "RWB"]:
			return true
	return false

func _expected_restart_position(
	simulation: MatchSimulation, scenario: Dictionary, crossing: Vector2
) -> Vector2:
	var field: Dictionary = simulation.config["field"]
	var restart_data: Dictionary = simulation.config["match"]["restarts"]
	var radius := float(field["ball_radius"])
	var boundary := str(scenario["boundary"])
	match str(scenario["kind"]):
		"throw_in":
			return Vector2(
				clampf(crossing.x, radius, float(field["width"]) - radius),
				radius if boundary == "top_touchline" else float(field["height"]) - radius
			)
		"corner_kick":
			return Vector2(
				radius if boundary == "left_goal_line" else float(field["width"]) - radius,
				radius if crossing.y < float(field["height"]) * 0.5 else float(field["height"]) - radius
			)
		"goal_kick":
			var left_goal := boundary == "left_goal_line"
			var half_goal_area := float(restart_data["goal_area_width"]) * 0.5
			return Vector2(
				float(restart_data["goal_area_depth"]) + radius
					if left_goal
					else float(field["width"]) - float(restart_data["goal_area_depth"]) - radius,
				clampf(
					crossing.y,
					float(field["height"]) * 0.5 - half_goal_area,
					float(field["height"]) * 0.5 + half_goal_area
				)
			)
	return Vector2.INF

func _inward_direction(boundary: String) -> Vector2:
	match boundary:
		"top_touchline":
			return Vector2.DOWN
		"bottom_touchline":
			return Vector2.UP
		"left_goal_line":
			return Vector2.RIGHT
		"right_goal_line":
			return Vector2.LEFT
	return Vector2.ZERO

func _count_awards(simulation: MatchSimulation, display_name: String) -> int:
	var count := 0
	for event in simulation.event_log:
		if str(event).contains("[Restart] %s awarded" % display_name):
			count += 1
	return count

func _restart_events(simulation: MatchSimulation) -> Array[String]:
	var result: Array[String] = []
	for event in simulation.event_log:
		if str(event).begins_with("[Restart]"):
			result.append(str(event))
	return result

func _restart_name(kind: String) -> String:
	match kind:
		"kickoff":
			return "kick-off"
		"throw_in":
			return "throw-in"
		"corner_kick":
			return "corner kick"
		"goal_kick":
			return "goal kick"
	return kind

func _vector_data(value: Vector2) -> Array[float]:
	return [value.x, value.y]
