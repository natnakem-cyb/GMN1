extends Node3D

const CONFIG_PATH := "res://data/match_config.json"

var simulation: MatchSimulation
var field: Dictionary = {}
var ball_data: Dictionary = {}
var view_data: Dictionary = {}
var metres_per_pixel := 0.105
var pitch_width := 0.0
var pitch_depth := 0.0
var ball_mesh: MeshInstance3D
var player_nodes: Dictionary = {}
var last_seen_event_count := 0
var goal_visual_position := Vector3.ZERO
var goal_visual_remaining := 0.0

func configure(match_simulation: MatchSimulation, field_config: Dictionary, flight_config: Dictionary, pitch_view_config: Dictionary) -> void:
	simulation = match_simulation
	field = field_config
	ball_data = flight_config
	view_data = pitch_view_config
	metres_per_pixel = float(ball_data["metres_per_pixel"])
	pitch_width = float(field["width"]) * metres_per_pixel
	pitch_depth = float(field["height"]) * metres_per_pixel
	last_seen_event_count = simulation.event_log.size()
	_build_pitch()
	_build_goals()
	_build_ball()
	_sync_players()
	_sync_dynamic_state()

func _process(delta: float) -> void:
	if simulation == null:
		return
	goal_visual_remaining = maxf(0.0, goal_visual_remaining - delta)
	_sync_players()
	_sync_dynamic_state()

func _build_pitch() -> void:
	var ground := MeshInstance3D.new()
	var ground_mesh := PlaneMesh.new()
	ground_mesh.size = Vector2(pitch_width, pitch_depth)
	ground.mesh = ground_mesh
	ground.position = Vector3(pitch_width * 0.5, -0.035, pitch_depth * 0.5)
	ground.material_override = _material(Color("#287c49"))
	add_child(ground)

	var line_color := Color("#e7f0dc")
	var line_width := float(view_data.get("marking_width_px", 1.5)) * metres_per_pixel
	_add_line(Vector2(0.0, 0.0), Vector2(float(field["width"]), 0.0), line_width, line_color)
	_add_line(Vector2(float(field["width"]), 0.0), Vector2(float(field["width"]), float(field["height"])), line_width, line_color)
	_add_line(Vector2(float(field["width"]), float(field["height"])), Vector2(0.0, float(field["height"])), line_width, line_color)
	_add_line(Vector2(0.0, float(field["height"])), Vector2(0.0, 0.0), line_width, line_color)
	_add_line(Vector2(float(field["width"]) * 0.5, 0.0), Vector2(float(field["width"]) * 0.5, float(field["height"])), line_width, line_color)
	_add_circle(Vector2(float(field["width"]) * 0.5, float(field["height"]) * 0.5), float(field["center_circle_radius"]), line_width, line_color)
	_add_spot(Vector2(float(field["width"]) * 0.5, float(field["height"]) * 0.5), line_width * 1.7, line_color)

	var box_depth_px := float(field["penalty_area_depth"])
	var box_half_px := float(field["penalty_area_height"]) * 0.5
	var middle_y := float(field["height"]) * 0.5
	for goal_x_value in [0.0, float(field["width"])]:
		var goal_x: float = float(goal_x_value)
		var inward := 1.0 if goal_x == 0.0 else -1.0
		var box_back_x := goal_x + inward * box_depth_px
		_add_line(Vector2(goal_x, middle_y - box_half_px), Vector2(box_back_x, middle_y - box_half_px), line_width, line_color)
		_add_line(Vector2(box_back_x, middle_y - box_half_px), Vector2(box_back_x, middle_y + box_half_px), line_width, line_color)
		_add_line(Vector2(box_back_x, middle_y + box_half_px), Vector2(goal_x, middle_y + box_half_px), line_width, line_color)
		var goal_area_depth := float(simulation.config["match"]["restarts"]["goal_area_depth"])
		var goal_area_half := float(simulation.config["match"]["restarts"]["goal_area_width"]) * 0.5
		var goal_area_back_x := goal_x + inward * goal_area_depth
		_add_line(Vector2(goal_x, middle_y - goal_area_half), Vector2(goal_area_back_x, middle_y - goal_area_half), line_width, line_color)
		_add_line(Vector2(goal_area_back_x, middle_y - goal_area_half), Vector2(goal_area_back_x, middle_y + goal_area_half), line_width, line_color)
		_add_line(Vector2(goal_area_back_x, middle_y + goal_area_half), Vector2(goal_x, middle_y + goal_area_half), line_width, line_color)
		var spot_distance_px := 11000.0 / float(field["pitch_length_m"])
		_add_spot(Vector2(goal_x + inward * spot_distance_px, middle_y), line_width * 1.7, line_color)

	var environment := WorldEnvironment.new()
	var environment_resource := Environment.new()
	environment_resource.background_mode = Environment.BG_COLOR
	environment_resource.background_color = Color("#18251c")
	environment.environment = environment_resource
	add_child(environment)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-52.0, -24.0, 0.0)
	light.light_energy = 1.15
	add_child(light)

	var camera := Camera3D.new()
	camera.name = "PitchCamera"
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = float(view_data.get("camera_vertical_size_px", 670.0)) * metres_per_pixel
	camera.current = true
	var target := Vector3(pitch_width * 0.5, 0.0, pitch_depth * 0.5)
	var elevation := deg_to_rad(float(view_data.get("camera_elevation_degrees", 70.0)))
	var camera_distance := pitch_width * 1.1
	camera.position = target + Vector3(0.0, sin(elevation) * camera_distance, cos(elevation) * camera_distance)
	add_child(camera)
	camera.look_at(target, Vector3.UP)

