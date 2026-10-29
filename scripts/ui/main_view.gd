extends Node2D

const SimulationScript = preload("res://scripts/simulation/match_simulation.gd")
const ManagerControllerScript = preload("res://scripts/managers/manager_controller.gd")
const NetworkSessionScript = preload("res://scripts/network/network_session.gd")
const CONFIG_PATH := "res://data/match_config.json"

var simulation: MatchSimulation
var manager_controller: ManagerController
var network_session: NetworkSession
var field: Dictionary
var view_offset := Vector2.ZERO
var debug_visible := true
var match_started := false
var formation_names: Array[String] = []
var formation_index := 0
var status_label: Label
var debug_label: Label
var score_label: Label
var clock_label: Label
var team_button: Button
var formation_button: Button
var start_button: Button
var mentality_button: Button
var plan_button: Button
var join_address_input: LineEdit
var network_status_label: Label
var join_button: Button
var drop_link_button: Button
var action_buttons: Array[Button] = []

func _ready() -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CONFIG_PATH))
	if not parsed is Dictionary:
		push_error("Could not load match configuration: " + CONFIG_PATH)
		return
	for formation_name in parsed["formations"]:
		formation_names.append(str(formation_name))
	if formation_names.is_empty():
		push_error("Match configuration does not define any formations.")
		return
	field = parsed["field"]
	view_offset = Vector2(float(field["margin"]), float(field["margin"]) + 8.0)
	simulation = SimulationScript.new()
	simulation.name = "MatchSimulation"
	add_child(simulation)
	if not simulation.setup_match(formation_names[formation_index]):
		push_error("Could not initialize match simulation.")
		return
	manager_controller = ManagerControllerScript.new(simulation)
	network_session = NetworkSessionScript.new()
	network_session.name = "NetworkSession"
	add_child(network_session)
	network_session.configure(simulation)
	manager_controller.network_session = network_session
	simulation.state_changed.connect(_refresh_ui)
	simulation.match_finished.connect(_on_match_finished)
	network_session.status_changed.connect(_on_network_status)
	network_session.session_changed.connect(_on_network_session_changed)
	network_session.match_forfeited.connect(_on_match_forfeited)
	_create_ui()
	_refresh_ui()

func _process(_delta: float) -> void:
	if simulation != null:
		queue_redraw()
		_update_clock()

func _draw() -> void:
	if field.is_empty() or simulation == null:
		return
	var width := float(field["width"])
	var height := float(field["height"])
	var bounds := Rect2(view_offset, Vector2(width, height))
	draw_rect(bounds, Color("#267c48"))
	draw_rect(bounds, Color("#e8f2e7"), false, 3.0)
	draw_line(view_offset + Vector2(width * 0.5, 0), view_offset + Vector2(width * 0.5, height), Color("#e8f2e7"), 2.0)
	draw_arc(view_offset + Vector2(width * 0.5, height * 0.5), float(field["center_circle_radius"]), 0, TAU, 64, Color("#e8f2e7"), 2.0)
	draw_circle(view_offset + Vector2(width * 0.5, height * 0.5), 4.0, Color("#e8f2e7"))
	var box_depth := float(field["penalty_area_depth"])
	var box_height := float(field["penalty_area_height"])
	var box_y := (height - box_height) * 0.5
	draw_rect(Rect2(view_offset + Vector2(0, box_y), Vector2(box_depth, box_height)), Color("#e8f2e7"), false, 2.0)
	draw_rect(Rect2(view_offset + Vector2(width - box_depth, box_y), Vector2(box_depth, box_height)), Color("#e8f2e7"), false, 2.0)
	var goal_height := float(field["goal_width"])
	draw_rect(Rect2(view_offset + Vector2(-8, (height - goal_height) * 0.5), Vector2(8, goal_height)), Color("#f4f4f4"))
	draw_rect(Rect2(view_offset + Vector2(width, (height - goal_height) * 0.5), Vector2(8, goal_height)), Color("#f4f4f4"))
	_draw_players()
	draw_circle(view_offset + simulation.ball_position, float(field["ball_radius"]), Color("#fff9df"))
	draw_circle(view_offset + simulation.ball_position, float(field["ball_radius"]), Color("#292929"), false, 1.2)

