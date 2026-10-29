extends Node
class_name MatchSimulation

signal state_changed
signal match_finished(home_score: int, away_score: int)
signal action_resolved(action_text: String, probability: float, formula_text: String)
signal halftime_started
signal substitution_made(team_name: String, outgoing_name: String, incoming_name: String)

const PlayerScript = preload("res://scripts/data/player.gd")
const TeamScript = preload("res://scripts/data/team.gd")
const CONFIG_PATH := "res://data/match_config.json"

var config: Dictionary
var teams: Array[FootballTeam] = []
var rng := RandomNumberGenerator.new()
var ball_position := Vector2.ZERO
var ball_velocity := Vector2.ZERO
var ball_owner: FootballPlayer
var ball_target: FootballPlayer
var active := false
var finished := false
var externally_ticked := false
var tick_count := 0
var elapsed_seconds := 0.0
var accumulator := 0.0
var decision_clock := 0.0
var goal_reset_clock := 0.0
var next_kickoff_team := 1
var half_index := 0
var ai_reaction_clock := 0.0
var event_log: Array[String] = []
var selected_player_index := 0
var last_action := "Ready to kick off"
var last_probability := 0.0
var last_formula := "No action resolved"
var last_shot_on_target_probability := -1.0
var last_goalkeeper_save_probability := -1.0
var last_rebound_probability := -1.0
var preferred_pass_debug := "No pass target evaluated"
var last_defensive_decision := "No defensive decision yet"
var last_jockey_log_key := ""
var home_formation := "4-3-3"

func _ready() -> void:
	config = _read_json(CONFIG_PATH)
	if config.is_empty():
		set_process(false)
		return
	rng.seed = int(config.get("seed", 1))

func _process(real_delta: float) -> void:
	if not active or externally_ticked:
		return
	var match_data: Dictionary = config["match"]
	accumulator += real_delta * float(match_data["simulation_seconds_per_real_second"])
	var tick_seconds := float(match_data["tick_seconds"])
	while accumulator >= tick_seconds and active:
		accumulator -= tick_seconds
		step_tick()

func step_tick() -> void:
	if not active or finished:
		return
	tick_count += 1
	_tick(float(config["match"]["tick_seconds"]))

func get_state_hash() -> String:
	var hash_state: Variant = _canonicalize_hash_value(_build_state_data(false))
	return JSON.stringify(hash_state, "", true, true).sha256_text()

func _canonicalize_hash_value(value: Variant) -> Variant:
	if value is float:
		return roundf(float(value) * 10000.0) / 10000.0
	if value is Array:
		var canonical_array: Array = []
		for item in value:
			canonical_array.append(_canonicalize_hash_value(item))
		return canonical_array
	if value is Dictionary:
		var canonical_dictionary: Dictionary = {}
		for key in value:
			canonical_dictionary[key] = _canonicalize_hash_value(value[key])
		return canonical_dictionary
	return value

func create_snapshot() -> Dictionary:
	return {
		"version": int(config["network"]["snapshot_version"]),
		"state": _build_state_data(true)
	}

func restore_snapshot(snapshot: Dictionary) -> bool:
	if int(snapshot.get("version", -1)) != int(config["network"]["snapshot_version"]) \
	or not snapshot.get("state") is Dictionary:
		return false
	var state: Dictionary = snapshot["state"]
	if state.get("teams", []).size() != teams.size():
		return false
	for team_index in range(teams.size()):
		var team_state: Dictionary = state["teams"][team_index]
		if team_state.get("players", []).size() != teams[team_index].players.size():
			return false
		if team_state.get("bench", []).size() != teams[team_index].bench.size():
			return false
		var existing_ids: Dictionary = {}
		for player in teams[team_index].players:
			existing_ids[player.id] = true
		for player in teams[team_index].bench:
			existing_ids[player.id] = true
		for player_data in team_state["players"] + team_state["bench"]:
			if not existing_ids.has(int(player_data.get("id", -1))):
				return false
	for team_index in range(teams.size()):
		var team: FootballTeam = teams[team_index]
		var team_state: Dictionary = state["teams"][team_index]
		var all_players: Dictionary = {}
		for player in team.players:
			all_players[player.id] = player
		for player in team.bench:
			all_players[player.id] = player
		var restored_players: Array[FootballPlayer] = []
		var restored_bench: Array[FootballPlayer] = []
		for player_data in team_state["players"]:
			var player_id := int(player_data["id"])
			if not all_players.has(player_id):
				return false
			var player: FootballPlayer = all_players[player_id]
			_restore_player_data(player, player_data)
			restored_players.append(player)
		for player_data in team_state["bench"]:
			var player_id := int(player_data["id"])
			if not all_players.has(player_id):
				return false
			var player: FootballPlayer = all_players[player_id]
			_restore_player_data(player, player_data)
			restored_bench.append(player)
		team.players = restored_players
		team.bench = restored_bench
		team.formation = str(team_state["formation"])
		team.mentality = str(team_state["mentality"])
		team.game_plan = str(team_state["game_plan"])
		team.instructions = team_state["instructions"].duplicate(true)
		team.completed_passes_in_possession = int(team_state.get("completed_passes_in_possession", 0))
		team.substitutions_used = int(team_state["substitutions_used"])
		team.tactical_points = float(team_state["tactical_points"])
		team.tactical_point_clock = float(team_state["tactical_point_clock"])
		team.instruction_cooldown = float(team_state["instruction_cooldown"])
		team.score = int(team_state["score"])
		team.is_home = bool(team_state["is_home"])
		team.attacks_right = bool(team_state["attacks_right"])
		team.change_cooldown = float(team_state["change_cooldown"])
	tick_count = int(state["tick_count"])
	elapsed_seconds = float(state["elapsed_seconds"])
	accumulator = float(state["accumulator"])
	decision_clock = float(state["decision_clock"])
	goal_reset_clock = float(state["goal_reset_clock"])
	next_kickoff_team = int(state["next_kickoff_team"])
	half_index = int(state["half_index"])
	ai_reaction_clock = float(state["ai_reaction_clock"])
	event_log.clear()
	for event in state["event_log"]:
		event_log.append(str(event))
	ball_position = _vector_from_array(state["ball_position"])
	ball_velocity = _vector_from_array(state["ball_velocity"])
	ball_owner = _find_player_by_id(int(state["ball_owner_id"]))
	ball_target = _find_player_by_id(int(state["ball_target_id"]))
	selected_player_index = int(state["selected_player_index"])
	last_action = str(state["last_action"])
	last_probability = float(state["last_probability"])
	last_formula = str(state["last_formula"])
	last_shot_on_target_probability = float(state["last_shot_on_target_probability"])
	last_goalkeeper_save_probability = float(state["last_goalkeeper_save_probability"])
	last_rebound_probability = float(state["last_rebound_probability"])
	preferred_pass_debug = str(state.get("preferred_pass_debug", "No pass target evaluated"))
	last_defensive_decision = str(state.get("last_defensive_decision", "No defensive decision yet"))
	last_jockey_log_key = str(state.get("last_jockey_log_key", ""))
	home_formation = str(state["home_formation"])
	rng.seed = int(state["rng_seed"])
	rng.state = int(state["rng_state"])
	active = bool(state["active"])
	finished = bool(state["finished"])
	_emit_state()
	return true

func _build_state_data(include_event_log: bool) -> Dictionary:
	var team_data: Array[Dictionary] = []
	for team in teams:
		var players: Array[Dictionary] = []
		var bench: Array[Dictionary] = []
		for player in team.players:
			players.append(_player_state_data(player))
		for player in team.bench:
			bench.append(_player_state_data(player))
		team_data.append({
			"formation": team.formation,
			"mentality": team.mentality,
			"game_plan": team.game_plan,
			"instructions": team.instructions.duplicate(true),
			"completed_passes_in_possession": team.completed_passes_in_possession,
			"substitutions_used": team.substitutions_used,
			"tactical_points": team.tactical_points,
			"tactical_point_clock": team.tactical_point_clock,
			"instruction_cooldown": team.instruction_cooldown,
			"score": team.score,
			"is_home": team.is_home,
			"attacks_right": team.attacks_right,
			"change_cooldown": team.change_cooldown,
			"players": players,
			"bench": bench
		})
	var serialized_events: Array[String] = event_log.duplicate() if include_event_log else []
	return {
		"tick_count": tick_count,
		"elapsed_seconds": elapsed_seconds,
		"accumulator": accumulator,
		"decision_clock": decision_clock,
		"goal_reset_clock": goal_reset_clock,
		"next_kickoff_team": next_kickoff_team,
		"half_index": half_index,
		"ai_reaction_clock": ai_reaction_clock,
		"event_log": serialized_events,
		"ball_position": _vector_to_array(ball_position),
		"ball_velocity": _vector_to_array(ball_velocity),
		"ball_owner_id": _player_id_or_sentinel(ball_owner),
		"ball_target_id": _player_id_or_sentinel(ball_target),
		"selected_player_index": selected_player_index,
		"last_action": last_action,
		"last_probability": last_probability,
		"last_formula": last_formula,
		"last_shot_on_target_probability": last_shot_on_target_probability,
		"last_goalkeeper_save_probability": last_goalkeeper_save_probability,
		"last_rebound_probability": last_rebound_probability,
		"preferred_pass_debug": preferred_pass_debug,
		"last_defensive_decision": last_defensive_decision,
		"last_jockey_log_key": last_jockey_log_key,
		"home_formation": home_formation,
		"rng_seed": rng.seed,
		"rng_state": rng.state,
		"active": active,
		"finished": finished,
		"teams": team_data
	}