func _build_goals() -> void:
	var goal_width_px := float(ball_data["goal_width_px"])
	var goal_height_px := float(ball_data["goal_height_px"])
	var post_radius_px := float(ball_data["post_radius_px"])
	var net_depth := float(view_data.get("net_depth_m", 3.0))
	var post_material := _material(Color("#f5f4e9"))
	var net_material := _material(Color(0.9, 0.95, 0.9, float(view_data.get("net_opacity", 0.42))), true)
	var center_y := float(field["height"]) * 0.5
	var half_goal_width := goal_width_px * 0.5
	var goal_height_m := goal_height_px * metres_per_pixel
	var post_radius_m := post_radius_px * metres_per_pixel
	var bar_radius_m := float(ball_data["crossbar_radius_px"]) * metres_per_pixel
	var net_depth_px := net_depth / metres_per_pixel
	for goal_x_value in [0.0, float(field["width"])]:
		var goal_x: float = float(goal_x_value)
		var outward := -1.0 if goal_x == 0.0 else 1.0
		for side in [-1.0, 1.0]:
			_add_cylinder(
				Vector3(goal_x * metres_per_pixel, goal_height_m * 0.5, (center_y + side * half_goal_width) * metres_per_pixel),
				post_radius_m, goal_height_m, post_material
			)
		_add_cylinder(
			Vector3(goal_x * metres_per_pixel, goal_height_m, center_y * metres_per_pixel),
			bar_radius_m, goal_width_px * metres_per_pixel, post_material, true
		)
		var back_x_px: float = goal_x + outward * net_depth_px
		var back_x: float = back_x_px * metres_per_pixel
		var z_min := (center_y - half_goal_width) * metres_per_pixel
		var z_max := (center_y + half_goal_width) * metres_per_pixel
		var net_rows := int(view_data.get("net_rows", 4))
		var net_columns := int(view_data.get("net_columns", 8))
		for row in range(net_rows + 1):
			var y := goal_height_m * float(row) / float(net_rows)
			_add_beam(Vector3(back_x, y, z_min), Vector3(back_x, y, z_max), net_material, 0.018)
			_add_beam(Vector3(goal_x * metres_per_pixel, y, z_min), Vector3(back_x, y, z_min), net_material, 0.018)
			_add_beam(Vector3(goal_x * metres_per_pixel, y, z_max), Vector3(back_x, y, z_max), net_material, 0.018)
		for column in range(net_columns + 1):
			var z := lerpf(z_min, z_max, float(column) / float(net_columns))
			_add_beam(Vector3(back_x, 0.0, z), Vector3(back_x, goal_height_m, z), net_material, 0.018)
			_add_beam(Vector3(goal_x * metres_per_pixel, goal_height_m, z), Vector3(back_x, goal_height_m, z), net_material, 0.018)
		for side in [-1.0, 1.0]:
			_add_beam(
				Vector3(goal_x * metres_per_pixel, goal_height_m, (center_y + side * half_goal_width) * metres_per_pixel),
				Vector3(back_x, goal_height_m, (center_y + side * half_goal_width) * metres_per_pixel),
				net_material, 0.018
			)

