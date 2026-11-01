extends SceneTree

const SimulationScript = preload("res://scripts/simulation/match_simulation.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	if not _test_pass_reception() or not _test_goal(true) or not _test_goal(false) \
	or not _test_post_collision() or not _test_overbar_out() or not _test_trajectory_determinism():
		quit(1)
		return
	if not _test_box_run_edge_eligibility():
		quit(1)
		return
	if not _test_pass_launch_clearance() or not _test_shot_launch_clearance() \
	or not _test_launch_point_interception_guard() or not _test_kicker_clearance_window():
		quit(1)
		return
	if not _test_box_edge_boundaries() or not _test_six_yard_shot_priority() \
	or not _test_pair_pass_limit() or not _test_midfield_forward_preference() \
	or not _test_progressive_pass_telemetry():
		quit(1)
		return
	print("PASS: ball-flight regressions, inclusive mirrored box-edge eligibility, six-yard shot priority, pair repetition limit, and progressive-pass classification/telemetry.")
	quit(0)

func _new_simulation() -> MatchSimulation:
	var simulation: MatchSimulation = SimulationScript.new()
	root.add_child(simulation)
	if not simulation.setup_match("4-3-3"):
		simulation.free()
		return null
	simulation.start_match()
	return simulation

func _player_with_role(team: FootballTeam, roles: Array[String]) -> FootballPlayer:
	for player in team.players:
		if roles.has(player.tactical_role):
			return player
	return null

func _test_box_edge_boundaries() -> bool:
	var simulation := _new_simulation()
	if simulation == null:
		return false
	var field: Dictionary = simulation.config["field"]
	var edge_margin := float(simulation.config["decision"]["shot_selection"]["box_edge_margin_px"])
	var team: FootballTeam = simulation.teams[0]
	var shooter := _player_with_role(team, ["ST", "CF"])
	if shooter == null:
		simulation.free()
		return false
	shooter.tactical_role = "ST"
	shooter.box_run_active = true
	team.completed_passes_in_possession = int(simulation.config["decision"]["pass_selection"]["minimum_build_up_passes_before_shot"])
	for defender in simulation.teams[1].players:
		defender.position = Vector2(-500.0, -500.0)
	var passed := true
	for attacks_right in [true, false]:
		team.attacks_right = attacks_right
		var line_x := float(field["width"]) - float(field["penalty_area_depth"]) \
			if attacks_right else float(field["penalty_area_depth"])
		var outside_x := line_x - edge_margin - 0.1 if attacks_right else line_x + edge_margin + 0.1
		shooter.position = Vector2(outside_x, float(field["height"]) * 0.5)
		shooter.box_run_target = shooter.position - Vector2(70.0, 0.0)
		var outside_distance := simulation._distance_to_penalty_area_line(shooter.position, team)
		var outside_declined := not simulation._box_run_shot_ready(shooter, team) \
			and str(simulation.event_log.back()).contains("box run not reached") \
			and not simulation._is_inside_or_on_shot_box_edge(shooter.position, team, edge_margin)
		shooter.box_run_active = false
		var outside_rules_allow := simulation._should_shoot(shooter, team)
		shooter.box_run_active = true
		var event_count := simulation.event_log.size()
		shooter.position.x = line_x - edge_margin if attacks_right else line_x + edge_margin
		shooter.box_run_target = shooter.position - Vector2(70.0, 0.0)
		var line_distance := simulation._distance_to_penalty_area_line(shooter.position, team)
		var edge_eligible := simulation._is_inside_or_on_shot_box_edge(shooter.position, team, edge_margin) \
			and simulation._box_run_shot_ready(shooter, team) \
			and simulation._should_shoot(shooter, team) \
			and simulation.event_log.size() == event_count
		passed = passed and is_equal_approx(outside_distance, edge_margin + 0.1) \
			and outside_declined and outside_rules_allow \
			and is_equal_approx(line_distance, edge_margin) and edge_eligible
	var telemetry: Dictionary = simulation.get_match_telemetry()["teams"][0]
	team.attacks_right = true
	shooter.position = Vector2(
		float(field["width"]) - float(field["penalty_area_depth"]) - edge_margin,
		float(field["height"]) * 0.5
	)
	shooter.box_run_target = shooter.position - Vector2(70.0, 0.0)
	shooter.box_run_active = true
	shooter.shot_cooldown_active = false
	simulation.ball_owner = shooter
	simulation.ball_target = null
	simulation.ball_position = shooter.position
	simulation.ball_in_flight = false
	simulation.ball_flight_phase = "none"
	simulation._resolve_next_action()
	var box_edge_priority_seen := false
	for event in simulation.event_log:
		if event.contains("box-edge shot priority"):
			box_edge_priority_seen = true
	telemetry = simulation.get_match_telemetry()["teams"][0]
	passed = passed and int(telemetry["box_run_inside_edge_declines"]) == 0 \
		and int(telemetry["box_edge_shot_priority"]) == 1 \
		and box_edge_priority_seen and simulation.ball_flight_phase == "shot"
	simulation.free()
	if not passed:
		push_error("Shot selection test failed: 30.1px outside rules or mirrored inclusive 30.0px edge behavior changed.")
	return passed

func _test_six_yard_shot_priority() -> bool:
	var simulation := _new_simulation()
	if simulation == null:
		return false
	var field: Dictionary = simulation.config["field"]
	var decision: Dictionary = simulation.config["decision"]
	var depth := float(decision["six_yard_depth_px"])
	var lateral_half := float(decision["six_yard_height_px"]) * 0.5
	var team: FootballTeam = simulation.teams[0]
	var passed := depth == 50.0 and is_equal_approx(float(decision["six_yard_height_px"]), 136.31) \
		and depth < float(field["penalty_area_depth"]) \
		and float(decision["six_yard_height_px"]) < float(field["penalty_area_height"])
	for attacks_right in [true, false]:
		team.attacks_right = attacks_right
		var goal_x := float(field["width"]) if attacks_right else 0.0
		var boundary_position := Vector2(
			goal_x - depth if attacks_right else goal_x + depth,
			float(field["height"]) * 0.5 + lateral_half
		)
		var boundary_inside := simulation._is_inside_six_yard_box(boundary_position, team)
		var outside_inside := simulation._is_inside_six_yard_box(
			boundary_position + Vector2(-0.1 if attacks_right else 0.1, 0.0), team
		)
		passed = passed and boundary_inside and not outside_inside
	var striker := _player_with_role(team, ["ST"])
	if striker == null:
		simulation.free()
		return false
	striker.tactical_role = "ST"
	for defender in simulation.teams[1].players:
		defender.position = Vector2(-500.0, -500.0)
	for attacks_right in [true, false]:
		team.attacks_right = attacks_right
		striker.tactical_role = "ST" if attacks_right else "RW"
		striker.position = Vector2(
			float(field["width"]) - 40.0 if attacks_right else 40.0,
			float(field["height"]) * 0.5
		)
		team.completed_passes_in_possession = 0
		striker.shot_cooldown_active = false
		simulation.ball_owner = striker
		simulation.ball_target = null
		simulation.ball_position = striker.position
		simulation.ball_in_flight = false
		simulation.ball_flight_phase = "none"
		simulation._resolve_next_action()
		passed = passed and simulation.ball_flight_phase == "shot" \
			and simulation.ball_target == null
	var telemetry: Dictionary = simulation.get_match_telemetry()["teams"][0]
	var priority_event_seen := false
	for event in simulation.event_log:
		if event.contains("six-yard shot priority"):
			priority_event_seen = true
	passed = passed and int(telemetry["six_yard_shot_priority"]) == 2 and priority_event_seen
	simulation.free()
	if not passed:
		push_error("Shot selection test failed: contained six-yard shot priority did not choose a shot.")
	return passed

func _test_pair_pass_limit() -> bool:
	var simulation := _new_simulation()
	if simulation == null:
		return false
	var team: FootballTeam = simulation.teams[0]
	var passer := _player_with_role(team, ["CM", "LCM", "RCM"])
	var receiver := _player_with_role(team, ["ST", "CF"])
	var alternative := _player_with_role(team, ["LW", "RW"])
	if passer == null or receiver == null or alternative == null:
		simulation.free()
		return false
	team.attacks_right = true
	passer.position = Vector2(500.0, 300.0)
	receiver.position = Vector2(650.0, 300.0)
	alternative.position = Vector2(600.0, 320.0)
	for player in team.players:
		if player != passer and player != receiver and player != alternative:
			player.position = Vector2(-500.0, -500.0)
	for defender in simulation.teams[1].players:
		defender.position = Vector2(-1000.0, -1000.0)
	var pair_key := simulation._pair_key(passer.id, receiver.id)
	simulation.match_telemetry[0]["pass_attempts"] = 3
	simulation._record_completed_open_play_pass(passer, receiver)
	simulation._record_completed_open_play_pass(receiver, passer)
	simulation._record_completed_open_play_pass(passer, receiver)
	var chosen := simulation._choose_receiver(passer, team)
	var telemetry: Dictionary = simulation.get_match_telemetry()["teams"][0]
	var blocked := chosen == alternative and int(simulation.pair_pass_counts[0][pair_key]) == 3 \
		and int(telemetry["pair_limit_interventions"]) == 1
	var replica := _new_simulation()
	var restored_pair_state := replica != null \
		and replica.restore_snapshot(simulation.create_snapshot()) \
		and int(replica.pair_pass_counts[0].get(pair_key, 0)) == 3
	if replica != null:
		replica.free()
	var turnover: FootballPlayer = simulation.teams[1].players[0]
	var opponent_pair_key := simulation._pair_key(
		simulation.teams[1].players[0].id, simulation.teams[1].players[1].id
	)
	simulation.ball_owner = passer
	simulation.pair_pass_counts[1][opponent_pair_key] = 2
	simulation._set_possession(turnover)
	var reset_on_turnover := simulation.pair_pass_counts[0].is_empty() \
		and simulation.pair_pass_counts[1].is_empty()
	simulation.pair_pass_counts[0][pair_key] = 3
	simulation.pair_pass_counts[1][opponent_pair_key] = 2
	var restarted := simulation._begin_restart(
		"kickoff", 0,
		Vector2(float(simulation.config["field"]["width"]) * 0.5, float(simulation.config["field"]["height"]) * 0.5),
		0.0
	)
	var reset_on_restart := restarted and simulation.pair_pass_counts[0].is_empty() \
		and simulation.pair_pass_counts[1].is_empty()
	simulation.free()
	if not blocked or not restored_pair_state or not reset_on_turnover or not reset_on_restart:
		push_error("Pass selection test failed: unordered three-exchange pair was not blocked or counters did not reset.")
	return blocked and reset_on_turnover and reset_on_restart

func _test_midfield_forward_preference() -> bool:
	var simulation := _new_simulation()
	if simulation == null:
		return false
	var team: FootballTeam = simulation.teams[0]
	var carrier := _player_with_role(team, ["CM", "LCM", "RCM"])
	var forward := _player_with_role(team, ["ST", "CF"])
	var nearest_midfielder: FootballPlayer = null
	for player in team.players:
		if player != carrier and player != forward and simulation._is_midfield_role(player.tactical_role):
			nearest_midfielder = player
			break
	if carrier == null or forward == null or nearest_midfielder == null:
		simulation.free()
		return false
	for attacks_right in [true, false]:
		team.attacks_right = attacks_right
		carrier.position = Vector2(500.0, 300.0)
		forward.position = Vector2(650.0 if attacks_right else 350.0, 300.0)
		nearest_midfielder.position = Vector2(510.0, 300.0)
		for player in team.players:
			if player != carrier and player != forward and player != nearest_midfielder:
				player.position = Vector2(-500.0, -500.0)
		for defender in simulation.teams[1].players:
			defender.position = Vector2(-1000.0, -1000.0)
		var chosen := simulation._choose_receiver(carrier, team)
		if chosen != forward:
			simulation.free()
			push_error("Pass selection test failed: midfield carrier selected a midfielder despite a viable forward receiver.")
			return false
	simulation.free()
	return true

func _test_progressive_pass_telemetry() -> bool:
	var first := _new_simulation()
	var second := _new_simulation()
	if first == null or second == null:
		if first != null:
			first.free()
		if second != null:
			second.free()
		return false
	var first_team: FootballTeam = first.teams[0]
	var second_team: FootballTeam = second.teams[0]
	var first_passer := _player_with_role(first_team, ["CM", "LCM", "RCM"])
	var first_receiver := _player_with_role(first_team, ["ST", "CF"])
	var second_passer := _player_with_role(second_team, ["CM", "LCM", "RCM"])
	var second_receiver := _player_with_role(second_team, ["ST", "CF"])
	if first_passer == null or first_receiver == null or second_passer == null or second_receiver == null:
		first.free()
		second.free()
		return false
	first_team.attacks_right = true
	first_passer.position = Vector2(400.0, 300.0)
	first_receiver.position = Vector2(550.0, 300.0)
	second_team.attacks_right = true
	second_passer.position = first_passer.position
	second_receiver.position = first_receiver.position
	var progressive_result := first._classify_progressive_pass(first_passer, first_receiver)
	var repeated_result := second._classify_progressive_pass(second_passer, second_receiver)
	var passed := bool(progressive_result["progressive"]) == bool(repeated_result["progressive"]) \
		and bool(progressive_result["progressive"])
	first.match_telemetry[0]["pass_attempts"] = 3
	first._record_completed_open_play_pass(first_passer, first_receiver)
	first_receiver.position.x = 500.0
	var non_progressive_result := first._classify_progressive_pass(first_passer, first_receiver)
	passed = passed and not bool(non_progressive_result["progressive"])
	first._record_completed_open_play_pass(first_passer, first_receiver)
	first_passer.position.x = 300.0
	first_receiver.position.x = 700.0
	var outside_origin_result := first._classify_progressive_pass(first_passer, first_receiver)
	passed = passed and not bool(outside_origin_result["origin_in_attacking_two_thirds"]) \
		and not bool(outside_origin_result["progressive"])
	first._record_completed_open_play_pass(first_passer, first_receiver)
	var telemetry: Dictionary = first.get_match_telemetry()["teams"][0]
	passed = passed and int(telemetry["pass_completions"]) == 3 \
		and int(telemetry["progressive_completions"]) == 1 \
		and int(telemetry["attacking_two_thirds_pass_completions"]) == 2 \
		and is_equal_approx(float(telemetry["progressive_share"]), 0.5)
	for defender in first.teams[1].players:
		defender.position = Vector2(-1000.0, -1000.0)
	first._set_possession(first_passer)
	first._resolve_pass(first_passer, first_team)
	first.ball_pass_probability = 0.0
	first._complete_flight_pass()
	telemetry = first.get_match_telemetry()["teams"][0]
	passed = passed and int(telemetry["pass_attempts"]) == 4 \
		and int(telemetry["pass_completions"]) == 3 \
		and int(telemetry["progressive_completions"]) == 1
	first.free()
	second.free()
	if not passed:
		push_error("Progressive pass test failed: goal-distance threshold, origin band, or deterministic telemetry changed.")
	return passed

func _test_pass_reception() -> bool:
	var simulation := _new_simulation()
	if simulation == null:
		return false
	for defender in simulation.teams[1].players:
		defender.position = Vector2(-500.0, -500.0)
	var passer: FootballPlayer = simulation.teams[0].players[0]
	simulation._set_possession(passer)
	simulation._resolve_pass(passer, simulation.teams[0])
	var receiver := simulation.ball_target
	if receiver == null or not simulation.ball_in_flight:
		push_error("Ball flight test failed: pass did not launch into flight.")
		simulation.free()
		return false
	simulation.ball_pass_probability = 1.0
	var ticks := 0
	while ticks < 100 and simulation.ball_owner != receiver:
		simulation._advance_ball(float(simulation.config["match"]["tick_seconds"]))
		ticks += 1
	var passed := simulation.ball_owner == receiver and ticks > 0
	if not passed:
		push_error("Ball flight test failed: ground pass did not reach the receiver after multiple ticks.")
	simulation.free()
	return passed

func _expected_kicker_clearance_px(simulation: MatchSimulation) -> float:
	var field_data: Dictionary = simulation.config["field"]
	var ball_data: Dictionary = simulation.config["match"]["ball_flight"]
	var margin_px := float(ball_data["kicker_clearance_margin_m"]) / float(ball_data["metres_per_pixel"])
	return float(field_data["player_radius"]) + float(ball_data["ball_radius_px"]) + margin_px

func _test_pass_launch_clearance() -> bool:
	var simulation := _new_simulation()
	if simulation == null:
		return false
	for defender in simulation.teams[1].players:
		defender.position = Vector2(-500.0, -500.0)
	var passer: FootballPlayer = simulation.teams[0].players[0]
	simulation._set_possession(passer)
	simulation._resolve_pass(passer, simulation.teams[0])
	var receiver: FootballPlayer = simulation.ball_target
	var need := _expected_kicker_clearance_px(simulation)
	var dist := simulation.ball_position.distance_to(passer.position)
	var launched := receiver != null and simulation.ball_in_flight \
		and simulation.ball_flight_phase == "ground_pass" \
		and simulation.ball_kicker_clearance_id == passer.id \
		and dist >= need - 0.001
	print("[Test] pass launch clearance dist=%.3fpx need=%.3fpx" % [dist, need])
	if not launched:
		push_error("Ball flight test failed: pass did not launch outside the required kicker clearance.")
		simulation.free()
		return false
	simulation.ball_pass_probability = 1.0
	var ticks := 0
	while ticks < 100 and simulation.ball_owner == null:
		simulation._advance_ball(float(simulation.config["match"]["tick_seconds"]))
		ticks += 1
	var received_by_target := simulation.ball_owner == receiver
	simulation.free()
	if not received_by_target:
		push_error("Ball flight test failed: launched ground pass did not resolve to its receiver.")
	return received_by_target

func _test_shot_launch_clearance() -> bool:
	var simulation := _new_simulation()
	if simulation == null:
		return false
	var shooter: FootballPlayer = simulation.teams[0].players[0]
	shooter.position = Vector2(float(simulation.config["field"]["width"]) - 150.0, float(simulation.config["field"]["height"]) * 0.5)
	simulation._set_possession(shooter)
	for keeper in simulation.teams[1].players:
		if keeper.tactical_role == "GK":
			keeper.position = Vector2(float(simulation.config["field"]["width"]) - 20.0, float(simulation.config["field"]["height"]) * 0.5)
		else:
			keeper.position = Vector2(-500.0, -500.0)
	simulation._resolve_shot(shooter, simulation.teams[0])
	var need := _expected_kicker_clearance_px(simulation)
	var dist := simulation.ball_position.distance_to(shooter.position)
	var passed := simulation.ball_in_flight and simulation.ball_flight_phase == "shot" \
		and simulation.ball_kicker_clearance_id == shooter.id and dist >= need - 0.001
	print("[Test] shot launch clearance dist=%.3fpx need=%.3fpx" % [dist, need])
	simulation.free()
	if not passed:
		push_error("Ball flight test failed: shot did not launch outside the required kicker clearance.")
	return passed

func _test_launch_point_interception_guard() -> bool:
	var simulation := _new_simulation()
	if simulation == null:
		return false
	var passer: FootballPlayer = simulation.teams[0].players[0]
	var receiver: FootballPlayer = simulation.teams[0].players[1]
	receiver.position = passer.position + Vector2(300.0, 0.0)
	for i in range(2, simulation.teams[0].players.size()):
		simulation.teams[0].players[i].position = Vector2(-500.0, -500.0 - float(i))
	var close_defender: FootballPlayer = simulation.teams[1].players[0]
	close_defender.position = passer.position + Vector2(3.0, 0.0)
	for i in range(1, simulation.teams[1].players.size()):
		simulation.teams[1].players[i].position = Vector2(-500.0, -500.0 - float(i))
	simulation._set_possession(passer)
	simulation._resolve_pass(passer, simulation.teams[0])
	simulation.ball_pass_probability = 1.0
	var max_ticks := int(simulation.config["match"]["ball_flight"]["kicker_contact_ignore_max_ticks"])
	var ticks := 0
	var instant_intercept := false
	while ticks < 5 and simulation.ball_owner == null:
		simulation._advance_ball(float(simulation.config["match"]["tick_seconds"]))
		ticks += 1
		if simulation.ball_owner == close_defender and ticks <= max_ticks:
			instant_intercept = true
			break
	var passed := not instant_intercept and simulation.ball_in_flight
	simulation.free()
	if not passed:
		push_error("Ball flight test failed: a defender at the launch point intercepted immediately or the pass did not remain in flight.")
	return passed

func _test_kicker_clearance_window() -> bool:
	var simulation := _new_simulation()
	if simulation == null:
		return false
	var kicker: FootballPlayer = simulation.teams[0].players[0]
	var ball_data: Dictionary = simulation.config["match"]["ball_flight"]
	var max_ticks := int(ball_data["kicker_contact_ignore_max_ticks"])
	var clear_radius := float(simulation.config["field"]["player_radius"]) \
		+ float(simulation.config["field"]["ball_radius"])
	var ball_radius := float(ball_data["ball_radius_px"])
	var passed := true

	simulation.ball_kicker_clearance_id = kicker.id
	simulation.ball_kicker_clearance_ticks = max_ticks - 1
	simulation.ball_position = kicker.position + Vector2(clear_radius, 0.0)
	simulation.ball_position_3d = Vector3(simulation.ball_position.x, simulation.ball_position.y, ball_radius)
	simulation.ball_velocity_3d = Vector3.ZERO
	simulation.ball_velocity = Vector2.ZERO
	simulation.ball_in_flight = true
	simulation.ball_on_ground = false
	simulation.ball_flight_phase = "shot"
	simulation._advance_ball(float(simulation.config["match"]["tick_seconds"]))
	passed = passed and simulation.ball_kicker_clearance_ticks >= max_ticks \
		and simulation.ball_kicker_clearance_id == kicker.id

	simulation.ball_kicker_clearance_id = kicker.id
	simulation.ball_kicker_clearance_ticks = max_ticks - 2
	simulation.ball_position = kicker.position + Vector2(clear_radius + 1.0, 0.0)
	simulation.ball_position_3d = Vector3(simulation.ball_position.x, simulation.ball_position.y, ball_radius)
	simulation.ball_velocity_3d = Vector3.ZERO
	simulation.ball_velocity = Vector2.ZERO
	simulation.ball_in_flight = true
	simulation.ball_on_ground = false
	simulation.ball_flight_phase = "shot"
	simulation._advance_ball(float(simulation.config["match"]["tick_seconds"]))
	passed = passed and simulation.ball_kicker_clearance_ticks < max_ticks \
		and simulation.ball_kicker_clearance_id == kicker.id

	simulation.ball_kicker_clearance_id = kicker.id
	simulation.ball_kicker_clearance_ticks = max_ticks - 1
	simulation.ball_position = kicker.position + Vector2(clear_radius + 1.0, 0.0)
	simulation.ball_position_3d = Vector3(simulation.ball_position.x, simulation.ball_position.y, ball_radius)
	simulation.ball_velocity_3d = Vector3.ZERO
	simulation.ball_velocity = Vector2.ZERO
	simulation.ball_in_flight = true
	simulation.ball_on_ground = false
	simulation.ball_flight_phase = "shot"
	simulation._advance_ball(float(simulation.config["match"]["tick_seconds"]))
	passed = passed and simulation.ball_kicker_clearance_ticks >= max_ticks \
		and simulation.ball_kicker_clearance_id == -1

	simulation.free()
	if not passed:
		push_error("Ball flight test failed: kicker clearance did not require distance > radius AND ticks >= max, with strict distance boundary.")
	return passed

func _test_box_run_edge_eligibility() -> bool:
	var simulation := _new_simulation()
	if simulation == null:
		return false
	var team: FootballTeam = simulation.teams[0]
	var shooter: FootballPlayer = null
	for player in team.players:
		if player.tactical_role == "ST":
			shooter = player
			break
	if shooter == null:
		simulation.free()
		return false
	var field: Dictionary = simulation.config["field"]
	var edge_margin := float(simulation.config["decision"]["shot_selection"]["box_edge_margin_px"])
	var edge_x := float(field["width"]) - float(field["penalty_area_depth"]) - edge_margin
	shooter.position = Vector2(edge_x - 0.1, float(field["height"]) * 0.5)
	shooter.box_run_active = true
	shooter.box_run_target = shooter.position - Vector2(70.0, 0.0)
	team.completed_passes_in_possession = int(simulation.config["decision"]["pass_selection"]["minimum_build_up_passes_before_shot"])
	for defender in simulation.teams[1].players:
		defender.position = Vector2(-500.0, -500.0)
	var outside_declined := not simulation._box_run_shot_ready(shooter, team) \
		and str(simulation.event_log.back()).contains("box run not reached")
	shooter.position.x = edge_x
	shooter.box_run_target = shooter.position - Vector2(70.0, 0.0)
	var line_distance := simulation._distance_to_penalty_area_line(shooter.position, team)
	var context := simulation._shot_context_breakdown(
		shooter.position, team, float(field["width"]) - shooter.position.x,
		simulation._attack_progress_x(shooter.position.x, team), 1000.0
	)
	var eligible := outside_declined and is_equal_approx(line_distance, edge_margin) \
		and simulation._is_inside_or_on_shot_box_edge(shooter.position, team, edge_margin) \
		and bool(context["inside_box_or_edge"]) and not bool(context["inside_box"]) \
		and simulation._should_shoot(shooter, team)
	if eligible:
		simulation._set_possession(shooter)
		simulation.config["match"]["minimum_probability"] = 0.999
		simulation.config["match"]["maximum_probability"] = 0.999
		simulation._resolve_shot(shooter, team)
		eligible = simulation.ball_in_flight and simulation.ball_flight_phase == "shot"
		for _tick in range(60):
			if team.score > 0 or simulation.restart_pending:
				break
			simulation._advance_ball(float(simulation.config["match"]["tick_seconds"]))
		eligible = eligible and team.score == 1 and simulation.restart_pending \
			and simulation.restart_kind == "kickoff"
	if not eligible:
		push_error("Shot selection test failed: the edge shot was declined or did not resolve through flight.")
	simulation.free()
	return eligible

func _test_goal(attacks_right: bool) -> bool:
	var simulation := _new_simulation()
	if simulation == null:
		return false
	if not attacks_right:
		simulation._start_second_half()
	var team_index := 0
	var team: FootballTeam = simulation.teams[team_index]
	if team.attacks_right != attacks_right:
		push_error("Ball flight test setup has the wrong attack direction.")
		simulation.free()
		return false
	var shooter: FootballPlayer = null
	for player in team.players:
		if player.tactical_role == "ST":
			shooter = player
			break
	if shooter == null:
		simulation.free()
		return false
	shooter.position = Vector2(850.0 if attacks_right else 150.0, 300.0)
	simulation._set_possession(shooter)
	var keeper := simulation._goalkeeper(simulation.teams[1 - team_index])
	keeper.position = Vector2(950.0 if attacks_right else 50.0, 0.0)
	keeper.tactical_position = keeper.position
	simulation.config["match"]["minimum_probability"] = 0.999
	simulation.config["match"]["maximum_probability"] = 0.999
	var score_before := team.score
	simulation._resolve_shot(shooter, team)
	if not simulation.ball_in_flight or simulation.ball_flight_phase != "shot":
		push_error("Ball flight test failed: shot did not launch as a physical flight.")
		simulation.free()
		return false
	for _tick in range(60):
		if team.score > score_before or simulation.restart_pending:
			break
		simulation._advance_ball(float(simulation.config["match"]["tick_seconds"]))
	var passed := team.score == score_before + 1 and simulation.restart_pending \
		and simulation.restart_kind == "kickoff" and simulation.restart_awarded_team == 1 - team_index
	if not passed:
		push_error("Ball flight test failed: central box shot did not score in attack direction %s." % str(attacks_right))
	simulation.free()
	return passed

func _test_post_collision() -> bool:
	var simulation := _new_simulation()
	if simulation == null:
		return false
	var keeper := simulation._goalkeeper(simulation.teams[1])
	keeper.position = Vector2(950.0, 0.0)
	keeper.tactical_position = keeper.position
	var ball_data: Dictionary = simulation.config["match"]["ball_flight"]
	var post_y := float(simulation.config["field"]["height"]) * 0.5 + float(ball_data["goal_width_px"]) * 0.5
	simulation.ball_position_3d = Vector3(970.0, post_y, float(ball_data["goal_height_px"]) * 0.5)
	simulation.ball_position = Vector2(simulation.ball_position_3d.x, simulation.ball_position_3d.y)
	simulation.ball_velocity_3d = Vector3(350.0, 0.0, 0.0)
	simulation.ball_velocity = Vector2(350.0, 0.0)
	simulation.ball_in_flight = true
	simulation.ball_on_ground = false
	simulation.ball_flight_phase = "shot"
	simulation.ball_shooter_id = simulation.teams[0].players[0].id
	simulation.last_touch_team_index = 0
	for _tick in range(8):
		if not simulation.ball_in_flight:
			break
		simulation._advance_ball(0.01)
	var hit := false
	for event in simulation.event_log:
		if str(event).contains("post/crossbar hit"):
			hit = true
	if not hit:
		push_error("Ball flight test failed: a post-directed shot did not collide with the post.")
	simulation.free()
	return hit

func _test_overbar_out() -> bool:
	var simulation := _new_simulation()
	if simulation == null:
		return false
	var ball_data: Dictionary = simulation.config["match"]["ball_flight"]
	var field: Dictionary = simulation.config["field"]
	simulation.ball_position_3d = Vector3(970.0, float(field["height"]) * 0.5, float(ball_data["goal_height_px"]) + 15.0)
	simulation.ball_position = Vector2(simulation.ball_position_3d.x, simulation.ball_position_3d.y)
	simulation.ball_velocity_3d = Vector3(450.0, 0.0, 0.0)
	simulation.ball_velocity = Vector2(450.0, 0.0)
	simulation.ball_in_flight = true
	simulation.ball_on_ground = false
	simulation.ball_flight_phase = "shot"
	simulation.ball_shooter_id = simulation.teams[0].players[0].id
	simulation.last_touch_team_index = 0
	simulation._advance_ball(0.1)
	var passed := simulation.restart_pending and simulation.restart_kind == "goal_kick" \
		and simulation.restart_awarded_team == 1 and simulation.teams[0].score == 0
	if not passed:
		push_error("Ball flight test failed: a shot above the crossbar was not ruled out for a goal kick.")
	simulation.free()
	return passed

func _test_trajectory_determinism() -> bool:
	var first := _trajectory_samples()
	var second := _trajectory_samples()
	var passed: bool = first.size() == 2 and second.size() == 2 \
		and first[0] == second[0] and first[1] == second[1]
	if not passed:
		push_error("Ball flight test failed: same-seed flight samples or event logs diverged.")
	return passed

func _trajectory_samples() -> Array:
	var simulation := _new_simulation()
	if simulation == null:
		return []
	var ball_data: Dictionary = simulation.config["match"]["ball_flight"]
	simulation.ball_position_3d = Vector3(100.0, 200.0, float(ball_data["ball_radius_px"]))
	simulation.ball_position = Vector2(100.0, 200.0)
	simulation.ball_velocity_3d = Vector3(300.0, 0.0, 40.0)
	simulation.ball_velocity = Vector2(300.0, 0.0)
	simulation.ball_in_flight = true
	simulation.ball_on_ground = false
	simulation.ball_flight_phase = "shot"
	simulation.ball_shooter_id = simulation.teams[0].players[0].id
	simulation.last_touch_team_index = 0
	var samples: Array = []
	for _tick in range(20):
		simulation._advance_ball(float(simulation.config["match"]["tick_seconds"]))
		samples.append([simulation.ball_position_3d.x, simulation.ball_position_3d.y, simulation.ball_position_3d.z])
	var events := simulation.event_log.duplicate()
	simulation.free()
	return [samples, events]