func _player_state_data(player: FootballPlayer) -> Dictionary:
	return {
		"id": player.id,
		"player_name": player.player_name,
		"number": player.number,
		"role": player.role,
		"natural_role": player.natural_role,
		"tactical_role": player.tactical_role,
		"attributes": player.attributes.duplicate(true),
		"form": player.form,
		"fatigue": player.fatigue,
		"stamina": player.stamina,
		"tackle_cooldown": player.tackle_cooldown,
		"carry_distance": player.carry_distance,
		"position": _vector_to_array(player.position),
		"tactical_position": _vector_to_array(player.tactical_position),
		"team_index": player.team_index,
		"on_pitch": player.on_pitch
	}

func _restore_player_data(player: FootballPlayer, data: Dictionary) -> void:
	player.player_name = str(data["player_name"])
	player.number = int(data["number"])
	player.role = str(data["role"])
	player.natural_role = str(data["natural_role"])
	player.tactical_role = str(data.get("tactical_role", player.role))
	player.attributes = data["attributes"].duplicate(true)
	player.form = float(data["form"])
	player.fatigue = float(data["fatigue"])
	player.stamina = float(data["stamina"])
	player.tackle_cooldown = float(data.get("tackle_cooldown", 0.0))
	player.carry_distance = float(data.get("carry_distance", 0.0))
	player.position = _vector_from_array(data["position"])
	player.tactical_position = _vector_from_array(data["tactical_position"])
	player.team_index = int(data["team_index"])
	player.on_pitch = bool(data["on_pitch"])

func _vector_to_array(value: Vector2) -> Array[float]:
	return [value.x, value.y]

func _vector_from_array(value: Array) -> Vector2:
	if value.size() != 2:
		return Vector2.ZERO
	return Vector2(float(value[0]), float(value[1]))

func _player_id_or_sentinel(player: FootballPlayer) -> int:
	return player.id if player != null else -1

func _find_player_by_id(player_id: int) -> FootballPlayer:
	if player_id < 0:
		return null
	for team in teams:
		for player in team.players:
			if player.id == player_id:
				return player
		for player in team.bench:
			if player.id == player_id:
				return player
	return null

func validate_manager_command(team_index: int, kind: String, value: String = "", player_index: int = -1) -> bool:
	if finished or team_index < 0 or team_index >= teams.size() or is_team_ai_controlled(team_index):
		return false
	var team: FootballTeam = teams[team_index]
	match kind:
		"mentality":
			return (
				config["probability"]["tactical_modifiers"]["mentality"].has(value)
				and team.mentality != value
				and (not active or team.change_cooldown <= 0.0)
			)
		"game_plan":
			return (
				config["probability"]["tactical_modifiers"]["game_plan"].has(value)
				and team.game_plan != value
				and (not active or team.change_cooldown <= 0.0)
			)
		"instruction":
			if not active:
				return false
			if team.has_instruction(value):
				return true
			var definitions: Dictionary = config["probability"]["instructions"]
			if not definitions.has(value) or team.instruction_cooldown > 0.0:
				return false
			var replacing_channel := (
				(value == "target_left_channel" and team.has_instruction("target_right_channel"))
				or (value == "target_right_channel" and team.has_instruction("target_left_channel"))
			)
			var active_slots := team.instructions.size() - (1 if replacing_channel else 0)
			return (
				active_slots < int(config["match"]["instruction_slots"])
				and team.tactical_points >= float(config["match"]["instruction_tactical_point_cost"])
			)
		"substitution":
			if not active or team.substitutions_used >= int(config["match"]["substitution_limit"]):
				return false
			if team.tactical_points < float(config["match"]["substitution_tactical_point_cost"]):
				return false
			if player_index < 0 or player_index >= team.players.size():
				return false
			var outgoing := team.players[player_index]
			var bench_index := _best_substitute_index(team, outgoing)
			if bench_index < 0:
				return false
			var incoming := team.bench[bench_index]
			return (outgoing.role == "GK") == (incoming.natural_role == "GK")
		_:
			return false

func apply_manager_command(team_index: int, kind: String, value: String = "", player_index: int = -1) -> bool:
	match kind:
		"mentality":
			return change_mentality(value, team_index)
		"game_plan":
			return change_game_plan(value, team_index)
		"instruction":
			return activate_instruction(team_index, value)
		"substitution":
			return substitute_player(team_index, player_index)
		_:
			push_error("Unknown manager command: " + kind)
			return false

func setup_match(chosen_formation: String) -> bool:
	if config.is_empty():
		return false
	home_formation = chosen_formation
	ball_owner = null
	ball_target = null
	teams.clear()
	for team_index in range(config["teams"].size()):
		var team_data: Dictionary = config["teams"][team_index]
		var team := TeamScript.new()
		team.team_name = str(team_data["name"])
		team.color = Color.from_string(str(team_data["color"]), Color.WHITE)
		team.formation = chosen_formation if team_index == 0 else str(team_data["formation"])
		team.is_home = team_index == 0
		team.attacks_right = team.is_home
		for player_data in team_data["players"]:
			team.players.append(_create_player(player_data, team_index))
		for player_data in team_data.get("bench", []):
			var substitute := _create_player(player_data, team_index)
			substitute.on_pitch = false
			team.bench.append(substitute)
		teams.append(team)
	if teams.size() != 2 or teams[0].players.size() != 11 or teams[1].players.size() != 11 or teams[0].bench.is_empty() or teams[1].bench.is_empty():
		push_error("Match setup requires two teams of eleven players and a non-empty bench.")
		return false
	_apply_formation(teams[0])
	_apply_formation(teams[1])
	_reset_match_state()
	return true

func start_match() -> void:
	if teams.size() != 2 or active:
		return
	active = true
	finished = false
	last_action = "Kick-off"
	_emit_state()

func change_mentality(value: String, team_index: int = 0) -> bool:
	if finished or team_index < 0 or team_index >= teams.size() or is_team_ai_controlled(team_index):
		return false
	if not config["probability"]["tactical_modifiers"]["mentality"].has(value):
		push_error("Unknown mentality: " + value)
		return false
	var cooldown := float(config["match"]["tactical_change_cooldown_seconds"]) if active else 0.0
	var changed := teams[team_index].set_mentality(value, cooldown)
	if changed:
		_emit_state()
	return changed

func change_game_plan(value: String, team_index: int = 0) -> bool:
	if finished or team_index < 0 or team_index >= teams.size() or is_team_ai_controlled(team_index):
		return false
	if not config["probability"]["tactical_modifiers"]["game_plan"].has(value):
		push_error("Unknown game plan: " + value)
		return false
	var cooldown := float(config["match"]["tactical_change_cooldown_seconds"]) if active else 0.0
	var changed := teams[team_index].set_game_plan(value, cooldown)
	if changed:
		_emit_state()
	return changed

func is_team_ai_controlled(team_index: int) -> bool:
	return team_index == 1 and bool(config["probability"]["ai"]["enabled"])