func _build_ball() -> void:
	ball_mesh = MeshInstance3D.new()
	ball_mesh.name = "SimulationBall"
	var sphere := SphereMesh.new()
	sphere.radius = float(ball_data["ball_radius_px"]) * metres_per_pixel
	sphere.height = sphere.radius * 2.0
	ball_mesh.mesh = sphere
	ball_mesh.material_override = _material(Color("#fff9df"))
	add_child(ball_mesh)

func _sync_dynamic_state() -> void:
	if ball_mesh == null:
		return
	var events: Array = simulation.event_log
	if last_seen_event_count > events.size():
		last_seen_event_count = 0
	for event_index in range(last_seen_event_count, events.size()):
		var event_text := str(events[event_index])
		if not event_text.contains("[Ball] goal volume entered by "):
			continue
		var coordinate_start := event_text.find(" at (")
		if coordinate_start < 0:
			continue
		var components := event_text.substr(coordinate_start + 5).trim_suffix(")").split(",")
		if components.size() == 3:
			goal_visual_position = Vector3(
				float(str(components[0]).strip_edges()),
				float(str(components[1]).strip_edges()),
				float(str(components[2]).strip_edges())
			)
			goal_visual_remaining = float(view_data.get("goal_display_seconds", 0.65))
	last_seen_event_count = events.size()
	if goal_visual_remaining > 0.0:
		ball_mesh.position = _to_world(goal_visual_position)
		return
	var ball_position: Vector3 = simulation.ball_position_3d
	ball_mesh.position = _to_world(ball_position)
	ball_mesh.visible = true

func _sync_players() -> void:
	if simulation == null:
		return
	var active_keys: Dictionary = {}
	for team in simulation.teams:
		for player in team.players:
			if not player.on_pitch:
				continue
			var key := "%d:%d" % [player.team_index, player.id]
			active_keys[key] = true
			if not player_nodes.has(key):
				player_nodes[key] = _create_player_marker(team.color, player.number)
			var marker: Node3D = player_nodes[key]
			marker.visible = true
			marker.position = Vector3(player.position.x * metres_per_pixel, 0.0, player.position.y * metres_per_pixel)
			var ring: Node3D = marker.get_node("SelectionRing")
			ring.visible = player == simulation.get_selected_player(player.team_index) or player == simulation.ball_owner
		for key in player_nodes.keys():
			if not active_keys.has(key):
				player_nodes[key].visible = false

