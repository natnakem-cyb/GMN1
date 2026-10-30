extends SceneTree

const SimulationScript = preload("res://scripts/simulation/match_simulation.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	if not _test_pass_reception() or not _test_goal(true) or not _test_goal(false) \
	or not _test_post_collision() or not _test_overbar_out() or not _test_trajectory_determinism():
		quit(1)
		return
	print("PASS: multi-tick pass, both goal directions, post collision, overbar exit, and deterministic trajectories.")
	quit(0)

func _new_simulation() -> MatchSimulation:
	var simulation: MatchSimulation = SimulationScript.new()
	root.add_child(simulation)
	if not simulation.setup_match("4-3-3"):
		simulation.free()
		return null
	simulation.start_match()
	return simulation

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