func _draw_players() -> void:
	var font := ThemeDB.fallback_font
	for team in simulation.teams:
		for player in team.players:
			var center := view_offset + player.position
			var radius := float(field["player_radius"])
			draw_circle(center, radius, team.color)
			draw_circle(center, radius, Color("#10231a"), false, 1.5)
			draw_string(font, center + Vector2(-6, 5), str(player.number), HORIZONTAL_ALIGNMENT_CENTER, 16, 11, Color.WHITE)
			if player == simulation.ball_owner:
				draw_arc(center, radius + 4.0, 0, TAU, 24, Color("#ffe173"), 2.0)

func _create_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(10, 8)
	panel.custom_minimum_size = Vector2(1060, 44)
	layer.add_child(panel)
	var row := HBoxContainer.new()
	panel.add_child(row)
	start_button = Button.new()
	start_button.text = "Start match"
	start_button.pressed.connect(_start_match)
	row.add_child(start_button)
	formation_button = Button.new()
	formation_button.text = "Formation: " + formation_names[formation_index]
	formation_button.pressed.connect(_cycle_formation)
	row.add_child(formation_button)
	team_button = Button.new()
	team_button.text = "Managing: Northbridge"
	team_button.pressed.connect(_toggle_managed_team)
	row.add_child(team_button)
	mentality_button = Button.new()
	mentality_button.text = "Mentality: Balanced"
	mentality_button.pressed.connect(_cycle_mentality)
	row.add_child(mentality_button)
	plan_button = Button.new()
	plan_button.text = "Plan: Possession"
	plan_button.pressed.connect(_cycle_game_plan)
	row.add_child(plan_button)
	var debug_button := Button.new()
	debug_button.text = "Debug (F1)"
	debug_button.pressed.connect(_toggle_debug)
	row.add_child(debug_button)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	status_label = Label.new()
	status_label.text = "Ready"
	row.add_child(status_label)
	var network_panel := PanelContainer.new()
	network_panel.position = Vector2(10, 54)
	network_panel.custom_minimum_size = Vector2(1060, 34)
	layer.add_child(network_panel)
	var network_row := HBoxContainer.new()
	network_panel.add_child(network_row)
	var host_button := Button.new()
	host_button.text = "Host PVP"
	host_button.pressed.connect(_host_pvp)
	network_row.add_child(host_button)
	var local_button := Button.new()
	local_button.text = "Local vs AI"
	local_button.pressed.connect(_select_local_ai)
	network_row.add_child(local_button)
	join_address_input = LineEdit.new()
	join_address_input.placeholder_text = "Host IP (e.g. 192.168.1.5)"
	join_address_input.text = "127.0.0.1"
	join_address_input.custom_minimum_size = Vector2(190, 0)
	network_row.add_child(join_address_input)
	join_button = Button.new()
	join_button.text = "Join PVP"
	join_button.pressed.connect(_join_pvp)
	network_row.add_child(join_button)
	drop_link_button = Button.new()
	drop_link_button.text = "Drop link (test)"
	drop_link_button.pressed.connect(_drop_pvp_link)
	network_row.add_child(drop_link_button)
	network_status_label = Label.new()
	network_status_label.text = "Offline / AI"
	network_row.add_child(network_status_label)
	score_label = Label.new()
	score_label.position = Vector2(420, 94)
	score_label.add_theme_font_size_override("font_size", 22)
	layer.add_child(score_label)
	clock_label = Label.new()
	clock_label.position = Vector2(970, 100)
	clock_label.add_theme_font_size_override("font_size", 16)
	layer.add_child(clock_label)
	debug_label = Label.new()
	debug_label.position = Vector2(10, 565)
	debug_label.custom_minimum_size = Vector2(1080, 130)
	debug_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	debug_label.add_theme_color_override("font_color", Color("#f4f3d9"))
	debug_label.add_theme_font_size_override("font_size", 13)
	layer.add_child(debug_label)
	var action_panel := PanelContainer.new()
	action_panel.position = Vector2(60, 660)
	action_panel.custom_minimum_size = Vector2(980, 32)
	layer.add_child(action_panel)
	var action_row := HBoxContainer.new()
	action_panel.add_child(action_row)
	_add_action_button(action_row, "Sub selected (U)", _substitute_selected)
	_add_action_button(action_row, "Push FB (Z)", _activate_instruction.bind("push_fullbacks"))
	_add_action_button(action_row, "Compact (X)", _activate_instruction.bind("drop_compact"))
	_add_action_button(action_row, "Left channel (C)", _activate_instruction.bind("target_left_channel"))
	_add_action_button(action_row, "Right channel (V)", _activate_instruction.bind("target_right_channel"))
	_add_action_button(action_row, "Press #6 (B)", _activate_instruction.bind("press_pivot"))
	_add_action_button(action_row, "Long balls (N)", _activate_instruction.bind("direct_long_balls"))

