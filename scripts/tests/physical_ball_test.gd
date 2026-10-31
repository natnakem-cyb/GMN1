extends SceneTree

const SimulationScript = preload("res://scripts/simulation/match_simulation.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	if not _test_scale_and_rest() or not _test_roll_and_bounce() \
	or not _test_kick_profiles() or not _test_player_contact() \
	or not _test_crossbar_contact() \
	or not _test_seeded_state_hashes():
		quit(1)
		return
	print("PASS: metric scale/rest, rolling resistance, airborne bounce, kick profiles, and seeded ball state/hash determinism.")
	quit(0)

func _new_simulation(seed: int = 1) -> MatchSimulation:
	var simulation: MatchSimulation = SimulationScript.new()
	root.add_child(simulation)
	if not simulation.setup_match("4-3-3"):
		simulation.free()
		return null
	simulation.rng.seed = seed
	simulation.start_match()
	return simulation

func _test_scale_and_rest() -> bool:
	var simulation := _new_simulation()
	if simulation == null:
		return false
	var field: Dictionary = simulation.config["field"]
	var ball: Dictionary = simulation.config["match"]["ball_flight"]
	var passed := is_equal_approx(float(field["pitch_length_m"]), 105.0) \
		and is_equal_approx(float(field["pitch_width_m"]), 68.0) \
		and is_equal_approx(simulation.ball_radius_m, 0.11) \
		and is_equal_approx(simulation.ball_mass_kg, 0.43) \
		and is_equal_approx(float(ball["player_visual_height_m"]), 1.8) \
		and is_equal_approx(simulation.ball_position_3d.y, simulation.ball_radius_m)
	if not passed:
		push_error("Physical ball test failed: metric dimensions or stationary centre height are incorrect.")
	simulation.free()
	return passed

func _test_roll_and_bounce() -> bool:
	var simulation := _new_simulation()
	if simulation == null:
		return false
	for team in simulation.teams:
		for player in team.players:
			player.position = Vector2(-500.0, -500.0)
	simulation.ball_in_flight = true
	simulation.ball_on_ground = true
	simulation.ball_flight_phase = "ground_pass"
	simulation.ball_position_3d = Vector3(30.0, simulation.ball_radius_m, 30.0)
	simulation.ball_velocity_3d = Vector3(4.0, 0.0, 0.0)
	simulation.ball_angular_velocity = Vector3.ZERO
	simulation._sync_ball_projection()
	var initial_speed := simulation.ball_velocity_3d.length()
	simulation._advance_ball(0.1)
	var rolled: bool := simulation.ball_orientation != Quaternion.IDENTITY \
		and simulation.ball_velocity_3d.length() < initial_speed
	for _step in range(200):
		if not simulation.ball_in_flight:
			break
		simulation._advance_ball(0.05)
	var settled := not simulation.ball_in_flight or simulation.ball_velocity_3d.length() < 0.18
	var roll_passed := rolled and settled
	simulation.ball_in_flight = true
	simulation.ball_on_ground = true
	simulation.ball_flight_phase = "ground_pass"
	simulation.ball_position_3d = Vector3(35.0, simulation.ball_radius_m, 30.0)
	simulation.ball_velocity_3d = Vector3(14.0, 0.0, 0.0)
	simulation._sync_ball_projection()
	simulation._advance_ball(0.5)
	var ground_pass_stayed_low := simulation.ball_on_ground \
		and absf(simulation.ball_position_3d.y - simulation.ball_radius_m) < 0.001
	simulation.ball_in_flight = true
	simulation.ball_on_ground = false
	simulation.ball_flight_phase = "ground_pass"
	simulation.ball_position_3d = Vector3(40.0, simulation.ball_radius_m, 30.0)
	simulation.ball_velocity_3d = simulation._kick_profile_velocity(Vector2.RIGHT, "lofted_pass")
	simulation.ball_angular_velocity = Vector3.ZERO
	simulation._sync_ball_projection()
	var peak_height := simulation.ball_position_3d.y
	var rebound_height := 0.0
	var bounced := false
	for _step in range(200):
		simulation._advance_ball(0.02)
		peak_height = maxf(peak_height, simulation.ball_position_3d.y)
		if not simulation.ball_on_ground and peak_height > simulation.ball_radius_m + 0.5 \
		and simulation.ball_position_3d.y <= simulation.ball_radius_m + 0.0001:
			bounced = true
		if bounced:
			rebound_height = maxf(rebound_height, simulation.ball_position_3d.y)
		if bounced and simulation.ball_on_ground:
			break
	var lofted_pass_bounced := bounced and rebound_height > simulation.ball_radius_m + 0.1 \
		and peak_height > simulation.ball_radius_m + 1.0
	# Also verify a controlled 2 m drop yields a visible rebound.
	simulation.ball_in_flight = true
	simulation.ball_on_ground = false
	simulation.ball_flight_phase = "rebound"
	simulation.ball_position_3d = Vector3(40.0, 2.0, 30.0)
	simulation.ball_velocity_3d = Vector3.ZERO
	simulation._sync_ball_projection()
	var drop_bounced := false
	var drop_rebound_height := 0.0
	for _step in range(100):
		simulation._advance_ball(0.02)
		if simulation.ball_position_3d.y <= simulation.ball_radius_m + 0.0001 \
		and simulation.ball_velocity_3d.y > 0.0:
			drop_bounced = true
		if drop_bounced:
			drop_rebound_height = maxf(drop_rebound_height, simulation.ball_position_3d.y)
		if drop_bounced and simulation.ball_on_ground:
			break
	var bounce_passed := lofted_pass_bounced and drop_bounced \
		and drop_rebound_height > simulation.ball_radius_m + 0.1 \
		and simulation.ball_position_3d.y >= simulation.ball_radius_m - 0.001
	if not roll_passed or not ground_pass_stayed_low or not bounce_passed:
		push_error("Physical ball test failed: rolling/settling or measurable landing bounce was not observed.")
	simulation.free()
	return roll_passed and bounce_passed

func _test_kick_profiles() -> bool:
	var simulation := _new_simulation()
	if simulation == null:
		return false
	var ground := simulation._kick_profile_velocity(Vector2.RIGHT, "ground_pass")
	var lofted := simulation._kick_profile_velocity(Vector2.RIGHT, "lofted_pass")
	var cross := simulation._kick_profile_velocity(Vector2.RIGHT, "cross")
	var driven := simulation._kick_profile_velocity(Vector2.RIGHT, "driven_shot")
	var high := simulation._kick_profile_velocity(Vector2.RIGHT, "high_shot")
	var team: FootballTeam = simulation.teams[0]
	var wide_passer: FootballPlayer = null
	var central_midfielder: FootballPlayer = null
	var striker: FootballPlayer = null
	for player in team.players:
		if player.tactical_role == "LW":
			wide_passer = player
		elif player.tactical_role in ["CM", "LCM", "RCM"]:
			central_midfielder = player
		elif player.tactical_role == "ST":
			striker = player
	if wide_passer == null or central_midfielder == null or striker == null:
		simulation.free()
		return false
	wide_passer.position = Vector2(750.0, 150.0)
	central_midfielder.position = Vector2(300.0, 300.0)
	striker.position = Vector2(500.0, 300.0)
	var cross_profile := simulation._pass_kick_profile(wide_passer, striker, team, 250.0)
	var lofted_profile := simulation._pass_kick_profile(central_midfielder, striker, team, 250.0)
	var passed := ground.y == 0.0 and ground.length() < 20.0 \
		and lofted.y > 0.0 and cross.y > lofted.y \
		and driven.length() > ground.length() and high.y > driven.y \
		and cross_profile == "cross" and lofted_profile == "lofted_pass"
	if not passed:
		push_error("Physical ball test failed: kick profile speeds or vertical arcs are not distinct.")
	var shooter := striker
	shooter.position = Vector2(800.0, float(simulation.config["field"]["height"]) * 0.5)
	for defender in simulation.teams[1].players:
		defender.position = Vector2(-500.0, -500.0)
	var goalkeeper := simulation._goalkeeper(simulation.teams[1])
	if goalkeeper != null:
		goalkeeper.position = Vector2(900.0, shooter.position.y)
		simulation._set_possession(shooter)
		simulation._resolve_shot(shooter, team)
		passed = passed and is_equal_approx(simulation.ball_velocity_3d.y, float(simulation.config["match"]["ball_flight"]["kick_profiles"]["high_shot"]["vertical_speed_m_s"]))
	else:
		passed = false
	simulation.free()
	return passed

func _test_player_contact() -> bool:
	var simulation := _new_simulation()
	if simulation == null:
		return false
	for team in simulation.teams:
		for player in team.players:
			player.position = Vector2(-500.0, -500.0)
	var contact_player: FootballPlayer = simulation.teams[1].players[1]
	contact_player.position = Vector2(50.0 / simulation._metres_per_pixel(), 30.0 / simulation._metres_per_pixel())
	simulation.ball_in_flight = true
	simulation.ball_on_ground = true
	simulation.ball_flight_phase = "shot"
	simulation.ball_shooter_id = simulation.teams[0].players[0].id
	simulation.ball_position_3d = Vector3(49.4, simulation.ball_radius_m, 30.0)
	simulation.ball_velocity_3d = Vector3(8.0, 0.0, 0.0)
	simulation._sync_ball_projection()
	simulation._advance_ball(0.1)
	var passed := simulation.ball_flight_phase == "rebound" \
		and simulation.last_touch_team_index == contact_player.team_index \
		and simulation.last_touch_player_id == contact_player.id
	if not passed:
		push_error("Physical ball test failed: swept outfield player contact did not deflect the ball.")
	simulation.free()
	return passed

func _test_crossbar_contact() -> bool:
	var simulation := _new_simulation()
	if simulation == null:
		return false
	var ball_data: Dictionary = simulation.config["match"]["ball_flight"]
	var goal_x := float(simulation.config["field"]["pitch_length_m"])
	var center_z := float(simulation.config["field"]["pitch_width_m"]) * 0.5
	var goal_height := float(ball_data["goal_height_m"])
	simulation.ball_in_flight = true
	simulation.ball_flight_phase = "shot"
	simulation.ball_shooter_id = simulation.teams[0].players[0].id
	simulation.ball_position_3d = Vector3(goal_x - 0.1, goal_height, center_z)
	simulation.ball_velocity_3d = Vector3(10.0, 0.0, 0.0)
	var hit := simulation._resolve_frame_collision()
	var passed := hit and simulation.ball_flight_phase == "rebound" \
		and simulation.ball_velocity_3d.x < 0.0
	if not passed:
		push_error("Physical ball test failed: swept football did not rebound from the crossbar.")
	simulation.free()
	return passed

func _test_seeded_state_hashes() -> bool:
	var first := _new_simulation(77)
	var second := _new_simulation(77)
	if first == null or second == null:
		if first != null:
			first.free()
		if second != null:
			second.free()
		return false
	for simulation in [first, second]:
		for team in simulation.teams:
			for player in team.players:
				player.position = Vector2(-500.0, -500.0)
		simulation.ball_in_flight = true
		simulation.ball_on_ground = false
		simulation.ball_flight_phase = "rebound"
		simulation.ball_position_3d = Vector3(30.0, 1.0, 30.0)
		simulation.ball_velocity_3d = Vector3(8.0, 2.0, 3.0)
		simulation._sync_ball_projection()
	var passed := first.get_state_hash() == second.get_state_hash()
	for _step in range(30):
		first._advance_ball(0.02)
		second._advance_ball(0.02)
		if first.get_state_hash() != second.get_state_hash():
			passed = false
			break
	if not passed:
		push_error("Physical ball test failed: identical seeded metric state trajectories or hashes diverged.")
	first.free()
	second.free()
	return passed