func substitute_player(team_index: int, outgoing_index: int, bench_index: int = -1) -> bool:
	if not active or finished or team_index < 0 or team_index >= teams.size() or is_team_ai_controlled(team_index):
		return false
	var team: FootballTeam = teams[team_index]
	if team.substitutions_used >= int(config["match"]["substitution_limit"]):
		return false
	var point_cost := float(config["match"]["substitution_tactical_point_cost"])
	if team.tactical_points < point_cost or outgoing_index < 0 or outgoing_index >= team.players.size():
		return false
	if bench_index < 0:
		bench_index = _best_substitute_index(team, team.players[outgoing_index])
	if bench_index < 0 or bench_index >= team.bench.size():
		return false
	var outgoing := team.players[outgoing_index]
	var incoming := team.bench[bench_index]
	if outgoing.role == "GK" and incoming.natural_role != "GK":
		return false
	if outgoing.role != "GK" and incoming.natural_role == "GK":
		return false
	team.tactical_points -= point_cost
	incoming.role = outgoing.role
	incoming.tactical_role = outgoing.tactical_role
	incoming.position = outgoing.position
	incoming.tactical_position = outgoing.tactical_position
	incoming.fatigue = outgoing.fatigue * float(config["match"]["substitution_fatigue_inheritance"])
	incoming.form = outgoing.form * float(config["match"]["substitution_form_inheritance"])
	incoming.on_pitch = true
	incoming.stamina = incoming.get_attribute("stamina") * (1.0 - incoming.fatigue)
	outgoing.role = outgoing.natural_role
	outgoing.tactical_role = outgoing.natural_role
	outgoing.on_pitch = false
	team.players[outgoing_index] = incoming
	team.bench[bench_index] = outgoing
	if ball_owner == outgoing:
		ball_owner = incoming
	if ball_target == outgoing:
		ball_target = incoming
	team.substitutions_used += 1
	var text := "%s substitutes %s for %s" % [team.team_name, incoming.player_name, outgoing.player_name]
	event_log.append(text)
	print("[Match] " + text)
	substitution_made.emit(team.team_name, outgoing.player_name, incoming.player_name)
	_emit_state()
	return true

func activate_instruction(team_index: int, instruction_id: String) -> bool:
	if not active or finished or team_index < 0 or team_index >= teams.size() or is_team_ai_controlled(team_index):
		return false
	var team: FootballTeam = teams[team_index]
	if team.has_instruction(instruction_id):
		var remaining_instructions: Array[Dictionary] = []
		for entry in team.instructions:
			if str(entry["id"]) != instruction_id:
				remaining_instructions.append(entry)
		team.instructions = remaining_instructions
		event_log.append("%s cancels %s" % [team.team_name, instruction_id])
		_emit_state()
		return true
	var definitions: Dictionary = config["probability"]["instructions"]
	if not definitions.has(instruction_id):
		return false
	var replaced_channel := ""
	if instruction_id == "target_left_channel" and team.has_instruction("target_right_channel"):
		replaced_channel = "target_right_channel"
	elif instruction_id == "target_right_channel" and team.has_instruction("target_left_channel"):
		replaced_channel = "target_left_channel"
	var active_slots := team.instructions.size() - (1 if not replaced_channel.is_empty() else 0)
	if active_slots >= int(config["match"]["instruction_slots"]):
		return false
	var point_cost := float(config["match"]["instruction_tactical_point_cost"])
	if team.tactical_points < point_cost or team.instruction_cooldown > 0.0:
		return false
	team.tactical_points -= point_cost
	team.instruction_cooldown = float(config["match"]["instruction_cooldown_seconds"])
	if not replaced_channel.is_empty():
		var remaining_instructions: Array[Dictionary] = []
		for entry in team.instructions:
			if str(entry["id"]) != replaced_channel:
				remaining_instructions.append(entry)
		team.instructions = remaining_instructions
	team.instructions.append({
		"id": instruction_id,
		"remaining": float(config["thresholds"]["instruction_duration_seconds"])
	})
	event_log.append("%s activates %s" % [team.team_name, instruction_id])
	_emit_state()
	return true

func _create_player(player_data: Dictionary, team_index: int) -> FootballPlayer:
	var player := PlayerScript.new()
	player.id = team_index * 100 + int(player_data["number"])
	player.player_name = str(player_data["name"])
	player.number = int(player_data["number"])
	player.role = str(player_data["role"])
	player.natural_role = player.role
	player.tactical_role = player.role
	player.attributes = (config["player_templates"][str(player_data["template"])] as Dictionary).duplicate(true)
	player.stamina = player.get_attribute("stamina")
	player.team_index = team_index
	return player

func _best_substitute_index(team: FootballTeam, outgoing: FootballPlayer) -> int:
	var preferred_template_role := "GK" if outgoing.role == "GK" else ("DEF" if ["LB", "RB", "CB"].has(outgoing.role) else ("ATT" if ["LW", "RW", "ST"].has(outgoing.role) else "MID"))
	var best_index := -1
	var best_score := -INF
	for index in range(team.bench.size()):
		var candidate := team.bench[index]
		if candidate.natural_role != preferred_template_role:
			continue
		var selection: Dictionary = config["probability"]["manager_tools"]["substitution_selection"]
		var score := candidate.get_attribute("stamina") * float(selection["stamina_weight"])
		score += candidate.get_attribute("pace") * float(selection["pace_weight"])
		score -= candidate.fatigue * float(selection["fatigue_penalty"])
		if preferred_template_role == "GK":
			score = candidate.get_attribute("reflexes") * float(selection["goalkeeper_reflexes_weight"])
			score += candidate.get_attribute("positioning") * float(selection["goalkeeper_positioning_weight"])
			score -= candidate.fatigue * float(selection["fatigue_penalty"])
		if score > best_score:
			best_index = index
			best_score = score
	return best_index

func cycle_selected_player(team_index: int = 0) -> void:
	if teams.is_empty() or team_index < 0 or team_index >= teams.size():
		return
	selected_player_index = (selected_player_index + 1) % teams[team_index].players.size()
	_emit_state()

func get_selected_player(team_index: int = 0) -> FootballPlayer:
	if team_index < 0 or team_index >= teams.size() or teams[team_index].players.is_empty():
		return null
	return teams[team_index].players[selected_player_index % teams[team_index].players.size()]

func _reset_match_state() -> void:
	rng.seed = int(config.get("seed", 1))
	for team in teams:
		team.score = 0
		team.completed_passes_in_possession = 0
		team.mentality = "Balanced"
		team.game_plan = "Possession"
		team.change_cooldown = 0.0
		team.instructions.clear()
		team.substitutions_used = 0
		team.tactical_points = float(config["match"]["tactical_points_maximum"])
		team.tactical_point_clock = 0.0
		team.instruction_cooldown = 0.0
		team.attacks_right = team.is_home
		for player in team.players + team.bench:
			player.tackle_cooldown = 0.0
			player.carry_distance = 0.0
	elapsed_seconds = 0.0
	tick_count = 0
	accumulator = 0.0
	decision_clock = 0.0
	goal_reset_clock = 0.0
	next_kickoff_team = 1
	half_index = 0
	ai_reaction_clock = 0.0
	event_log.clear()
	ball_velocity = Vector2.ZERO
	ball_target = null
	ball_owner = teams[0].players[9]
	ball_owner.position = Vector2(float(config["field"]["width"]) * 0.5, float(config["field"]["height"]) * 0.5)
	ball_position = ball_owner.position
	selected_player_index = 0
	last_shot_on_target_probability = -1.0
	last_goalkeeper_save_probability = -1.0
	last_rebound_probability = -1.0
	last_defensive_decision = "No defensive decision yet"
	last_jockey_log_key = ""
	last_action = "Ready to kick off"
	last_probability = 0.0
	last_formula = "No action resolved"
	active = false
	finished = false
	externally_ticked = false

