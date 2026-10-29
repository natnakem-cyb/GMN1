extends SceneTree

const SimulationScript = preload("res://scripts/simulation/match_simulation.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var kickoff_first := _run_kickoff("4-4-2")
	var kickoff_replay := _run_kickoff("4-4-2")
	if not _same_result("initial kickoff", kickoff_first, kickoff_replay):
		quit(1)
		return
	print("[Validation PASS] initial kickoff: %s" % _result_text(kickoff_first))

	var single_striker := _run_kickoff("4-3-3")
	if single_striker.is_empty() or str(single_striker["receiver_role"]) not in [
		"CM", "LCM", "RCM", "CDM", "LDM", "RDM", "CAM"
	]:
		push_error("Initial kickoff failed the single-striker midfield-receiver fallback.")
		quit(1)
		return

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
	if not _require(
		kickoff_team == 0 and not simulation.restart_pending
		and simulation.restart_kind == "in_play"
		and taker != null and taker.team_index == kickoff_team
		and taker.position.is_equal_approx(center)
		and receiver != null and receiver.on_pitch
		and receiver.team_index == kickoff_team and receiver != taker
		and simulation.ball_owner == null
		and simulation.ball_velocity.length() > 0.0
		and simulation.last_touch_team_index == kickoff_team
		and simulation.last_action.contains("kick-off taken")
		and simulation.last_formula.contains("Guaranteed deterministic restart delivery"),
		"initial kickoff did not immediately start its guaranteed teammate pass."
	):
		simulation.free()
		return {}
	if formation == "4-4-2" and not _require(
		taker.tactical_role in ["ST", "CF"] and receiver.tactical_role in ["ST", "CF"],
		"two-forward kickoff did not choose a forward receiver."
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
		and kickoff_awards == 1,
		"kickoff did not enter normal play exactly once at the receiver."
	):
		simulation.free()
		return {}
	var result := {
		"formation": formation,
		"team": kickoff_team,
		"taker_id": taker.id,
		"receiver_id": receiver.id,
		"receiver_role": receiver.tactical_role,
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
	simulation.ball_owner = null
	simulation.ball_target = last_toucher
	simulation.ball_position = scenario["start"]
	simulation.ball_velocity = scenario["velocity"]
	simulation.last_touch_team_index = last_touch_team
	simulation.last_touch_player_id = last_toucher.id
	simulation.step_tick()

	var kind := str(scenario["kind"])
	var expected_boundary := str(scenario["boundary"])
	var taker := simulation._find_player_by_id(simulation.restart_taker_id)
	var receiver := simulation._find_player_by_id(simulation.restart_receiver_id)
	var crossing: Vector2 = simulation.restart_crossing_position
	var expected_position := _expected_restart_position(simulation, scenario, crossing)
	if not _require(
		simulation.restart_pending and simulation.restart_kind == kind
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
	if not _require(
		simulation.teams[0].score == scores_before[0]
		and simulation.teams[1].score == scores_before[1],
		"out-of-bounds crossing incorrectly changed the score."
	):
		simulation.free()
		return {}
	if kind == "throw_in" and not _require(
		taker.tactical_role in ["LB", "RB", "LWB", "RWB"],
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
		and simulation.ball_velocity.length() > 0.0
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
		and _count_awards(simulation, _restart_name(kind)) == restart_awards_before,
		"%s pass failed to reach its receiver or created a duplicate restart." % kind
	):
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
	simulation._goalkeeper(simulation.teams[1]).attributes["goalkeeping"] = 0
	var starting_score := [simulation.teams[0].score, simulation.teams[1].score]
	var awards_before := _count_awards(simulation, "kick-off")
	simulation._resolve_shot(shooter, simulation.teams[0])
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
		and simulation.ball_position.is_equal_approx(Vector2(500.0, 300.0))
		and simulation.ball_target == receiver and simulation.ball_owner == null
		and simulation.last_touch_team_index == 1
		and simulation.last_touch_player_id == taker.id
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
		and _count_awards(simulation, "kick-off") == awards_before + 1,
		"post-goal kickoff pass did not reach its receiver exactly once."
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
	for _step in range(120):
		if simulation.ball_owner == receiver:
			return simulation.tick_count
		simulation.step_tick()
		if peer != null:
			peer.step_tick()
			if simulation.get_state_hash() != peer.get_state_hash():
				push_error("Restart validation failed: snapshot peer diverged during ball delivery.")
				return -1
		hash_history.append(simulation.get_state_hash())
	push_error("Restart validation timed out waiting for player #%d to receive the ball." % receiver.id)
	return -1

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