func _create_player_marker(team_color: Color, shirt_number: int) -> Node3D:
	var marker := Node3D.new()
	marker.name = "Player_%d" % shirt_number
	var player_radius := float(field["player_radius"]) * metres_per_pixel
	var disc := MeshInstance3D.new()
	var disc_mesh := CylinderMesh.new()
	disc_mesh.top_radius = player_radius
	disc_mesh.bottom_radius = player_radius
	disc_mesh.height = 0.12
	disc.mesh = disc_mesh
	disc.position.y = 0.06
	disc.material_override = _material(team_color)
	marker.add_child(disc)
	var label := Label3D.new()
	label.text = str(shirt_number)
	label.font_size = 42
	label.pixel_size = 0.005
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.modulate = Color.WHITE
	label.outline_size = 8
	label.position.y = 0.13
	marker.add_child(label)
	var ring := Node3D.new()
	ring.name = "SelectionRing"
	ring.position.y = 0.015
	ring.visible = false
	var segments := 32
	var ring_radius := player_radius * 1.18
	for segment in range(segments):
		var a0 := TAU * float(segment) / float(segments)
		var a1 := TAU * float(segment + 1) / float(segments)
		_add_line_to(ring, Vector2(cos(a0) * ring_radius / metres_per_pixel, sin(a0) * ring_radius / metres_per_pixel), Vector2(cos(a1) * ring_radius / metres_per_pixel, sin(a1) * ring_radius / metres_per_pixel), 1.5, Color("#ffe173"))
	marker.add_child(ring)
	add_child(marker)
	return marker

func _to_world(position: Vector3) -> Vector3:
	return Vector3(position.x * metres_per_pixel, position.z * metres_per_pixel, position.y * metres_per_pixel)

func _material(color: Color, transparent: bool = false) -> StandardMaterial3D:
	var result := StandardMaterial3D.new()
	result.albedo_color = color
	result.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if transparent:
		result.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		result.cull_mode = BaseMaterial3D.CULL_DISABLED
	return result

func _add_spot(position_px: Vector2, radius_m: float, color: Color) -> void:
	var spot := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = radius_m
	mesh.height = radius_m * 2.0
	spot.mesh = mesh
	spot.scale = Vector3(1.0, 0.05, 1.0)
	spot.position = Vector3(position_px.x * metres_per_pixel, 0.015, position_px.y * metres_per_pixel)
	spot.material_override = _material(color)
	add_child(spot)

func _add_circle(center_px: Vector2, radius_px: float, line_width_m: float, color: Color) -> void:
	var segments := 64
	for segment in range(segments):
		var a0 := TAU * float(segment) / float(segments)
		var a1 := TAU * float(segment + 1) / float(segments)
		_add_line(center_px + Vector2(cos(a0), sin(a0)) * radius_px, center_px + Vector2(cos(a1), sin(a1)) * radius_px, line_width_m, color)

func _add_line(start_px: Vector2, end_px: Vector2, width_m: float, color: Color) -> void:
	_add_line_to(self, start_px, end_px, width_m / metres_per_pixel, color)

func _add_line_to(parent: Node3D, start_px: Vector2, end_px: Vector2, width_px: float, color: Color) -> void:
	var delta := end_px - start_px
	var length_m := delta.length() * metres_per_pixel
	if length_m <= 0.001:
		return
	var beam := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(length_m, 0.018, width_px * metres_per_pixel)
	beam.mesh = mesh
	beam.position = Vector3((start_px.x + end_px.x) * 0.5 * metres_per_pixel, 0.014, (start_px.y + end_px.y) * 0.5 * metres_per_pixel)
	beam.rotation.y = -atan2(delta.y, delta.x)
	beam.material_override = _material(color)
	parent.add_child(beam)

func _add_beam(start: Vector3, end: Vector3, beam_material: Material, thickness: float) -> void:
	var beam := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	var delta := end - start
	mesh.size = Vector3(maxf(delta.length(), thickness), thickness, thickness)
	beam.mesh = mesh
	beam.position = (start + end) * 0.5
	if absf(delta.y) > absf(delta.x) and absf(delta.y) > absf(delta.z):
		beam.rotation.z = PI * 0.5
	elif absf(delta.z) > absf(delta.x):
		beam.rotation.y = -PI * 0.5
	beam.material_override = beam_material
	add_child(beam)

func _add_cylinder(position: Vector3, radius: float, length: float, cylinder_material: Material, horizontal: bool = false) -> void:
	var cylinder := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = length
	cylinder.mesh = mesh
	cylinder.position = position
	if horizontal:
		cylinder.rotation.x = PI * 0.5
	cylinder.material_override = cylinder_material
	add_child(cylinder)