func _tick(seconds: float) -> void:
	elapsed_seconds += seconds
	decision_clock += seconds
	ai_reaction_clock += seconds
	for team in teams:
		team.tick_cooldown(seconds)
		team.tactical_point_clock += seconds
		var regen_interval := float(config["thresholds"]["tactical_point_regen_interval_seconds"])
		while team.tactical_point_clock >= regen_interval:
			team.tactical_point_clock -= regen_interval
			team.tactical_points = minf(team.tactical_points + float(config["match"]["tactical_points_regen_per_minute"]), float(config["match"]["tactical_points_maximum"]))
		_update_tactical_positions(team)
		for player in team.players:
			player.apply_condition(seconds, float(config["match"]["condition_fatigue_per_second"]))
			player.tackle_cooldown = maxf(0.0, player.tackle_cooldown - seconds)
			player.position = player.position.move_toward(
				player.tactical_position,
				float(config["match"]["player_move_speed"]) * seconds
			)
		for player in team.bench:
			player.tackle_cooldown = maxf(0.0, player.tackle_cooldown - seconds)
	if ball_owner != null:
		var attack_direction := 1.0 if teams[ball_owner.team_index].attacks_right else -1.0
		var carry_target := ball_owner.tactical_position + Vector2(attack_direction * float(config["match"]["carry_advance_distance"]), 0.0)
		var boundary_margin := float(config["match"]["player_boundary_margin"])
		carry_target.x = clampf(carry_target.x, boundary_margin, float(config["field"]["width"]) - boundary_margin)
		var previous_position := ball_owner.position
		ball_owner.position = ball_owner.position.move_toward(
			carry_target,
			float(config["match"]["carry_speed"]) * seconds
		)
		ball_owner.carry_distance += maxf(0.0, (ball_owner.position.x - previous_position.x) * attack_direction)
		ball_position = ball_owner.position
	if goal_reset_clock > 0.0:
		goal_reset_clock -= seconds
		if goal_reset_clock <= 0.0:
			_restart_after_goal()
	else:
		_advance_ball(seconds)
		if decision_clock >= float(config["match"]["decision_interval_seconds"]):
			decision_clock = 0.0
			_resolve_next_action()
	if half_index == 0 and elapsed_seconds >= float(config["match"]["half_duration_seconds"]):
		_start_second_half()
	if ai_reaction_clock >= float(config["probability"]["ai"]["reaction_cooldown_seconds"]):
		ai_reaction_clock = 0.0
		_update_ai_manager()
	if elapsed_seconds >= float(config["match"]["half_duration_seconds"]) * 2.0:
		active = false
		finished = true
		last_action = "Full time"
		match_finished.emit(teams[0].score, teams[1].score)
	_emit_state()

func _start_second_half() -> void:
	half_index = 1
	for team in teams:
		team.attacks_right = not team.attacks_right
		_update_tactical_positions(team)
		for player in team.players:
			player.position = player.tactical_position
	next_kickoff_team = int(config["match"]["halftime_restart_team_index"])
	var kickoff_player := teams[next_kickoff_team].players[9]
	kickoff_player.position = Vector2(float(config["field"]["width"]) * 0.5, float(config["field"]["height"]) * 0.5)
	_set_possession(kickoff_player)
	decision_clock = 0.0
	event_log.append("HALFTIME: teams switch ends")
	halftime_started.emit()
	print("[Match] HALFTIME: teams switch ends")

func _update_ai_manager() -> void:
	if not bool(config["probability"]["ai"]["enabled"]) or teams.size() < 2:
		return
	var ai_team: FootballTeam = teams[1]
	var ai_data: Dictionary = config["probability"]["ai"]
	var losing_by := teams[0].score - ai_team.score
	var late_seconds := float(config["match"]["half_duration_seconds"]) * 2.0 - elapsed_seconds
	var desired_mentality := ai_team.mentality
	var desired_plan := ai_team.game_plan
	if losing_by >= int(ai_data["losing_by_goals"]):
		desired_mentality = str(ai_data["attacking_mentality"])
	elif late_seconds <= float(ai_data["defensive_late_match_seconds"]) and losing_by < 0:
		desired_mentality = str(ai_data["defensive_mentality"])
		desired_plan = str(ai_data["defensive_game_plan"])
	if desired_mentality != ai_team.mentality and ai_team.can_change_tactics():
		ai_team.set_mentality(desired_mentality, float(config["match"]["tactical_change_cooldown_seconds"]))
		event_log.append("AI changes mentality to %s" % desired_mentality)
	if desired_plan != ai_team.game_plan and ai_team.can_change_tactics():
		ai_team.set_game_plan(desired_plan, float(config["match"]["tactical_change_cooldown_seconds"]))
		event_log.append("AI changes game plan to %s" % desired_plan)

func _resolve_next_action() -> void:
	if goal_reset_clock > 0.0:
		return
	if ball_target != null:
		return
	if ball_owner == null:
		var nearest := _nearest_player(ball_position)
		if nearest != null:
			_set_possession(nearest)
		return
	var owner_team: FootballTeam = teams[ball_owner.team_index]
	var opponent_team: FootballTeam = teams[1 - ball_owner.team_index]
	var defender := _nearest_opponent_to_ball(opponent_team)
	if defender != null and _resolve_tackle(defender):
		return
	if ball_owner == null:
		return
	if _should_shoot(ball_owner, owner_team):
		_resolve_shot(ball_owner, owner_team)
	else:
		_resolve_pass(ball_owner, owner_team)

func _resolve_pass(player: FootballPlayer, team: FootballTeam) -> void:
	var receiver := _choose_receiver(player, team)
	if receiver == null:
		return
	var distance := player.position.distance_to(receiver.position)
	var tactical := _tactical_modifier(team, "pass")
	var range_modifier := -distance * float(config["probability"]["long_pass_distance_scale"])
	if team.game_plan == "Possession":
		range_modifier *= float(config["decision"]["possession_pass_range_factor"])
	if team.has_instruction("direct_long_balls"):
		range_modifier += float(config["probability"]["instructions"]["direct_long_balls"]["range_modifier"])
	var channel_modifier := _channel_pass_modifier(team, receiver)
	range_modifier += channel_modifier
	var attributes: Dictionary = config["probability"]["action_weights"]["pass"]
	var probability := _calculate_probability(player, attributes, tactical + range_modifier)
	var formula := _formula_description(player, attributes, tactical + range_modifier)
	var success := rng.randf() < probability
	player.record_action(success, float(config["match"]["condition_form_change_per_success"]))
	_set_last_action("%s %s → %s: %s" % [team.team_name, player.player_name, receiver.player_name, "complete" if success else "intercepted"], probability, formula)
	if success:
		ball_owner = null
		ball_target = receiver
		ball_position = player.position
		var direction := (receiver.position - player.position).normalized()
		ball_velocity = direction * float(config["match"]["pass_ball_speed"])
	else:
		_set_possession(_nearest_opponent_to_ball(teams[1 - player.team_index]))