func _add_action_button(parent: HBoxContainer, text: String, callback: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.add_theme_font_size_override("font_size", 11)
	button.pressed.connect(callback)
	parent.add_child(button)
	action_buttons.append(button)

func _start_match() -> void:
	if simulation == null or match_started:
		return
	var did_start := false
	if network_session.mode == "host":
		did_start = network_session.start_pvp_match(formation_names[formation_index])
	elif network_session.mode == "client":
		status_label.text = "Waiting for the host to start the match."
		return
	else:
		did_start = network_session.start_local_match(formation_names[formation_index])
	if not did_start:
		status_label.text = "Start unavailable; in a PVP lobby, wait for a manager to join."
		return
	match_started = true
	formation_button.disabled = true
	start_button.disabled = true
	status_label.text = "LIVE | manager controls locked to your PVP team" if network_session.mode != "offline" else "LIVE | T team | 1-3 mentality | Q-E plan | U sub | Z-N instructions"
	_on_network_session_changed()

func _host_pvp() -> void:
	if match_started:
		return
	var result := network_session.host_game(int(simulation.config["network"]["default_port"]), false)
	if result == OK:
		match_started = false
		manager_controller.team_index = network_session.local_team_index
		status_label.text = "Waiting for opponent on UDP %d." % int(simulation.config["network"]["default_port"])
		_on_network_session_changed()

func _select_local_ai() -> void:
	if match_started:
		return
	network_session.host_game(int(simulation.config["network"]["default_port"]), true)
	manager_controller.team_index = 0
	start_button.disabled = false
	formation_button.disabled = false
	_on_network_session_changed()

func _join_pvp() -> void:
	var can_reconnect := (
		network_session.mode == "client"
		and network_session.match_started
		and network_session.disconnect_clock >= 0.0
	)
	if match_started and not can_reconnect:
		return
	var result := network_session.join_game(
		join_address_input.text.strip_edges(),
		int(simulation.config["network"]["default_port"])
	)
	if result == OK:
		status_label.text = "Connecting to PVP host..."
		_on_network_session_changed()

func _drop_pvp_link() -> void:
	network_session.simulate_connection_drop()

func _cycle_formation() -> void:
	if match_started:
		return
	var starting_mentalities: Array[String] = [simulation.teams[0].mentality, simulation.teams[1].mentality]
	var starting_game_plans: Array[String] = [simulation.teams[0].game_plan, simulation.teams[1].game_plan]
	formation_index = (formation_index + 1) % formation_names.size()
	formation_button.text = "Formation: " + formation_names[formation_index]
	simulation.setup_match(formation_names[formation_index])
	for team_index in range(simulation.teams.size()):
		simulation.change_mentality(starting_mentalities[team_index], team_index)
		simulation.change_game_plan(starting_game_plans[team_index], team_index)
	_refresh_ui()

func _cycle_mentality() -> void:
	if simulation == null or simulation.finished:
		return
	var changed := manager_controller.cycle_mentality()
	if not changed:
		status_label.text = _manager_action_failure("mentality")

func _cycle_game_plan() -> void:
	if simulation == null or simulation.finished:
		return
	var changed := manager_controller.cycle_game_plan()
	if not changed:
		status_label.text = _manager_action_failure("game plan")

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_F1:
			_toggle_debug()
		KEY_TAB:
			if simulation != null:
				simulation.cycle_selected_player(manager_controller.team_index)
		KEY_T:
			_toggle_managed_team()
		KEY_1:
			if simulation != null and (simulation.active or not match_started):
				_request_mentality("Cautious")
		KEY_2:
			if simulation != null and (simulation.active or not match_started):
				_request_mentality("Balanced")
		KEY_3:
			if simulation != null and (simulation.active or not match_started):
				_request_mentality("Attacking")
		KEY_Q:
			if simulation != null and (simulation.active or not match_started):
				_request_game_plan("Possession")
		KEY_W:
			if simulation != null and (simulation.active or not match_started):
				_request_game_plan("Direct")
		KEY_E:
			if simulation != null and (simulation.active or not match_started):
				_request_game_plan("Counter")
		KEY_U:
			_substitute_selected()
		KEY_Z:
			_activate_instruction("push_fullbacks")
		KEY_X:
			_activate_instruction("drop_compact")
		KEY_C:
			_activate_instruction("target_left_channel")
		KEY_V:
			_activate_instruction("target_right_channel")
		KEY_B:
			_activate_instruction("press_pivot")
		KEY_N:
			_activate_instruction("direct_long_balls")

func _toggle_debug() -> void:
	debug_visible = not debug_visible
	if debug_label != null:
		debug_label.visible = debug_visible

func _toggle_managed_team() -> void:
	if simulation == null or match_started and not simulation.active:
		return
	if network_session.mode != "offline":
		return
	manager_controller.toggle_team()
	_refresh_ui()

func _substitute_selected() -> void:
	if simulation == null:
		return
	if manager_controller.substitute_selected_player():
		_show_command_feedback("Substitution")
	else:
		status_label.text = _manager_action_failure("substitution")

func _activate_instruction(instruction_id: String) -> void:
	if simulation == null:
		return
	if manager_controller.activate_instruction(instruction_id):
		_show_command_feedback("Instruction")
	else:
		status_label.text = _manager_action_failure("instruction")

func _request_mentality(value: String) -> void:
	if manager_controller.set_mentality(value):
		_show_command_feedback("Mentality")
	else:
		status_label.text = _manager_action_failure("mentality")

func _request_game_plan(value: String) -> void:
	if manager_controller.set_game_plan(value):
		_show_command_feedback("Game plan")
	else:
		status_label.text = _manager_action_failure("game plan")

func _show_command_feedback(command_name: String) -> void:
	if network_session.mode == "offline":
		status_label.text = "%s changed." % command_name
	elif network_session.mode == "host":
		status_label.text = "%s command scheduled provisionally; outcome is decided at execution." % command_name
	else:
		status_label.text = "%s command sent; waiting for host confirmation." % command_name

func _manager_action_failure(action_name: String) -> String:
	var team: FootballTeam = simulation.teams[manager_controller.team_index]
	if simulation.is_team_ai_controlled(manager_controller.team_index):
		return "%s is controlled by the opponent AI." % team.team_name
	if not simulation.active:
		return "Start the match before using %s." % action_name
	if action_name == "substitution" and team.substitutions_used >= int(simulation.config["match"]["substitution_limit"]):
		return "No substitutions remain."
	if action_name == "instruction" and team.instruction_cooldown > 0.0:
		return "Instruction cooldown: %.1fs" % team.instruction_cooldown
	return "%s unavailable; tactical points %.1f, cooldown %.1fs." % [
		action_name.capitalize(), team.tactical_points, team.change_cooldown
	]

func _refresh_ui() -> void:
	if simulation == null or simulation.teams.size() != 2 or score_label == null:
		return
	var home: FootballTeam = simulation.teams[0]
	var away: FootballTeam = simulation.teams[1]
	var managed: FootballTeam = simulation.teams[manager_controller.team_index]
	score_label.text = "%s  %d  –  %d  %s" % [home.team_name, home.score, away.score, away.team_name]
	mentality_button.text = "Mentality: " + managed.mentality
	plan_button.text = "Plan: " + managed.game_plan
	team_button.text = "Managing: " + managed.team_name
	if simulation.is_team_ai_controlled(manager_controller.team_index):
		team_button.text += " (AI)"
	var selected := simulation.get_selected_player(manager_controller.team_index)
	if selected == null:
		return
	debug_label.text = "HOME %s/%s | AWAY %s/%s | H%d | Managed: %s\nHOME TP %.1f / Subs %d / %s\nAWAY TP %.1f / Subs %d / %s\nPlay: HOME %s (%d passes) | AWAY %s (%d passes)\nPass target: %s\nDefence: %s\nShot on target %s | GK save %s | Rebound %s\nSelected #%d %s | Form %+.2f | Fatigue %.1f%% | Stamina %.1f%%\nLast: %s (P=%.3f) | %s\nNetwork: %s" % [
		home.mentality, home.game_plan, away.mentality, away.game_plan,
		simulation.half_index + 1, managed.team_name,
		home.tactical_points, int(simulation.config["match"]["substitution_limit"]) - home.substitutions_used,
		_format_instructions(home),
		away.tactical_points, int(simulation.config["match"]["substitution_limit"]) - away.substitutions_used,
		_format_instructions(away),
		simulation.get_team_play_mode(0), home.completed_passes_in_possession,
		simulation.get_team_play_mode(1), away.completed_passes_in_possession,
		simulation.preferred_pass_debug,
		simulation.last_defensive_decision,
		_probability_text(simulation.last_shot_on_target_probability),
		_probability_text(simulation.last_goalkeeper_save_probability),
		_probability_text(simulation.last_rebound_probability),
		selected.number, selected.player_name, selected.form, selected.fatigue * 100.0, selected.stamina,
		simulation.last_action, simulation.last_probability, simulation.last_formula,
		network_session.get_network_debug_text()
	]
	_update_clock()

func _probability_text(probability: float) -> String:
	return "n/a" if probability < 0.0 else "%.3f" % probability

func _format_instructions(team: FootballTeam) -> String:
	if team.instructions.is_empty():
		return "none"
	var text := ""
	for instruction in team.instructions:
		if not text.is_empty():
			text += ", "
		text += "%s (%.0fs)" % [str(instruction["id"]).replace("_", " "), float(instruction["remaining"])]
	return text

func _update_clock() -> void:
	if clock_label == null or simulation == null:
		return
	var half_duration := float(simulation.config["match"]["half_duration_seconds"])
	var half := 1 if simulation.elapsed_seconds < half_duration else 2
	var half_elapsed := simulation.elapsed_seconds if half == 1 else simulation.elapsed_seconds - half_duration
	var shown_seconds := int(minf(half_elapsed, half_duration))
	var minute := int(shown_seconds / 60.0)
	var second := shown_seconds % 60
	clock_label.text = "H%d  %02d:%02d" % [half, minute, second]

func _on_match_finished(home_score: int, away_score: int) -> void:
	status_label.text = "FULL TIME — Final score: %d - %d" % [home_score, away_score]

func _on_network_status(message: String) -> void:
	if status_label != null:
		status_label.text = message

func _on_network_session_changed() -> void:
	if network_session == null or status_label == null:
		return
	if network_session.mode == "client" and network_session.local_team_index >= 0:
		manager_controller.team_index = network_session.local_team_index
	if network_status_label != null:
		network_status_label.text = network_session.get_lobby_status()
	if join_button != null:
		var reconnect_available := network_session.mode == "client" \
			and network_session.match_started and network_session.disconnect_clock >= 0.0
		join_button.text = "Reconnecting..." if network_session.reconnecting else ("Reconnect" if reconnect_available else "Join PVP")
		join_button.disabled = network_session.reconnecting
	if drop_link_button != null:
		drop_link_button.disabled = network_session.mode != "client" or not network_session.match_started or network_session.reconnecting
	if start_button != null and not match_started:
		start_button.disabled = network_session.mode == "client" or (
			network_session.mode == "host" and not network_session.can_host_start()
		)
	if formation_button != null and not match_started:
		formation_button.disabled = network_session.mode == "client"
	_refresh_ui()

func _on_match_forfeited(winner_team: int) -> void:
	var winner_name := str(simulation.config["teams"][winner_team]["name"])
	status_label.text = "%s wins by disconnect forfeit." % winner_name