func _resolve_shot(player: FootballPlayer, team: FootballTeam) -> void:
	_finish_pass_sequence(team, "shot")
	last_rebound_probability = -1.0
	var goal_x := float(config["field"]["width"]) if team.attacks_right else 0.0
	var distance_to_goal := absf(goal_x - player.position.x)
	var zone_modifier := -distance_to_goal * float(config["probability"]["shot_distance_scale"])
	var preferred_x := float(config["thresholds"]["shot_preferred_attack_x"])
	var attack_x := player.position.x / float(config["field"]["width"])
	if not team.attacks_right:
		attack_x = 1.0 - attack_x
	var central_bonus := float(config["probability"]["central_shot_bonus"]) if absf(player.position.y - float(config["field"]["height"]) * 0.5) < float(config["probability"]["central_shot_distance"]) else 0.0
	var preferred_zone_bonus := float(config["probability"]["preferred_zone_shot_bonus"]) if attack_x >= preferred_x else 0.0
	var nearest_defender := _nearest_opponent_to_position(player.position, teams[1 - player.team_index])
	if nearest_defender == null:
		push_error("Shot resolution failed: defending team has no outfield players.")
		return
	var pressure_distance := nearest_defender.position.distance_to(player.position)
	var pressure_factor := clampf(1.0 - pressure_distance / float(config["probability"]["shot_pressure_distance"]), 0.0, 1.0)
	var pressure_modifier := -pressure_factor * float(config["probability"]["shot_pressure_penalty"])
	var tactical := _tactical_modifier(team, "shot")
	var modifier := float(config["probability"]["shot_base_modifier"]) + zone_modifier + central_bonus + preferred_zone_bonus + pressure_modifier + tactical
	var attributes: Dictionary = config["probability"]["action_weights"]["shot"]
	var shot_probability := _calculate_probability(player, attributes, modifier)
	last_shot_on_target_probability = shot_probability
	var shot_power_weights: Dictionary = config["probability"]["shot_power_attribute_weights"]
	var placement_weights: Dictionary = config["probability"]["shot_placement_attribute_weights"]
	var shot_power := _weighted_attribute(player, shot_power_weights)
	var shot_placement := _weighted_attribute(player, placement_weights)
	var on_target := rng.randf() < shot_probability
	player.record_action(on_target, float(config["match"]["condition_form_change_per_success"]))
	if not on_target:
		last_goalkeeper_save_probability = -1.0
		var miss_formula := _formula_description(player, attributes, modifier)
		_set_last_action("%s %s misses the target (wide)" % [team.team_name, player.player_name], shot_probability, miss_formula)
		_set_possession(_goalkeeper(teams[1 - player.team_index]))
		return
	var goalkeeper := _goalkeeper(teams[1 - player.team_index])
	if goalkeeper == null:
		push_error("Shot resolution failed: defending team has no goalkeeper.")
		return
	var gk_weights: Dictionary = config["probability"]["action_weights"]["goalkeeper"]
	var gk_distance_modifier := distance_to_goal * float(config["probability"]["goalkeeper_distance_scale"])
	var gk_power_modifier := -shot_power * float(config["probability"]["goalkeeper_power_penalty"])
	var gk_placement_modifier := -shot_placement * float(config["probability"]["goalkeeper_placement_penalty"])
	var gk_pressure_modifier := pressure_factor * float(config["probability"]["goalkeeper_pressure_bonus"])
	var gk_tactical := float(config["probability"]["goalkeeper_tactical_modifiers"]["mentality"][teams[goalkeeper.team_index].mentality])
	gk_tactical += float(config["probability"]["goalkeeper_tactical_modifiers"]["game_plan"][teams[goalkeeper.team_index].game_plan])
	if teams[goalkeeper.team_index].has_instruction("press_pivot") and player.number == int(config["probability"]["instructions"]["press_pivot"]["pivot_shirt_number"]):
		gk_tactical += float(config["probability"]["instructions"]["press_pivot"]["save_pressure_bonus"])
	var gk_modifier := gk_distance_modifier + gk_power_modifier + gk_placement_modifier + gk_pressure_modifier + gk_tactical
	var save_probability := _calculate_probability_with_slope(
		goalkeeper, gk_weights, gk_modifier,
		float(config["probability"]["goalkeeper_save_slope"]),
		float(config["match"]["minimum_probability"]),
		float(config["match"]["maximum_probability"])
	)
	last_goalkeeper_save_probability = save_probability
	var saved := rng.randf() < save_probability
	var goal_center_y := float(config["field"]["height"]) * 0.5
	ball_position = Vector2(goal_x, lerpf(goal_center_y, player.position.y, shot_placement))
	var shot_formula := _formula_description(player, attributes, modifier)
	var keeper_formula := _formula_description_with_slope(
		goalkeeper, gk_weights, gk_modifier, float(config["probability"]["goalkeeper_save_slope"])
	)
	if saved:
		var support_player := _nearest_outfield_player_to_position(ball_position, team)
		var support_modifier := float(config["probability"]["rebound_base_modifier"]) + float(config["probability"]["rebound_save_modifier"])
		if support_player != null and support_player.position.distance_to(ball_position) <= float(config["probability"]["rebound_support_distance"]):
			support_modifier += float(config["probability"]["rebound_support_bonus"])
		var rebound_weights: Dictionary = config["probability"]["action_weights"]["rebound"]
		var rebound_probability := _calculate_probability_with_slope(
			support_player if support_player != null else player,
			rebound_weights, support_modifier,
			float(config["probability"]["rebound_slope"]),
			float(config["thresholds"]["rebound_minimum_probability"]),
			float(config["thresholds"]["rebound_maximum_probability"])
		)
		last_rebound_probability = rebound_probability
		var rebound_won := rng.randf() < rebound_probability
		var rebound_formula := _formula_description_with_slope(
			support_player if support_player != null else player,
			rebound_weights, support_modifier, float(config["probability"]["rebound_slope"])
		)
		if rebound_won and support_player != null:
			_set_possession(support_player)
			_set_last_action("%s shot on target (%.3f); saved by %s (%.3f); rebound to %s (%.3f)" % [
				player.player_name, shot_probability, goalkeeper.player_name, save_probability,
				support_player.player_name, rebound_probability
			], shot_probability, "%s | GK: %s | Rebound: %s" % [shot_formula, keeper_formula, rebound_formula])
		else:
			_set_possession(goalkeeper)
			_set_last_action("%s shot on target (%.3f); saved by %s (%.3f); keeper holds (rebound %.3f)" % [
				player.player_name, shot_probability, goalkeeper.player_name, save_probability, rebound_probability
			], shot_probability, "%s | GK: %s | Rebound: %s" % [shot_formula, keeper_formula, rebound_formula])
	else:
		team.score += 1
		next_kickoff_team = 1 - player.team_index
		_set_last_action("%s %s scores! (on target %.3f; keeper save %.3f)" % [
			team.team_name, player.player_name, shot_probability, save_probability
		], shot_probability, "%s | GK: %s" % [shot_formula, keeper_formula])
		ball_position = Vector2(goal_x, float(config["field"]["height"]) * 0.5)
		ball_velocity = Vector2.ZERO
		ball_owner = null
		ball_target = null
		goal_reset_clock = float(config["match"]["goal_reset_seconds"])

func _resolve_tackle(defender: FootballPlayer) -> bool:
	if ball_owner == null:
		return false
	var decision := _tackle_decision(defender, ball_owner)
	if not bool(decision["attempt"]):
		_log_jockey_decision(defender, ball_owner, str(decision["reason"]))
		if bool(decision["poor_position"]):
			var tackle_data: Dictionary = config["match"]["tackle_decision"]
			defender.tackle_cooldown = maxf(
				defender.tackle_cooldown,
				float(tackle_data["poor_position_cooldown_seconds"])
			)
		return false
	last_defensive_decision = "%s attempts tackle on %s (decision %.0f%%)" % [
		defender.player_name, ball_owner.player_name, float(decision["chance"]) * 100.0
	]
	print("[Defence] " + last_defensive_decision)
	var distance := defender.position.distance_to(ball_owner.position)
	var pressure_modifier := -distance * float(config["probability"]["tackle_pressure_scale"])
	if teams[defender.team_index].has_instruction("press_pivot") and ball_owner.number == int(config["probability"]["instructions"]["press_pivot"]["pivot_shirt_number"]):
		pressure_modifier += float(config["probability"]["instructions"]["press_pivot"]["tackle_modifier"])
	var tactical := _tactical_modifier(teams[defender.team_index], "tackle")
	var modifier := pressure_modifier + tactical
	var attributes: Dictionary = config["probability"]["action_weights"]["tackle"]
	var probability := _calculate_probability(defender, attributes, modifier)
	var formula := _formula_description(defender, attributes, modifier)
	var won_ball := rng.randf() < probability
	defender.record_action(won_ball, float(config["match"]["condition_form_change_per_success"]))
	if won_ball:
		last_defensive_decision = "%s tackles (%.0fpx, P %.2f)" % [defender.player_name, distance, probability]
	else:
		var tackle_data: Dictionary = config["match"]["tackle_decision"]
		defender.tackle_cooldown = float(tackle_data["failed_tackle_cooldown_seconds"])
		last_defensive_decision = "%s jockeys after failed tackle (%.1fs cooldown)" % [
			defender.player_name, defender.tackle_cooldown
		]
		print("[Defence] %s beaten; %s contains for %.1fs." % [
			defender.player_name, defender.player_name, defender.tackle_cooldown
		])
	_set_last_action("%s tackle by %s: %s" % [teams[defender.team_index].team_name, defender.player_name, "won" if won_ball else "beaten"], probability, formula)
	if won_ball:
		_set_possession(defender)
	return won_ball

func _tackle_decision(defender: FootballPlayer, carrier: FootballPlayer) -> Dictionary:
	var decision_data: Dictionary = config["match"]["tackle_decision"]
	var defender_team: FootballTeam = teams[defender.team_index]
	var distance := defender.position.distance_to(carrier.position)
	if distance > float(decision_data["jockey_distance"]):
		return {"attempt": false, "reason": "distance %.0fpx: hold shape" % distance, "poor_position": false}
	if distance > float(decision_data["maximum_attempt_distance"]):
		return {"attempt": false, "reason": "distance %.0fpx: jockey, outside tackle range" % distance, "poor_position": false}
	if defender.tackle_cooldown > 0.0:
		return {"attempt": false, "reason": "jockey cooldown %.1fs" % defender.tackle_cooldown, "poor_position": false}
	var stamina_percent := defender.stamina / maxf(defender.get_attribute("stamina"), 1.0) * 100.0
	if stamina_percent < float(decision_data["minimum_stamina_percent"]):
		return {"attempt": false, "reason": "low stamina %.0f%%" % stamina_percent, "poor_position": true}
	if defender.fatigue > float(decision_data["maximum_fatigue"]):
		return {"attempt": false, "reason": "fatigue %.0f%%" % (defender.fatigue * 100.0), "poor_position": true}

	var attack_sign := 1.0 if teams[carrier.team_index].attacks_right else -1.0
	var carrier_to_defender := (defender.position - carrier.position).normalized()
	var goalside_cosine := carrier_to_defender.x * -attack_sign
	var is_goalside := goalside_cosine >= float(decision_data["goalside_cosine"])
	var is_facing_defender := carrier_to_defender.x * attack_sign >= float(decision_data["facing_defender_cosine"])
	var is_committed := carrier.carry_distance >= float(decision_data["carrier_commitment_distance"])
	if not is_goalside and not is_committed:
		return {"attempt": false, "reason": "angle: not goalside (cos %.2f)" % goalside_cosine, "poor_position": true}
	if is_facing_defender and not is_committed:
		return {"attempt": false, "reason": "carrier facing defender", "poor_position": true}

	var chance := float(decision_data["base_attempt_chance"])
	chance += float(decision_data["mentality_attempt_modifiers"][defender_team.mentality])
	chance += float(decision_data["game_plan_attempt_modifiers"][defender_team.game_plan])
	chance += float(decision_data["role_attempt_modifiers"][_pass_role_profile(defender.tactical_role)])
	if is_goalside:
		chance += float(decision_data["goalside_attempt_bonus"])
	if is_committed:
		chance += float(decision_data["committed_carrier_attempt_bonus"])
	if is_facing_defender:
		chance -= float(decision_data["facing_carrier_attempt_penalty"])
	var stamina_ratio := clampf(stamina_percent / 100.0, 0.0, 1.0)
	chance -= (1.0 - stamina_ratio) * float(decision_data["low_stamina_attempt_penalty"])
	var fatigue_ratio := clampf(defender.fatigue / maxf(float(decision_data["maximum_fatigue"]), 0.01), 0.0, 1.0)
	chance -= fatigue_ratio * float(decision_data["fatigue_attempt_penalty"])
	chance = clampf(
		chance,
		float(decision_data["minimum_attempt_chance"]),
		float(decision_data["maximum_attempt_chance"])
	)
	if rng.randf() >= chance:
		return {"attempt": false, "reason": "selective contain (attempt chance %.0f%%)" % (chance * 100.0), "poor_position": false, "chance": chance}
	return {"attempt": true, "reason": "good tackle opportunity", "poor_position": false, "chance": chance}

func _log_jockey_decision(defender: FootballPlayer, carrier: FootballPlayer, reason: String) -> void:
	last_defensive_decision = "%s jockeys/contains vs %s: %s" % [defender.player_name, carrier.player_name, reason]
	var reason_category := reason.get_slice(" ", 0)
	var key := "%d:%d:%s" % [defender.id, carrier.id, reason_category]
	if key == last_jockey_log_key:
		return
	last_jockey_log_key = key
	var text := "[Defence] %s; %s." % [last_defensive_decision, "force the safe outlet and delay"]
	event_log.append(text)
	print(text)

func _calculate_probability(player: FootballPlayer, weights: Dictionary, context_modifier: float) -> float:
	return _calculate_probability_with_slope(
		player, weights, context_modifier,
		float(config["probability"]["sigmoid_slope"]),
		float(config["match"]["minimum_probability"]),
		float(config["match"]["maximum_probability"])
	)

func _calculate_probability_with_slope(player: FootballPlayer, weights: Dictionary, context_modifier: float, slope: float, minimum: float, maximum: float) -> float:
	var weighted_attribute := _weighted_attribute(player, weights)
	var fatigue_penalty := player.fatigue * float(config["probability"]["fatigue_weight"])
	if player.fatigue >= float(config["thresholds"]["fatigue_breakpoint"]):
		fatigue_penalty += float(config["probability"]["fatigue_breakpoint_penalty"])
	var form_modifier := player.form * float(config["probability"]["form_weight"])
	var logit := (weighted_attribute - 0.5) * slope
	logit += context_modifier + form_modifier - fatigue_penalty
	var raw_probability := 1.0 / (1.0 + exp(-logit))
	return clampf(raw_probability, minimum, maximum)

func _weighted_attribute(player: FootballPlayer, weights: Dictionary) -> float:
	var weighted_attribute := 0.0
	for attribute_name in weights:
		weighted_attribute += player.get_attribute(str(attribute_name)) / 100.0 * float(weights[attribute_name])
	return weighted_attribute

func _formula_description(player: FootballPlayer, weights: Dictionary, modifier: float) -> String:
	return _formula_description_with_slope(player, weights, modifier, float(config["probability"]["sigmoid_slope"]))

func _formula_description_with_slope(player: FootballPlayer, weights: Dictionary, modifier: float, slope: float) -> String:
	var weight_text := ""
	var weighted_attribute := _weighted_attribute(player, weights)
	for attribute_name in weights:
		if not weight_text.is_empty():
			weight_text += " + "
		weight_text += "%s×%.2f" % [str(attribute_name), float(weights[attribute_name])]
	var fatigue_penalty := player.fatigue * float(config["probability"]["fatigue_weight"])
	if player.fatigue >= float(config["thresholds"]["fatigue_breakpoint"]):
		fatigue_penalty += float(config["probability"]["fatigue_breakpoint_penalty"])
	var form_modifier := player.form * float(config["probability"]["form_weight"])
	return "sigmoid((skill %.2f - .50) × %.1f + ctx %+.2f + form %+.2f - fatigue %.2f) | %s" % [
		weighted_attribute, slope, modifier,
		form_modifier, fatigue_penalty, weight_text
	]

func _advance_ball(seconds: float) -> void:
	if ball_target == null:
		return
	var drag := maxf(0.0, 1.0 - float(config["match"]["ball_drag_per_second"]) * seconds)
	var spin := float(config["match"]["ball_spin_influence"])
	ball_velocity += Vector2(-ball_velocity.y, ball_velocity.x) * spin * seconds
	ball_velocity *= drag
	ball_position += ball_velocity * seconds
	if ball_position.distance_to(ball_target.position) <= float(config["match"]["pass_arrival_radius"]) or ball_velocity.length() < float(config["match"]["ball_minimum_speed"]):
		_set_possession(ball_target)

func _set_possession(player: FootballPlayer) -> void:
	if player == null:
		ball_owner = null
		ball_target = null
		ball_velocity = Vector2.ZERO
		return
	var previous_team_index := -1
	if ball_owner != null:
		previous_team_index = ball_owner.team_index
	elif ball_target != null:
		previous_team_index = ball_target.team_index
	if previous_team_index >= 0 and previous_team_index != player.team_index:
		_finish_pass_sequence(teams[previous_team_index], "possession lost")
	elif ball_target != null and ball_target.team_index == player.team_index:
		teams[player.team_index].completed_passes_in_possession += 1
		var pass_count := teams[player.team_index].completed_passes_in_possession
		var sequence_text := "[Possession] %s combination pass %d completed (sequence length %d)." % [
			teams[player.team_index].team_name, pass_count, pass_count
		]
		event_log.append(sequence_text)
		print(sequence_text)
	if ball_owner != player:
		player.carry_distance = 0.0
	ball_owner = player
	ball_target = null
	ball_velocity = Vector2.ZERO
	ball_position = player.position
	preferred_pass_debug = "%s possession: waiting for pass selection" % teams[player.team_index].team_name

func _finish_pass_sequence(team: FootballTeam, reason: String) -> void:
	if team.completed_passes_in_possession > 0:
		var sequence_text := "[Possession] %s sequence ended after %d completed passes (%s)." % [
			team.team_name, team.completed_passes_in_possession, reason
		]
		event_log.append(sequence_text)
		print(sequence_text)
	team.completed_passes_in_possession = 0

func _choose_receiver(player: FootballPlayer, team: FootballTeam) -> FootballPlayer:
	var best_player: FootballPlayer
	var best_score := -INF
	var attack_direction := 1.0 if team.attacks_right else -1.0
	var field_width := float(config["field"]["width"])
	var pass_data: Dictionary = config["decision"]["pass_selection"]
	var tackle_data: Dictionary = config["match"]["tackle_decision"]
	var direct_mode := _is_direct_play_mode(team)
	var nearest_to_carrier := _nearest_opponent_to_position(player.position, teams[1 - player.team_index])
	var carrier_pressure := player.position.distance_to(nearest_to_carrier.position) if nearest_to_carrier != null else INF
	var is_pressured := carrier_pressure <= float(tackle_data["pressure_pass_distance"])
	for candidate in team.players:
		if candidate == player:
			continue
		var forward_progress := (candidate.position.x - player.position.x) * attack_direction
		var distance := player.position.distance_to(candidate.position)
		var nearest_defender := _nearest_opponent_to_position(candidate.position, teams[1 - candidate.team_index])
		var defender_distance := candidate.position.distance_to(nearest_defender.position) if nearest_defender != null else field_width
		var direction := (candidate.position - player.position).normalized()
		var forward_alignment := direction.x * attack_direction
		var support_angle_quality := 1.0 - absf(forward_alignment)
		var role_profile_name := _pass_role_profile(candidate.tactical_role)
		var role_profiles: Dictionary = pass_data["role_profiles"]
		var role_profile: Dictionary = role_profiles[role_profile_name]
		var nearby_multiplier := float(role_profile["nearby_multiplier"])
		if direct_mode:
			nearby_multiplier *= float(pass_data["direct_nearby_multiplier"])
		if is_pressured:
			nearby_multiplier += float(tackle_data["pressure_nearby_bonus"]) / maxf(float(pass_data["nearby_weight"]), 1.0)
		var distance_ratio := clampf(distance / float(pass_data["maximum_candidate_distance"]), 0.0, 1.0)
		var score := (1.0 - distance_ratio) * float(pass_data["nearby_weight"]) * nearby_multiplier
		score += clampf(defender_distance / float(pass_data["openness_distance"]), 0.0, 1.0) * float(pass_data["openness_weight"])
		score += support_angle_quality * float(pass_data["support_angle_weight"])
		var progress_ratio := clampf(forward_progress / field_width, -1.0, 1.0)
		var progression_weight := float(pass_data["direct_progression_weight"]) if direct_mode else float(pass_data["possession_progression_weight"])
		if is_pressured and not direct_mode:
			progression_weight *= float(tackle_data["pressure_progression_multiplier"])
		score += progress_ratio * progression_weight * float(role_profile["progression_multiplier"])
		score -= maxf(0.0, -progress_ratio) * float(pass_data["backward_pass_penalty"])
		score -= maxf(0.0, distance - float(pass_data["maximum_candidate_distance"])) / 100.0 * float(pass_data["over_range_penalty_per_100"])
		if is_pressured and forward_progress <= float(tackle_data["pressure_safe_pass_forward_limit"]):
			var outlet_quality := clampf(defender_distance / float(tackle_data["pressure_safe_pass_open_distance"]), 0.0, 1.0)
			score += float(tackle_data["pressure_safe_pass_bonus"]) * outlet_quality
		if _is_attacking_role(candidate.tactical_role):
			score += float(config["decision"]["attacking_role_receiver_bonus"]) if direct_mode else 0.0
		if team.has_instruction("direct_long_balls"):
			score += float(config["probability"]["instructions"]["direct_long_balls"]["forward_bonus"]) if forward_progress > 0.0 else 0.0
		score += _channel_receiver_bonus(team, candidate)
		if score > best_score or (is_equal_approx(score, best_score) and best_player != null and candidate.id < best_player.id):
			best_score = score
			best_player = candidate
			preferred_pass_debug = "%s: %s #%d %s | %.0fpx, angle %.2f, %s profile, score %.1f, %s%s" % [
				team.team_name, candidate.player_name, candidate.number, candidate.tactical_role, distance,
				support_angle_quality, role_profile_name, score, "open %.0fpx" % defender_distance,
				" | carrier pressure %.0fpx" % carrier_pressure if is_pressured else ""
			]
	return best_player

func _should_shoot(player: FootballPlayer, team: FootballTeam) -> bool:
	var attack_x := player.position.x / float(config["field"]["width"])
	if not team.attacks_right:
		attack_x = 1.0 - attack_x
	var threshold := float(config["thresholds"]["shot_minimum_attack_x"])
	var decision_data: Dictionary = config["decision"]
	if team.mentality == "Attacking":
		threshold -= float(decision_data["attacking_shot_threshold_bonus"])
	if team.game_plan == "Direct":
		threshold -= float(decision_data["direct_shot_threshold_bonus"])
	if team.game_plan == "Possession":
		threshold += float(decision_data["possession_shot_threshold_penalty"])
	if attack_x < threshold or not (_is_forward_role(player.tactical_role) or _is_direct_play_mode(team) or team.mentality == "Attacking"):
		return false
	var pass_data: Dictionary = decision_data["pass_selection"]
	if team.game_plan == "Possession" and not team.has_instruction("direct_long_balls"):
		if team.completed_passes_in_possession < int(pass_data["minimum_build_up_passes_before_shot"]):
			var nearest_defender := _nearest_opponent_to_position(player.position, teams[1 - player.team_index])
			var open_distance := player.position.distance_to(nearest_defender.position) if nearest_defender != null else INF
			return attack_x >= float(pass_data["clear_chance_attack_x"]) and open_distance >= float(pass_data["clear_chance_open_distance"])
	return true

func _is_direct_play_mode(team: FootballTeam) -> bool:
	return team.game_plan == "Direct" or team.game_plan == "Counter" or team.has_instruction("direct_long_balls")

func _is_fullback_role(role: String) -> bool:
	return ["LB", "RB", "LWB", "RWB"].has(role)

func _is_attacking_role(role: String) -> bool:
	return ["LW", "RW", "LM", "RM", "CAM", "LAM", "RAM", "ST", "CF"].has(role)

func _is_forward_role(role: String) -> bool:
	return ["ST", "CF"].has(role)

func _pass_role_profile(role: String) -> String:
	if role == "GK" or ["LB", "RB", "LWB", "RWB", "CB", "LCB", "RCB", "CDM", "LDM", "RDM"].has(role):
		return "defensive"
	if ["LW", "RW", "LM", "RM", "CAM", "LAM", "RAM", "ST", "CF"].has(role):
		return "attacking"
	return "central"

func get_team_play_mode(team_index: int) -> String:
	if team_index < 0 or team_index >= teams.size():
		return "Unavailable"
	var team: FootballTeam = teams[team_index]
	if team.has_instruction("direct_long_balls") or team.game_plan == "Direct":
		return "Direct"
	if team.game_plan == "Counter":
		return "Counter"
	return "Build-up / combinations"

func _nearest_opponent_to_ball(team: FootballTeam) -> FootballPlayer:
	var nearest: FootballPlayer
	var nearest_distance := INF
	for player in team.players:
		var distance := player.position.distance_to(ball_position)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = player
	return nearest

func _nearest_player(target: Vector2) -> FootballPlayer:
	var nearest: FootballPlayer
	var nearest_distance := INF
	for team in teams:
		for player in team.players:
			var distance := player.position.distance_to(target)
			if distance < nearest_distance:
				nearest_distance = distance
				nearest = player
	return nearest

func _nearest_opponent_to_position(target: Vector2, team: FootballTeam) -> FootballPlayer:
	var nearest: FootballPlayer
	var nearest_distance := INF
	for player in team.players:
		var distance := player.position.distance_to(target)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = player
	return nearest

func _nearest_outfield_player_to_position(target: Vector2, team: FootballTeam) -> FootballPlayer:
	var nearest: FootballPlayer
	var nearest_distance := INF
	for player in team.players:
		if player.role == "GK":
			continue
		var distance := player.position.distance_to(target)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = player
	return nearest

func _goalkeeper(team: FootballTeam) -> FootballPlayer:
	for player in team.players:
		if player.role == "GK":
			return player
	return null

func _channel_receiver_bonus(team: FootballTeam, candidate: FootballPlayer) -> float:
	var instruction_id := "target_left_channel" if team.has_instruction("target_left_channel") else ("target_right_channel" if team.has_instruction("target_right_channel") else "")
	if instruction_id.is_empty():
		return 0.0
	var instruction: Dictionary = config["probability"]["instructions"][instruction_id]
	var channel_y := float(instruction["channel_y"]) * float(config["field"]["height"])
	var distance := absf(candidate.position.y - channel_y)
	var maximum_distance := float(config["field"]["height"]) * float(config["decision"]["channel_distance_scale"])
	return float(instruction["receiver_bonus"]) * clampf(1.0 - distance / maximum_distance, 0.0, 1.0)

func _channel_pass_modifier(team: FootballTeam, receiver: FootballPlayer) -> float:
	return _channel_receiver_bonus(team, receiver) * float(config["probability"]["manager_tools"]["channel_probability_scale"])

func _update_tactical_positions(team: FootballTeam) -> void:
	var formation: Array = config["formations"][team.formation]
	var assigned_players: Array[FootballPlayer] = []
	var movement: Dictionary = config["probability"]["movement"]
	var instruction_data: Dictionary = config["probability"]["instructions"]
	var has_possession := ball_owner != null and ball_owner.team_index == team.players[0].team_index
	var attack_sign := 1.0 if team.attacks_right else -1.0
	var tackle_data: Dictionary = config["match"]["tackle_decision"]
	var carrier_pressure := INF
	var pressure_support_blend := 0.0
	if has_possession and ball_owner != null:
		var nearest_defender := _nearest_opponent_to_position(ball_owner.position, teams[1 - ball_owner.team_index])
		if nearest_defender != null:
			carrier_pressure = ball_owner.position.distance_to(nearest_defender.position)
			if carrier_pressure <= float(tackle_data["pressure_pass_distance"]):
				pressure_support_blend = float(tackle_data["pressure_support_blend_bonus"])
	var team_advance := float(movement["mentality_advance_x"][team.mentality]) + float(movement["game_plan_advance_x"][team.game_plan])
	if has_possession:
		team_advance += float(movement["possession_advance_x"])
	if team.has_instruction("direct_long_balls"):
		team_advance += float(instruction_data["direct_long_balls"]["forward_bonus"]) * float(movement["direct_ball_movement_factor"])
	for slot in formation:
		var slot_role := str(slot["role"])
		var player := _find_formation_player(team, slot_role, assigned_players)
		if player == null:
			push_error("Formation %s cannot assign all players for team %s." % [team.formation, team.team_name])
			return
		player.tactical_role = slot_role
		var normalized_x := float(slot["x"])
		var normalized_y := float(slot["y"])
		if not team.attacks_right:
			normalized_x = 1.0 - normalized_x
		var target := Vector2(float(config["field"]["width"]) * normalized_x, float(config["field"]["height"]) * normalized_y)
		if player.tactical_role != "GK":
			target.x += attack_sign * team_advance
			if has_possession and _is_fullback_role(player.tactical_role):
				target.x += attack_sign * float(movement["fullback_possession_advance_x"])
			if team.has_instruction("push_fullbacks") and _is_fullback_role(player.tactical_role):
				target.x += attack_sign * float(instruction_data["push_fullbacks"]["advance_x"])
			if team.has_instruction("drop_compact"):
				var compact_instruction: Dictionary = instruction_data["drop_compact"]
				target.x -= attack_sign * float(compact_instruction["drop_x"])
				var compact_factor := float(compact_instruction["compact_y"])
				target.y = lerpf(target.y, float(config["field"]["height"]) * float(movement["compact_center_y"]), compact_factor)
			if team.has_instruction("target_left_channel") or team.has_instruction("target_right_channel"):
				var channel_id := "target_left_channel" if team.has_instruction("target_left_channel") else "target_right_channel"
				var channel_y := float(instruction_data[channel_id]["channel_y"]) * float(config["field"]["height"])
				if ["LW", "RW", "LM", "RM", "LWB", "RWB", "ST", "CF"].has(player.tactical_role):
					target.y = lerpf(target.y, channel_y, float(movement["winger_channel_blend"]))
			if has_possession and ball_owner != null and player != ball_owner:
				if player.position.distance_to(ball_owner.position) <= float(movement["ball_support_radius"]):
					var support_rank := _support_rank(player, ball_owner, team, float(movement["ball_support_radius"]))
					var support_offsets: Array = movement["support_offsets"]
					if support_rank < support_offsets.size():
						var support_offset: Array = support_offsets[support_rank]
						var support_target := ball_owner.position + Vector2(
							attack_sign * float(support_offset[0]),
							float(support_offset[1])
						)
						var support_blend := clampf(
							float(movement["support_shape_blend"]) + pressure_support_blend,
							0.0, 1.0
						)
						target = target.lerp(support_target, support_blend)
		target.x = clampf(target.x, float(config["field"]["margin"]), float(config["field"]["width"]) - float(config["field"]["margin"]))
		target.y = clampf(target.y, float(config["field"]["margin"]), float(config["field"]["height"]) - float(config["field"]["margin"]))
		player.tactical_position = target
		assigned_players.append(player)

func _find_formation_player(team: FootballTeam, role: String, assigned: Array[FootballPlayer]) -> FootballPlayer:
	var fallback_roles := _formation_role_preferences(role)
	for player in team.players:
		if player.role == role and not assigned.has(player):
			return player
	for fallback_role in fallback_roles:
		for player in team.players:
			if player.role == fallback_role and not assigned.has(player):
				return player
	for player in team.players:
		if not assigned.has(player):
			return player
	return null

func _formation_role_preferences(role: String) -> Array[String]:
	match role:
		"GK":
			return ["GK"]
		"LB", "RB", "LWB", "RWB":
			return [role, "DEF", "LB", "RB", "CB", "MID", "CM"]
		"CB", "LCB", "RCB":
			return [role, "CB", "DEF", "LCB", "RCB", "LB", "RB", "MID", "CM"]
		"CDM", "LDM", "RDM":
			return [role, "CDM", "CM", "MID", "DEF", "CAM", "ATT", "LW", "RW"]
		"CM", "LCM", "RCM":
			return [role, "CM", "MID", "CDM", "CAM", "ATT", "LW", "RW"]
		"LM", "RM":
			return [role, "LW", "RW", "MID", "CM", "LM", "RM", "ATT"]
		"LW", "RW":
			return [role, "ATT", "LW", "RW", "LM", "RM", "CM", "MID"]
		"CAM", "LAM", "RAM":
			return [role, "MID", "CM", "CAM", "ATT", "LW", "RW", "ST"]
		"ST", "CF":
			return [role, "ATT", "ST", "CF", "LW", "RW", "CM", "MID"]
	return [role, "MID", "CM", "DEF", "ATT"]

func _support_rank(player: FootballPlayer, owner: FootballPlayer, team: FootballTeam, radius: float) -> int:
	var tackle_data: Dictionary = config["match"]["tackle_decision"]
	var player_score := _support_candidate_score(player, owner, radius, tackle_data)
	var rank := 0
	for teammate in team.players:
		if teammate == owner or teammate == player or teammate.tactical_role == "GK":
			continue
		var teammate_distance := teammate.position.distance_to(owner.position)
		if teammate_distance > radius:
			continue
		var teammate_score := _support_candidate_score(teammate, owner, radius, tackle_data)
		if teammate_score < player_score or (is_equal_approx(teammate_score, player_score) and teammate.id < player.id):
			rank += 1
	return rank

func _support_candidate_score(player: FootballPlayer, owner: FootballPlayer, radius: float, decision_data: Dictionary) -> float:
	var distance_ratio := player.position.distance_to(owner.position) / maxf(radius, 1.0)
	var nearest_defender := _nearest_opponent_to_position(player.position, teams[1 - player.team_index])
	var defender_distance := player.position.distance_to(nearest_defender.position) if nearest_defender != null else radius
	var openness_ratio := clampf(defender_distance / float(decision_data["pressure_pass_distance"]), 0.0, 1.0)
	return distance_ratio * float(decision_data["support_distance_weight"]) \
		- openness_ratio * float(decision_data["support_openness_weight"])

func _apply_formation(team: FootballTeam) -> void:
	_update_tactical_positions(team)
	for player in team.players:
		player.position = player.tactical_position

func _tactical_modifier(team: FootballTeam, action: String) -> float:
	var modifiers: Dictionary = config["probability"]["tactical_modifiers"]
	var mentality_modifiers: Dictionary = modifiers["mentality"]
	var plan_modifiers: Dictionary = modifiers["game_plan"]
	return float(mentality_modifiers[team.mentality]) + float(plan_modifiers[team.game_plan][action])

func _restart_after_goal() -> void:
	var kickoff_player := teams[next_kickoff_team].players[9]
	kickoff_player.position = Vector2(float(config["field"]["width"]) * 0.5, float(config["field"]["height"]) * 0.5)
	_set_possession(kickoff_player)
	_update_tactical_positions(teams[next_kickoff_team])

func _set_last_action(text: String, probability: float, formula: String) -> void:
	last_action = text
	last_probability = probability
	last_formula = formula
	event_log.append(text)
	print("[Match] %s | p=%.3f | %s" % [text, probability, formula])
	action_resolved.emit(text, probability, formula)

func _emit_state() -> void:
	state_changed.emit()

func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("Required data file not found: " + path)
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		push_error("Invalid JSON object in data file: " + path)
		return {}
	return parsed
